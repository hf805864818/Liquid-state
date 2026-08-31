#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const void *kLGDynamicIslandGlassKey = &kLGDynamicIslandGlassKey;
static const void *kLGDynamicIslandMaskKey = &kLGDynamicIslandMaskKey;

static BOOL LGDynamicIslandEnabled(void) {
    return lgHostEnabled(@"DynamicIsland");
}

static CGFloat LGDynamicIslandCornerRadiusForView(UIView *view) {
    CGFloat height = CGRectGetHeight(view.bounds);
    if (height > 0) return height * 0.5;
    return 18.0;
}

static void LGUpdateDynamicIslandMask(LGLiveBackdropView *glassView, UIView *containerView) {
    if (!glassView || !containerView || CGRectIsEmpty(glassView.bounds)) return;

    CAShapeLayer *mask = objc_getAssociatedObject(glassView, kLGDynamicIslandMaskKey);
    if (!mask) {
        mask = [CAShapeLayer layer];
        mask.fillColor = UIColor.blackColor.CGColor;
        objc_setAssociatedObject(glassView, kLGDynamicIslandMaskKey, mask,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.layer.mask = mask;
    }

    CGRect bounds = glassView.bounds;
    CGFloat cornerRadius = LGDynamicIslandCornerRadiusForView(containerView);
    if (cornerRadius > CGRectGetHeight(bounds) * 0.5) {
        cornerRadius = CGRectGetHeight(bounds) * 0.5;
    }

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds
                                               byRoundingCorners:UIRectCornerAllCorners
                                                     cornerRadii:CGSizeMake(cornerRadius, cornerRadius)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.path = path.CGPath;
    mask.frame = bounds;
    [CATransaction commit];
}

static void LGInstallDynamicIslandGlass(UIView *containerView) {
    if (!containerView || !containerView.window) return;
    if (!LGDynamicIslandEnabled()) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDynamicIslandGlassKey);
    if (!glassView) {
        glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glassView.userInteractionEnabled = NO;
        glassView.backgroundColor = UIColor.clearColor;
        objc_setAssociatedObject(containerView, kLGDynamicIslandGlassKey, glassView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [containerView insertSubview:glassView atIndex:0];
    }

    glassView.frame = containerView.bounds;
    LGUpdateDynamicIslandMask(glassView, containerView);
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

// Hook Dynamic Island container views
%hook SBDynamicIslandView
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGInstallDynamicIslandGlass((UIView *)self);
    } else {
        LGRemoveDynamicIslandGlass((UIView *)self);
    }
}
- (void)layoutSubviews {
    %orig;
    LGInstallDynamicIslandGlass((UIView *)self);
}
%end

// Alternative: hook the proud lock container which holds the dynamic island on lockscreen
%hook SBUIProudLockContainerView
- (void)didMoveToWindow {
    %orig;
    if (self.window && LGDynamicIslandEnabled()) {
        LGInstallDynamicIslandGlass((UIView *)self);
    } else {
        LGRemoveDynamicIslandGlass((UIView *)self);
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
