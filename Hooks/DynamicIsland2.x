// =============================================================================
//  DynamicIsland2.x — 灵动岛2（参考原版 Liquid (Gl)ass + DI1 架构）
//
//  用 Theos %hook 方式，hook 灵动岛相关的系统类
//  核心思路：
//  1. 隐藏系统黑色幕布 + 增益图
//  2. 玻璃插在 TouchPassThroughView（最高不裁剪祖先）最底层
//  3. 几何跟随 curtainView 形变
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGHostRegistry.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGDI2Mutex.h"
#import <notify.h>

#define LIQUIDASS_DEBUG 1

static void LGDI2Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDI2Log(NSString *fmt, ...) {
#if LIQUIDASS_DEBUG
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI2] %@", s);
#else
    (void)fmt;
#endif
}

// 私有类前向声明
@interface _SBSystemApertureMagiciansCurtainView : UIView
@end
@interface _SBGainMapView : UIView
@end
@interface SBFTouchPassThroughView : UIView
@end

// =============================================================================
// 全局状态
// =============================================================================

static __weak UIView *sLGDI2Curtain = nil;
static __weak UIView *sLGDI2Host = nil;
static __weak LGLiveBackdropView *sLGDI2Glass = nil;

// =============================================================================
// 功能开关
// =============================================================================

static BOOL LGDI2FeatureEnabled(void) {
    if (!LG_prefBool(@"DynamicIsland2.Enabled", NO)) return NO;
    if (!LG_globalEnabled()) return NO;
    // DI1 开着时 DI2 不工作（互斥）
    if (LG_prefBool(@"DynamicIsland.Enabled", YES)) return NO;
    return YES;
}

// =============================================================================
// 工具函数
// =============================================================================

static UIView *LGDI2FindHostForCurtain(UIView *curtain) {
    UIWindow *window = curtain.window;
    if (!window) return nil;

    UIView *topNonClipping = nil;
    UIView *touchPassThrough = nil;
    for (UIView *a = curtain.superview; a && a != window; a = a.superview) {
        if (a.clipsToBounds) continue;
        topNonClipping = a;
        if ([NSStringFromClass(a.class) containsString:@"TouchPassThrough"]) {
            touchPassThrough = a;
        }
    }
    return touchPassThrough ?: topNonClipping ?: window;
}

static void LGDI2HideBlackInView(UIView *view) {
    if (!view) return;

    NSString *cls = NSStringFromClass(view.class);
    BOOL shouldHide = NO;
    if ([cls containsString:@"Material"]) shouldHide = YES;
    if ([cls containsString:@"GainMap"]) shouldHide = YES;
    if ([cls containsString:@"Backdrop"]) shouldHide = YES;
    if ([cls containsString:@"Vibrancy"]) shouldHide = YES;

    if (shouldHide && view != sLGDI2Glass) {
        view.hidden = YES;
    }

    for (UIView *sv in view.subviews) {
        LGDI2HideBlackInView(sv);
    }
}

// =============================================================================
// 玻璃创建/更新/销毁
// =============================================================================

static void LGDI2Engage(UIView *curtain) {
    if (!LGDI2FeatureEnabled()) return;
    if (!curtain || !curtain.window) return;
    if (sLGDI2Glass) return;

    LGDI2Log(@"engage: curtain=%@ bounds=%@",
             NSStringFromClass(curtain.class),
             NSStringFromCGRect(curtain.bounds));

    UIView *host = LGDI2FindHostForCurtain(curtain);
    if (!host) {
        LGDI2Log(@"  no host found");
        return;
    }
    LGDI2Log(@"  host=%@", NSStringFromClass(host.class));

    // 隐藏系统黑色
    LGDI2HideBlackInView(curtain);
    curtain.backgroundColor = [UIColor clearColor];

    // 创建玻璃
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    if (!filterType) filterType = @"dylv.liquidglass.island";

    CGRect glassFrame = [host convertRect:curtain.frame
                                 fromView:curtain.superview];
    CGFloat cornerRadius = CGRectGetHeight(glassFrame) / 2.0;

    LGDI2Log(@"  glass frame=%@ cornerRadius=%.1f filter=%@",
             NSStringFromCGRect(glassFrame), cornerRadius, filterType);

    LGLiveBackdropView *glass = [[LGLiveBackdropView alloc]
        initWithFrame:glassFrame
            groupName:@"IslandGlassDI2"
           filterType:filterType];
    glass.userInteractionEnabled = NO;
    glass.layer.cornerRadius = cornerRadius;
    glass.layer.masksToBounds = YES;
    glass.layer.cornerCurve = kCACornerCurveContinuous;

    [host insertSubview:glass atIndex:0];
    [glass applyFilters];

    // 延迟刷新 backdrop
    for (NSNumber *delay in @[@0.3, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            [glass lgForceRefreshBackdrop];
        });
    }

    sLGDI2Glass = glass;
    sLGDI2Curtain = curtain;
    sLGDI2Host = host;

    LGDI2Log(@"engage DONE");
}

static void LGDI2UpdateLayout(void) {
    if (!sLGDI2Glass || !sLGDI2Curtain || !sLGDI2Host) return;

    CGRect glassFrame = [sLGDI2Host convertRect:sLGDI2Curtain.frame
                                       fromView:sLGDI2Curtain.superview];
    sLGDI2Glass.frame = glassFrame;
    sLGDI2Glass.layer.cornerRadius = CGRectGetHeight(glassFrame) / 2.0;
}

static void LGDI2Disengage(void) {
    if (sLGDI2Glass) {
        [sLGDI2Glass removeFromSuperview];
        sLGDI2Glass = nil;
        LGDI2Log(@"disengage");
    }
    sLGDI2Curtain = nil;
    sLGDI2Host = nil;
}

// =============================================================================
// Hook Group 1: _SBSystemApertureMagiciansCurtainView（核心）
// =============================================================================

%group LGDI2CurtainHook

%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;
    if (!LGDI2FeatureEnabled()) return;

    LGDI2Log(@"[Curtain] didMoveToWindow: window=%@ bounds=%@",
             self.window ? NSStringFromClass(self.window.class) : @"nil",
             NSStringFromCGRect(self.bounds));

    if (self.window) {
        LGDI2Engage(self);
    } else if (sLGDI2Curtain == self) {
        LGDI2Disengage();
    }
}

- (void)layoutSubviews {
    %orig;
    if (!LGDI2FeatureEnabled()) return;

    if (!sLGDI2Glass) {
        LGDI2Engage(self);
    } else {
        LGDI2UpdateLayout();
    }
}

- (void)setHidden:(BOOL)hidden {
    BOOL shouldForceHide = (LGDI2FeatureEnabled() && !hidden && sLGDI2Curtain == self);
    if (shouldForceHide) {
        // 如果功能开着，强制隐藏 curtain（玻璃在它下面显示）
        hidden = YES;
        LGDI2Log(@"[Curtain] setHidden:NO blocked (keeping hidden)");
    }
    %orig(hidden);

    // 注意：玻璃不跟随 curtain 的 hidden 状态
    // （curtain 被我们强制隐藏了，但玻璃应该显示）
    // 玻璃的显隐由 HideWhenInactive 控制
    if (sLGDI2Glass && sLGDI2Curtain == self && !shouldForceHide) {
        sLGDI2Glass.hidden = hidden;
    }
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(alpha);
    if (sLGDI2Glass && sLGDI2Curtain == self) {
        sLGDI2Glass.alpha = alpha;
    }
}

%end
%end

// =============================================================================
// Hook Group 2: _SBGainMapView（增益图层，需要隐藏）
// =============================================================================

%group LGDI2GainMapHook

%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;
    if (!LGDI2FeatureEnabled()) return;

    if (self.window) {
        LGDI2Log(@"[GainMap] didMoveToWindow, hiding");
        self.hidden = YES;
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGDI2FeatureEnabled() && !hidden) {
        hidden = YES;
        LGDI2Log(@"[GainMap] setHidden:NO blocked");
    }
    %orig(hidden);
}

%end
%end

// =============================================================================
// Hook Group 3: SBFTouchPassThroughView（玻璃宿主）
// =============================================================================

%group LGDI2TouchHook

%hook SBFTouchPassThroughView

- (void)layoutSubviews {
    %orig;
    if (!LGDI2FeatureEnabled()) return;
    if (sLGDI2Host != self) return;

    LGDI2UpdateLayout();
}

%end
%end

// =============================================================================
// 构造函数
// =============================================================================

__attribute__((constructor))
static void LGDynamicIsland2Init(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (@available(iOS 16.0, *)) {} else return;

    LGDI2Log(@"========================================");
    LGDI2Log(@"DI2 module loaded");
    LGDI2Log(@"========================================");

    BOOL di2Enabled = LG_prefBool(@"DynamicIsland2.Enabled", NO);
    BOOL di1Enabled = LG_prefBool(@"DynamicIsland.Enabled", YES);
    LGDI2Log(@"config: DI2=%d DI1=%d global=%d",
             di2Enabled, di1Enabled, LG_globalEnabled());

    // 启动时互斥：DI2 开着就把 DI1 关掉
    if (di2Enabled && di1Enabled) {
        LGDI2Log(@"startup: disabling DI1");
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanFalse,
                                 (__bridge CFStringRef)LGPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        notify_post(LGPrefsChangedNotificationCString);
    }

    // 激活所有 hook group
    if (LGDI2FeatureEnabled()) {
        %init(LGDI2CurtainHook);
        %init(LGDI2GainMapHook);
        %init(LGDI2TouchHook);
        LGDI2Log(@"all hook groups activated");
    }

    // 监听偏好变更
    lgObservePreferenceReload(^{
        LGDI2Log(@"preference reload");

        BOOL di2Now = LG_prefBool(@"DynamicIsland2.Enabled", NO);
        BOOL di1Now = LG_prefBool(@"DynamicIsland.Enabled", YES);

        // 互斥
        if (di2Now && di1Now) {
            LGDI2Log(@"  mutual exclusion: turning off DI1");
            CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                     kCFBooleanFalse,
                                     (__bridge CFStringRef)LGPrefsDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        }

        if (LGDI2FeatureEnabled()) {
            LGDI2Log(@"  feature enabled");
            // 如果还没激活 hook group，现在激活
            // 注意：Theos 的 %init 不能重复调用，这里只在首次需要时激活
            // （如果是 respring 后启动时已激活，这里不需要做什么）
        } else {
            LGDI2Log(@"  feature disabled, disengage");
            LGDI2Disengage();
        }
    });

    LGDI2Log(@"DI2 init complete");
}
