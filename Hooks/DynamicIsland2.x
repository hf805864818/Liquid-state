// =============================================================================
//  DynamicIsland2.x — 灵动岛2（原版 Liquid (Gl)ass 架构）
//
//  完全复刻 Banana deb 的实现方式：
//  - Hook _SBSystemApertureMagiciansCurtainView（系统灵动岛幕布视图）
//  - 直接在系统视图上注入玻璃层，不创建独立视图
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

#ifndef LIQUIDASS_DEBUG
#define LIQUIDASS_DEBUG 0
#endif

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
// Hook _SBSystemApertureMagiciansCurtainView
// =============================================================================

%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToSuperview {
    %orig;

    LGDI2Log(@"MagiciansCurtainView didMoveToSuperview: self=%@ superview=%@",
             NSStringFromClass(self.class),
             self.superview ? NSStringFromClass(self.superview.class) : @"nil");

    if (!LGDI2FeatureEnabled()) return;

    if (self.superview) {
        // 延迟一下等布局稳定
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.1 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            [[LGIslandGlassDriver sharedDriver] attachToCurtainView:self];
        });
    }
}

- (void)layoutSubviews {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    // 布局变化时更新玻璃层
    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self) {
        [driver updateLayout];
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    if (!LGDI2FeatureEnabled()) return;

    // 同步隐藏玻璃层
    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self) {
        [driver.glass setHidden:hidden];
    }
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(alpha);

    if (!LGDI2FeatureEnabled()) return;

    // 同步透明度
    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView == self && driver.glass) {
        driver.glass.alpha = alpha;
    }
}

%end

// =============================================================================
// Hook _SBGainMapView（增益图视图，用于增强液态效果）
// =============================================================================

%hook _SBGainMapView

- (void)didMoveToSuperview {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    LGDI2Log(@"_SBGainMapView didMoveToSuperview: %@",
             self.superview ? NSStringFromClass(self.superview.class) : @"nil");
}

- (void)layoutSubviews {
    %orig;

    if (!LGDI2FeatureEnabled()) return;

    // 可以在这里做增益图相关的增强
}

%end

// =============================================================================
// 构造函数
// =============================================================================

__attribute__((constructor))
static void LGDynamicIsland2Init(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (@available(iOS 16.0, *)) {} else return;

    LGDI2Log(@"constructor: DI2 module loaded (original Liquid (Gl)ass style)");

    // 验证 HostRegistry 中存在 Island 条目
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    if (filterType) {
        LGDI2Log(@"host registry OK: filterType=%@", filterType);
    } else {
        LGDI2Log(@"WARNING: Island not found in LG_HOST_REGISTRY, using fallback");
    }

    // [启动时互斥检查] 如果 DI2 已开启，确保 DI1 关闭
    if (LG_prefBool(@"DynamicIsland2.Enabled", NO) &&
        LG_prefBool(@"DynamicIsland.Enabled", YES)) {
        LGDI2Log(@"startup mutual exclusion: DI2 enabled, disabling DI1");
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanFalse,
                                 (__bridge CFStringRef)LGPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        notify_post(LGPrefsChangedNotificationCString);
    }

    // 监听偏好变更（用于互斥切换和配置刷新）
    lgObservePreferenceReload(^{
        LGDI2Log(@"preference reload");

        // [互斥] 如果 DI2 和 DI1 同时开启，自动关闭 DI1
        if (LG_prefBool(@"DynamicIsland2.Enabled", NO) &&
            LG_prefBool(@"DynamicIsland.Enabled", YES)) {
            LGDI2Log(@"mutual exclusion: DI2 on, turning off DI1");
            CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                     kCFBooleanFalse,
                                     (__bridge CFStringRef)LGPrefsDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        }

        // 刷新驱动配置
        LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
        if (LGDI2FeatureEnabled()) {
            [driver refreshConfiguration];
        } else {
            [driver detach];
        }
    });

    LGDI2Log(@"DI2 module initialized (original Liquid (Gl)ass architecture)");
}
