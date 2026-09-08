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

// 安装灵动岛液态玻璃（参考 LGInjectGlassIntoMaterialGroupType 的模式）
static void LGInstallDynamicIslandGlass(UIView *containerView) {
    if (!containerView || !containerView.window) return;
    if (!LGDynamicIslandEnabled()) return;

    UIView *parent = containerView.superview;
    if (!parent) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDynamicIslandGlassKey);
    if (!glassView) {
        CGFloat radius = LGDynamicIslandCornerRadiusForSize(containerView.bounds.size);
        glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
        glassView.userInteractionEnabled = NO;
        glassView.backgroundColor = UIColor.clearColor;
        glassView.layer.cornerRadius = radius;
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
        glassView.layer.masksToBounds = YES;

        // 延迟重试 applyFilters（防止 backboardd filter 还没注册好）
        __weak LGLiveBackdropView *weakGlass = glassView;
        for (NSNumber *delay in @[ @1.5, @3.0, @5.0, @8.0, @12.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }

        [parent insertSubview:glassView aboveSubview:containerView];
        objc_setAssociatedObject(containerView, kLGDynamicIslandGlassKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 更新位置和大小
    glassView.frame = containerView.frame;
    CGFloat radius = LGDynamicIslandCornerRadiusForSize(containerView.bounds.size);
    if (fabs(glassView.layer.cornerRadius - radius) > 0.5) {
        glassView.layer.cornerRadius = radius;
        [glassView applyFilters];
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

#pragma mark - Hook SBDynamicIslandView（主路径：确保类存在）

%hook SBDynamicIslandView
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

#pragma mark - Hook _SBGainMapView（优化路径：获取更精确的形状）

// 如果 _SBGainMapView 存在，优先用它的形状（更贴近真实灵动岛）
%hook _SBGainMapView
- (void)didMoveToWindow {
    %orig;
    // 暂时只做日志验证，确认类是否存在
    // 后续版本会用 gain map 形状替换 SDF 胶囊形状
}
- (void)layoutSubviews {
    %orig;
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
