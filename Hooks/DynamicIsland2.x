// =============================================================================
//  DynamicIsland2.x — 灵动岛2（原版 Liquid (Gl)ass 架构）
//
//  完全复刻 Banana deb 的实现方式：
//  - Hook 系统灵动岛视图，直接注入玻璃层
//  - 使用 dylv.liquidglass.island 滤镜类型
//  - 极简配置：Enabled + HideWhenInactive
// =============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../Shared/LGIslandGlassDriver.h"
#import "../Shared/LGDI2Mutex.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGHostRegistry.h"
#import <notify.h>

// 强制开启调试，方便排查问题
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
@interface SBSystemApertureContainerView : UIView
@end

// =============================================================================
// 功能开关
// =============================================================================

static BOOL LGDI2FeatureEnabled(void) {
    if (!LG_prefBool(@"DynamicIsland2.Enabled", NO)) return NO;
    if (!LG_globalEnabled()) return NO;
    // 互斥：DI1 开启时 DI2 不生效
    if (LG_prefBool(@"DynamicIsland.Enabled", YES)) return NO;
    return YES;
}

// =============================================================================
// 递归查找灵动岛相关视图（fallback 方案）
// =============================================================================

static UIView *LGDI2FindIslandView(UIView *rootView) {
    if (!rootView) return nil;

    NSString *className = NSStringFromClass(rootView.class);
    if ([className containsString:@"MagiciansCurtain"] ||
        [className containsString:@"ApertureContainer"]) {
        LGDI2Log(@"found island view: %@ (frame=%@)", className,
                 NSStringFromCGRect(rootView.frame));
        return rootView;
    }

    for (UIView *subview in rootView.subviews) {
        UIView *found = LGDI2FindIslandView(subview);
        if (found) return found;
    }
    return nil;
}

// =============================================================================
// 尝试在窗口中查找并注入玻璃
// =============================================================================

static void LGDI2TryInjectInWindow(UIWindow *window) {
    if (!window) return;

    UIView *islandView = LGDI2FindIslandView(window.rootViewController.view);
    if (!islandView) {
        // 也试试直接遍历窗口的子视图
        islandView = LGDI2FindIslandView(window);
    }

    if (islandView && LGDI2FeatureEnabled()) {
        LGDI2Log(@"injecting glass into: %@", NSStringFromClass(islandView.class));
        [[LGIslandGlassDriver sharedDriver] attachToCurtainView:islandView];
    }
}

// =============================================================================
// Hook _SBSystemApertureMagiciansCurtainView（主要注入点）
// =============================================================================

%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToSuperview {
    %orig;

    LGDI2Log(@"[_SBSystemApertureMagiciansCurtainView] didMoveToSuperview: "
             @"self=%@ superview=%@ frame=%@",
             NSStringFromClass(self.class),
             self.superview ? NSStringFromClass(self.superview.class) : @"nil",
             NSStringFromCGRect(self.frame));

    if (!LGDI2FeatureEnabled()) return;

    if (self.superview) {
        // 延迟一下等布局稳定
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.2 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            LGDI2Log(@"[_SBSystemApertureMagiciansCurtainView] attaching glass, "
                     @"bounds=%@", NSStringFromCGRect(self.bounds));
            [[LGIslandGlassDriver sharedDriver] attachToCurtainView:self];
        });
    }
}

- (void)layoutSubviews {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self) {
        [driver updateLayout];
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    if (!LGDI2FeatureEnabled()) return;

    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self && driver.glass) {
        driver.glass.hidden = hidden;
        LGDI2Log(@"[_SBSystemApertureMagiciansCurtainView] setHidden=%d", hidden);
    }
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(alpha);

    if (!LGDI2FeatureEnabled()) return;

    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self && driver.glass) {
        driver.glass.alpha = alpha;
    }
}

%end

// =============================================================================
// Hook SBSystemApertureContainerView（备用注入点）
// =============================================================================

%hook SBSystemApertureContainerView

- (void)didMoveToSuperview {
    %orig;

    LGDI2Log(@"[SBSystemApertureContainerView] didMoveToSuperview: "
             @"self=%@ superview=%@ frame=%@",
             NSStringFromClass(self.class),
             self.superview ? NSStringFromClass(self.superview.class) : @"nil",
             NSStringFromCGRect(self.frame));

    if (!LGDI2FeatureEnabled()) return;

    if (self.superview) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            // 检查是否已经通过 MagiciansCurtainView 注入了
            LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
            if (!driver.curtainView) {
                LGDI2Log(@"[SBSystemApertureContainerView] fallback inject");
                [driver attachToCurtainView:self];
            }
        });
    }
}

- (void)layoutSubviews {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self) {
        [driver updateLayout];
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
    LGDI2Log(@"DI2 module loaded (Liquid (Gl)ass style)");
    LGDI2Log(@"========================================");

    // 验证 HostRegistry
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    LGDI2Log(@"HostRegistry: Island filterType=%@", filterType);

    // 检查功能是否开启
    BOOL di2Enabled = LG_prefBool(@"DynamicIsland2.Enabled", NO);
    BOOL di1Enabled = LG_prefBool(@"DynamicIsland.Enabled", YES);
    BOOL globalEnabled = LG_globalEnabled();
    LGDI2Log(@"config: DI2=%d DI1=%d global=%d", di2Enabled, di1Enabled, globalEnabled);

    // 启动时互斥检查
    if (di2Enabled && di1Enabled) {
        LGDI2Log(@"startup: DI2+DI1 both enabled, disabling DI1");
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanFalse,
                                 (__bridge CFStringRef)LGPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        notify_post(LGPrefsChangedNotificationCString);
    }

    // 监听偏好变更
    lgObservePreferenceReload(^{
        LGDI2Log(@"preference reload fired");

        BOOL di2Now = LG_prefBool(@"DynamicIsland2.Enabled", NO);
        BOOL di1Now = LG_prefBool(@"DynamicIsland.Enabled", YES);
        LGDI2Log(@"  DI2=%d DI1=%d", di2Now, di1Now);

        // 互斥处理
        if (di2Now && di1Now) {
            LGDI2Log(@"  mutual exclusion: turning off DI1");
            CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                     kCFBooleanFalse,
                                     (__bridge CFStringRef)LGPrefsDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        }

        LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
        if (LGDI2FeatureEnabled()) {
            LGDI2Log(@"  feature enabled, refreshing");
            [driver refreshConfiguration];
            // 如果还没注入，尝试在所有窗口中查找
            if (!driver.curtainView) {
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    LGDI2TryInjectInWindow(w);
                }
            }
        } else {
            LGDI2Log(@"  feature disabled, detaching");
            [driver detach];
        }
    });

    // 延迟尝试首次注入（等 SpringBoard 完全启动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        LGDI2Log(@"delayed initial injection attempt");
        if (LGDI2FeatureEnabled()) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                LGDI2Log(@"  scanning window: %@", NSStringFromClass(w.class));
                LGDI2TryInjectInWindow(w);
            }
        } else {
            LGDI2Log(@"  feature not enabled, skipping");
        }
    });

    LGDI2Log(@"DI2 initialization complete");
}
