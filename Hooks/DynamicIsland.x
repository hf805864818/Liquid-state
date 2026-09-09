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

// backboardd reads this packed alpha mask directly
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
static void *kLGDIOriginalBackgroundColorKey = &kLGDIOriginalBackgroundColorKey;

static uint64_t sLGDIMaskNextGeneration = 0;

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

    // 渲染视图层级到上下文
    [view.layer renderInContext:ctx];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

// 更新 glassView 的 layer mask（裁剪掉方形角）
static void LGDIUpdateGlassMask(UIView *glassView, UIImage *maskImage) {
    if (!glassView || !maskImage) return;

    CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIMaskLayerKey);
    if (!maskLayer) {
        maskLayer = [CALayer layer];
        maskLayer.contentsGravity = kCAGravityResizeAspect;
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

    // 获取在屏幕上的位置
    CGPoint origin = [sourceView convertPoint:CGPointZero toView:nil];

    UIImage *maskImage = LGDIRenderAlphaMaskFromView(sourceView);
    if (!maskImage) return;

    // 更新 glassView 的 layer mask（裁剪形状，解决方形角问题）
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
static __weak UIView *sLGDIPendingSourceView = nil;
static __weak UIView *sLGDIPendingGlassView = nil;

static const NSTimeInterval kLGDIMaskUpdateThrottle = 1.0 / 30.0; // 30fps 上限

static void LGDIScheduleMaskUpdate(UIView *sourceView, UIView *glassView) {
    if (!sourceView) return;

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval timeSinceLast = now - sLGDILastMaskUpdateTime;

    if (timeSinceLast >= kLGDIMaskUpdateThrottle) {
        sLGDILastMaskUpdateTime = now;
        LGDIUpdateMask(sourceView, glassView);
    } else {
        sLGDIPendingSourceView = sourceView;
        sLGDIPendingGlassView = glassView;
        if (!sLGDIMaskUpdatePending) {
            sLGDIMaskUpdatePending = YES;
            NSTimeInterval delay = kLGDIMaskUpdateThrottle - timeSinceLast;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                sLGDIMaskUpdatePending = NO;
                UIView *src = sLGDIPendingSourceView;
                UIView *glass = sLGDIPendingGlassView;
                if (src) {
                    sLGDILastMaskUpdateTime = CACurrentMediaTime();
                    LGDIUpdateMask(src, glass);
                }
                sLGDIPendingSourceView = nil;
                sLGDIPendingGlassView = nil;
            });
        }
    }
}

#pragma mark - Find gain map view

static UIView *LGDIFindGainMapViewInView(UIView *root) {
    if (!root) return nil;
    for (UIView *subview in root.subviews) {
        NSString *clsName = NSStringFromClass(subview.class);
        if ([clsName containsString:@"GainMap"]) {
            return subview;
        }
        UIView *found = LGDIFindGainMapViewInView(subview);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Install / Remove

static void LGDIInstallGlassInContainer(UIView *containerView, UIView *gainMapView) {
    if (!containerView || !containerView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    // 用 gainMapView 作为 key 存储 glassView
    UIView *keyView = gainMapView ?: containerView;
    LGLiveBackdropView *glassView = objc_getAssociatedObject(keyView, kLGDIGlassViewKey);

    if (!glassView) {
        glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
        if (!glassView) return;

        glassView.userInteractionEnabled = NO;
        glassView.backgroundColor = UIColor.clearColor;
        glassView.layer.cornerRadius = 0.0;
        glassView.layer.masksToBounds = YES;

        // 插入到容器的最底层（作为背景）
        [containerView insertSubview:glassView atIndex:0];

        objc_setAssociatedObject(keyView, kLGDIGlassViewKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 标记已附加
        objc_setAssociatedObject(keyView, kLGDIAttachedKey, @(YES),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 保存原始背景色
        UIColor *origBg = containerView.backgroundColor;
        if (origBg) {
            objc_setAssociatedObject(keyView, kLGDIOriginalBackgroundColorKey, origBg,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        // 把容器背景设为透明，让玻璃层显示出来
        containerView.backgroundColor = UIColor.clearColor;

        // 延迟重试 applyFilters（防止 backboardd filter 还没注册好）
        __weak LGLiveBackdropView *weakGlass = glassView;
        for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
                            });
        }

        // 生成初始 mask（延迟一点，确保视图布局完成）
        __weak UIView *weakSource = gainMapView ?: containerView;
        __weak LGLiveBackdropView *weakGlass2 = glassView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           LGDIUpdateMask(weakSource, weakGlass2);
                       });

        LGDILog(@"Installed DynamicIsland glass container=%@ gainMap=%@ size=%.1fx%.1f",
                NSStringFromClass(containerView.class),
                gainMapView ? NSStringFromClass(gainMapView.class) : @"(nil)",
                containerView.bounds.size.width, containerView.bounds.size.height);
    }

    // 更新位置和大小
    CGRect targetFrame = containerView.bounds;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        // 更新 mask layer 的 frame
        CALayer *maskLayer = objc_getAssociatedObject(keyView, kLGDIMaskLayerKey);
        if (maskLayer) {
            maskLayer.frame = glassView.bounds;
        }
    }

    // 确保 glassView 在最底层
    [containerView sendSubviewToBack:glassView];
}

static void LGDIRemoveGlassFromContainer(UIView *containerView, UIView *gainMapView) {
    UIView *keyView = gainMapView ?: containerView;
    LGLiveBackdropView *glassView = objc_getAssociatedObject(keyView, kLGDIGlassViewKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(keyView, kLGDIGlassViewKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(keyView, kLGDIAttachedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(keyView, kLGDIMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 恢复原始背景色
        UIColor *origBg = objc_getAssociatedObject(keyView, kLGDIOriginalBackgroundColorKey);
        if (origBg) {
            containerView.backgroundColor = origBg;
            objc_setAssociatedObject(keyView, kLGDIOriginalBackgroundColorKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        LGDILog(@"Removed DynamicIsland glass");
    }
}

#pragma mark - Hook SBDynamicIslandView（主路径：容器视图）

// SBDynamicIslandView 是灵动岛的容器视图
// 我们在这里插入玻璃层，并隐藏黑色背景
%hook SBDynamicIslandView

- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (selfView.window) {
        // 找子视图中的 gain map view（作为形状源）
        UIView *gainMapView = LGDIFindGainMapViewInView(selfView);
        LGDIInstallGlassInContainer(selfView, gainMapView);
    } else {
        UIView *gainMapView = LGDIFindGainMapViewInView(selfView);
        LGDIRemoveGlassFromContainer(selfView, gainMapView);
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *selfView = (UIView *)self;

    UIView *gainMapView = LGDIFindGainMapViewInView(selfView);
    UIView *keyView = gainMapView ?: selfView;
    NSNumber *attached = objc_getAssociatedObject(keyView, kLGDIAttachedKey);

    if (attached && attached.boolValue) {
        LGDIInstallGlassInContainer(selfView, gainMapView);

        // 形状可能变化，更新 mask（节流）
        LGLiveBackdropView *glassView = objc_getAssociatedObject(keyView, kLGDIGlassViewKey);
        LGDIScheduleMaskUpdate(gainMapView ?: selfView, glassView);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    UIView *selfView = (UIView *)self;
    UIView *gainMapView = LGDIFindGainMapViewInView(selfView);
    UIView *keyView = gainMapView ?: selfView;
    LGLiveBackdropView *glassView = objc_getAssociatedObject(keyView, kLGDIGlassViewKey);
    if (glassView) glassView.hidden = hidden;
}

%end

#pragma mark - Hook _SBGainMapView（形状源）

// _SBGainMapView 是灵动岛的增益图视图，负责定义灵动岛的形状
// 我们主要用它来生成 mask，实际 glassView 插在 SBDynamicIslandView 里
%hook _SBGainMapView

- (void)layoutSubviews {
    %orig;
    // 形状变化时，通知容器更新 mask
    UIView *selfView = (UIView *)self;

    // 向上找容器视图
    UIView *container = selfView.superview;
    while (container && ![NSStringFromClass(container.class) containsString:@"DynamicIsland"]) {
        container = container.superview;
    }

    if (container) {
        UIView *keyView = selfView;
        NSNumber *attached = objc_getAssociatedObject(keyView, kLGDIAttachedKey);
        if (attached && attached.boolValue) {
            LGLiveBackdropView *glassView = objc_getAssociatedObject(keyView, kLGDIGlassViewKey);
            LGDIScheduleMaskUpdate(selfView, glassView);
        }
    }
}

%end

#pragma mark - 偏好设置变更监听

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
    }
}

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (!LGIsAtLeastiOS16()) return;

    // 监听偏好设置变更
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LGDIPrefsChanged,
                                    CFSTR("dylv.liquidglass/PrefsReloaded"),
                                    NULL, 0);

    LGDILog(@"Dynamic Island tweak initialized");
}
