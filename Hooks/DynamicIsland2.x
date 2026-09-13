// =============================================================================
//  DynamicIsland2.x — 灵动岛2（原版 Liquid (Gl)ass 架构）
//
//  基于逆向分析的原版实现方式：
//  1. Hook SBFTouchPassThroughView（稳定容器，玻璃宿主）
//  2. Hook _SBSystemApertureMagiciansCurtainView（黑色幕布）
//  3. 隐藏系统黑色材质（material + gainMap）
//  4. 玻璃插在 SBFTouchPassThroughView 里、curtainView 下方
//  5. 玻璃尺寸跟随 curtainView 形变
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "../Shared/LGIslandGlassDriver.h"
#import "../Shared/LGDI2Mutex.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGHostRegistry.h"
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
@interface SBFTouchPassThroughView : UIView
@end

// =============================================================================
// 功能开关
// =============================================================================

static BOOL LGDI2FeatureEnabled(void) {
    if (!LG_prefBool(@"DynamicIsland2.Enabled", NO)) return NO;
    if (!LG_globalEnabled()) return NO;
    if (LG_prefBool(@"DynamicIsland.Enabled", YES)) return NO;
    return YES;
}

// =============================================================================
// 全局状态
// =============================================================================

static __weak UIView *sLGDI2Curtain = nil;    // 黑色幕布
static __weak UIView *sLGDI2Host = nil;       // 玻璃宿主（TouchPassThroughView）
static __weak LGLiveBackdropView *sLGDI2Glass = nil;  // 玻璃视图

// =============================================================================
// 隐藏系统黑色材质
// =============================================================================

static void LGDI2HideSystemBlack(UIView *curtain) {
    if (!curtain) return;

    LGDI2Log(@"hideSystemBlack in %@", NSStringFromClass(curtain.class));

    // 递归隐藏材质/增益图/装饰视图
    for (UIView *sv in curtain.subviews) {
        NSString *cls = NSStringFromClass(sv.class);
        BOOL shouldHide = NO;

        if ([cls containsString:@"Material"]) shouldHide = YES;
        if ([cls containsString:@"GainMap"]) shouldHide = YES;
        if ([cls containsString:@"Backdrop"]) shouldHide = YES;
        if ([cls containsString:@"Vibrancy"]) shouldHide = YES;

        if (shouldHide) {
            LGDI2Log(@"  hiding: %@ (was hidden=%d)", cls, sv.hidden);
            sv.hidden = YES;
        }

        // 继续递归
        LGDI2HideSystemBlack(sv);
    }

    // 幕布本身也清底
    curtain.backgroundColor = [UIColor clearColor];
}

// =============================================================================
// 创建玻璃并插入
// =============================================================================

static void LGDI2EngageGlass(void) {
    if (!LGDI2FeatureEnabled()) return;
    if (sLGDI2Glass) return;  // 已经有了
    if (!sLGDI2Curtain || !sLGDI2Host) return;

    LGDI2Log(@"engageGlass: curtain=%@ host=%@",
             NSStringFromClass(sLGDI2Curtain.class),
             NSStringFromClass(sLGDI2Host.class));

    // 创建玻璃
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    if (!filterType) filterType = @"dylv.liquidglass.island";

    CGRect glassFrame = [sLGDI2Host convertRect:sLGDI2Curtain.frame
                                       fromView:sLGDI2Curtain.superview];

    LGLiveBackdropView *glass = [[LGLiveBackdropView alloc]
        initWithFrame:glassFrame
            groupName:@"IslandGlass"
           filterType:filterType];
    glass.userInteractionEnabled = NO;
    glass.alpha = 1.0;

    // 插在 curtainView 的下方
    NSInteger curtainIdx = [sLGDI2Host.subviews indexOfObject:sLGDI2Curtain];
    if (curtainIdx == NSNotFound) curtainIdx = 0;
    [sLGDI2Host insertSubview:glass atIndex:curtainIdx];

    glass.layer.cornerRadius = CGRectGetHeight(glassFrame) / 2.0;
    glass.layer.masksToBounds = YES;

    [glass applyFilters];
    [glass lgForceRefreshBackdrop];

    sLGDI2Glass = glass;

    // 隐藏系统黑色背景
    LGDI2HideSystemBlack(sLGDI2Curtain);

    LGDI2Log(@"engageGlass complete: frame=%@ cornerRadius=%.1f",
             NSStringFromCGRect(glassFrame), CGRectGetHeight(glassFrame) / 2.0);
}

// 移除玻璃
static void LGDI2DisengageGlass(void) {
    if (sLGDI2Glass) {
        [sLGDI2Glass removeFromSuperview];
        sLGDI2Glass = nil;
        LGDI2Log(@"disengageGlass");
    }
}

// 更新玻璃布局（跟随 curtainView）
static void LGDI2UpdateGlassLayout(void) {
    if (!sLGDI2Glass || !sLGDI2Curtain || !sLGDI2Host) return;

    CGRect curtainFrame = sLGDI2Curtain.frame;
    CGRect glassFrame = [sLGDI2Host convertRect:curtainFrame
                                       fromView:sLGDI2Curtain.superview];

    sLGDI2Glass.frame = glassFrame;
    CGFloat cornerRadius = CGRectGetHeight(glassFrame) / 2.0;
    sLGDI2Glass.layer.cornerRadius = cornerRadius;
    sLGDI2Glass.layer.masksToBounds = YES;

    [sLGDI2Glass applyFilters];
}

// =============================================================================
// Hook _SBSystemApertureMagiciansCurtainView
// =============================================================================

%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;

    LGDI2Log(@"[Curtain] didMoveToWindow: window=%@",
             self.window ? NSStringFromClass(self.window.class) : @"nil");

    if (!LGDI2FeatureEnabled()) return;

    if (self.window) {
        sLGDI2Curtain = self;
        // 尝试装配玻璃
        LGDI2EngageGlass();
    } else {
        if (sLGDI2Curtain == self) {
            sLGDI2Curtain = nil;
            LGDI2DisengageGlass();
        }
    }
}

- (void)layoutSubviews {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    sLGDI2Curtain = self;

    if (sLGDI2Glass) {
        LGDI2UpdateGlassLayout();
    } else {
        LGDI2EngageGlass();
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    if (!LGDI2FeatureEnabled()) return;

    if (sLGDI2Glass && sLGDI2Curtain == self) {
        sLGDI2Glass.hidden = hidden;
    }
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(alpha);

    if (!LGDI2FeatureEnabled()) return;

    if (sLGDI2Glass && sLGDI2Curtain == self) {
        sLGDI2Glass.alpha = alpha;
    }
}

%end

// =============================================================================
// Hook SBFTouchPassThroughView（玻璃的稳定宿主）
// =============================================================================

%hook SBFTouchPassThroughView

- (void)didMoveToWindow {
    %orig;

    LGDI2Log(@"[TouchPassThrough] didMoveToWindow: window=%@ subviews=%lu",
             self.window ? NSStringFromClass(self.window.class) : @"nil",
             (unsigned long)self.subviews.count);

    if (!LGDI2FeatureEnabled()) return;

    if (self.window) {
        // 检查这个 TouchPassThroughView 是不是灵动岛的
        // （它的子视图里应该有 MagiciansCurtainView）
        for (UIView *sv in self.subviews) {
            if ([NSStringFromClass(sv.class) containsString:@"MagiciansCurtain"]) {
                LGDI2Log(@"[TouchPassThrough] found island host");
                sLGDI2Host = self;
                sLGDI2Curtain = sv;
                LGDI2EngageGlass();
                break;
            }
        }
    }
}

- (void)layoutSubviews {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    // 如果这是灵动岛的宿主，更新玻璃布局
    if (sLGDI2Host == self && sLGDI2Glass) {
        LGDI2UpdateGlassLayout();
    }
}

%end

// =============================================================================
// 构造函数
// =============================================================================

__attribute__((constructor))
static void LGDynamicIsland2Init(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (@available(iOS 16.0, *)) {} else return;

    LGDI2Log(@"========================================");
    LGDI2Log(@"DI2 module loaded (Liquid (Gl)ass architecture)");
    LGDI2Log(@"========================================");

    BOOL di2Enabled = LG_prefBool(@"DynamicIsland2.Enabled", NO);
    BOOL di1Enabled = LG_prefBool(@"DynamicIsland.Enabled", YES);
    LGDI2Log(@"config: DI2=%d DI1=%d global=%d",
             di2Enabled, di1Enabled, LG_globalEnabled());

    // 启动时互斥
    if (di2Enabled && di1Enabled) {
        LGDI2Log(@"startup: disabling DI1");
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanFalse,
                                 (__bridge CFStringRef)LGPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        notify_post(LGPrefsChangedNotificationCString);
    }

    // 监听偏好变更
    lgObservePreferenceReload(^{
        LGDI2Log(@"preference reload");

        BOOL di2Now = LG_prefBool(@"DynamicIsland2.Enabled", NO);
        BOOL di1Now = LG_prefBool(@"DynamicIsland.Enabled", YES);

        if (di2Now && di1Now) {
            LGDI2Log(@"  mutual exclusion: turning off DI1");
            CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                     kCFBooleanFalse,
                                     (__bridge CFStringRef)LGPrefsDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        }

        if (LGDI2FeatureEnabled()) {
            LGDI2EngageGlass();
        } else {
            LGDI2DisengageGlass();
        }
    });

    LGDI2Log(@"DI2 init complete");
}
