#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const void *kLGDynamicIslandGlassKey = &kLGDynamicIslandGlassKey;

static BOOL LGDynamicIslandEnabled(void) {
    return lgHostEnabled(@"DynamicIsland");
}

// 计算灵动岛玻璃的圆角（胶囊形状 = 高度的一半）
static CGFloat LGDynamicIslandCornerRadiusForSize(CGSize size) {
    CGFloat height = size.height;
    if (height > 0) return height * 0.5;
    return 18.0;
}

// 安装灵动岛液态玻璃
static void LGInstallDynamicIslandGlass(UIView *containerView) {
    if (!containerView || !containerView.window) return;
    if (!LGDynamicIslandEnabled()) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDynamicIslandGlassKey);
    if (!glassView) {
        glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glassView.userInteractionEnabled = NO;
        glassView.backgroundColor = UIColor.clearColor;
        // 胶囊形状：圆角 = 高度的一半
        CGFloat radius = LGDynamicIslandCornerRadiusForSize(containerView.bounds.size);
        glassView.layer.cornerRadius = radius;
        glassView.layer.masksToBounds = YES;
        objc_setAssociatedObject(containerView, kLGDynamicIslandGlassKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [containerView insertSubview:glassView atIndex:0];
    }

    glassView.frame = containerView.bounds;
    // 更新圆角（展开/收起时高度变化）
    CGFloat radius = LGDynamicIslandCornerRadiusForSize(containerView.bounds.size);
    if (fabs(glassView.layer.cornerRadius - radius) > 0.5) {
        glassView.layer.cornerRadius = radius;
    }
}

static void LGRemoveDynamicIslandGlass(UIView *containerView) {
    if (!containerView) return;
    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDynamicIslandGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(containerView, kLGDynamicIslandGlassKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

// 判断 view 是否是灵动岛的 gain map 视图
static BOOL LGIsGainMapView(UIView *view) {
    if (!view) return NO;
    Class cls = object_getClass(view);
    NSString *name = NSStringFromClass(cls);
    if ([name containsString:@"GainMap"]) return YES;
    return NO;
}

// 递归查找 gain map view
static UIView *LGFindGainMapViewInView(UIView *view) {
    if (!view) return nil;
    if (LGIsGainMapView(view)) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = LGFindGainMapViewInView(subview);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Hook _SBGainMapView（主路径：真实形状 + 跟随动画）

%hook _SBGainMapView
- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (selfView.window) {
        LGInstallDynamicIslandGlass(selfView);
    } else {
        LGRemoveDynamicIslandGlass(selfView);
    }
}
- (void)layoutSubviews {
    %orig;
    LGInstallDynamicIslandGlass((UIView *)self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    LGLiveBackdropView *glassView = objc_getAssociatedObject(self, kLGDynamicIslandGlassKey);
    if (glassView) glassView.hidden = hidden;
}
%end

#pragma mark - Hook SBDynamicIslandView（Fallback：老版本兼容）

%hook SBDynamicIslandView
- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    // 如果子视图里有 GainMapView，说明主路径已经在工作了，不重复装
    if (LGFindGainMapViewInView(selfView)) return;
    if (selfView.window) {
        LGInstallDynamicIslandGlass(selfView);
    } else {
        LGRemoveDynamicIslandGlass(selfView);
    }
}
- (void)layoutSubviews {
    %orig;
    UIView *selfView = (UIView *)self;
    if (LGFindGainMapViewInView(selfView)) return;
    LGInstallDynamicIslandGlass(selfView);
}
%end

#pragma mark - Hook SBUIProudLockContainerView（锁屏场景）

%hook SBUIProudLockContainerView
- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (selfView.window && LGDynamicIslandEnabled()) {
        LGInstallDynamicIslandGlass(selfView);
    } else {
        LGRemoveDynamicIslandGlass(selfView);
    }
}
- (void)layoutSubviews {
    %orig;
    if (LGDynamicIslandEnabled()) {
        LGInstallDynamicIslandGlass((UIView *)self);
    }
}
%end

%ctor {
    lgObservePreferenceReload(^{
        // Glass will be re-evaluated on next layout pass
    });
}
