// =============================================================================
//  DynamicIsland.x — Mango 架构精确复制（直接 hook 渲染视图）
//
//  事件源（与 Mango 二进制完全一致）：
//  1. _SBGainMapView didMoveToWindow  → pill 视图出现时安装玻璃
//  2. _SBGainMapView layoutSubviews   → 布局变化时更新玻璃 frame
//  3. _SBGainMapView setHidden:       → 显隐变化
//  4. FBSceneLayerManager._setLayers: → 场景图层变化（backdrop 刷新）
//
//  零 VC 查找：不依赖 SBSystemApertureViewController，不调用 _elementForContainerView:
//  零递归扫描：直接在目标视图生命周期方法里操作
//  零重试机制：视图出现即安装，视图消失即移除
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

// CydiaSubstrate (for MSHookMessageEx, same as Mango uses)
#ifdef __cplusplus
extern "C"
#endif
void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *origImp);

static void LGDILog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDILog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI] %@", s);
}

#pragma mark - Process / OS checks

static inline BOOL LGIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}
static inline BOOL LGIsAtLeastiOS16(void) {
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}

#pragma mark - Cross-process glyph mask (保留原有实现)

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

static uint64_t sLGDIMaskNextGeneration = 0;

#pragma mark - Mask rendering

static UIImage *LGDIRenderAlphaMaskFromView(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return nil;
    CGSize size = view.bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return nil; }
    [view.layer renderInContext:ctx];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static void LGDIUpdateGlassMask(UIView *glassView, UIImage *maskImage, void *maskLayerKey) {
    if (!glassView || !maskImage) return;
    CALayer *maskLayer = objc_getAssociatedObject(glassView, maskLayerKey);
    if (!maskLayer) {
        maskLayer = [CALayer layer];
        maskLayer.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(glassView, maskLayerKey, maskLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.layer.mask = maskLayer;
    }
    maskLayer.frame = glassView.bounds;
    maskLayer.contents = (__bridge id _Nullable)(maskImage.CGImage);
}

static void LGDIUpdateMask(UIView *sourceView, UIView *glassView, void *maskLayerKey) {
    if (!sourceView || !sourceView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    CGPoint origin = [sourceView convertPoint:CGPointZero toView:nil];
    UIImage *maskImage = LGDIRenderAlphaMaskFromView(sourceView);
    if (!maskImage) return;
    if (glassView) LGDIUpdateGlassMask(glassView, maskImage, maskLayerKey);
    uint64_t generation = ++sLGDIMaskNextGeneration;
    if (LGDIWriteMaskImage(maskImage, origin, generation)) {
        if (glassView) [glassView.layer setNeedsDisplay];
    }
}

static NSTimeInterval sLGDILastMaskUpdateTime = 0.0;
static BOOL sLGDIMaskUpdatePending = NO;
static const NSTimeInterval kLGDIMaskUpdateThrottle = 1.0 / 30.0;

static void LGDIScheduleMaskUpdate(UIView *sourceView, UIView *glassView, void *maskLayerKey) {
    if (!sourceView) return;
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval timeSinceLast = now - sLGDILastMaskUpdateTime;
    if (timeSinceLast >= kLGDIMaskUpdateThrottle) {
        sLGDILastMaskUpdateTime = now;
        LGDIUpdateMask(sourceView, glassView, maskLayerKey);
    } else if (!sLGDIMaskUpdatePending) {
        sLGDIMaskUpdatePending = YES;
        NSTimeInterval delay = kLGDIMaskUpdateThrottle - timeSinceLast;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sLGDIMaskUpdatePending = NO;
            if (sourceView) {
                sLGDILastMaskUpdateTime = CACurrentMediaTime();
                LGDIUpdateMask(sourceView, glassView, maskLayerKey);
            }
        });
    }
}

#pragma mark - Association keys

static void *kLGDIPillGlassKey = &kLGDIPillGlassKey;
static void *kLGDIPillMaskLayerKey = &kLGDIPillMaskLayerKey;

#pragma mark - Size validation

static BOOL LGDIIsPlausibleIslandSize(CGSize size) {
    if (size.width <= 0 || size.height <= 0) return NO;
    if (size.width > 420 || size.height > 200) return NO;
    if (size.width < 80 || size.height < 20) return NO;
    return YES;
}

// =============================================================================
//  Glass installation helpers
// =============================================================================

// 在 gainMapView 上安装液态玻璃
static void LGDIInstallGlassOnGainMapView(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGDIIsPlausibleIslandSize(gainMapView.bounds.size)) return;

    // 已经安装过了
    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (glassView) return;

    glassView = LGCreateRegisteredGlass(gainMapView.bounds, nil, @"DynamicIsland");
    if (!glassView) {
        LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil");
        return;
    }

    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = UIColor.clearColor;
    glassView.layer.cornerRadius = 0.0;
    glassView.layer.masksToBounds = YES;
    glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glassView.frame = gainMapView.bounds;

    // 插入到 gainMapView 的底层（glass 在内容下面）
    [gainMapView insertSubview:glassView atIndex:0];

    objc_setAssociatedObject(gainMapView, kLGDIPillGlassKey, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 延迟应用滤镜（给系统渲染时间）
    __weak LGLiveBackdropView *weakGlass = glassView;
    for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakGlass applyFilters];
        });
    }

    LGDIScheduleMaskUpdate(gainMapView, glassView, kLGDIPillMaskLayerKey);

    LGDILog(@"glass created on _SBGainMapView h=%.1f", gainMapView.bounds.size.height);
}

// 从 gainMapView 移除液态玻璃
static void LGDIRemoveGlassFromGainMapView(UIView *gainMapView) {
    if (!gainMapView) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(gainMapView, kLGDIPillGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(gainMapView, kLGDIPillMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"glass removed from _SBGainMapView");
    }
}

// =============================================================================
//  Hook: _SBGainMapView
//  Mango 二进制确认：hook 了 didMoveToWindow / layoutSubviews / setHidden:
//  这是灵动岛 pill 的核心渲染视图，玻璃直接安装在这个 view 上
// =============================================================================

// 声明 _SBGainMapView 是 UIView 子类，让编译器识别 window / bounds 等属性
@interface _SBGainMapView : UIView
@end

%group GainMapViewHook
%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        // 视图出现 → 安装玻璃
        LGDILog(@"[_SBGainMapView didMoveToWindow] added to window");
        LGDIInstallGlassOnGainMapView(self);
    } else {
        // 视图移除 → 移除玻璃
        LGDILog(@"[_SBGainMapView didMoveToWindow] removed from window");
        LGDIRemoveGlassFromGainMapView(self);
    }
}

- (void)layoutSubviews {
    %orig;

    // 布局变化 → 更新玻璃 frame 和 mask
    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGDIPillGlassKey);
    if (glass && !CGRectIsEmpty(self.bounds)) {
        LGDIUpdateMask(self, glass, kLGDIPillMaskLayerKey);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGDIPillGlassKey);
    if (glass) {
        glass.hidden = hidden;
        LGDILog(@"[_SBGainMapView setHidden:%d]", hidden);
    }
}

%end
%end

// =============================================================================
//  Hook: FBSceneLayerManager._setLayers:
//  Mango 二进制确认：hook 的是 _setLayers: 方法
//  用于 backdrop 刷新（场景内容变化时更新 mask）
// =============================================================================

%group SceneLayerManager
%hook FBSceneLayerManager

- (void)_setLayers:(id)layers {
    %orig;

    // 只在有内容时触发 backdrop 刷新
    NSUInteger layerCount = 0;
    if (layers && [layers respondsToSelector:@selector(count)]) {
        layerCount = ((NSUInteger (*)(id, SEL))[layers methodForSelector:@selector(count)])(layers, @selector(count));
    }

    if (layerCount > 0) {
        // 找到当前的 gainMapView 并刷新 backdrop
        // 这里不扫描，只是标记需要刷新，实际刷新在 layoutSubviews 里做
        // 但为了跟 Mango 一致，我们直接找 keyWindow 上的 gainMapView
        // 实际上 didMoveToWindow 已经装好了，这里只做节流刷新
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.windowLevel > 1000) { // 灵动岛窗口层级很高
                // 简单检查：不递归扫描，只在已知有 glass 的 gainMapView 上刷新
                // 由于 glass 已经通过 didMoveToWindow 安装，这里触发节流刷新
                // 我们通过通知所有已安装的 gainMapView 来刷新
                break;
            }
        }

        // 实际上 glass 已经通过 didMoveToWindow 安装，_setLayers: 只是额外的刷新信号
        // 由于 layoutSubviews 已经在每次布局时刷新 mask，这里不需要额外操作
        // 保留此 hook 用于未来可能的场景状态跟踪
    }
}

%end
%end

// =============================================================================
//  偏好设置变更监听
// =============================================================================

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
        // 偏好变更时，重新应用滤镜参数
        // 由于玻璃视图已经通过 didMoveToWindow 安装，
        // 我们需要找到所有已安装的 glass 并重新应用
        // 这里简单处理：遍历所有 window 查找 gainMapView
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            for (UIView *subview in window.subviews) {
                // 递归查找已安装 glass 的 gainMapView
                // 不直接扫描类名（避免开销），只检查 associated object
                id glass = objc_getAssociatedObject(subview, kLGDIPillGlassKey);
                if (glass && [glass isKindOfClass:[LGLiveBackdropView class]]) {
                    [(LGLiveBackdropView *)glass applyFilters];
                    LGDIScheduleMaskUpdate(subview, glass, kLGDIPillMaskLayerKey);
                }
                // 继续检查子视图
                for (UIView *sv in subview.subviews) {
                    id g = objc_getAssociatedObject(sv, kLGDIPillGlassKey);
                    if (g && [g isKindOfClass:[LGLiveBackdropView class]]) {
                        [(LGLiveBackdropView *)g applyFilters];
                        LGDIScheduleMaskUpdate(sv, g, kLGDIPillMaskLayerKey);
                    }
                }
            }
        }
    }
}

// =============================================================================
//  Constructor — 安装所有 hooks
// =============================================================================

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (!LGIsAtLeastiOS16()) return;

    // 1. Darwin 通知监听 — 偏好设置变更
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LGDIPrefsChanged,
                                    CFSTR("dylv.liquidglass/PrefsReloaded"),
                                    NULL, 0);

    // 2. Logos %init: _SBGainMapView
    %init(GainMapViewHook);

    // 3. Logos %init: FBSceneLayerManager._setLayers:
    %init(SceneLayerManager);

    // 4. 检查关键类是否存在
    Class gainMapClass = objc_getClass("_SBGainMapView");
    Class sceneLayerMgrClass = objc_getClass("FBSceneLayerManager");
    LGDILog(@"Class check: _SBGainMapView=%@ FBSceneLayerManager=%@",
            gainMapClass ? @"YES" : @"NO",
            sceneLayerMgrClass ? @"YES" : @"NO");

    LGDILog(@"Dynamic Island initialized (Mango architecture: _SBGainMapView direct hook)");
}
