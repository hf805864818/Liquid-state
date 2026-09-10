// =============================================================================
//  DynamicIsland.x — 灵动岛液态玻璃（v2 重构版）
//
//  核心思路（对照 Mango 的实际实现，不再走壁纸窗口弯路）：
//
//  1. 黑色形体来自 SpringBoard 内部三个私有视图：
//       _SBSystemApertureMagiciansCurtainView  黑色幕布（药丸/展开卡片的形变主体）
//       _SBGainMapView                         HDR 增益压暗层（幕布子视图）
//       描边/压暗装饰视图                       SBFTouchPassThroughView 容器内
//     它们一律强制隐藏/清底，而不是去改 SBSystemApertureWindow 的透明度。
//
//  2. 玻璃（LGLiveBackdropView / CABackdropLayer + backboardd 折射滤镜）
//     直接插在灵动岛自己的层级里：幕布向上找到的“第一个不裁剪子视图的容器”
//     （iOS 16 上即 SBFTouchPassThroughView），insertSubview:atIndex:0，
//     位于所有实时活动内容层之下。backdrop 可以直接采样到灵动岛窗口下方的
//     实时画面（前台 App / 桌面图标 / 壁纸），这是和 Mango pillLiquidGlassView
//     相同的层级方案。
//
//  3. 几何以 curtain 为唯一真源（药丸 ↔ 展开卡片都是它在形变）。
//     setLayoutMode:reason: 触发后用 CADisplayLink 读 curtain 图层的
//     presentationLayer 逐帧跟随弹簧动画，避免玻璃与黑色形体脱节。
//
//  4. 触控：LGLiveBackdropView 初始化时已 userInteractionEnabled = NO，
//     不需要任何 hitTest 覆盖。
//
//  事件源（与 Mango 二进制中确认的 hook 点一致）：
//    - SBSystemApertureViewController  viewWillAppear: / viewDidLayoutSubviews
//    - SBFTouchPassThroughView         layoutSubviews
//    - _SBSystemApertureMagiciansCurtainView  didMoveToWindow / layoutSubviews / setHidden:
//    - _SBGainMapView                  didMoveToWindow / layoutSubviews / setHidden:
//    - SBSystemApertureSceneElement    setLayoutMode:reason:
//    - _SBSystemApertureContainerViewContentView  setBackgroundColor:（可选类，旧系统）
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <math.h>

#ifndef LIQUIDASS_DEBUG
#define LIQUIDASS_DEBUG 0
#endif

#pragma mark - Logging

static void LGDILog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDILog(NSString *fmt, ...) {
#if LIQUIDASS_DEBUG
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI] %@", s);
#else
    (void)fmt;
#endif
}

#pragma mark - Private class interfaces

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end
@interface _SBGainMapView : UIView
@end
@interface SBFTouchPassThroughView : UIView
@end
@interface SBSystemApertureViewController : UIViewController
@end
@interface SBSystemApertureSceneElement : NSObject
@end
@interface _SBSystemApertureContainerViewContentView : UIView
@end
@interface SBSystemApertureWindow : UIWindow
@end

#pragma mark - Constants / association keys

static NSString * const kLGDIFilterPrefix    = @"DynamicIsland";
static NSString * const kLGDIBackdropGroup   = @"dylv.liquidglass.island";

static void *kLGDIRestoreInfoKey  = &kLGDIRestoreInfoKey; // 被压制装饰视图 -> 原始状态

// 药丸/展开判定与尺寸门限
static const CGFloat kLGDIMinWidth  = 60.0;
static const CGFloat kLGDIMinHeight = 20.0;
static const CGFloat kLGDIMaxWidth  = 500.0;
static const CGFloat kLGDIMaxHeight = 300.0;

#pragma mark - Controller state

static __weak UIView            *sLGDICurtain;   // 当前幕布（唯一）
static __weak UIView            *sLGDIHost;      // 玻璃挂载容器
static __weak LGLiveBackdropView *sLGDIGlass;    // 当前玻璃
static BOOL                      sLGDIActive;    // 功能开关（本进程）
static BOOL                      sLGDISyncQueued;
static CADisplayLink            *sLGDILink;
static CFTimeInterval            sLGDILinkDeadline;

// =============================================================================
//  View tree helpers
// =============================================================================

static inline BOOL LGDIIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static BOOL LGDIClassName(UIView *v, NSString *name) {
    return v && [NSStringFromClass(v.class) isEqualToString:name];
}

static BOOL LGDIInApertureWindow(UIView *v) {
    for (UIView *a = v; a; a = a.superview) {
        NSString *name = NSStringFromClass(a.class);
        if ([name containsString:@"SystemAperture"]) return YES;
    }
    return NO;
}

static UIView *LGDIFindSubviewOfClass(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *hit = LGDIFindSubviewOfClass(sub, className);
        if (hit) return hit;
    }
    return nil;
}

static UIView *LGDIFindCurtainInWindows(void) {
    Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
    if (!curtainClass) return nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *hit = LGDIFindSubviewOfClass(window,
                                                 @"_SBSystemApertureMagiciansCurtainView");
            if (hit) return hit;
        }
    }
    // 兼容老系统（connectedScenes 取不到系统窗口时回退 keyWindow/windows）
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIView *hit = LGDIFindSubviewOfClass(window,
                                             @"_SBSystemApertureMagiciansCurtainView");
        if (hit) return hit;
    }
    return nil;
}

static BOOL LGDIIsPlausibleSize(CGSize size) {
    return size.width  >= kLGDIMinWidth  && size.width  <= kLGDIMaxWidth &&
           size.height >= kLGDIMinHeight && size.height <= kLGDIMaxHeight;
}

// 从 curtain 向上找“最深的不裁剪子视图的祖先”作为玻璃容器。
// iOS 16 实测为 SBFTouchPassThroughView；找不到时退回灵动岛窗口。
static UIView *LGDIHostForCurtain(UIView *curtain) {
    UIWindow *window = curtain.window;
    UIView *fallback = window;
    for (UIView *a = curtain.superview; a && a != window; a = a.superview) {
        if (a.clipsToBounds) continue;
        return a; // 第一个（最深的）不裁剪祖先
    }
    return fallback;
}

// =============================================================================
//  装饰视图压制（描边 / 压暗层 / 容器底色）
//  只动“叶子级、非交互、非内容”的视图，实时活动内容绝不碰。
// =============================================================================

static BOOL LGDIStringMatchesAny(NSString *s, NSArray<NSString *> *keywords) {
    for (NSString *k in keywords) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static BOOL LGDIIsContentSubview(UIView *v) {
    static NSArray *kContentKeywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kContentKeywords = @[
            @"Element", @"Presenter", @"Content", @"Scene", @"Compact",
            @"Expanded", @"Leading", @"Trailing", @"Hero", @"Attachment",
            @"Custom", @"Activity", @"ViewController",
        ];
    });
    return LGDIStringMatchesAny(NSStringFromClass(v.class), kContentKeywords);
}

static BOOL LGDIIsDecorSubview(UIView *v) {
    static NSArray *kDecorKeywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kDecorKeywords = @[
            @"Line", @"Outline", @"Stroke", @"Separator", @"Dim",
            @"Gradient", @"Shadow", @"Backdrop", @"Material",
            @"Background", @"Tint", @"Overlay",
        ];
    });
    return LGDIStringMatchesAny(NSStringFromClass(v.class), kDecorKeywords);
}

static BOOL LGDIShouldSuppressDecor(UIView *v) {
    if (!v || v == sLGDIGlass) return NO;
    if (LGDIClassName(v, @"_SBSystemApertureMagiciansCurtainView")) return NO;
    if (LGDIClassName(v, @"_SBGainMapView")) return NO;
    if (v.userInteractionEnabled || v.gestureRecognizers.count > 0) return NO;
    if (v.subviews.count > 2) return NO;            // 内容容器一定有子视图
    if (LGDIIsContentSubview(v)) return NO;
    return LGDIIsDecorSubview(v);
}

// 灵动岛内可能嵌套多个 SBFTouchPassThroughView，每个容器的装饰压制都要
// 能在停用/换宿主时还原，因此用 weak 集合统一追踪所有被动过的视图。
static NSHashTable<UIView *> *sLGDISuppressedViews;

static void LGDIRegisterSuppressed(UIView *v, NSDictionary *info) {
    if (!sLGDISuppressedViews) {
        sLGDISuppressedViews = [NSHashTable weakObjectsHashTable];
    }
    objc_setAssociatedObject(v, kLGDIRestoreInfoKey, info,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sLGDISuppressedViews addObject:v];
}

static void LGDISuppressDecorations(UIView *host) {
    if (!host || !sLGDIActive) return;

    // 容器自身底色清空
    if (host.backgroundColor && host.backgroundColor != UIColor.clearColor
        && !objc_getAssociatedObject(host, kLGDIRestoreInfoKey)) {
        LGDIRegisterSuppressed(host, @{ @"bg": host.backgroundColor });
    }
    if (objc_getAssociatedObject(host, kLGDIRestoreInfoKey)
        && host.backgroundColor != UIColor.clearColor) {
        host.backgroundColor = UIColor.clearColor;
    }

    for (UIView *sub in host.subviews) {
        if (!LGDIShouldSuppressDecor(sub)) continue;
        if (!objc_getAssociatedObject(sub, kLGDIRestoreInfoKey)) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"alpha"]  = @(sub.alpha);
            info[@"hidden"] = @(sub.hidden);
            if (sub.backgroundColor) info[@"bg"] = sub.backgroundColor;
            LGDIRegisterSuppressed(sub, info);
            LGDILog(@"suppressed decor %@", NSStringFromClass(sub.class));
        }
        // 已记录过：系统可能在布局中把状态改回来，等值时不重复写（驱动每帧调用）
        if (sub.alpha != 0.0) sub.alpha = 0.0;
        if (sub.backgroundColor && sub.backgroundColor != UIColor.clearColor) {
            sub.backgroundColor = UIColor.clearColor;
        }
    }
}

static void LGDIRestoreAllSuppressed(void) {
    for (UIView *v in [sLGDISuppressedViews allObjects]) {
        NSDictionary *info = objc_getAssociatedObject(v, kLGDIRestoreInfoKey);
        if (!info) continue;
        if (info[@"alpha"])  v.alpha = [info[@"alpha"] floatValue];
        if (info[@"hidden"]) v.hidden = [info[@"hidden"] boolValue];
        // 直接写图层，绕过 setBackgroundColor: hook（热切换宿主时开关仍为开启状态）
        if (info[@"bg"])     v.layer.backgroundColor = [info[@"bg"] CGColor];
        objc_setAssociatedObject(v, kLGDIRestoreInfoKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"restored decor %@", NSStringFromClass(v.class));
    }
    [sLGDISuppressedViews removeAllObjects];
}

// =============================================================================
//  Geometry sync
// =============================================================================

static CGFloat LGDIFallbackCornerRadius(CGRect f) {
    // 药丸：完全半圆角；展开卡片：约为高度的 1/4（系统实测 40~44pt 区间）
    if (f.size.width > f.size.height * 1.5) {
        return MIN(MAX(f.size.height * 0.24, 36.0), 52.0);
    }
    return f.size.height / 2.0;
}

static void LGDISyncGeometryFromPresentation(BOOL usePresentation) {
    LGLiveBackdropView *glass = sLGDIGlass;
    UIView *curtain = sLGDICurtain;
    UIView *host = sLGDIHost;
    if (!glass || !curtain || !host) return;

    CALayer *pl = usePresentation ? curtain.layer.presentationLayer : nil;
    CGRect targetFrame;
    CGFloat targetRadius;

    if (pl) {
        // presentationLayer.frame 位于 curtain.superview 的坐标系。
        // 注意不能用 isnormal()：原点坐标合法地可以是 0，而 isnormal(0)==false。
        CGRect pf = pl.frame;
        BOOL pfValid = isfinite(pf.origin.x) && isfinite(pf.origin.y)
                    && isfinite(pf.size.width) && isfinite(pf.size.height)
                    && !CGRectIsNull(pf) && !CGRectIsInfinite(pf)
                    && pf.size.width > 1.0 && pf.size.height > 1.0;
        if (pfValid) {
            targetFrame = [curtain.superview convertRect:pf toView:host];
            targetRadius = pl.cornerRadius > 0.5 ? pl.cornerRadius
                                                 : LGDIFallbackCornerRadius(pf);
        } else {
            pl = nil;
        }
    }
    if (!pl) {
        targetFrame = [curtain convertRect:curtain.bounds toView:host];
        targetRadius = curtain.layer.cornerRadius > 0.5
                           ? curtain.layer.cornerRadius
                           : LGDIFallbackCornerRadius(curtain.bounds);
    }

    if (!LGDIIsPlausibleSize(targetFrame.size)) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (!CGRectEqualToRect(glass.frame, targetFrame)) {
        glass.frame = targetFrame;
    }
    if (fabs(glass.layer.cornerRadius - targetRadius) > 0.25) {
        glass.layer.cornerRadius = targetRadius;
    }
    // cornerCurve / masksToBounds 安装时已固定，逐帧同步不再重复写入
    [CATransaction commit];
}

// =============================================================================
//  Transition driver — 逐帧跟随系统弹簧形变
// =============================================================================

static void LGDIStopDriver(void);

static void LGDIDriverTick(CADisplayLink *link) {
    (void)link;
    @autoreleasepool {
        UIView *curtain = sLGDICurtain;
        UIView *host = sLGDIHost;
        if (!sLGDIActive || !curtain || !host || !sLGDIGlass) {
            LGDIStopDriver();
            return;
        }
        // 形变期间系统可能反复把幕布/装饰放回来，每帧重新压制
        if (!curtain.hidden) curtain.hidden = YES;
        UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
        if (gain && !gain.hidden) gain.hidden = YES;
        LGDISuppressDecorations(host);
        LGDISyncGeometryFromPresentation(YES);

        if (CACurrentMediaTime() >= sLGDILinkDeadline) {
            LGDISyncGeometryFromPresentation(NO);
            LGDIStopDriver();
        }
    }
}

#pragma mark - driver target（不能把 self 用在 C 函数里，用独立对象承载）

@interface LGDIDisplayLinkTarget : NSObject
@end
@implementation LGDIDisplayLinkTarget
- (void)tick:(CADisplayLink *)link { LGDIDriverTick(link); }
@end

static LGDIDisplayLinkTarget *sLGDILinkTarget;

static void LGDIStartDriverReal(NSTimeInterval duration) {
    if (!sLGDILinkTarget) sLGDILinkTarget = [LGDIDisplayLinkTarget new];
    if (!sLGDILink) {
        sLGDILink = [CADisplayLink displayLinkWithTarget:sLGDILinkTarget
                                                selector:@selector(tick:)];
        [sLGDILink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    sLGDILink.paused = NO;
    sLGDILinkDeadline = CACurrentMediaTime() + duration;
}

static void LGDIStopDriver(void) {
    sLGDILink.paused = YES;
}

#pragma mark - Forward declarations

static void LGDIScheduleSync(NSTimeInterval driverDuration);
static void LGDIReconcile(void);

// =============================================================================
//  Glass lifecycle
// =============================================================================

static void LGDIInstallGlass(UIView *curtain) {
    if (!sLGDIActive || !curtain || !curtain.window) return;
    if (!LGDIIsPlausibleSize(curtain.bounds.size)) return;

    UIView *host = LGDIHostForCurtain(curtain);
    if (!host) return;

    // 幕布 + GainMap 必须先于玻璃隐藏：它们和玻璃同属一个窗口层级，
    // 若幕布仍渲染黑色，backdrop 采样到的就是黑幕布而不是窗外实时画面。
    curtain.hidden = YES;
    UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
    gain.hidden = YES;

    LGLiveBackdropView *glass = sLGDIGlass;
    if (!glass || glass.superview != host) {
        if (!glass) {
            CGRect frame = [curtain convertRect:curtain.bounds toView:host];
            glass = LGCreateRegisteredGlass(frame, kLGDIBackdropGroup, kLGDIFilterPrefix);
            if (!glass) {
                LGDILog(@"install failed: LGCreateRegisteredGlass returned nil");
                return;
            }
            sLGDIGlass = glass;
        }
        glass.layer.cornerCurve   = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        [host insertSubview:glass atIndex:0];
        LGDILog(@"glass installed in host=%@ frame=%@",
                NSStringFromClass(host.class),
                NSStringFromCGRect(glass.frame));

        // backboardd 滤镜 atom 注册有重试，补发几次 applyFilters
        __weak LGLiveBackdropView *weakGlass = glass;
        for (NSNumber *delay in @[ @0.5, @1.5, @3.0, @6.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }
    }

    sLGDICurtain = curtain;
    sLGDIHost = host;

    LGDISuppressDecorations(host);
    LGDISyncGeometryFromPresentation(NO);
    LGDIScheduleSync(0.35);
}

static void LGDITeardown(BOOL featureDisabled) {
    LGLiveBackdropView *glass = sLGDIGlass;

    LGDIStopDriver();

    if (glass) {
        [glass removeFromSuperview];
        sLGDIGlass = nil;
    }
    // 恢复所有被压制的装饰视图（可能分布在多个嵌套容器中）
    LGDIRestoreAllSuppressed();

    if (featureDisabled) {
        // 恢复系统黑色形体（setHidden: hook 在 sLGDIActive=NO 时放行）
        UIView *curtain = sLGDICurtain;
        if (!curtain) curtain = LGDIFindCurtainInWindows();
        if (curtain) {
            UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
            if (gain) gain.hidden = NO;
            curtain.hidden = NO;
        }
    }

    sLGDICurtain = nil;
    sLGDIHost = nil;
}

// =============================================================================
//  Sync scheduling
// =============================================================================

static void LGDIDoScheduledSync(void) {
    sLGDISyncQueued = NO;
    if (!sLGDIActive) return;

    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (!curtain || !curtain.window) return;

    if (!sLGDIGlass) {
        LGDIInstallGlass(curtain);
        return;
    }

    // 弱引用可能在场景切换后丢失，找回后必须回写，否则几何同步会永久空转
    sLGDICurtain = curtain;

    // 容器可能在展开时被系统换掉
    UIView *host = LGDIHostForCurtain(curtain);
    if (host && host != sLGDIHost) {
        LGDILog(@"host changed: %@ -> %@, reinstalling",
                NSStringFromClass(sLGDIHost.class), NSStringFromClass(host.class));
        LGDITeardown(NO);
        LGDIInstallGlass(curtain);
        return;
    }

    if (!curtain.hidden) curtain.hidden = YES;
    UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
    if (gain && !gain.hidden) gain.hidden = YES;
    LGDISuppressDecorations(host);
    LGDISyncGeometryFromPresentation(NO);
}

static void LGDIScheduleSync(NSTimeInterval driverDuration) {
    if (!sLGDIActive) return;

    if (driverDuration > 0) {
        LGDIStartDriverReal(driverDuration);
    }
    if (!sLGDISyncQueued) {
        sLGDISyncQueued = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            LGDIDoScheduledSync();
        });
    }
}

// =============================================================================
//  Reconcile（开关 / 启动 / 视图挂载）
// =============================================================================

static void LGDIReconcile(void) {
    BOOL enabled = lgHostEnabled(kLGDIFilterPrefix);

    if (!enabled) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"feature disabled, stock island restored");
        }
        return;
    }

    sLGDIActive = YES;
    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (curtain && curtain.window) {
        LGDIInstallGlass(curtain);
    } else {
        LGDILog(@"reconcile: no on-screen curtain yet");
    }
}

static void LGDIHandleCurtainAttached(UIView *curtain) {
    if (!sLGDIActive) return;
    sLGDICurtain = curtain;
    // didMoveToWindow 时层级往往还没布局完，延后一拍再装
    dispatch_async(dispatch_get_main_queue(), ^{
        if (curtain.window && LGDIIsPlausibleSize(curtain.bounds.size)) {
            LGDIInstallGlass(curtain);
        } else {
            LGDIScheduleSync(0.25);
        }
    });
}

static BOOL LGDIShouldForceHidden(UIView *view) {
    return sLGDIActive && view.window != nil && LGDIInApertureWindow(view);
}

// =============================================================================
//  Hook: _SBSystemApertureMagiciansCurtainView（黑色形变主体）
// =============================================================================

%group LGDICurtainHook
%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGDILog(@"curtain didMoveToWindow bounds=%@", NSStringFromCGRect(self.bounds));
        LGDIHandleCurtainAttached(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGDIShouldForceHidden(self)) {
        if (!self.hidden) self.hidden = YES;
        LGDIScheduleSync(0.35);
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGDIShouldForceHidden(self) && !hidden) {
        LGDILog(@"curtain setHidden:NO blocked");
        hidden = YES;
    }
    %orig(hidden);
}

%end
%end

// =============================================================================
//  Hook: _SBGainMapView（HDR 压暗层）
// =============================================================================

%group LGDIGainMapHook
%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        if (LGDIShouldForceHidden(self)) {
            self.hidden = YES;
            LGDIScheduleSync(0.25);
        }
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGDIShouldForceHidden(self)) {
        if (!self.hidden) self.hidden = YES;
        LGDIScheduleSync(0.35);
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGDIShouldForceHidden(self) && !hidden) hidden = YES;
    %orig(hidden);
}

%end
%end

// =============================================================================
//  Hook: SBFTouchPassThroughView（灵动岛容器：压装饰 + 布局信号）
//  该类系统多处使用，必须用灵动岛窗口祖先过滤。
// =============================================================================

%group LGDITouchHook
%hook SBFTouchPassThroughView

- (void)layoutSubviews {
    %orig;
    if (sLGDIActive && LGDIInApertureWindow(self)) {
        LGDISuppressDecorations(self);
        LGDIScheduleSync(0.35);
    }
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureViewController
// =============================================================================

%group LGDIApertureVCHook
%hook SBSystemApertureViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    LGDILog(@"aperture viewWillAppear");
    if (sLGDIActive) LGDIScheduleSync(0.35);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (sLGDIActive) LGDIScheduleSync(0.35);
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureSceneElement（药丸 ↔ 展开形变时机）
// =============================================================================

%group LGDISceneElementHook
%hook SBSystemApertureSceneElement

- (void)setLayoutMode:(NSInteger)layoutMode reason:(NSInteger)reason {
    %orig(layoutMode, reason);
    LGDILog(@"setLayoutMode=%ld reason=%ld", (long)layoutMode, (long)reason);
    if (sLGDIActive) {
        // 弹簧形变约 0.5~0.7s，驱动逐帧跟随
        LGDIScheduleSync(0.85);
    }
}

%end
%end

// =============================================================================
//  Hook: _SBSystemApertureContainerViewContentView（部分版本上的容器底色）
// =============================================================================

%group LGDIContentContainerHook
%hook _SBSystemApertureContainerViewContentView

- (void)setBackgroundColor:(UIColor *)color {
    if (sLGDIActive && color && color != UIColor.clearColor
        && CGColorGetAlpha(color.CGColor) > 0.0) {
        // 记录原色，停用功能时由 LGDIRestoreAllSuppressed 统一还原
        if (!objc_getAssociatedObject(self, kLGDIRestoreInfoKey)) {
            LGDIRegisterSuppressed(self, @{ @"bg": color });
        }
        color = UIColor.clearColor;
    }
    %orig(color);
}

- (void)layoutSubviews {
    %orig;
    if (sLGDIActive && self.backgroundColor
        && self.backgroundColor != UIColor.clearColor) {
        if (!objc_getAssociatedObject(self, kLGDIRestoreInfoKey)) {
            LGDIRegisterSuppressed(self, @{ @"bg": self.backgroundColor });
        }
        self.backgroundColor = UIColor.clearColor;
    }
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureWindow（布局信号，绝不动窗口透明度）
// =============================================================================

%group LGDIApertureWindowHook
%hook SBSystemApertureWindow

- (void)layoutSubviews {
    %orig;
    if (sLGDIActive) LGDIScheduleSync(0.35);
}

%end
%end

// =============================================================================
//  Constructor
// =============================================================================

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGDIIsSpringBoardProcess()) return;
    if (@available(iOS 16.0, *)) {} else return;

    // 设置变更：开关关闭时恢复原黑色岛，开启时重新装配（滤镜参数刷新由
    // LGLiveBackdropView 全局监听 ParametersReloaded 自动完成，无需此处处理）
    lgObservePreferenceReload(^{
        LGDIReconcile();
    });

    if (objc_getClass("_SBSystemApertureMagiciansCurtainView")) {
        %init(LGDICurtainHook);
    }
    if (objc_getClass("_SBGainMapView")) {
        %init(LGDIGainMapHook);
    }
    if (objc_getClass("SBFTouchPassThroughView")) {
        %init(LGDITouchHook);
    }
    if (objc_getClass("SBSystemApertureViewController")) {
        %init(LGDIApertureVCHook);
    }
    if (objc_getClass("SBSystemApertureSceneElement")) {
        %init(LGDISceneElementHook);
    }
    if (objc_getClass("_SBSystemApertureContainerViewContentView")) {
        %init(LGDIContentContainerHook);
    }
    if (objc_getClass("SBSystemApertureWindow")) {
        %init(LGDIApertureWindowHook);
    }

    sLGDIActive = lgHostEnabled(kLGDIFilterPrefix);
    LGDILog(@"initialized enabled=%d", sLGDIActive);

    // SpringBoard 启动时灵动岛已存在，didMoveToWindow 早于注入发生
    for (NSNumber *delay in @[ @0.8, @2.5, @5.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (sLGDIActive && !sLGDIGlass) LGDIReconcile();
        });
    }
}
