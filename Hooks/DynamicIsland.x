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
static void *kLGDIOriginalOpacityKey = &kLGDIOriginalOpacityKey;
static void *kLGDIAttachedKey = &kLGDIAttachedKey;

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

// 更新 mask
static void LGDIUpdateMask(UIView *sourceView) {
    if (!sourceView || !sourceView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;

    // 获取在屏幕上的位置
    CGPoint origin = [sourceView convertPoint:CGPointZero toView:nil];

    UIImage *maskImage = LGDIRenderAlphaMaskFromView(sourceView);
    if (!maskImage) return;

    uint64_t generation = ++sLGDIMaskNextGeneration;
    if (LGDIWriteMaskImage(maskImage, origin, generation)) {
        LGLiveBackdropView *glassView = objc_getAssociatedObject(sourceView, kLGDIGlassViewKey);
        if (glassView) {
            [glassView.layer setNeedsDisplay];
        }
    }
}

#pragma mark - Throttled mask update

static NSTimeInterval sLGDILastMaskUpdateTime = 0.0;
static BOOL sLGDIMaskUpdatePending = NO;
static __weak UIView *sLGDIPendingSourceView = nil;

static const NSTimeInterval kLGDIMaskUpdateThrottle = 1.0 / 30.0; // 30fps 上限

static void LGDIScheduleMaskUpdate(UIView *sourceView) {
    if (!sourceView) return;

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval timeSinceLast = now - sLGDILastMaskUpdateTime;

    if (timeSinceLast >= kLGDIMaskUpdateThrottle) {
        sLGDILastMaskUpdateTime = now;
        LGDIUpdateMask(sourceView);
    } else {
        sLGDIPendingSourceView = sourceView;
        if (!sLGDIMaskUpdatePending) {
            sLGDIMaskUpdatePending = YES;
            NSTimeInterval delay = kLGDIMaskUpdateThrottle - timeSinceLast;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                sLGDIMaskUpdatePending = NO;
                UIView *view = sLGDIPendingSourceView;
                if (view) {
                    sLGDILastMaskUpdateTime = CACurrentMediaTime();
                    LGDIUpdateMask(view);
                }
                sLGDIPendingSourceView = nil;
            });
        }
    }
}

#pragma mark - Install / Remove

static void LGDIInstallGlassForSourceView(UIView *sourceView, UIView *containerView) {
    if (!sourceView || !containerView || !containerView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    UIView *parent = containerView.superview;
    if (!parent) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(sourceView, kLGDIGlassViewKey);
    if (!glassView) {
        glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
        if (!glassView) return;

        glassView.userInteractionEnabled = NO;
        glassView.backgroundColor = UIColor.clearColor;
        glassView.layer.cornerRadius = 0.0;
        glassView.layer.masksToBounds = NO;

        // 插入到容器视图下方
        [parent insertSubview:glassView belowSubview:containerView];

        objc_setAssociatedObject(sourceView, kLGDIGlassViewKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 标记已附加
        objc_setAssociatedObject(sourceView, kLGDIAttachedKey, @(YES),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 延迟重试 applyFilters（防止 backboardd filter 还没注册好）
        __weak LGLiveBackdropView *weakGlass = glassView;
        for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }

        // 生成初始 mask（延迟一点，确保视图布局完成）
        __weak UIView *weakSource = sourceView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGDIUpdateMask(weakSource);
        });

        LGDILog(@"Installed DynamicIsland glass source=%@ container=%@ origin=%.1f,%.1f size=%.1fx%.1f",
                NSStringFromClass(sourceView.class),
                NSStringFromClass(containerView.class),
                containerView.frame.origin.x, containerView.frame.origin.y,
                containerView.bounds.size.width, containerView.bounds.size.height);
    }

    // 更新位置和大小
    CGRect targetFrame = containerView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
    }

    // 确保 glassView 在容器视图下方
    [parent insertSubview:glassView belowSubview:containerView];
}

static void LGDIRemoveGlassForSourceView(UIView *sourceView) {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(sourceView, kLGDIGlassViewKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(sourceView, kLGDIGlassViewKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sourceView, kLGDIAttachedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"Removed DynamicIsland glass");
    }
}

#pragma mark - Hook _SBGainMapView（主路径）

// _SBGainMapView 是灵动岛的增益图视图，负责定义灵动岛的形状
%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (selfView.window) {
        LGDIInstallGlassForSourceView(selfView, selfView);
    } else {
        LGDIRemoveGlassForSourceView(selfView);
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *selfView = (UIView *)self;
    LGDIInstallGlassForSourceView(selfView, selfView);

    // 形状可能变化，更新 mask（节流）
    LGDIScheduleMaskUpdate(selfView);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    LGLiveBackdropView *glassView = objc_getAssociatedObject(self, kLGDIGlassViewKey);
    if (glassView) glassView.hidden = hidden;
}

%end

#pragma mark - Hook SBDynamicIslandView（备用路径）

// 某些 iOS 版本可能用 SBDynamicIslandView 作为容器
// 如果 _SBGainMapView 不存在，尝试用 SBDynamicIslandView 作为源
%hook SBDynamicIslandView

- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (!selfView.window) return;

    // 先检查子视图中有没有 _SBGainMapView，如果有，主路径会处理
    __block BOOL hasGainMap = NO;
    [selfView.subviews enumerateObjectsUsingBlock:^(__kindof UIView *subview, NSUInteger idx, BOOL *stop) {
        NSString *clsName = NSStringFromClass(subview.class);
        if ([clsName containsString:@"GainMap"]) {
            hasGainMap = YES;
            *stop = YES;
        }
    }];

    if (hasGainMap) {
        LGDILog(@"SBDynamicIslandView has gain map subview, using primary path");
        return;
    }

    // 没有 gain map，用备用路径（直接以 SBDynamicIslandView 为源）
    LGDILog(@"Using fallback path: SBDynamicIslandView as source");
    LGDIInstallGlassForSourceView(selfView, selfView);
}

- (void)layoutSubviews {
    %orig;
    UIView *selfView = (UIView *)self;

    // 检查是否是备用路径（自己是 source）
    NSNumber *attached = objc_getAssociatedObject(self, kLGDIAttachedKey);
    if (attached && attached.boolValue) {
        LGDIInstallGlassForSourceView(selfView, selfView);
        LGDIScheduleMaskUpdate(selfView);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    NSNumber *attached = objc_getAssociatedObject(self, kLGDIAttachedKey);
    if (attached && attached.boolValue) {
        LGLiveBackdropView *glassView = objc_getAssociatedObject(self, kLGDIGlassViewKey);
        if (glassView) glassView.hidden = hidden;
    }
}

%end

#pragma mark - 偏好设置变更监听

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        // 偏好变更时重新检查开关状态
        // 如果关闭了，移除 glass；如果开启了，重新安装
        // 这里简单处理，具体逻辑可以后续优化
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
