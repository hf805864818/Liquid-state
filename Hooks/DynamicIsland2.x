// =============================================================================
//  DynamicIsland2.x — 灵动岛2
//
//  实现策略（参考原版 Liquid (Gl)ass + DI1 验证可行的方案）：
//  1. 启动后延迟扫描所有窗口，递归查找 MagiciansCurtainView
//  2. 找到后用 runtime swizzle layoutSubviews
//  3. 隐藏系统黑色材质（curtain + gainMap + material）
//  4. 玻璃插在 TouchPassThroughView（最高不裁剪祖先）的最底层
//  5. 玻璃几何跟随 curtainView 形变
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "../Shared/LGDI2Mutex.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGHostRegistry.h"
#import "../Shared/LGLiveBackdropView.h"
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
// 全局状态
// =============================================================================

static __weak UIView *sLGDI2Curtain = nil;     // 黑色幕布
static __weak UIView *sLGDI2Host = nil;        // 玻璃宿主
static __weak LGLiveBackdropView *sLGDI2Glass = nil;  // 玻璃视图
static BOOL sLGDI2Swizzled = NO;               // 是否已 swizzle
static IMP sLGDI2OrigLayoutSubviews = NULL;    // 原始 layoutSubviews

// =============================================================================
// 工具函数
// =============================================================================

// 递归查找类名匹配的视图
static UIView *LGDI2FindViewOfClass(UIView *root, NSString *substring) {
    if (!root) return nil;
    NSString *cls = NSStringFromClass(root.class);
    if ([cls containsString:substring]) return root;
    for (UIView *sv in root.subviews) {
        UIView *found = LGDI2FindViewOfClass(sv, substring);
        if (found) return found;
    }
    return nil;
}

// 找到最高的不裁剪祖先（优先 TouchPassThrough）
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

// 隐藏系统黑色材质
static void LGDI2HideSystemBlack(UIView *root) {
    if (!root) return;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *cls = NSStringFromClass(v.class);
        BOOL shouldHide = NO;
        if ([cls containsString:@"Material"]) shouldHide = YES;
        if ([cls containsString:@"GainMap"]) shouldHide = YES;
        if ([cls containsString:@"Backdrop"]) shouldHide = YES;
        if ([cls containsString:@"Vibrancy"]) shouldHide = YES;

        if (shouldHide && v != sLGDI2Glass) {
            v.hidden = YES;
        }

        [stack addObjectsFromArray:v.subviews];
    }

    // 幕布本身也清底
    root.backgroundColor = [UIColor clearColor];
}

// 打印视图树（调试）
static void LGDI2PrintTree(UIView *v, NSInteger depth) {
    if (!v) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    LGDI2Log(@"%@%@ (%.0f,%.0f %.0fx%.0f) hidden=%d alpha=%.2f clips=%d",
             indent, NSStringFromClass(v.class),
             v.frame.origin.x, v.frame.origin.y,
             v.frame.size.width, v.frame.size.height,
             v.hidden, v.alpha, v.clipsToBounds);
    for (UIView *sv in v.subviews) {
        LGDI2PrintTree(sv, depth + 1);
    }
}

// =============================================================================
// 创建玻璃
// =============================================================================

static void LGDI2CreateGlass(UIView *curtain, UIView *host) {
    if (!curtain || !host) return;
    if (sLGDI2Glass) return;

    LGDI2Log(@"createGlass: curtain=%@ host=%@",
             NSStringFromClass(curtain.class),
             NSStringFromClass(host.class));
    LGDI2Log(@"  curtain frame=%@ bounds=%@",
             NSStringFromCGRect(curtain.frame),
             NSStringFromCGRect(curtain.bounds));

    // 隐藏系统黑色
    LGDI2HideSystemBlack(curtain);

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

    // 插在宿主最底层
    [host insertSubview:glass atIndex:0];

    [glass applyFilters];

    // 延迟刷新 backdrop（首次采样可能为空）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [glass lgForceRefreshBackdrop];
        });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [glass lgForceRefreshBackdrop];
        });

    sLGDI2Glass = glass;
    sLGDI2Curtain = curtain;
    sLGDI2Host = host;

    LGDI2Log(@"createGlass DONE");
}

// 更新玻璃布局
static void LGDI2UpdateGlass(void) {
    if (!sLGDI2Glass || !sLGDI2Curtain || !sLGDI2Host) return;

    CGRect glassFrame = [sLGDI2Host convertRect:sLGDI2Curtain.frame
                                       fromView:sLGDI2Curtain.superview];
    sLGDI2Glass.frame = glassFrame;

    CGFloat cornerRadius = CGRectGetHeight(glassFrame) / 2.0;
    sLGDI2Glass.layer.cornerRadius = cornerRadius;
}

// 销毁玻璃
static void LGDI2DestroyGlass(void) {
    if (sLGDI2Glass) {
        [sLGDI2Glass removeFromSuperview];
        sLGDI2Glass = nil;
        LGDI2Log(@"destroyGlass");
    }
    sLGDI2Curtain = nil;
    sLGDI2Host = nil;
}

// =============================================================================
// Swizzled layoutSubviews
// =============================================================================

static void swizzled_LGDI2_layoutSubviews(id self, SEL _cmd) {
    // 调用原始实现
    if (sLGDI2OrigLayoutSubviews) {
        ((void(*)(id, SEL))sLGDI2OrigLayoutSubviews)(self, _cmd);
    }

    if (!LGDI2FeatureEnabled()) return;

    @autoreleasepool {
        UIView *curtain = (UIView *)self;

        if (sLGDI2Curtain != curtain) {
            // 首次发现
            LGDI2Log(@"swizzled layoutSubviews: new curtain %@",
                     NSStringFromClass(curtain.class));

            UIView *host = LGDI2FindHostForCurtain(curtain);
            if (host) {
                LGDI2Log(@"  host found: %@", NSStringFromClass(host.class));
                LGDI2CreateGlass(curtain, host);
            }
        } else {
            // 已创建，更新布局
            LGDI2UpdateGlass();
        }
    }
}

// =============================================================================
// 查找并 swizzle 灵动岛类
// =============================================================================

static void LGDI2SwizzleIslandClass(Class cls) {
    if (!cls || sLGDI2Swizzled) return;

    SEL layoutSel = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, layoutSel);
    if (!method) {
        LGDI2Log(@"swizzle failed: layoutSubviews not found on %@", NSStringFromClass(cls));
        return;
    }

    sLGDI2OrigLayoutSubviews = method_getImplementation(method);
    method_setImplementation(method, (IMP)swizzled_LGDI2_layoutSubviews);
    sLGDI2Swizzled = YES;

    LGDI2Log(@"swizzled layoutSubviews on %@", NSStringFromClass(cls));
}

// 尝试多个候选类名
static void LGDI2TrySwizzleCandidates(void) {
    NSArray *candidates = @[
        @"_SBSystemApertureMagiciansCurtainView",
        @"SBSystemApertureMagiciansCurtainView",
        @"_SAUIMagiciansCurtainView",
        @"SAUIMagiciansCurtainView",
    ];

    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name);
        if (cls) {
            LGDI2Log(@"found candidate class: %@", name);
            LGDI2SwizzleIslandClass(cls);
            return;
        }
    }

    LGDI2Log(@"no candidate class found, will fallback to view scanning");
}

// 递归扫描所有窗口查找灵动岛
static void LGDI2ScanAndInject(void) {
    if (!LGDI2FeatureEnabled()) return;
    if (sLGDI2Glass) return;

    LGDI2Log(@"scanAndInject: scanning all windows");

    NSArray *windows = [UIApplication sharedApplication].windows;
    LGDI2Log(@"  total windows: %lu", (unsigned long)windows.count);

    for (UIWindow *w in windows) {
        LGDI2Log(@"  window: %@ (%.0fx%.0f)",
                 NSStringFromClass(w.class),
                 w.bounds.size.width, w.bounds.size.height);

        UIView *curtain = LGDI2FindViewOfClass(w, @"MagiciansCurtain");
        if (curtain) {
            LGDI2Log(@"  FOUND curtain in window: %@", NSStringFromClass(w.class));
            LGDI2Log(@"  curtain class: %@ frame=%@",
                     NSStringFromClass(curtain.class),
                     NSStringFromCGRect(curtain.frame));

            // 如果还没 swizzle，现在 swizzle
            if (!sLGDI2Swizzled) {
                LGDI2SwizzleIslandClass([curtain class]);
            }

            // 直接创建玻璃
            UIView *host = LGDI2FindHostForCurtain(curtain);
            if (host) {
                LGDI2Log(@"  host: %@", NSStringFromClass(host.class));
                LGDI2CreateGlass(curtain, host);
            }

            // 打印视图树（调试）
            LGDI2Log(@"  --- curtain subview tree ---");
            LGDI2PrintTree(curtain, 2);
            LGDI2Log(@"  --- host subview tree (first 3 levels) ---");
            LGDI2PrintTree(host, 2);

            return;
        }
    }

    LGDI2Log(@"scanAndInject: no curtain found");
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

    // 尝试 swizzle 候选类
    LGDI2TrySwizzleCandidates();

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
            LGDI2ScanAndInject();
        } else {
            LGDI2DestroyGlass();
        }
    });

    // 多次延迟扫描（灵动岛可能启动较晚）
    NSArray *delays = @[@0.5, @1.5, @3.0, @6.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            LGDI2Log(@"delayed scan (%.1fs)", delay.doubleValue);
            LGDI2ScanAndInject();
        });
    }

    LGDI2Log(@"DI2 init complete");
}
