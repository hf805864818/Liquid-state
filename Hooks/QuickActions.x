#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static void *kQAGlassKey = &kQAGlassKey;
static void *kQABackdropKey = &kQABackdropKey;
static void *kQABackdropAlphaKey = &kQABackdropAlphaKey;
static NSHashTable<UIVisualEffectView *> *sQuickActionHosts;
static void removeQuickActionsGlass(UIVisualEffectView *fx);

static void LGQALog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGQALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[QA] %@", s);
}

static UIView *qaBackdropView(UIView *effectView) {
    for (UIView *sub in effectView.subviews) {
        if ([sub isKindOfClass:[LGLiveBackdropView class]]) continue;
        if ([NSStringFromClass(sub.class) containsString:@"Backdrop"]) return sub;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[LGLiveBackdropView class]]) continue;
            if ([NSStringFromClass(inner.class) containsString:@"Backdrop"]) return inner;
        }
    }
    return nil;
}

static void qaSetBackdropHidden(UIVisualEffectView *effectView) {
    UIView *backdrop = qaBackdropView(effectView);
    if (!backdrop) return;
    if (!objc_getAssociatedObject(effectView, kQABackdropAlphaKey)) {
        objc_setAssociatedObject(effectView, kQABackdropKey, backdrop,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(effectView, kQABackdropAlphaKey, @(backdrop.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    backdrop.alpha = 0.0;
}

static BOOL isQuickActionsHost(UIView *view) {
    if (![view isKindOfClass:[UIVisualEffectView class]] || !view.window) return NO;
    // 移除 safeAreaInsets.bottom 检查 — iOS 17 上 didMoveToWindow 触发时
    // safe area 可能尚未设置,导致误判为非快捷操作。
    // CSQuickActionsButton 祖先检查已足够精确 (SpringBoard 专属类)。
    Class qaCls = NSClassFromString(@"CSQuickActionsButton");
    if (!qaCls) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            LGQALog(@"CSQuickActionsButton class NOT FOUND — QA detection will fail");
        });
        return NO;
    }
    for (UIView *a = view.superview; a; a = a.superview) {
        if (qaCls && [a isKindOfClass:qaCls]) {
            LGQALog(@"host detected via ancestor: %@", NSStringFromClass(a.class));
            return YES;
        }
        if ([a isKindOfClass:[UIVisualEffectView class]]) return NO;
    }
    return NO;
}

// 在 CSQuickActionsButton 子视图树中查找 UIVisualEffectView (最多 3 层)
static UIVisualEffectView *qaFindEffectView(UIView *view) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            LGQALog(@"findEffectView: found at level 1: %@ bounds=%@",
                    NSStringFromClass(sub.class),
                    NSStringFromCGRect(((UIVisualEffectView *)sub).bounds));
            return (UIVisualEffectView *)sub;
        }
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[UIVisualEffectView class]]) {
                LGQALog(@"findEffectView: found at level 2 in %@: %@ bounds=%@",
                        NSStringFromClass(sub.class),
                        NSStringFromClass(inner.class),
                        NSStringFromCGRect(((UIVisualEffectView *)inner).bounds));
                return (UIVisualEffectView *)inner;
            }
        }
    }
    LGQALog(@"findEffectView: NOT found in %@ (subviews=%lu)",
            NSStringFromClass(view.class),
            (unsigned long)view.subviews.count);
    return nil;
}

static void injectQuickActionsGlass(UIVisualEffectView *fx) {
    if (!lgHostEnabled(@"QuickActions")) {
        removeQuickActionsGlass(fx);
        return;
    }
    UIView *container = fx.contentView;
    if (CGRectGetWidth(container.bounds) < 4.0 || CGRectGetHeight(container.bounds) < 4.0) return;

    qaSetBackdropHidden(fx);

    if (@available(iOS 13.0, *)) {
        fx.overrideUserInterfaceStyle        = UIUserInterfaceStyleLight;
        container.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kQAGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"QuickActions");
        if (!glass) {
            LGQALog(@"inject FAILED — glass creation returned nil (bounds=%@)",
                    NSStringFromCGRect(container.bounds));
            return;
        }
        LGQALog(@"inject: created new glass bounds=%@", NSStringFromCGRect(container.bounds));
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(fx, kQAGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    glass.frame               = container.bounds;
    glass.layer.cornerRadius  = fmin(CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds)) * 0.5;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    if (!sQuickActionHosts) sQuickActionHosts = [NSHashTable weakObjectsHashTable];
    [sQuickActionHosts addObject:fx];
    lgTrackGlass(glass, @"QuickActions", nil);
}

static void removeQuickActionsGlass(UIVisualEffectView *fx) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(fx, kQAGlassKey);
    if (@available(iOS 13.0, *)) {
        fx.overrideUserInterfaceStyle             = UIUserInterfaceStyleUnspecified;
        fx.contentView.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    }
    UIView *backdrop = objc_getAssociatedObject(fx, kQABackdropKey);
    NSNumber *alpha = objc_getAssociatedObject(fx, kQABackdropAlphaKey);
    if (backdrop && alpha) backdrop.alpha = alpha.doubleValue;
    objc_setAssociatedObject(fx, kQABackdropKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(fx, kQABackdropAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(fx, kQAGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [sQuickActionHosts removeObject:fx];
}

static void LGReconcileQuickActionHosts(void) {
    for (UIVisualEffectView *host in sQuickActionHosts.allObjects) {
        if (lgHostEnabled(@"QuickActions")) injectQuickActionsGlass(host);
        else removeQuickActionsGlass(host);
    }
}

%hook UIVisualEffectView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) { removeQuickActionsGlass((UIVisualEffectView *)self_); return; }
    if (isQuickActionsHost(self_)) injectQuickActionsGlass((UIVisualEffectView *)self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (isQuickActionsHost(self_)) injectQuickActionsGlass((UIVisualEffectView *)self_);
}
%end

// 直接 Hook CSQuickActionsButton — 当按钮本身移动到窗口或布局变化时重新注入玻璃。
// 解决 iOS 17 上 UIVisualEffectView 不触发 didMoveToWindow 的问题。
// 这些方法只在锁屏显示/隐藏时触发,无定时器、无轮询,不影响耗电和温度。
%hook CSQuickActionsButton
- (void)didMoveToWindow {
    %orig;
    UIView *btn = (UIView *)self;
    LGQALog(@"CSQuickActionsButton didMoveToWindow (hasWindow=%d class=%@)",
            btn.window != nil, NSStringFromClass(btn.class));
    UIVisualEffectView *fx = qaFindEffectView(btn);
    if (!fx) return;
    if (!btn.window) {
        removeQuickActionsGlass(fx);
    } else {
        injectQuickActionsGlass(fx);
    }
}
- (void)layoutSubviews {
    %orig;
    UIView *btn = (UIView *)self;
    if (!btn.window) return;
    UIVisualEffectView *fx = qaFindEffectView(btn);
    if (fx) injectQuickActionsGlass(fx);
}
%end

%ctor {
    LGQALog(@"QuickActions module loaded — CSQuickActionsButton class %@",
            NSClassFromString(@"CSQuickActionsButton") ? @"FOUND" : @"NOT FOUND");
    lgObservePreferenceReload(^{ LGReconcileQuickActionHosts(); });
}
