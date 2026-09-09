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
    // 用 drawViewHierarchyInRect 替代 renderInContext
    // renderInContext 不会捕捉 layer.mask，而 drawViewHierarchyInRect 会
    [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
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
    if (size.width > 500 || size.height > 300) return NO;
    if (size.width < 80 || size.height < 20) return NO;
    return YES;
}

// =============================================================================
//  View finding helpers
// =============================================================================

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
//  Glass installation — Mango 架构：玻璃是 gainMapView 的兄弟视图
//
//  视图层级（从上到下）：
//    elementContainer (curtainView.superview)
//      ├── _SBGainMapView 所在的视图层级（curtainView 等）
//      └── glassView  ← 我们的玻璃，插在 curtainView 下面
//
//  为什么不加到 gainMapView 上：
//    _SBGainMapView 是特殊的增益渲染层（Metal/CAMetalLayer），
//    子视图不会被正确渲染和布局（size 变化不跟随、显示异常）
//
//  尺寸更新：
//    - 玻璃 frame = curtainView.frame（在 elementContainer 中的位置）
//    - layoutSubviews 时同步更新 glass frame 和 mask
//    - mask 从 gainMapView 渲染（获取胶囊形状的 alpha）
// =============================================================================

// =============================================================================
//  诊断：逐层探测 — 在每个候选层都加彩色标记视图
//  颜色对应：
//    红色 = gainMapView 内部（addSubview）
//    绿色 = curtainView 内部（addSubview）
//    蓝色 = elementContainer, curtainView 下面（belowSubview）
//    黄色 = elementContainer, curtainView 上面（aboveSubview）
//    紫色 = elementContainer 的 superview 里
//
//  哪个颜色能正确显示出药丸形状，哪层就是对的
// =============================================================================

static void LGDIInstallDiagnosticMarkers(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;

    UIView *curtainView = gainMapView.superview;
    if (!curtainView) return;
    UIView *elementContainer = curtainView.superview;
    if (!elementContainer) return;
    UIView *grandContainer = elementContainer.superview;

    CGSize size = gainMapView.bounds.size;
    CGFloat cornerRadius = size.height / 2.0;

    LGDILog(@"DIAG: Installing markers — gainMap=%@ curtain=%@ container=%@ grand=%@",
            NSStringFromClass(gainMapView.class),
            NSStringFromClass(curtainView.class),
            NSStringFromClass(elementContainer.class),
            grandContainer ? NSStringFromClass(grandContainer.class) : @"nil");
    LGDILog(@"DIAG: gainMapView.frame=%@ curtainView.frame=%@ container.frame=%@",
            NSStringFromCGRect(gainMapView.frame),
            NSStringFromCGRect(curtainView.frame),
            NSStringFromCGRect(elementContainer.frame));
    LGDILog(@"DIAG: gainMapView.layer class=%@ cornerRadius=%.1f masksToBounds=%d",
            NSStringFromClass(gainMapView.layer.class),
            gainMapView.layer.cornerRadius,
            gainMapView.layer.masksToBounds);

    // 标记1: 红色 — gainMapView 内部
    UIView *redMarker = [[UIView alloc] initWithFrame:gainMapView.bounds];
    redMarker.backgroundColor = [UIColor colorWithRed:1.0 green:0 blue:0 alpha:0.4];
    redMarker.layer.cornerRadius = cornerRadius;
    redMarker.layer.masksToBounds = YES;
    redMarker.userInteractionEnabled = NO;
    [gainMapView addSubview:redMarker];
    LGDILog(@"DIAG: RED marker added to gainMapView (inside)");

    // 标记2: 绿色 — curtainView 内部
    UIView *greenMarker = [[UIView alloc] initWithFrame:curtainView.bounds];
    greenMarker.backgroundColor = [UIColor colorWithRed:0 green:1.0 blue:0 alpha:0.4];
    greenMarker.layer.cornerRadius = cornerRadius;
    greenMarker.layer.masksToBounds = YES;
    greenMarker.userInteractionEnabled = NO;
    [curtainView addSubview:greenMarker];
    LGDILog(@"DIAG: GREEN marker added to curtainView (inside)");

    // 标记3: 蓝色 — elementContainer, curtainView 下面
    UIView *blueMarker = [[UIView alloc] initWithFrame:curtainView.frame];
    blueMarker.backgroundColor = [UIColor colorWithRed:0 green:0 blue:1.0 alpha:0.4];
    blueMarker.layer.cornerRadius = cornerRadius;
    blueMarker.layer.masksToBounds = YES;
    blueMarker.userInteractionEnabled = NO;
    [elementContainer insertSubview:blueMarker belowSubview:curtainView];
    LGDILog(@"DIAG: BLUE marker inserted below curtainView in elementContainer");

    // 标记4: 黄色 — elementContainer, curtainView 上面
    UIView *yellowMarker = [[UIView alloc] initWithFrame:curtainView.frame];
    yellowMarker.backgroundColor = [UIColor colorWithRed:1.0 green:1.0 blue:0 alpha:0.4];
    yellowMarker.layer.cornerRadius = cornerRadius;
    yellowMarker.layer.masksToBounds = YES;
    yellowMarker.userInteractionEnabled = NO;
    [elementContainer insertSubview:yellowMarker aboveSubview:curtainView];
    LGDILog(@"DIAG: YELLOW marker inserted above curtainView in elementContainer");

    // 标记5: 紫色 — grandContainer 里（如果存在）
    if (grandContainer) {
        CGRect purpleFrame = [elementContainer convertRect:curtainView.frame toView:grandContainer];
        UIView *purpleMarker = [[UIView alloc] initWithFrame:purpleFrame];
        purpleMarker.backgroundColor = [UIColor colorWithRed:0.5 green:0 blue:0.5 alpha:0.4];
        purpleMarker.layer.cornerRadius = cornerRadius;
        purpleMarker.layer.masksToBounds = YES;
        purpleMarker.userInteractionEnabled = NO;
        [grandContainer insertSubview:purpleMarker aboveSubview:elementContainer];
        LGDILog(@"DIAG: PURPLE marker added to grandContainer=%@ frame=%@",
                NSStringFromClass(grandContainer.class),
                NSStringFromCGRect(purpleFrame));
    }

    // 再往上走 3 层，看看更大的容器
    UIView *v = grandContainer;
    NSArray *colors = @[
        [UIColor colorWithRed:1.0 green:0.5 blue:0 alpha:0.3],   // 橙色
        [UIColor colorWithRed:0 green:0.5 blue:0.5 alpha:0.3],   // 青色
        [UIColor colorWithRed:0.5 green:0.5 blue:0 alpha:0.3],   // 橄榄色
    ];
    NSArray *names = @[@"ORANGE", @"CYAN", @"OLIVE"];
    for (NSInteger i = 0; i < 3 && v.superview; i++) {
        v = v.superview;
        CGRect markerFrame = [elementContainer convertRect:curtainView.frame toView:v];
        UIView *marker = [[UIView alloc] initWithFrame:markerFrame];
        marker.backgroundColor = colors[i];
        marker.layer.cornerRadius = cornerRadius;
        marker.layer.masksToBounds = YES;
        marker.userInteractionEnabled = NO;
        [v addSubview:marker];
        LGDILog(@"DIAG: %@ marker added to level%ld %@ frame=%@",
                names[i], (long)(i + 3),
                NSStringFromClass(v.class),
                NSStringFromCGRect(markerFrame));
    }
}

static void LGDIInstallPillGlass(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGDIIsPlausibleIslandSize(gainMapView.bounds.size)) return;

    // 已经装过了（glass 关联在 gainMapView 上，每个实例一个 glass）
    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (glassView) return;

    // gainMapView.superview = curtainView
    UIView *curtainView = gainMapView.superview;
    if (!curtainView) return;

    // curtainView.superview = elementContainer（玻璃装在这里，作为 curtainView 的兄弟视图）
    UIView *elementContainer = curtainView.superview;
    if (!elementContainer) return;

    // 安装诊断标记（每层不同颜色）
    LGDIInstallDiagnosticMarkers(gainMapView);

    // 玻璃 frame = curtainView.frame（在 elementContainer 中的位置和大小）
    CGRect glassFrame = curtainView.frame;
    glassView = LGCreateRegisteredGlass(glassFrame, nil, @"DynamicIsland");
    if (!glassView) {
        LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil");
        return;
    }

    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.5]; // 白色半透明，更容易看到
    glassView.layer.cornerRadius = 0.0; // 形状靠 mask 控制
    glassView.layer.masksToBounds = YES;
    glassView.frame = glassFrame;

    // 暂时插到最上面，确保能看到
    [elementContainer addSubview:glassView];

    // 关联到 gainMapView 上（每个 gainMapView 实例对应一个 glass）
    objc_setAssociatedObject(gainMapView, kLGDIPillGlassKey, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 延迟应用滤镜
    __weak LGLiveBackdropView *weakGlass = glassView;
    for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakGlass applyFilters];
        });
    }

    // 用 gainMapView 渲染 mask（获取胶囊形状的 alpha）
    LGDIScheduleMaskUpdate(gainMapView, glassView, kLGDIPillMaskLayerKey);

    LGDILog(@"glass created size=%@ on elementContainer=%@",
            NSStringFromCGSize(glassFrame.size),
            NSStringFromClass(elementContainer.class));
}

static void LGDIRemovePillGlass(UIView *gainMapView) {
    if (!gainMapView) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(gainMapView, kLGDIPillGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(gainMapView, kLGDIPillMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"glass removed from gainMapView");
    }
}

static void LGDIRefreshPillGlass(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (!glassView) return;

    // gainMapView.superview = curtainView
    UIView *curtainView = gainMapView.superview;
    if (!curtainView) return;

    // 同步 glass frame 到 curtainView.frame（在 elementContainer 中的位置）
    CGRect targetFrame = curtainView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIPillMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    // 用 gainMapView 渲染 mask
    LGDIScheduleMaskUpdate(gainMapView, glassView, kLGDIPillMaskLayerKey);
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
        LGDILog(@"[_SBGainMapView layoutSubviews] bounds=%@", NSStringFromCGRect(self.bounds));
        LGDIRefreshPillGlass(self);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;

    // glass 直接关联在 gainMapView 上
    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGDIPillGlassKey);
    if (glass) glass.hidden = hidden;
}

%end
%end

// =============================================================================
//  Hook: _SBSystemApertureMagiciansCurtainView
//  Mango 二进制确认：hook 了 didMoveToWindow / setHidden:
//  作用：窗帘视图显隐变化时同步玻璃显隐（通过 gainMapView 间接驱动）
//  注意：glass 直接装在 gainMapView 上，不由 curtainView 管理
// =============================================================================

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end

%group CurtainViewHook
%hook _SBSystemApertureMagiciansCurtainView

- (void)setHidden:(BOOL)hidden {
    %orig;
    // curtainView 显隐变化时，gainMapView 也会跟着变化，glass 由 gainMapView 管理
}

- (void)layoutSubviews {
    %orig;
    // curtainView layout 变化时，gainMapView 也会 layout，glass 更新由 gainMapView layoutSubviews 驱动
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
        // 找到已存在的 gainMapView 并重新应用滤镜
        UIView *gainMapView = LGDIFindExistingGainMapView();
        if (gainMapView) {
            LGLiveBackdropView *glass = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
            if (glass && [glass isKindOfClass:[LGLiveBackdropView class]]) {
                [glass applyFilters];
                LGDIScheduleMaskUpdate(gainMapView, glass, kLGDIPillMaskLayerKey);
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
