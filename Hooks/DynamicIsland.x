// =============================================================================
//  DynamicIsland.x — Mango 架构精确复制
//
//  事件源（与 Mango 二进制完全一致）：
//  1. _SBGainMapView didMoveToWindow  → pill 出现信号（触发安装）
//  2. _SBGainMapView layoutSubviews   → 布局变化时更新玻璃
//  3. _SBGainMapView setHidden:       → 显隐同步
//  4. FBSceneLayerManager._setLayers: → 场景图层变化
//
//  关键架构（与 Mango 一致）：
//  - gainMapView 只是检测时机，不装玻璃
//  - 玻璃装在 gainMapView 的 superview（element 容器）上
//  - mask 形状来自 _SBSystemApertureMagiciansCurtainView（窗帘视图）
//  - 玻璃作为 curtainView 的兄弟视图，插入在它下面
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
static void *kLGDICurtainViewKey = &kLGDICurtainViewKey;

#pragma mark - Size validation

static BOOL LGDIIsPlausibleIslandSize(CGSize size) {
    if (size.width <= 0 || size.height <= 0) return NO;
    if (size.width > 420 || size.height > 200) return NO;
    if (size.width < 80 || size.height < 20) return NO;
    return YES;
}

// =============================================================================
//  View finding helpers
// =============================================================================

// 在兄弟视图中查找 _SBSystemApertureMagiciansCurtainView
static UIView *LGDIFindCurtainViewInContainer(UIView *container) {
    if (!container) return nil;
    Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
    if (!curtainClass) return nil;

    for (UIView *subview in container.subviews) {
        if ([subview isKindOfClass:curtainClass]) return subview;
    }
    return nil;
}

// 递归查找 _SBGainMapView
static UIView *LGDIFindGainMapViewInView(UIView *root) {
    if (!root) return nil;
    Class gainMapClass = objc_getClass("_SBGainMapView");
    if (!gainMapClass) return nil;
    if ([root isKindOfClass:gainMapClass]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = LGDIFindGainMapViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static UIView *LGDIFindExistingGainMapView(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIView *found = LGDIFindGainMapViewInView(window);
        if (found) return found;
    }
    return nil;
}

// =============================================================================
//  Glass installation
//  玻璃装在 gainMapView.superview 上（element 容器）
//  mask 形状来自 curtainView（窗帘视图）
// =============================================================================

static void LGDIInstallPillGlass(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGDIIsPlausibleIslandSize(gainMapView.bounds.size)) return;

    UIView *container = gainMapView.superview;
    if (!container) return;

    // 已经装过了（glass 关联在 container 上）
    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, kLGDIPillGlassKey);
    if (glassView) return;

    // 找到 curtainView（mask 形状来源）
    UIView *curtainView = LGDIFindCurtainViewInContainer(container);
    if (!curtainView) {
        LGDILog(@"installPillGlass: curtainView not found in container %@",
                NSStringFromClass(container.class));
        return;
    }

    // 用 curtainView 的尺寸创建玻璃
    CGRect glassFrame = curtainView.frame;
    glassView = LGCreateRegisteredGlass(glassFrame, nil, @"DynamicIsland");
    if (!glassView) {
        LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil");
        return;
    }

    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = UIColor.clearColor;
    glassView.layer.cornerRadius = 0.0;
    glassView.layer.masksToBounds = YES;
    glassView.frame = glassFrame;

    // 插入到 curtainView 下面（兄弟视图关系）
    [container insertSubview:glassView belowSubview:curtainView];

    // 关联到 container 上
    objc_setAssociatedObject(container, kLGDIPillGlassKey, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(container, kLGDICurtainViewKey, curtainView,
                             OBJC_ASSOCIATION_ASSIGN);

    // 延迟应用滤镜
    __weak LGLiveBackdropView *weakGlass = glassView;
    for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakGlass applyFilters];
        });
    }

    // 用 curtainView 渲染 mask
    LGDIScheduleMaskUpdate(curtainView, glassView, kLGDIPillMaskLayerKey);

    LGDILog(@"glass created on container=%@ curtain=%@ frame=%@",
            NSStringFromClass(container.class),
            NSStringFromClass(curtainView.class),
            NSStringFromCGRect(glassFrame));
}

static void LGDIRemovePillGlass(UIView *gainMapView) {
    if (!gainMapView) return;
    UIView *container = gainMapView.superview;
    if (!container) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, kLGDIPillGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(container, kLGDIPillGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(container, kLGDIPillMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(container, kLGDICurtainViewKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        LGDILog(@"glass removed from container=%@", NSStringFromClass(container.class));
    }
}

static void LGDIRefreshPillGlass(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;
    UIView *container = gainMapView.superview;
    if (!container) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, kLGDIPillGlassKey);
    if (!glassView) return;

    UIView *curtainView = objc_getAssociatedObject(container, kLGDICurtainViewKey);
    if (!curtainView || !curtainView.window) {
        // curtainView 可能变了，重新找
        curtainView = LGDIFindCurtainViewInContainer(container);
        if (curtainView) {
            objc_setAssociatedObject(container, kLGDICurtainViewKey, curtainView,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
    }
    if (!curtainView) return;

    // 同步 frame
    CGRect targetFrame = curtainView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIPillMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    LGDIScheduleMaskUpdate(curtainView, glassView, kLGDIPillMaskLayerKey);
}

// =============================================================================
//  Hook: _SBGainMapView
//  Mango 二进制确认：hook 了 didMoveToWindow / layoutSubviews / setHidden:
//  作用：检测 pill 出现/消失时机，驱动玻璃安装/更新
//  玻璃不装在 gainMapView 上，装在它的 superview 上
// =============================================================================

@interface _SBGainMapView : UIView
@end

%group GainMapViewHook
%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;

    if (self.window) {
        LGDILog(@"[_SBGainMapView didMoveToWindow] added to window");
        LGDIInstallPillGlass(self);
    } else {
        LGDILog(@"[_SBGainMapView didMoveToWindow] removed from window");
        LGDIRemovePillGlass(self);
    }
}

- (void)layoutSubviews {
    %orig;

    if (!CGRectIsEmpty(self.bounds)) {
        LGDIRefreshPillGlass(self);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;

    UIView *container = self.superview;
    if (container) {
        LGLiveBackdropView *glass = objc_getAssociatedObject(container, kLGDIPillGlassKey);
        if (glass) glass.hidden = hidden;
    }
}

%end
%end

// =============================================================================
//  Hook: _SBSystemApertureMagiciansCurtainView
//  Mango 二进制确认：hook 了 didMoveToWindow / setHidden:
//  作用：窗帘视图显隐变化时同步玻璃显隐
// =============================================================================

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end

%group CurtainViewHook
%hook _SBSystemApertureMagiciansCurtainView

- (void)setHidden:(BOOL)hidden {
    %orig;

    UIView *container = self.superview;
    if (container) {
        LGLiveBackdropView *glass = objc_getAssociatedObject(container, kLGDIPillGlassKey);
        if (glass) glass.hidden = hidden;
    }
}

- (void)layoutSubviews {
    %orig;

    UIView *container = self.superview;
    if (container && !CGRectIsEmpty(self.bounds)) {
        LGLiveBackdropView *glass = objc_getAssociatedObject(container, kLGDIPillGlassKey);
        if (glass) {
            if (!CGRectEqualToRect(glass.frame, self.frame)) {
                glass.frame = self.frame;
            }
            LGDIScheduleMaskUpdate(self, glass, kLGDIPillMaskLayerKey);
        }
    }
}

%end
%end

// =============================================================================
//  Hook: FBSceneLayerManager._setLayers:
//  保留作为场景状态跟踪（Mango 也有此 hook）
// =============================================================================

%group SceneLayerManager
%hook FBSceneLayerManager

- (void)_setLayers:(id)layers {
    %orig;
    // 场景图层变化时，layoutSubviews 会自动触发 mask 更新
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
        // 遍历所有窗口，找到已安装的 glass 并重新应用滤镜
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            for (UIView *subview in window.subviews) {
                // 检查当前视图
                id glass = objc_getAssociatedObject(subview, kLGDIPillGlassKey);
                if (glass && [glass isKindOfClass:[LGLiveBackdropView class]]) {
                    [(LGLiveBackdropView *)glass applyFilters];
                    UIView *curtain = objc_getAssociatedObject(subview, kLGDICurtainViewKey);
                    if (curtain) LGDIScheduleMaskUpdate(curtain, glass, kLGDIPillMaskLayerKey);
                }
                // 检查子视图（递归一层，够用了）
                for (UIView *sv in subview.subviews) {
                    id g = objc_getAssociatedObject(sv, kLGDIPillGlassKey);
                    if (g && [g isKindOfClass:[LGLiveBackdropView class]]) {
                        [(LGLiveBackdropView *)g applyFilters];
                        UIView *c = objc_getAssociatedObject(sv, kLGDICurtainViewKey);
                        if (c) LGDIScheduleMaskUpdate(c, g, kLGDIPillMaskLayerKey);
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

    // 1. Darwin 通知监听
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LGDIPrefsChanged,
                                    CFSTR("dylv.liquidglass/PrefsReloaded"),
                                    NULL, 0);

    // 2. Hook: _SBGainMapView
    %init(GainMapViewHook);

    // 3. Hook: _SBSystemApertureMagiciansCurtainView
    %init(CurtainViewHook);

    // 4. Hook: FBSceneLayerManager._setLayers:
    %init(SceneLayerManager);

    // 5. 类检查
    Class gainMapClass = objc_getClass("_SBGainMapView");
    Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
    Class sceneLayerMgrClass = objc_getClass("FBSceneLayerManager");
    LGDILog(@"Class check: gainMap=%@ curtain=%@ sceneLayerMgr=%@",
            gainMapClass ? @"YES" : @"NO",
            curtainClass ? @"YES" : @"NO",
            sceneLayerMgrClass ? @"YES" : @"NO");

    LGDILog(@"Dynamic Island initialized (gainMap trigger + curtain mask)");

    // 6. 主动查找已存在的 gainMapView 并安装玻璃
    //    SpringBoard 启动时灵动岛已经在窗口上，didMoveToWindow 早调用过了
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *existingGainMap = LGDIFindExistingGainMapView();
        if (existingGainMap) {
            LGDILog(@"constructor: found existing gainMapView %@",
                    NSStringFromCGRect(existingGainMap.frame));
            LGDIInstallPillGlass(existingGainMap);
        } else {
            LGDILog(@"constructor: no existing gainMapView found");
        }
    });
}
