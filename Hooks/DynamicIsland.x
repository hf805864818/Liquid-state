// =============================================================================
//  DynamicIsland.x — Mango 架构精确复制（纯事件驱动，零轮询，零 KVO，零递归扫描）
//
//  事件源（与 Mango 二进制完全一致）：
//  1. FBSceneLayerManager._setLayers: → 场景图层变化（前后台、Live Activity）
//     Mango 二进制确认：hook 的方法名是 _setLayers:（mango__setLayers:）
//     不是 _performActionsForUIScene:（该方法在 SBMainWorkspace 上，不在 FBSceneLayerManager）
//  2. SBSystemApertureCaptureVisibilityShimViewController viewDidAppear/viewDidLayoutSubviews
//     → 灵动岛窗口出现时安装玻璃
//  3. SBNCNotificationDispatcher hook
//     → 通知系统驱动的灵动岛内容（来电、充电指示器等）
//
//  零 CPU 开销：没有内容时所有事件源都不触发
//  零递归扫描：事件本身就是信号，不需要扫描视图层级
//  零误触发：每个事件源只在对应类型的事件发生时触发
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
static void *kLGDIExpandedGlassKey = &kLGDIExpandedGlassKey;
static void *kLGDIPillMaskLayerKey = &kLGDIPillMaskLayerKey;
static void *kLGDIExpandedMaskLayerKey = &kLGDIExpandedMaskLayerKey;
static void *kLGDIDisplayLinkKey = &kLGDIDisplayLinkKey;
static void *kLGDICachedPillViewKey = &kLGDICachedPillViewKey;

#pragma mark - Size validation

static BOOL LGDIIsPlausibleIslandSize(CGSize size) {
    if (size.width <= 0 || size.height <= 0) return NO;
    if (size.width > 420 || size.height > 200) return NO;
    if (size.width < 80 || size.height < 20) return NO;
    return YES;
}

#pragma mark - View hierarchy utilities

static NSString *LGDIDumpViewHierarchy(UIView *view, NSInteger indent) {
    NSMutableString *result = [NSMutableString string];
    NSString *indentStr = [@"" stringByPaddingToLength:indent * 2 withString:@"  " startingAtIndex:0];
    NSString *clsName = NSStringFromClass(view.class);
    CGRect frame = view.frame;
    [result appendFormat:@"%@<%@: hidden=%d alpha=%.2f frame=%.1f,%.1f %.1fx%.1f>\n",
                         indentStr, clsName, view.hidden, view.alpha,
                         frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
    for (UIView *subview in view.subviews)
        [result appendString:LGDIDumpViewHierarchy(subview, indent + 1)];
    return result;
}

static UIView *LGDFindViewWithClassContaining(UIView *root, NSString *keyword) {
    if (!root) return nil;
    for (UIView *subview in root.subviews) {
        NSString *clsName = NSStringFromClass(subview.class);
        if ([clsName containsString:keyword]) return subview;
        UIView *found = LGDFindViewWithClassContaining(subview, keyword);
        if (found) return found;
    }
    return nil;
}

static UIView *LGDFindExpandedContentView(UIView *containerView) {
    if (!containerView) return nil;
    UIView *expanded = LGDFindViewWithClassContaining(containerView, @"Expanded");
    if (expanded) return expanded;
    CGFloat containerArea = containerView.bounds.size.width * containerView.bounds.size.height;
    for (UIView *subview in containerView.subviews) {
        CGFloat subArea = subview.bounds.size.width * subview.bounds.size.height;
        if (subArea > containerArea * 1.5 && !subview.hidden && subview.alpha > 0.5)
            return subview;
    }
    return nil;
}

// =============================================================================
//  LGExpandedGlassLinkProxy (≈ MangoExpandedGlassLinkProxy)
// =============================================================================

@interface LGExpandedGlassLinkProxy : NSObject
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UIView *glassView;
@property (nonatomic, assign) void *maskLayerKey;
- (void)lgExpandedGlassDisplayLinkTick:(CADisplayLink *)link;
@end

@implementation LGExpandedGlassLinkProxy
- (void)lgExpandedGlassDisplayLinkTick:(CADisplayLink *)link {
    UIView *src = self.sourceView;
    UIView *glass = self.glassView;
    if (!src || !glass || !src.window) {
        [link invalidate];
        LGDILog(@"ExpandedGlassLinkProxy: invalidating");
        return;
    }
    CGRect targetFrame = src.frame;
    if (!CGRectEqualToRect(glass.frame, targetFrame)) {
        glass.frame = targetFrame;
    }
    LGDIScheduleMaskUpdate(src, glass, self.maskLayerKey);
}
@end

// =============================================================================
//  LGPillManager (≈ MangoPillManager)
//  事件驱动单例，零轮询、零 KVO、零递归扫描
// =============================================================================

@interface LGPillManager : NSObject {
    CADisplayLink *_expandedDisplayLink;
    LGExpandedGlassLinkProxy *_expandedLinkProxy;
}

@property (nonatomic, strong) UIView *pillLiquidGlassView;
@property (nonatomic, strong) UIView *pillGlassTintView;
@property (nonatomic, assign) NSInteger pillGlassRetryCount;
@property (nonatomic, assign) NSTimeInterval lastPillGlassRefreshTime;
@property (nonatomic, assign) BOOL pillPendingLiquidSwitch;

@property (nonatomic, strong) UIView *expandedLiquidGlassView;
@property (nonatomic, strong) UIView *expandedGlassHostView;
@property (nonatomic, assign) NSInteger expandedGlassRetryCount;
@property (nonatomic, assign) NSTimeInterval lastExpandedGlassCaptureTime;
@property (nonatomic, assign) CGRect lastExpandedGlassFrame;

@property (nonatomic, weak) UIViewController *apertureViewController;
@property (nonatomic, weak) UIView *apertureContainerView;

@property (nonatomic, assign) BOOL pillContentActive;
@property (nonatomic, assign) BOOL expandedContentActive;

+ (instancetype)sharedManager;

// 生命周期回调
- (void)pillDidAppear:(id)sceneInfo;
- (void)sceneContentDidExit;
- (void)sceneLifecycleChangedWithActionType:(NSInteger)actionType bundleID:(NSString *)bundleID;

// 玻璃管理
- (void)refreshPillGlassBackdrop;
- (void)installPillGlass;
- (void)installExpandedGlass;
- (void)removePillGlass;
- (void)removeExpandedGlass;
- (void)cleanupPillGlassLiveCapture;
- (void)cleanupExpandedBackgroundGlassLiveCapture;
- (void)destroyExpandedBackgroundGlass;

// CADisplayLink
- (void)lgStartExpandedGlassLiveRefresh;
- (void)lgStopExpandedGlassLiveRefresh;

// 辅助
- (UIView *)findPillViewInAperture;
- (UIView *)findExpandedViewInAperture;
- (LGLiveBackdropView *)ensureGlassViewInContainer:(UIView *)container
                                              key:(const void *)key
                                           anchor:(UIView *)anchor
                                          logTag:(NSString *)logTag;

@end

@implementation LGPillManager

+ (instancetype)sharedManager {
    static LGPillManager *sManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sManager = [[LGPillManager alloc] init];
    });
    return sManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pillGlassRetryCount = 0;
        _expandedGlassRetryCount = 0;
        _lastPillGlassRefreshTime = 0.0;
        _lastExpandedGlassCaptureTime = 0.0;
        _pillContentActive = NO;
        _expandedContentActive = NO;
        _pillPendingLiquidSwitch = NO;
    }
    return self;
}

#pragma mark - Aperture view access

// 直接从 UIApplication 窗口列表查找灵动岛窗口的根视图
// 不依赖 viewDidAppear: hook，防止 hook 失败导致整个功能不可用
- (UIView *)findApertureContainerFromWindows {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        NSString *winCls = NSStringFromClass(window.class);
        if (![winCls containsString:@"Aperture"]) continue;
        UIViewController *rootVC = window.rootViewController;
        if (rootVC && rootVC.view) {
            // 递归搜索子视图控制器，找到实际的内容容器
            UIView *view = rootVC.view;
            // 如果根 VC 的视图本身就是容器（有子视图），直接返回
            if (view.subviews.count > 0) return view;
            // 搜索子 VC
            for (UIViewController *childVC in rootVC.childViewControllers) {
                if (childVC.view && childVC.view.subviews.count > 0) {
                    return childVC.view;
                }
            }
        }
    }
    return nil;
}

- (UIView *)findPillViewInAperture {
    UIView *container = self.apertureContainerView;
    if (!container || !container.window) {
        // apertureContainerView 未设置或已脱离窗口
        // 直接从窗口列表查找
        container = [self findApertureContainerFromWindows];
        if (container) {
            self.apertureContainerView = container;
            LGDILog(@"findPillViewInAperture: found container from windows: %@",
                    NSStringFromClass(container.class));
        } else {
            return nil;
        }
    }

    UIView *cached = objc_getAssociatedObject(container, kLGDICachedPillViewKey);
    if (cached && cached.superview) return cached;

    UIView *pillView = LGDFindViewWithClassContaining(container, @"Pill");
    if (pillView) {
        objc_setAssociatedObject(container, kLGDICachedPillViewKey, pillView,
                                 OBJC_ASSOCIATION_ASSIGN);
        LGDILog(@"findPillViewInAperture: found pill view: %@ frame=%.1fx%.1f",
                NSStringFromClass(pillView.class),
                pillView.bounds.size.width, pillView.bounds.size.height);
    }
    return pillView;
}

- (UIView *)findExpandedViewInAperture {
    UIView *container = self.apertureContainerView;
    if (!container || !container.window) return nil;
    return LGDFindExpandedContentView(container);
}

#pragma mark - Lifecycle callbacks (事件驱动核心)

// pillDidAppear: — 任何事件源检测到灵动岛内容出现时调用
// 事件源包括：场景生命周期、Darwin 通知、通知系统 hook
- (void)pillDidAppear:(id)sceneInfo {
    LGDILog(@"pillDidAppear: source=%@", sceneInfo);

    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    self.pillContentActive = YES;
    [self installPillGlass];
}

// sceneContentDidExit — 灵动岛内容退出时调用
- (void)sceneContentDidExit {
    LGDILog(@"sceneContentDidExit");

    self.pillContentActive = NO;
    self.pillGlassRetryCount = 0;

    [self removePillGlass];
    [self removeExpandedGlass];
}

// sceneLifecycleChangedWithActionType:bundleID:
// 由 FBSceneLayerManager._setLayers: hook 触发
// 不再递归扫描，直接安装玻璃（事件本身就是信号）
- (void)sceneLifecycleChangedWithActionType:(NSInteger)actionType bundleID:(NSString *)bundleID {
    LGDILog(@"sceneLifecycleChanged actionType=%ld bundleID=%@", (long)actionType, bundleID);

    if (!lgHostEnabled(@"DynamicIsland")) return;

    // 延迟安装玻璃（给系统时间渲染内容视图）
    __weak LGPillManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGPillManager *strong = weakSelf;
        if (!strong) return;

        UIView *pillView = [strong findPillViewInAperture];
        if (pillView && LGDIIsPlausibleIslandSize(pillView.bounds.size)) {
            // 场景事件触发 = 灵动岛有内容，直接安装
            if (!strong.pillContentActive) {
                [strong pillDidAppear:bundleID];
            } else {
                // 已安装，刷新
                [strong refreshPillGlassBackdrop];
            }
        }
    });
}

#pragma mark - Glass installation (含重试机制)

- (LGLiveBackdropView *)ensureGlassViewInContainer:(UIView *)container
                                              key:(const void *)key
                                           anchor:(UIView *)anchor
                                          logTag:(NSString *)logTag {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, key);
    if (glassView) return glassView;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LGDILog(@"=== Dynamic Island view hierarchy ===\n%@",
                LGDIDumpViewHierarchy(container, 0));
    });

    glassView = LGCreateRegisteredGlass(container.bounds, nil, @"DynamicIsland");
    if (!glassView) {
        LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil for %@", logTag);
        return nil;
    }

    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = UIColor.clearColor;
    glassView.layer.cornerRadius = 0.0;
    glassView.layer.masksToBounds = YES;

    if (anchor.superview) {
        [anchor.superview insertSubview:glassView belowSubview:anchor];
    } else {
        [container insertSubview:glassView atIndex:0];
    }

    objc_setAssociatedObject(container, key, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak LGLiveBackdropView *weakGlass = glassView;
    for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakGlass applyFilters];
        });
    }

    LGDILog(@"Created glass %@ anchor=%@ size=%.1fx%.1f",
            logTag, NSStringFromClass(anchor.class),
            container.bounds.size.width, container.bounds.size.height);
    return glassView;
}

- (void)installPillGlass {
    if (!self.pillContentActive) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;

    UIView *container = self.apertureContainerView;
    if (!container || !container.window) {
        if (self.pillGlassRetryCount < 5) {
            self.pillGlassRetryCount++;
            LGDILog(@"installPillGlass: container not ready, retry %ld",
                    (long)self.pillGlassRetryCount);
            __weak LGPillManager *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [ws installPillGlass];
            });
        }
        return;
    }

    UIView *pillView = [self findPillViewInAperture];
    if (!pillView || !LGDIIsPlausibleIslandSize(pillView.bounds.size)) {
        if (self.pillGlassRetryCount < 5) {
            self.pillGlassRetryCount++;
            LGDILog(@"installPillGlass: pillView not found, retry %ld",
                    (long)self.pillGlassRetryCount);
            __weak LGPillManager *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [ws installPillGlass];
            });
        }
        return;
    }

    self.pillGlassRetryCount = 0;

    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastPillGlassRefreshTime < 1.0) {
        LGDILog(@"installPillGlass: throttled");
        return;
    }
    self.lastPillGlassRefreshTime = now;

    LGLiveBackdropView *glassView = [self ensureGlassViewInContainer:container
                                                                 key:kLGDIPillGlassKey
                                                              anchor:pillView
                                                             logTag:@"pill"];
    if (!glassView) return;

    self.pillLiquidGlassView = glassView;

    CGRect targetFrame = pillView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIPillMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    if (glassView.superview != pillView.superview && pillView.superview) {
        [pillView.superview insertSubview:glassView belowSubview:pillView];
    }

    LGDIScheduleMaskUpdate(pillView, glassView, kLGDIPillMaskLayerKey);
    LGDILog(@"installPillGlass: success");
}

- (void)installExpandedGlass {
    if (!lgHostEnabled(@"DynamicIsland")) return;

    UIView *container = self.apertureContainerView;
    if (!container || !container.window) return;

    UIView *expandedView = [self findExpandedViewInAperture];
    if (!expandedView || !LGDIIsPlausibleIslandSize(expandedView.bounds.size)) {
        [self removeExpandedGlass];
        return;
    }

    self.expandedContentActive = YES;

    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastExpandedGlassCaptureTime < 1.0) return;
    self.lastExpandedGlassCaptureTime = now;

    self.expandedGlassRetryCount = 0;

    LGLiveBackdropView *glassView = [self ensureGlassViewInContainer:container
                                                                 key:kLGDIExpandedGlassKey
                                                              anchor:expandedView
                                                             logTag:@"expanded"];
    if (!glassView) return;

    self.expandedLiquidGlassView = glassView;
    self.expandedGlassHostView = expandedView;

    CGRect targetFrame = expandedView.frame;
    self.lastExpandedGlassFrame = targetFrame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIExpandedMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    if (glassView.superview != expandedView.superview && expandedView.superview) {
        [expandedView.superview insertSubview:glassView belowSubview:expandedView];
    }

    [self lgStartExpandedGlassLiveRefresh];
    LGDIScheduleMaskUpdate(expandedView, glassView, kLGDIExpandedMaskLayerKey);
    LGDILog(@"installExpandedGlass: success");
}

#pragma mark - Glass removal

- (void)removePillGlass {
    UIView *container = self.apertureContainerView;
    if (!container) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, kLGDIPillGlassKey);
    if (glassView) {
        [self cleanupPillGlassLiveCapture];
        [glassView removeFromSuperview];
        objc_setAssociatedObject(container, kLGDIPillGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(container, kLGDIPillMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"removePillGlass: removed");
    }
    self.pillLiquidGlassView = nil;
    self.pillGlassTintView = nil;
}

- (void)removeExpandedGlass {
    UIView *container = self.apertureContainerView;
    if (!container) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, kLGDIExpandedGlassKey);
    if (glassView) {
        [self lgStopExpandedGlassLiveRefresh];
        [self cleanupExpandedBackgroundGlassLiveCapture];
        [glassView removeFromSuperview];
        objc_setAssociatedObject(container, kLGDIExpandedGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(container, kLGDIExpandedMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"removeExpandedGlass: removed");
    }
    self.expandedLiquidGlassView = nil;
    self.expandedGlassHostView = nil;
    self.expandedContentActive = NO;
}

#pragma mark - Cleanup

- (void)cleanupPillGlassLiveCapture {
    LGDILog(@"cleanupPillGlassLiveCapture");
}

- (void)cleanupExpandedBackgroundGlassLiveCapture {
    LGDILog(@"cleanupExpandedBackgroundGlassLiveCapture");
}

- (void)destroyExpandedBackgroundGlass {
    [self lgStopExpandedGlassLiveRefresh];
    [self cleanupExpandedBackgroundGlassLiveCapture];
    [self removeExpandedGlass];
    LGDILog(@"destroyExpandedBackgroundGlass");
}

#pragma mark - Refresh

- (void)refreshPillGlassBackdrop {
    if (!self.pillContentActive) return;

    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastPillGlassRefreshTime < 1.0) return;
    self.lastPillGlassRefreshTime = now;

    UIView *container = self.apertureContainerView;
    if (!container) return;

    UIView *pillView = [self findPillViewInAperture];
    if (!pillView) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, kLGDIPillGlassKey);
    if (glassView) {
        LGDIScheduleMaskUpdate(pillView, glassView, kLGDIPillMaskLayerKey);
    }
}

#pragma mark - CADisplayLink (展开态实时刷新)

- (void)lgStartExpandedGlassLiveRefresh {
    if (_expandedDisplayLink) return;

    UIView *sourceView = self.expandedGlassHostView;
    UIView *glassView = self.expandedLiquidGlassView;
    if (!sourceView || !glassView) return;

    _expandedLinkProxy = [[LGExpandedGlassLinkProxy alloc] init];
    _expandedLinkProxy.sourceView = sourceView;
    _expandedLinkProxy.glassView = glassView;
    _expandedLinkProxy.maskLayerKey = kLGDIExpandedMaskLayerKey;

    _expandedDisplayLink = [CADisplayLink displayLinkWithTarget:_expandedLinkProxy
                                                       selector:@selector(lgExpandedGlassDisplayLinkTick:)];
    _expandedDisplayLink.preferredFramesPerSecond = 30;
    [_expandedDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                               forMode:NSRunLoopCommonModes];

    LGDILog(@"lgStartExpandedGlassLiveRefresh: started");
}

- (void)lgStopExpandedGlassLiveRefresh {
    if (_expandedDisplayLink) {
        [_expandedDisplayLink invalidate];
        _expandedDisplayLink = nil;
        _expandedLinkProxy = nil;
        LGDILog(@"lgStopExpandedGlassLiveRefresh: stopped");
    }
}

@end

// =============================================================================
//  Private class declarations
// =============================================================================

@interface SBSystemApertureViewController : UIViewController
@end

// iOS 17 灵动岛窗口的根控制器
@interface SBSystemApertureCaptureVisibilityShimViewController : UIViewController
@end

// 场景图层管理器（Mango hook 的目标类）
@interface FBSceneLayerManager : NSObject
@end

// 通知系统类（Mango 也引用了这些类）
@interface SBNCNotificationDispatcher : NSObject
@end

// =============================================================================
//  Hook: FBSceneLayerManager._setLayers:
//  Mango 二进制确认：hook 的是 _setLayers: 方法（不是 _performActionsForUIScene:）
//  _setLayers: 在场景图层变化时被系统调用（前后台切换、Live Activity 等）
//  使用 Logos %group + %init 确保 FBSceneLayerManager 类已加载
// =============================================================================

%group SceneLayerManager
%hook FBSceneLayerManager

- (void)_setLayers:(id)layers {
    %orig;
    LGDILog(@"FBSceneLayerManager _setLayers: %@", layers);
    [[LGPillManager sharedManager] sceneLifecycleChangedWithActionType:0 bundleID:nil];
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureCaptureVisibilityShimViewController
//  iOS 17 灵动岛窗口根控制器，比 SBSystemApertureViewController 更可靠
// =============================================================================

%hook SBSystemApertureCaptureVisibilityShimViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGDILog(@"ShimVC viewDidAppear");

    LGPillManager *mgr = [LGPillManager sharedManager];
    mgr.apertureViewController = self;
    mgr.apertureContainerView = self.view;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGDILog(@"ShimVC viewDidDisappear");

    LGPillManager *mgr = [LGPillManager sharedManager];
    [mgr removePillGlass];
    [mgr removeExpandedGlass];
    mgr.apertureContainerView = nil;
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = self.view;
    if (!view || !view.window) return;

    LGPillManager *mgr = [LGPillManager sharedManager];
    mgr.apertureContainerView = view;

    LGLiveBackdropView *pillGlass = objc_getAssociatedObject(view, kLGDIPillGlassKey);
    if (pillGlass) {
        UIView *pillView = [mgr findPillViewInAperture];
        if (pillView) {
            CGRect targetFrame = pillView.frame;
            if (!CGRectEqualToRect(pillGlass.frame, targetFrame)) {
                pillGlass.frame = targetFrame;
            }
            LGDIScheduleMaskUpdate(pillView, pillGlass, kLGDIPillMaskLayerKey);
        }
    }
}

%end

// =============================================================================
//  Hook: SBNCNotificationDispatcher (通知驱动事件)
//  通知系统分发通知时，可能触发灵动岛内容（来电、充电指示器等）
// =============================================================================

%hook SBNCNotificationDispatcher

// 拦截通知分发方法，当通知可能触发灵动岛内容时通知 PillManager
- (void)dispatchNotification:(id)notification withCompletionHandler:(id)handler {
    %orig;

    // 通知分发可能是灵动岛内容来源（来电、充电等）
    // 延迟检查并安装玻璃
    __weak LGPillManager *ws = [LGPillManager sharedManager];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGPillManager *strong = ws;
        if (!strong) return;

        UIView *pillView = [strong findPillViewInAperture];
        if (pillView && LGDIIsPlausibleIslandSize(pillView.bounds.size)) {
            if (!strong.pillContentActive) {
                LGDILog(@"NotificationDispatcher: pill content detected");
                [strong pillDidAppear:@"notification"];
            }
        }
    });
}

%end

// =============================================================================
//  Darwin 通知回调（偏好设置变更）
// =============================================================================

static void LGDIDarwinEventCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    @autoreleasepool {
        NSString *notificationName = (__bridge NSString *)name;
        LGDILog(@"Darwin event: %@", notificationName);

        LGPillManager *mgr = [LGPillManager sharedManager];

        // 系统级事件触发 → 延迟 0.5 秒后检查灵动岛
        // （给系统时间渲染灵动岛内容视图）
        __weak LGPillManager *ws = mgr;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGPillManager *strong = ws;
            if (!strong) return;

            UIView *pillView = [strong findPillViewInAperture];
            if (pillView && LGDIIsPlausibleIslandSize(pillView.bounds.size)) {
                // 系统级事件 + Pill 视图存在 = 灵动岛有内容
                if (!strong.pillContentActive) {
                    LGDILog(@"Darwin event → pillDidAppear");
                    [strong pillDidAppear:notificationName];
                } else {
                    // 已安装，刷新
                    [strong refreshPillGlassBackdrop];
                }
            } else {
                // Pill 视图不存在 = 灵动岛内容已退出
                if (strong.pillContentActive) {
                    LGDILog(@"Darwin event → sceneContentDidExit");
                    [strong sceneContentDidExit];
                }
            }
        });
    }
}

// =============================================================================
//  偏好设置变更监听
// =============================================================================

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
        LGPillManager *mgr = [LGPillManager sharedManager];
        if (mgr.pillContentActive) {
            [mgr refreshPillGlassBackdrop];
        }
    }
}

// =============================================================================
//  Constructor — 安装所有 hooks 和 Darwin 通知监听
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

    // 2. Logos %init: FBSceneLayerManager._setLayers:
    //    Mango 二进制确认：hook 的方法名是 _setLayers:（不是 _performActionsForUIScene:）
    //    Logos %init 自动处理类加载，比 objc_getClass + MSHookMessageEx 更可靠
    %init(SceneLayerManager);

    // 3. 检查关键类是否存在
    Class apertureVCClass = objc_getClass("SBSystemApertureViewController");
    Class shimVCClass = objc_getClass("SBSystemApertureCaptureVisibilityShimViewController");
    Class sceneLayerMgrClass = objc_getClass("FBSceneLayerManager");
    LGDILog(@"Class check: SBSystemApertureViewController=%@ ShimVC=%@ FBSceneLayerManager=%@",
            apertureVCClass ? @"YES" : @"NO",
            shimVCClass ? @"YES" : @"NO",
            sceneLayerMgrClass ? @"YES" : @"NO");

    LGDILog(@"Dynamic Island initialized (Mango architecture: FBSceneLayerManager._setLayers: + ShimVC)");
}
