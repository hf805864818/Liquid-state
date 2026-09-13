// =============================================================================
//  DynamicIsland2.x — 灵动岛2（原版 Liquid (Gl)ass 架构）
//
//  策略：
//  1. 先尝试 hook 已知的灵动岛类名
//  2. 同时在 SpringBoard 启动后递归扫描所有窗口查找灵动岛视图
//  3. 找到后注入玻璃
// =============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../Shared/LGIslandGlassDriver.h"
#import "../Shared/LGDI2Mutex.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGHostRegistry.h"
#import <notify.h>

// 强制开启调试
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
// 递归查找灵动岛视图
// =============================================================================

static BOOL LGDI2LooksLikeIslandView(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass(view.class);
    // 匹配各种可能的灵动岛视图类名
    return ([cls containsString:@"MagiciansCurtain"] ||
            [cls containsString:@"ApertureCurtain"] ||
            [cls containsString:@"IslandCurtain"]);
}

static UIView *LGDI2FindIslandViewInView(UIView *rootView) {
    if (!rootView) return nil;

    if (LGDI2LooksLikeIslandView(rootView)) {
        return rootView;
    }

    for (UIView *subview in rootView.subviews) {
        UIView *found = LGDI2FindIslandViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static UIView *LGDI2FindIslandViewGlobally(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        UIView *found = LGDI2FindIslandViewInView(w);
        if (found) {
            LGDI2Log(@"found island view in window: %@", NSStringFromClass(w.class));
            return found;
        }
        // 也试试 rootViewController.view
        if (w.rootViewController.view) {
            found = LGDI2FindIslandViewInView(w.rootViewController.view);
            if (found) {
                LGDI2Log(@"found island view in window.rootViewController.view: %@",
                         NSStringFromClass(w.class));
                return found;
            }
        }
    }
    return nil;
}

// 打印视图层级（调试用）
static void LGDI2PrintViewTree(UIView *view, NSInteger depth) {
    if (!view) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    CGRect f = view.frame;
    LGDI2Log(@"%@%@ (%.0f,%.0f %.0fx%.0f) alpha=%.2f hidden=%d",
             indent, NSStringFromClass(view.class),
             f.origin.x, f.origin.y, f.size.width, f.size.height,
             view.alpha, view.hidden);
    for (UIView *sv in view.subviews) {
        LGDI2PrintViewTree(sv, depth + 1);
    }
}

// =============================================================================
// 尝试注入
// =============================================================================

static void LGDI2TryInject(void) {
    if (!LGDI2FeatureEnabled()) return;

    LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
    if (driver.curtainView && driver.glass) {
        // 已经注入了，刷新一下
        [driver refreshConfiguration];
        return;
    }

    UIView *islandView = LGDI2FindIslandViewGlobally();
    if (islandView) {
        LGDI2Log(@"injecting glass into island view: %@", NSStringFromClass(islandView.class));
        LGDI2Log(@"  island view frame: %@", NSStringFromCGRect(islandView.frame));
        LGDI2Log(@"  island view bounds: %@", NSStringFromCGRect(islandView.bounds));
        LGDI2Log(@"  subviews:");
        LGDI2PrintViewTree(islandView, 2);

        [driver attachToCurtainView:islandView];
    } else {
        LGDI2Log(@"no island view found, will retry later");
        // 打印所有窗口类名方便排查
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            LGDI2Log(@"  window: %@ subviews=%lu",
                     NSStringFromClass(w.class), (unsigned long)w.subviews.count);
        }
    }
}

// =============================================================================
// 动态 hook：尝试对已知的灵动岛类名进行 hook
// 如果类不存在（类名不对），%hook 会静默失败，所以我们用 runtime 方式检查
// =============================================================================

// 尝试多个可能的类名
static NSArray *LGDI2CandidateClassNames(void) {
    return @[
        @"_SBSystemApertureMagiciansCurtainView",
        @"SBSystemApertureMagiciansCurtainView",
        @"_SAUIMagiciansCurtainView",
        @"SAUIMagiciansCurtainView",
    ];
}

static Class LGDI2FindIslandViewClass(void) {
    for (NSString *name in LGDI2CandidateClassNames()) {
        Class cls = NSClassFromString(name);
        if (cls) {
            LGDI2Log(@"found island view class: %@", name);
            return cls;
        }
    }
    LGDI2Log(@"no island view class found from candidates");
    return nil;
}

// =============================================================================
// 用 runtime 方式 swizzle layoutSubviews
// =============================================================================

static IMP original_LGDI2_layoutSubviews = NULL;

static void swizzled_LGDI2_layoutSubviews(id self, SEL _cmd) {
    if (original_LGDI2_layoutSubviews) {
        ((void(*)(id, SEL))original_LGDI2_layoutSubviews)(self, _cmd);
    }

    if (!LGDI2FeatureEnabled()) return;

    @autoreleasepool {
        UIView *view = (UIView *)self;
        LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];

        if (driver.curtainView != view) {
            // 首次发现，注入
            LGDI2Log(@"swizzled layoutSubviews: found island view %@",
                     NSStringFromClass([view class]));
            [driver attachToCurtainView:view];
        } else {
            // 已注入，更新布局
            [driver updateLayout];
        }
    }
}

static void LGDI2SwizzleIslandClass(void) {
    Class islandCls = LGDI2FindIslandViewClass();
    if (!islandCls) {
        LGDI2Log(@"cannot swizzle: no island class found");
        return;
    }

    SEL layoutSel = @selector(layoutSubviews);
    Method layoutMethod = class_getInstanceMethod(islandCls, layoutSel);
    if (!layoutMethod) {
        LGDI2Log(@"cannot swizzle: layoutSubviews not found on %@",
                 NSStringFromClass(islandCls));
        return;
    }

    original_LGDI2_layoutSubviews = method_getImplementation(layoutMethod);
    method_setImplementation(layoutMethod, (IMP)swizzled_LGDI2_layoutSubviews);

    LGDI2Log(@"swizzled layoutSubviews on %@", NSStringFromClass(islandCls));
}

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

    // 检查功能
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

    // 尝试 swizzle 灵动岛类
    LGDI2SwizzleIslandClass();

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

        LGIslandGlassDriver *driver = [LGIslandGlassDriver sharedDriver];
        if (LGDI2FeatureEnabled()) {
            LGDI2Log(@"  feature enabled, trying inject");
            LGDI2TryInject();
        } else {
            LGDI2Log(@"  feature disabled, detaching");
            [driver detach];
        }
    });

    // 多次延迟尝试（灵动岛可能启动较晚）
    NSArray *delays = @[@1.0, @2.0, @4.0, @8.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            LGDI2Log(@"delayed inject attempt (%.0fs)", delay.doubleValue);
            LGDI2TryInject();
        });
    }

    LGDI2Log(@"DI2 init complete");
}
