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
// 注意：使用 gain map view 作为锚点，因为它是灵动岛的核心形状视图
// 在不同 iOS 版本中类名可能变化，但 _SBGainMapView 通常是稳定的内部类
static void LGInstallDynamicIslandGlass(UIView *containerView) {
    if (!containerView || !containerView.window) return;
    if (!LGDynamicIslandEnabled()) return;

    UIView *parent = containerView.superview;
    if (!parent) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDynamicIslandGlassKey);
    if (!glassView) {
        CGFloat radius = LGDynamicIslandCornerRadiusForSize(containerView.bounds.size);
        glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
        if (!glassView) return;

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

    // 确保 glassView 在最上层（防止其他子视图遮挡）
    [parent bringSubviewToFront:glassView];

    // 更新位置和大小
    CGRect targetFrame = containerView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
    }

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

#pragma mark - Hook _SBGainMapView（主路径：灵动岛核心形状视图）

// _SBGainMapView 是灵动岛的增益图视图，负责定义灵动岛的形状
// 这是内部类，类名通常以 _ 开头，在各 iOS 版本中相对稳定
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

#pragma mark - Hook SBDynamicIslandView（备用路径：部分 iOS 版本可能使用此类）

// 某些 iOS 版本中灵动岛的主容器视图可能叫 SBDynamicIslandView
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

#pragma mark - Hook SBUIProudLockContainerView（锁屏场景）

// 锁屏状态下的灵动岛容器视图
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
        // 偏好设置变更时，glass 会在下一次 layout 时重新评估
    });
}
