// =============================================================================
//  DynamicIsland2.x — 灵动岛2（DI2）锁屏/桌面挂载 + 状态管理
//
//  [Banana deb 方式] 不做锁屏检测，不主动拆除
//  跟随系统灵动岛的自然行为，通过 HideWhenInactive 控制无活动时显示
//
//  Hook 目标：
//    SBCoverSheetPanelBackgroundContainerView — 锁屏背景容器
//    SBIconController — 桌面图标控制器（解锁态主页根视图）
//
//  DI2 是纯自定义 UIView，不 Hook 任何系统灵动岛私有类
//  玻璃渲染链路：LGCreateRegisteredGlass → LGLiveBackdropView → CABackdropLayer
//  → backboardd 通过 g_internAtom(filterType) 注册 → LGHostParamsForAtom 匹配参数
// =============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../Shared/LGDI2View.h"
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
@interface SBCoverSheetPanelBackgroundContainerView : UIView
@end
@interface SBIconController : UIViewController
@end

// =============================================================================
// 全局状态
// =============================================================================

static __weak LGDI2View *sLGDI2View = nil;
static BOOL sLGDI2Installed = NO;
static NSTimer *sLGDI2ReconcileTimer = nil;

// =============================================================================
// 功能开关
// =============================================================================

// [Banana deb 方式] 不做锁屏检测，跟随系统自然行为
static BOOL LGDI2FeatureEnabled(void) {
    if (!LG_prefBool(@"DynamicIsland2.Enabled", NO)) return NO;
    if (!LG_globalEnabled()) return NO;
    // 互斥：DI1 开启时 DI2 不显示
    if (LG_prefBool(@"DynamicIsland.Enabled", YES)) return NO;
    return YES;
}

// =============================================================================
// 视图树查找
// =============================================================================

// 在所有窗口中查找合适的挂载点
// 优先级：CoverSheet 窗口 > 主窗口
static UIView *LGDI2FindHostView(void) {
    // 优先查找 CoverSheet 窗口（锁屏态）
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *winClass = NSStringFromClass(w.class);
        if ([winClass containsString:@"CoverSheet"] ||
            [winClass containsString:@"Notification"]) {
            if (w.rootViewController.view) {
                LGDI2Log(@"found CoverSheet window: %@", winClass);
                return w.rootViewController.view;
            }
            // 回退到窗口本身
            if (w.subviews.count > 0) {
                return w.subviews.lastObject;
            }
        }
    }
    // 回退：主窗口（桌面态）
    UIWindow *mainWindow = [UIApplication sharedApplication].keyWindow;
    if (mainWindow) {
        LGDI2Log(@"fallback to main window: %@", NSStringFromClass(mainWindow.class));
        return mainWindow;
    }
    LGDI2Log(@"ERROR: no host view found!");
    return nil;
}

// =============================================================================
// 生命周期
// =============================================================================

static void LGDI2Engage(UIView *hostView) {
    if (sLGDI2Installed) return;
    if (!LGDI2FeatureEnabled()) return;
    if (!hostView) return;

    LGDI2Log(@"engage: hostView=%@", NSStringFromClass(hostView.class));

    sLGDI2View = [LGDI2View installInSuperview:hostView
                                   filterPrefix:@"DynamicIsland2"];

    // 检查玻璃是否创建成功
    if (!sLGDI2View.glassView) {
        LGDI2Log(@"ERROR: glassView creation failed, aborting engage");
        [sLGDI2View uninstall];
        sLGDI2View = nil;
        return;
    }

    sLGDI2Installed = YES;

    // 启动定时布局同步（用于 hideWhenInactive 状态检测）
    [sLGDI2View startLayoutSyncTimer];

    LGDI2Log(@"engage complete: DI2View installed, glassView=OK");
}

static void LGDI2Disengage(void) {
    if (!sLGDI2Installed) return;

    LGDI2Log(@"disengage");

    [sLGDI2View uninstall];
    sLGDI2View = nil;
    sLGDI2Installed = NO;

    LGDI2Log(@"disengage complete");
}

static void LGDI2Reconcile(UIView *hostView) {
    if (LGDI2FeatureEnabled()) {
        if (!sLGDI2Installed) {
            LGDI2Engage(hostView);
        } else if (sLGDI2View) {
            // 已安装，刷新布局
            [sLGDI2View updateLayout];
        }
    } else {
        if (sLGDI2Installed) {
            LGDI2Disengage();
        }
    }
}

// 定时器回调：周期性检查是否需要重新挂载或更新布局
static void LGDI2TimerReconcile(void) {
    if (LGDI2FeatureEnabled()) {
        UIView *host = LGDI2FindHostView();
        if (host) {
            if (!sLGDI2Installed) {
                LGDI2Engage(host);
            } else if (sLGDI2View) {
                // 检查 DI2View 是否仍在窗口中
                if (!sLGDI2View.window) {
                    // 视图已脱离窗口，需要重新挂载
                    LGDI2Log(@"DI2View lost window, re-mounting");
                    LGDI2Disengage();
                    LGDI2Engage(host);
                } else {
                    [sLGDI2View updateLayout];
                }
            }
        }
    } else {
        if (sLGDI2Installed) {
            LGDI2Disengage();
        }
    }
}

// =============================================================================
// Hook 注册
// =============================================================================

%hook SBCoverSheetPanelBackgroundContainerView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        // 延迟 0.3s 等系统布局稳定后挂载
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            LGDI2Reconcile(self);
        });
    } else {
        // 窗口移除时检查是否需要清理
        if (sLGDI2Installed && !LGDI2FeatureEnabled()) {
            LGDI2Disengage();
        }
    }
}

- (void)layoutSubviews {
    %orig;
    if (sLGDI2View) {
        [sLGDI2View updateLayout];
    }
}

%end

// 桌面态：Hook SBIconController 以在解锁后重新挂载 DI2
%hook SBIconController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (LGDI2FeatureEnabled() && !sLGDI2Installed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            UIView *host = LGDI2FindHostView();
            if (host) {
                LGDI2Reconcile(host);
            }
        });
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (sLGDI2View) {
        [sLGDI2View updateLayout];
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

    LGDI2Log(@"constructor: DI2 module loaded");

    // 验证 HostRegistry 中存在 DynamicIsland2 条目
    NSString *filterType = LGFilterTypeForHostPrefix(@"DynamicIsland2");
    if (filterType) {
        LGDI2Log(@"host registry OK: filterType=%@", filterType);
    } else {
        LGDI2Log(@"ERROR: DynamicIsland2 not found in LG_HOST_REGISTRY!");
        LGDI2Log(@"ensure LGHostRegistry.h has the DynamicIsland2 entry");
        return; // 不继续加载，避免后续崩溃
    }

    // 监听偏好变更（用于互斥切换）
    lgObservePreferenceReload(^{
        LGDI2Log(@"preference reload, reconciling");

        // [互斥] 如果 DI2 和 DI1 同时开启，自动关闭 DI1
        if (LG_prefBool(@"DynamicIsland2.Enabled", NO) &&
            LG_prefBool(@"DynamicIsland.Enabled", YES)) {
            LGDI2Log(@"mutual exclusion: DI2 on, turning off DI1");
            CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                     kCFBooleanFalse,
                                     (__bridge CFStringRef)LGPrefsDomain);
            CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        }

        UIView *host = LGDI2FindHostView();
        if (host) {
            LGDI2Reconcile(host);
        } else if (sLGDI2Installed) {
            LGDI2Disengage();
        }
    });

    // [Banana deb 方式] 不监听锁屏状态变化
    // DI2 跟随系统灵动岛的自然行为，不做主动锁屏检测/拆除
    // 仅监听偏好变更用于互斥切换

    // 启动周期性检查定时器（每 2 秒检查一次是否需要重新挂载）
    sLGDI2ReconcileTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            target:nil
                                                          block:^(NSTimer *t) {
        LGDI2TimerReconcile();
    }
                                                        repeats:YES];

    // 延迟首次尝试挂载（等 SpringBoard 完全启动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        UIView *host = LGDI2FindHostView();
        if (host) {
            LGDI2Reconcile(host);
        } else {
            LGDI2Log(@"initial mount: no host view yet, will retry on next hook");
        }
    });
}
