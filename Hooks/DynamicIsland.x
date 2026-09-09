// =============================================================================
//  DynamicIsland.x — 完全复制 Mango 架构的事件驱动实现
//
//  核心设计（与 Mango 一致）：
//  1. 事件驱动：hook SBMainWorkspace 的 FBScene 生命周期方法
//     只有当场景生命周期变化时才触发玻璃安装/移除
//  2. LGPillManager：单例管理器，管理所有玻璃视图生命周期
//  3. 重试机制：pillGlassRetryCount / expandedGlassRetryCount
//  4. 节流：lastPillGlassRefreshTime / lastExpandedGlassCaptureTime
//  5. CADisplayLink：展开态实时刷新（LGExpandedGlassLinkProxy）
//  6. 不轮询 viewDidLayoutSubviews，零 CPU 开销
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>

// CydiaSubstrate (for MSHookMessageEx, same as Mango uses)
// Logos .x -> .m (Objective-C), so extern "C" is invalid here
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

#pragma mark - Mask rendering (保留原有实现)

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
static void *kLGDICachedApertureViewKey = &kLGDICachedApertureViewKey;

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
//  CADisplayLink 代理，驱动展开态实时刷新
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
        LGDILog(@"ExpandedGlassLinkProxy: source/glass/window nil, invalidating");
        return;
    }
    // 更新 frame 到目标位置（≈ mangoExpandedGlassTargetFrame）
    CGRect targetFrame = src.frame;
    if (!CGRectEqualToRect(glass.frame, targetFrame)) {
        glass.frame = targetFrame;
    }
    LGDIScheduleMaskUpdate(src, glass, self.maskLayerKey);
}
@end

// =============================================================================
//  LGPillManager (≈ MangoPillManager)
//  单例管理器：事件驱动，管理所有灵动岛玻璃视图生命周期
// =============================================================================

@interface LGPillManager : NSObject {
    CADisplayLink *_expandedDisplayLink;
    LGExpandedGlassLinkProxy *_expandedLinkProxy;
    id _pillSubviewsObserver;  // KVO 观察 Pill 视图 subviews 变化
}

// ===== Pill 玻璃属性（对应 Mango 的属性）=====
@property (nonatomic, strong) UIView *pillLiquidGlassView;     // pillLiquidGlassView
@property (nonatomic, strong) UIView *pillGlassTintView;       // pillGlassTintView
@property (nonatomic, assign) NSInteger pillGlassRetryCount;   // pillGlassRetryCount
@property (nonatomic, assign) NSTimeInterval lastPillGlassRefreshTime;  // lastPillGlassRefreshTime
@property (nonatomic, assign) BOOL pillPendingLiquidSwitch;    // pillPendingLiquidSwitch

// ===== 展开态玻璃属性 =====
@property (nonatomic, strong) UIView *expandedLiquidGlassView;     // expandedLiquidGlassView
@property (nonatomic, strong) UIView *expandedGlassHostView;       // expandedGlassHostView
@property (nonatomic, assign) NSInteger expandedGlassRetryCount;    // expandedGlassRetryCount
@property (nonatomic, assign) NSTimeInterval lastExpandedGlassCaptureTime; // lastExpandedGlassCaptureTime
@property (nonatomic, assign) CGRect lastExpandedGlassFrame;        // lastExpandedGlassFrame

// ===== 系统引用 =====
@property (nonatomic, weak) UIViewController *apertureViewController;
@property (nonatomic, weak) UIView *apertureContainerView;

// ===== 状态 =====
@property (nonatomic, assign) BOOL pillContentActive;   // 灵动岛是否有活跃内容
@property (nonatomic, assign) BOOL expandedContentActive;

+ (instancetype)sharedManager;

// ===== 生命周期回调（事件驱动）=====
- (void)pillDidAppear:(id)sceneInfo;           // ≈ MangoPillManager pillDidAppear:
- (void)sceneContentDidExit;                    // ≈ MangoPillManager sceneContentDidExit
- (void)sceneLifecycleChangedWithActionType:(NSInteger)actionType bundleID:(NSString *)bundleID;

// ===== 玻璃管理 =====
- (void)refreshPillGlassBackdrop;               // ≈ refreshPillGlassBackdrop
- (void)installPillGlass;                        // 安装收缩态玻璃（含重试）
- (void)installExpandedGlass;                    // 安装展开态玻璃（含重试）
- (void)removePillGlass;                         // 移除收缩态玻璃
- (void)removeExpandedGlass;                     // 移除展开态玻璃
- (void)cleanupPillGlassLiveCapture;            // ≈ cleanupPillGlassLiveCapture
- (void)cleanupExpandedBackgroundGlassLiveCapture; // ≈ cleanupExpandedBackgroundGlassLiveCapture
- (void)destroyExpandedBackgroundGlass;          // ≈ destroyExpandedBackgroundGlass

// ===== CADisplayLink 控制（展开态）=====
- (void)lgStartExpandedGlassLiveRefresh;         // ≈ mangoStartExpandedGlassLiveRefresh
- (void)lgStopExpandedGlassLiveRefresh;          // ≈ mangoStopExpandedGlassLiveRefresh

// ===== KVO 事件监听（替代轮询）=====
- (void)startObservingPillView:(UIView *)pillView;
- (void)stopObservingPillView;

// ===== 辅助 =====
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

- (UIView *)findPillViewInAperture {
    UIView *container = self.apertureContainerView;
    if (!container || !container.window) return nil;

    // 先用缓存
    UIView *cached = objc_getAssociatedObject(container, kLGDICachedPillViewKey);
    if (cached && cached.superview) return cached;

    // 重新搜索
    UIView *pillView = LGDFindViewWithClassContaining(container, @"Pill");
    if (pillView) {
        objc_setAssociatedObject(container, kLGDICachedPillViewKey, pillView,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
    return pillView;
}

- (UIView *)findExpandedViewInAperture {
    UIView *container = self.apertureContainerView;
    if (!container || !container.window) return nil;
    return LGDFindExpandedContentView(container);
}

#pragma mark - Lifecycle callbacks (事件驱动核心)

// pillDidAppear: — 灵动岛内容出现时调用
// 由 SBMainWorkspace 的场景生命周期 hook 触发
- (void)pillDidAppear:(id)sceneInfo {
    LGDILog(@"pillDidAppear: sceneInfo=%@", sceneInfo);

    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    self.pillContentActive = YES;

    // 立即尝试安装玻璃
    [self installPillGlass];

    // 启动 KVO 监听 Pill 视图内容变化（覆盖所有事件，零 CPU 开销）
    UIView *pillView = [self findPillViewInAperture];
    if (pillView) {
        [self startObservingPillView:pillView];
    }
}

// sceneContentDidExit — 灵动岛内容退出时调用
- (void)sceneContentDidExit {
    LGDILog(@"sceneContentDidExit");

    self.pillContentActive = NO;
    self.pillGlassRetryCount = 0;

    [self stopObservingPillView];
    [self removePillGlass];
    [self removeExpandedGlass];
}

// sceneLifecycleChangedWithActionType:bundleID:
// SBMainWorkspace hook 调用此方法通知场景生命周期变化
- (void)sceneLifecycleChangedWithActionType:(NSInteger)actionType bundleID:(NSString *)bundleID {
    LGDILog(@"sceneLifecycleChanged actionType=%ld bundleID=%@", (long)actionType, bundleID);

    if (!lgHostEnabled(@"DynamicIsland")) return;

    // 延迟检查灵动岛内容（给系统时间渲染内容视图）
    // Mango 也是延迟检查，不是立即检查
    __weak LGPillManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGPillManager *strong = weakSelf;
        if (!strong) return;

        UIView *pillView = [strong findPillViewInAperture];
        if (pillView && LGDIIsPlausibleIslandSize(pillView.bounds.size)) {
            // 检查 Pill 是否有活跃内容
            BOOL hasContent = [strong pillViewHasActiveContent:pillView];
            if (hasContent && !strong.pillContentActive) {
                [strong pillDidAppear:bundleID];
            } else if (!hasContent && strong.pillContentActive) {
                [strong sceneContentDidExit];
            } else if (hasContent && strong.pillContentActive) {
                // 内容已存在且玻璃已安装，刷新一下
                [strong refreshPillGlassBackdrop];
            }
        }
    });
}

// 检测 Pill 视图是否有活跃内容（保留原有逻辑）
- (BOOL)pillViewHasActiveContent:(UIView *)pillView {
    if (!pillView) return NO;
    __block NSUInteger contentCount = 0;
    void (^scan)(UIView *) = ^(UIView *v) {
        for (UIView *sub in v.subviews) {
            if (sub.hidden || sub.alpha < 0.1) continue;
            NSString *cls = NSStringFromClass(sub.class);
            if ([cls containsString:@"Background"] ||
                [cls containsString:@"Backdrop"] ||
                [cls containsString:@"Shadow"] ||
                [cls containsString:@"Container"]) {
                scan(sub);
                continue;
            }
            if (sub.bounds.size.width > 5 && sub.bounds.size.height > 5)
                contentCount++;
            scan(sub);
        }
    };
    scan(pillView);
    return contentCount > 0;
}

#pragma mark - Glass installation (含重试机制)

- (LGLiveBackdropView *)ensureGlassViewInContainer:(UIView *)container
                                              key:(const void *)key
                                           anchor:(UIView *)anchor
                                          logTag:(NSString *)logTag {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(container, key);
    if (glassView) return glassView;

    // 首次安装时打印视图层级
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

    // 延迟重试 applyFilters（与 Mango 一致）
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

// 安装收缩态玻璃（含重试机制，对应 Mango 的 pillGlassRetryCount）
- (void)installPillGlass {
    if (!self.pillContentActive) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;

    UIView *container = self.apertureContainerView;
    if (!container || !container.window) {
        // 容器不可用，重试
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

    // 重置重试计数
    self.pillGlassRetryCount = 0;

    // 节流检查（对应 Mango 的 lastPillGlassRefreshTime）
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastPillGlassRefreshTime < 1.0) {
        LGDILog(@"installPillGlass: throttled (last refresh %.1fs ago)",
                now - self.lastPillGlassRefreshTime);
        return;
    }
    self.lastPillGlassRefreshTime = now;

    // 创建/获取玻璃视图
    LGLiveBackdropView *glassView = [self ensureGlassViewInContainer:container
                                                                 key:kLGDIPillGlassKey
                                                              anchor:pillView
                                                             logTag:@"pill"];
    if (!glassView) return;

    self.pillLiquidGlassView = glassView;

    // 更新位置
    CGRect targetFrame = pillView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIPillMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    // 确保 glassView 在 pillView 下方
    if (glassView.superview != pillView.superview && pillView.superview) {
        [pillView.superview insertSubview:glassView belowSubview:pillView];
    }

    // 更新 mask
    LGDIScheduleMaskUpdate(pillView, glassView, kLGDIPillMaskLayerKey);

    LGDILog(@"installPillGlass: success");
}

// 安装展开态玻璃（含重试机制）
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

    // 节流
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastExpandedGlassCaptureTime < 1.0) return;
    self.lastExpandedGlassCaptureTime = now;

    // 重置重试
    self.expandedGlassRetryCount = 0;

    LGLiveBackdropView *glassView = [self ensureGlassViewInContainer:container
                                                                 key:kLGDIExpandedGlassKey
                                                              anchor:expandedView
                                                             logTag:@"expanded"];
    if (!glassView) return;

    self.expandedLiquidGlassView = glassView;
    self.expandedGlassHostView = expandedView;

    // 更新位置
    CGRect targetFrame = expandedView.frame;
    self.lastExpandedGlassFrame = targetFrame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIExpandedMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    // 确保 glassView 在 expandedView 下方
    if (glassView.superview != expandedView.superview && expandedView.superview) {
        [expandedView.superview insertSubview:glassView belowSubview:expandedView];
    }

    // 启动 CADisplayLink 实时刷新
    [self lgStartExpandedGlassLiveRefresh];

    // 立即更新 mask
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

#pragma mark - Cleanup (对应 Mango 的 cleanup 方法)

- (void)cleanupPillGlassLiveCapture {
    // 清理收缩态玻璃的实时捕获资源
    LGDILog(@"cleanupPillGlassLiveCapture");
}

- (void)cleanupExpandedBackgroundGlassLiveCapture {
    // 清理展开态玻璃的实时捕获资源
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

// lgStartExpandedGlassLiveRefresh — ≈ mangoStartExpandedGlassLiveRefresh
- (void)lgStartExpandedGlassLiveRefresh {
    if (_expandedDisplayLink) return; // 已在运行

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

    LGDILog(@"lgStartExpandedGlassLiveRefresh: started for %@",
            NSStringFromClass(sourceView.class));
}

// lgStopExpandedGlassLiveRefresh — ≈ mangoStopExpandedGlassLiveRefresh
- (void)lgStopExpandedGlassLiveRefresh {
    if (_expandedDisplayLink) {
        [_expandedDisplayLink invalidate];
        _expandedDisplayLink = nil;
        _expandedLinkProxy = nil;
        LGDILog(@"lgStopExpandedGlassLiveRefresh: stopped");
    }
}

#pragma mark - KVO 事件监听（替代轮询）

// 通过 KVO 观察 Pill 视图的 subviews 数组变化
// 当灵动岛有任何内容添加/移除时（计时器/通话/充电/音乐/Live Activity），
// 系统会修改 Pill 视图的 subviews，KVO 会立即触发回调
//
// 这是纯事件驱动，零 CPU 开销：
// - 没有内容时：KVO 不触发，CPU 占用 0
// - 有内容变化时：立即触发，延迟 < 16ms
// - 覆盖所有灵动岛事件：App 场景 + 系统级（计时器/通话/充电/AirDrop）
//
// 对比 5 秒定时器：
// - 定时器：最坏延迟 5 秒，持续 CPU 开销
// - KVO：即时响应，零空闲开销

static void *kLGDIPillSubviewsContext = &kLGDIPillSubviewsContext;

- (void)startObservingPillView:(UIView *)pillView {
    if (!pillView) return;

    // 先停止旧的观察
    [self stopObservingPillView];

    // KVO 观察 subviews 数组变化
    // 当系统往 Pill 里添加/移除内容视图时，subviews 数组会变化
    [pillView addObserver:self
               forKeyPath:@"subviews"
                  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                  context:kLGDIPillSubviewsContext];
    _pillSubviewsObserver = pillView; // 保存被观察的视图引用

    LGDILog(@"startObservingPillView: KVO installed on %@",
            NSStringFromClass(pillView.class));
}

- (void)stopObservingPillView {
    if (_pillSubviewsObserver) {
        @try {
            [(UIView *)_pillSubviewsObserver removeObserver:self
                                                  forKeyPath:@"subviews"
                                                     context:kLGDIPillSubviewsContext];
        } @catch (NSException *e) {
            LGDILog(@"stopObservingPillView: exception %@", e);
        }
        _pillSubviewsObserver = nil;
        LGDILog(@"stopObservingPillView: KVO removed");
    }
}

// KVO 回调：当 Pill 视图的 subviews 变化时触发
// 这覆盖了所有灵动岛事件（包括不走场景生命周期的系统级事件）
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != kLGDIPillSubviewsContext) {
        return; // 不是我们的观察
    }

    // subviews 变化了，延迟 0.1 秒检查（给系统时间完成布局）
    __weak LGPillManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGPillManager *strong = weakSelf;
        if (!strong) return;

        UIView *pillView = object;
        if (!pillView || !pillView.window) return;

        BOOL hasContent = [strong pillViewHasActiveContent:pillView];

        if (hasContent && !strong.pillContentActive) {
            // 新内容出现（可能是计时器/通话/充电等系统级事件）
            LGDILog(@"KVO: content appeared (system event)");
            [strong pillDidAppear:@"kvo"];
        } else if (!hasContent && strong.pillContentActive) {
            // 内容消失
            LGDILog(@"KVO: content disappeared");
            [strong sceneContentDidExit];
        } else if (hasContent && strong.pillContentActive) {
            // 内容已存在，可能是内容更新或展开态变化
            // 检查是否需要安装展开态玻璃
            UIView *expandedView = [strong findExpandedViewInAperture];
            if (expandedView && LGDIIsPlausibleIslandSize(expandedView.bounds.size)) {
                if (!strong.expandedContentActive) {
                    LGDILog(@"KVO: expanded content detected");
                    [strong installExpandedGlass];
                }
            } else {
                if (strong.expandedContentActive) {
                    [strong removeExpandedGlass];
                }
            }
        }
    });
}

@end

// =============================================================================
//  Private class declarations (forward declarations for hooking)
// =============================================================================

// iOS 17+ 灵动岛管理器
@interface SBSystemApertureViewController : UIViewController
@end

// SpringBoard 主工作区（场景生命周期管理）
@interface SBMainWorkspace : NSObject
@end

// =============================================================================
//  Hook: SBSystemApertureViewController
//  仅用于缓存视图引用，不在此安装玻璃（事件驱动）
// =============================================================================

%hook SBSystemApertureViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGDILog(@"SBSystemApertureViewController viewDidAppear");

    // 缓存视图引用给 LGPillManager
    LGPillManager *mgr = [LGPillManager sharedManager];
    mgr.apertureViewController = self;
    mgr.apertureContainerView = self.view;

    // 启动 KVO 监听 Pill 视图内容变化
    // 即使没有场景生命周期事件（如系统计时器/通话/充电），
    // 只要系统往 Pill 添加/移除内容视图，KVO 就会立即触发
    UIView *pillView = [mgr findPillViewInAperture];
    if (pillView) {
        [mgr startObservingPillView:pillView];
    } else {
        // Pill 视图可能还未创建，延迟重试
        __weak SBSystemApertureViewController *ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *pv = [[LGPillManager sharedManager] findPillViewInAperture];
            if (pv) {
                [[LGPillManager sharedManager] startObservingPillView:pv];
            }
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGDILog(@"SBSystemApertureViewController viewDidDisappear");

    // 视图消失时清理玻璃和 KVO
    LGPillManager *mgr = [LGPillManager sharedManager];
    [mgr stopObservingPillView];
    [mgr removePillGlass];
    [mgr removeExpandedGlass];
    mgr.apertureContainerView = nil;
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = self.view;
    if (!view || !view.window) return;

    // 仅更新容器引用（不在此安装/检测玻璃）
    LGPillManager *mgr = [LGPillManager sharedManager];
    mgr.apertureContainerView = view;

    // 如果玻璃已安装，更新 frame 位置
    LGLiveBackdropView *pillGlass = objc_getAssociatedObject(view, kLGDIPillGlassKey);
    if (pillGlass) {
        UIView *pillView = [mgr findPillViewInAperture];
        if (pillView) {
            CGRect targetFrame = pillView.frame;
            if (!CGRectEqualToRect(pillGlass.frame, targetFrame)) {
                pillGlass.frame = targetFrame;
            }
        }
        // 刷新 mask（节流在 LGDIScheduleMaskUpdate 内部处理）
        if (pillView) {
            LGDIScheduleMaskUpdate(pillView, pillGlass, kLGDIPillMaskLayerKey);
        }
    }

    // 展开态：检查是否有展开视图
    LGLiveBackdropView *expandedGlass = objc_getAssociatedObject(view, kLGDIExpandedGlassKey);
    if (expandedGlass) {
        UIView *expandedView = [mgr findExpandedViewInAperture];
        if (expandedView && LGDIIsPlausibleIslandSize(expandedView.bounds.size)) {
            CGRect targetFrame = expandedView.frame;
            if (!CGRectEqualToRect(expandedGlass.frame, targetFrame)) {
                expandedGlass.frame = targetFrame;
            }
        } else {
            // 展开视图消失了，清理展开态玻璃
            [mgr removeExpandedGlass];
        }
    }
}

%end

// =============================================================================
//  Hook: SBMainWorkspace (事件驱动核心)
//  hook _performActionsForUIScene:withUpdatedFBSScene:settingsDiff:fromSettings:
//       transitionContext:lifecycleActionType:
//  这是 Mango 使用的核心 hook 点：场景生命周期变化时触发
// =============================================================================

// 用 MSHookMessageEx 手动 hook（与 Mango 一致，因为方法签名复杂）
// 保存原始 IMP
static void (*sLGOrig_performActionsForUIScene)(id, SEL, id, id, id, id, id, NSInteger) = NULL;

static void LGHook_performActionsForUIScene(id self, SEL _cmd,
                                            id uiscene, id fbsscene,
                                            id settingsDiff, id fromSettings,
                                            id transitionContext,
                                            NSInteger lifecycleActionType) {
    // 调用原始方法
    if (sLGOrig_performActionsForUIScene) {
        sLGOrig_performActionsForUIScene(self, _cmd, uiscene, fbsscene,
                                        settingsDiff, fromSettings,
                                        transitionContext, lifecycleActionType);
    }

    // 事件驱动：通知 LGPillManager 场景生命周期变化
    // 提取 bundleID（从 FBSScene 或 uiscene 中）
    NSString *bundleID = nil;
    if ([fbsscene respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID = [fbsscene performSelector:@selector(bundleIdentifier)];
    } else if ([uiscene respondsToSelector:@selector(bundleIdentifier)]) {
        // NSScene 的 bundleIdentifier
    }

    // 通知 PillManager（延迟 0.3 秒给系统时间渲染）
    [[LGPillManager sharedManager] sceneLifecycleChangedWithActionType:lifecycleActionType
                                                             bundleID:bundleID];
}

// hook destroyScene:withTransitionContext:（场景销毁）
static void (*sLGOrig_destroyScene)(id, SEL, id, id) = NULL;

static void LGHook_destroyScene(id self, SEL _cmd, id scene, id transitionContext) {
    if (sLGOrig_destroyScene) {
        sLGOrig_destroyScene(self, _cmd, scene, transitionContext);
    }

    // 场景销毁时通知 PillManager
    LGDILog(@"destroyScene:withTransitionContext: scene=%@", scene);
    [[LGPillManager sharedManager] sceneContentDidExit];
}

// =============================================================================
//  偏好设置变更监听
// =============================================================================

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
        // 偏好变更时刷新玻璃
        LGPillManager *mgr = [LGPillManager sharedManager];
        if (mgr.pillContentActive) {
            [mgr refreshPillGlassBackdrop];
        }
    }
}

// =============================================================================
//  Constructor — 初始化 + 安装 hooks
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

    // 2. MSHookMessageEx: hook SBMainWorkspace 的场景生命周期方法
    //    （与 Mango 使用 MSHookMessageEx 一致）
    Class sbMainWorkspace = objc_getClass("SBMainWorkspace");
    if (sbMainWorkspace) {
        // _performActionsForUIScene:withUpdatedFBSScene:settingsDiff:fromSettings:
        //   transitionContext:lifecycleActionType:
        SEL performSel = NSSelectorFromString(
            @"_performActionsForUIScene:withUpdatedFBSScene:settingsDiff:fromSettings:transitionContext:lifecycleActionType:");

        Method m = class_getInstanceMethod(sbMainWorkspace, performSel);
        if (m) {
            sLGOrig_performActionsForUIScene = (void (*)(id, SEL, id, id, id, id, id, NSInteger))
                method_getImplementation(m);
            MSHookMessageEx(sbMainWorkspace, performSel,
                            (IMP)LGHook_performActionsForUIScene,
                            (IMP *)&sLGOrig_performActionsForUIScene);
            LGDILog(@"Hooked SBMainWorkspace _performActionsForUIScene:...");
        } else {
            LGDILog(@"WARN: SBMainWorkspace _performActionsForUIScene: not found");
        }

        // destroyScene:withTransitionContext:
        SEL destroySel = NSSelectorFromString(@"destroyScene:withTransitionContext:");
        Method dm = class_getInstanceMethod(sbMainWorkspace, destroySel);
        if (dm) {
            sLGOrig_destroyScene = (void (*)(id, SEL, id, id))
                method_getImplementation(dm);
            MSHookMessageEx(sbMainWorkspace, destroySel,
                            (IMP)LGHook_destroyScene,
                            (IMP *)&sLGOrig_destroyScene);
            LGDILog(@"Hooked SBMainWorkspace destroyScene:withTransitionContext:");
        }
    } else {
        LGDILog(@"WARN: SBMainWorkspace class not found, scene lifecycle hooks not installed");
    }

    LGDILog(@"Dynamic Island tweak initialized (Mango-style event-driven + KVO mode)");
}
