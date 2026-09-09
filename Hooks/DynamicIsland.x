#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

static void LGDILog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDILog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI] %@", s);
}

#pragma mark - Cross-process glyph mask

static NSString *LGDIMaskPath(void) {
    return @"/var/mobile/Library/Accessibility/liquidglass-dynamicisland-mask.bin";
}
static CFStringRef const LGDIMaskReloadNotification =
    CFSTR("dylv.liquidglass/DynamicIslandMaskReload");

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    float    imageScale;
    float    bezelWidthPoints;
    float    originX;
    float    originY;
    uint64_t generation;
} LGDynamicIslandMaskHeader;

#define LG_DI_MASK_MAGIC 0x4c474449 // "LGDI"

static BOOL LGDIWriteMaskImage(UIImage *image, CGPoint screenOrigin, uint64_t generation) {
    CGImageRef cg = image.CGImage;
    if (!cg) return NO;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    if (!width || !height || width > UINT32_MAX || height > UINT32_MAX) return NO;

    size_t rgbaBytes = width * height * 4;
    uint8_t *rgba = (uint8_t *)calloc(1, rgbaBytes);
    uint8_t *alpha = (uint8_t *)malloc(width * height);
    BOOL wrote = NO;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = rgba && alpha
        ? CGBitmapContextCreate(rgba, width, height, 8, width * 4, colorSpace,
                                kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast)
        : NULL;
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
        for (size_t i = 0; i < width * height; i++) alpha[i] = rgba[i * 4 + 3];

        LGDynamicIslandMaskHeader header = {
            LG_DI_MASK_MAGIC,
            (uint32_t)width,
            (uint32_t)height,
            (float)MAX(image.scale, 1.0),
            18.0f,
            (float)screenOrigin.x,
            (float)screenOrigin.y,
            generation,
        };
        NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
        [data appendBytes:alpha length:width * height];
        if ([data writeToFile:LGDIMaskPath() options:NSDataWritingAtomic error:nil]) {
            wrote = YES;
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 LGDIMaskReloadNotification,
                                                 NULL, NULL, true);
        }
    }
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    free(alpha);
    free(rgba);
    return wrote;
}

static inline BOOL LGIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}
static inline BOOL LGIsAtLeastiOS16(void) {
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}

#pragma mark - Dynamic Island Glass View

static void *kLGDIGlassViewKey = &kLGDIGlassViewKey;
static void *kLGDIMaskLayerKey = &kLGDIMaskLayerKey;
static void *kLGDIAttachedKey = &kLGDIAttachedKey;

static uint64_t sLGDIMaskNextGeneration = 0;
static NSTimer *sLGDIScanTimer = nil;
static UIView *sLGDIIslandView = nil; // 找到的灵动岛视图
static LGLiveBackdropView *sLGDIGlassView = nil;

// 递归打印视图层级
static NSString *LGDIDumpViewHierarchy(UIView *view, NSInteger indent) {
    NSMutableString *result = [NSMutableString string];
    NSString *indentStr = [@"" stringByPaddingToLength:indent * 2 withString:@"  " startingAtIndex:0];
    NSString *clsName = NSStringFromClass(view.class);
    CGRect frame = view.frame;
    CGFloat alpha = view.alpha;
    BOOL hidden = view.hidden;
    UIColor *bgColor = view.backgroundColor;
    NSString *bgDesc = bgColor ? [bgColor description] : @"(nil)";
    if (bgDesc.length > 50) bgDesc = [bgDesc substringToIndex:50];

    [result appendFormat:@"%@<%@: hidden=%d alpha=%.2f frame=%.1f,%.1f %.1fx%.1f bg=%@>\n",
                         indentStr, clsName, hidden, alpha,
                         frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                         bgDesc];

    for (UIView *subview in view.subviews) {
        [result appendString:LGDIDumpViewHierarchy(subview, indent + 1)];
    }
    return result;
}

// 递归查找灵动岛视图
// 在 iOS 17+ 上，灵动岛相关的视图类名可能包含 "Island"
// 也可能是不包含 "Island" 但有特定特征的视图
static UIView *LGDIFindIslandViewRecursive(UIView *view, CGFloat screenWidth) {
    if (!view) return nil;

    NSString *clsName = NSStringFromClass(view.class);

    // 检查类名是否包含 Island
    if ([clsName containsString:@"Island"] || [clsName containsString:@"island"]) {
        // 进一步检查：位置在屏幕顶部中间区域
        CGRect f = view.frame;
        // 灵动岛通常在屏幕顶部，y < 50，宽度小于屏幕宽度
        if (f.origin.y < 60 && f.size.width < screenWidth && f.size.width > 50) {
            return view;
        }
    }

    // 递归查找子视图
    for (UIView *subview in view.subviews) {
        UIView *found = LGDIFindIslandViewRecursive(subview, screenWidth);
        if (found) return found;
    }
    return nil;
}

// 渲染视图为 alpha mask 图片
static UIImage *LGDIRenderAlphaMaskFromView(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return nil;

    CGSize size = view.bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;

    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    [view.layer renderInContext:ctx];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

// 更新 glassView 的 layer mask
static void LGDIUpdateGlassMask(UIView *glassView, UIImage *maskImage) {
    if (!glassView || !maskImage) return;

    CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIMaskLayerKey);
    if (!maskLayer) {
        maskLayer = [CALayer layer];
        maskLayer.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(glassView, kLGDIMaskLayerKey, maskLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.layer.mask = maskLayer;
    }

    maskLayer.frame = glassView.bounds;
    maskLayer.contents = (__bridge id _Nullable)(maskImage.CGImage);
}

// 更新 mask
static void LGDIUpdateMask(UIView *sourceView, UIView *glassView) {
    if (!sourceView || !sourceView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;

    CGPoint origin = [sourceView convertPoint:CGPointZero toView:nil];

    UIImage *maskImage = LGDIRenderAlphaMaskFromView(sourceView);
    if (!maskImage) return;

    if (glassView) {
        LGDIUpdateGlassMask(glassView, maskImage);
    }

    uint64_t generation = ++sLGDIMaskNextGeneration;
    if (LGDIWriteMaskImage(maskImage, origin, generation)) {
        if (glassView) {
            [glassView.layer setNeedsDisplay];
        }
    }
}

#pragma mark - Throttled mask update

static NSTimeInterval sLGDILastMaskUpdateTime = 0.0;
static BOOL sLGDIMaskUpdatePending = NO;

static const NSTimeInterval kLGDIMaskUpdateThrottle = 1.0 / 30.0;

static void LGDIScheduleMaskUpdate(UIView *sourceView, UIView *glassView) {
    if (!sourceView) return;

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval timeSinceLast = now - sLGDILastMaskUpdateTime;

    if (timeSinceLast >= kLGDIMaskUpdateThrottle) {
        sLGDILastMaskUpdateTime = now;
        LGDIUpdateMask(sourceView, glassView);
    } else if (!sLGDIMaskUpdatePending) {
        sLGDIMaskUpdatePending = YES;
        NSTimeInterval delay = kLGDIMaskUpdateThrottle - timeSinceLast;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sLGDIMaskUpdatePending = NO;
            if (sourceView) {
                sLGDILastMaskUpdateTime = CACurrentMediaTime();
                LGDIUpdateMask(sourceView, glassView);
            }
        });
    }
}

#pragma mark - Install / Remove

static void LGDIInstallGlass(UIView *islandView) {
    if (!islandView || !islandView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    UIView *parent = islandView.superview;
    if (!parent) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(islandView, kLGDIGlassViewKey);
    if (!glassView) {
        // 打印视图层级
        LGDILog(@"=== Island view found! class=%@ frame=%@ ===",
                NSStringFromClass(islandView.class), NSStringFromCGRect(islandView.frame));
        LGDILog(@"=== View hierarchy ===\n%@",
                LGDIDumpViewHierarchy(islandView, 0));

        glassView = LGCreateRegisteredGlass(islandView.bounds, nil, @"DynamicIsland");
        if (!glassView) {
            LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil");
            return;
        }

        glassView.userInteractionEnabled = NO;
        glassView.backgroundColor = UIColor.clearColor;
        glassView.layer.cornerRadius = 0.0;
        glassView.layer.masksToBounds = YES;

        // 插入到灵动岛下方
        [parent insertSubview:glassView belowSubview:islandView];

        objc_setAssociatedObject(islandView, kLGDIGlassViewKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(islandView, kLGDIAttachedKey, @(YES),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 延迟重试 applyFilters
        __weak LGLiveBackdropView *weakGlass = glassView;
        for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }

        // 生成初始 mask
        __weak UIView *weakIsland = islandView;
        __weak LGLiveBackdropView *weakGlass2 = glassView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGDIUpdateMask(weakIsland, weakGlass2);
        });

        LGDILog(@"Installed glass for island view class=%@ size=%.1fx%.1f",
                NSStringFromClass(islandView.class),
                islandView.bounds.size.width, islandView.bounds.size.height);
    }

    // 更新位置和大小
    CGRect targetFrame = islandView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIMaskLayerKey);
        if (maskLayer) {
            maskLayer.frame = glassView.bounds;
        }
    }

    // 确保 glassView 在灵动岛下方
    if (glassView.superview != parent) {
        [parent insertSubview:glassView belowSubview:islandView];
    }
}

static void LGDIRemoveGlass(UIView *islandView) {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(islandView, kLGDIGlassViewKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(islandView, kLGDIGlassViewKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(islandView, kLGDIAttachedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(islandView, kLGDIMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"Removed glass from island view");
    }
}

#pragma mark - Dynamic scanning (不依赖固定类名)

static void LGDIScanAndInstall(void) {
    if (!lgHostEnabled(@"DynamicIsland")) return;

    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    CGFloat screenWidth = keyWindow.bounds.size.width;

    // 如果已经找到了灵动岛视图，检查它是否还在
    if (sLGDIIslandView) {
        if (sLGDIIslandView.window) {
            // 还在，更新 glass
            LGDIInstallGlass(sLGDIIslandView);
            LGDIScheduleMaskUpdate(sLGDIIslandView,
                                   objc_getAssociatedObject(sLGDIIslandView, kLGDIGlassViewKey));
            return;
        } else {
            // 不在了，清理
            LGDIRemoveGlass(sLGDIIslandView);
            sLGDIIslandView = nil;
        }
    }

    // 搜索灵动岛视图
    UIView *found = LGDIFindIslandViewRecursive(keyWindow, screenWidth);
    if (found) {
        sLGDIIslandView = found;
        LGDIInstallGlass(found);

        // 找到后停止扫描定时器
        if (sLGDIScanTimer) {
            [sLGDIScanTimer invalidate];
            sLGDIScanTimer = nil;
        }
    }
}

#pragma mark - 偏好设置变更监听

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
        // 如果关闭了，移除 glass
        if (!lgHostEnabled(@"DynamicIsland")) {
            if (sLGDIIslandView) {
                LGDIRemoveGlass(sLGDIIslandView);
                sLGDIIslandView = nil;
            }
        }
    }
}

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (!LGIsAtLeastiOS16()) return;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LGDIPrefsChanged,
                                    CFSTR("dylv.liquidglass/PrefsReloaded"),
                                    NULL, 0);

    LGDILog(@"Dynamic Island tweak initialized (dynamic scanning mode)");

    // 延迟启动扫描，等 SpringBoard 完全加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 初始扫描
        LGDIScanAndInstall();

        // 如果没找到，定时重试
        if (!sLGDIIslandView) {
            // 每 2 秒扫描一次，最多扫描 30 次（60秒）
            __block int scanCount = 0;
            sLGDIScanTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                             repeats:YES
                                                               block:^(NSTimer *timer) {
                scanCount++;
                LGDIScanAndInstall();

                if (sLGDIIslandView || scanCount >= 30) {
                    [timer invalidate];
                    sLGDIScanTimer = nil;

                    if (!sLGDIIslandView) {
                        LGDILog(@"WARNING: Island view not found after %d scans", scanCount);
                    }
                }
            }];
        }
    });
}
