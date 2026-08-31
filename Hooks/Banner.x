#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static const void *kLGBannerGlassAnimatedKey = &kLGBannerGlassAnimatedKey;
static const void *kLGBannerGlassViewKey = &kLGBannerGlassViewKey;

static BOOL LGBannerSmoothAnimationEnabled(void) {
    return LG_prefBool(@"Banner.Animation.SmoothGlass", NO);
}

static CGFloat LGBannerAnimationDuration(void) {
    return LG_prefFloat(@"Banner.Animation.Duration", 0.5);
}

static BOOL LGBannerSpringEffectEnabled(void) {
    return LG_prefBool(@"Banner.Animation.SpringEffect", YES);
}

static void LGBannerAnimateGlassIn(UIView *glassView) {
    if (!glassView || !LGBannerSmoothAnimationEnabled()) return;

    glassView.alpha = 0.0;
    CGFloat duration = LGBannerAnimationDuration();
    BOOL spring = LGBannerSpringEffectEnabled();

    if (spring) {
        [UIView animateWithDuration:duration
                              delay:0.0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            glassView.alpha = 1.0;
        } completion:nil];
    } else {
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            glassView.alpha = 1.0;
        } completion:nil];
    }
}

static void LGBannerAnimateGlassOut(UIView *glassView, void (^completion)(void)) {
    if (!glassView || !LGBannerSmoothAnimationEnabled()) {
        if (completion) completion();
        return;
    }

    CGFloat duration = LGBannerAnimationDuration() * 0.6;
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        glassView.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (completion) completion();
    }];
}

static BOOL LGHasMaterialAncestorBefore(UIView *material, NSString *stopClassName) {
    Class stopCls = NSClassFromString(stopClassName);
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        if (stopCls && [v isKindOfClass:stopCls]) return NO;
        if (materialClass && [v isKindOfClass:materialClass]) return YES;
    }
    return NO;
}

static BOOL LGIsPlatterMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"PLPlatterView")) return NO;
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return !LGHasMaterialAncestorBefore(material, @"PLPlatterView");
}

static BOOL LGIsPlatterActionMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"PLPlatterActionButton")) return NO;
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return !LGHasMaterialAncestorBefore(material, @"PLPlatterActionButton");
}

static BOOL LGResponderChainContainsClass(UIResponder *responder, NSString *name) {
    Class cls = NSClassFromString(name);
    for (UIResponder *r = responder; r; r = r.nextResponder)
        if (cls && [r isKindOfClass:cls]) return YES;
    return NO;
}

static void *kLGPlatterClassificationKey = &kLGPlatterClassificationKey;

static BOOL LGIsTopBannerPresentation(UIView *view) {
    if (!view.window) return NO;
    if ([NSStringFromClass(view.window.class) isEqualToString:@"SBBannerWindow"]) return YES;
    if (hasAncestorOfClassName(view, @"BNContentViewControllerView")) return YES;
    if (LGResponderChainContainsClass(view, @"BNContentViewController")) return YES;
    return LGResponderChainContainsClass(view, @"SBNotificationPresentableViewController");
}

static BOOL LGIsLightLockscreenNotificationView(UIView *view) {
    if (!view || LGIsTopBannerPresentation(view)) return NO;
    if (view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight) return NO;
    return hasAncestorOfClassName(view, @"NCNotificationShortLookView") ||
           hasAncestorOfClassName(view, @"NCNotificationLongLookView") ||
           hasAncestorOfClassName(view, @"PLPlatterView");
}

static UIColor *LGForcedPlatterTextColor(UIView *view) {
    if (!view || view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight) return nil;
    if (LGIsTopBannerPresentation(view)) return UIColor.blackColor;
    return LGIsLightLockscreenNotificationView(view) ? UIColor.whiteColor : nil;
}

static NSAttributedString *LGAttributedTextWithColor(NSAttributedString *text, UIColor *color) {
    if (!color) return text;
    if (!text.length) return text;
    NSMutableAttributedString *copy = [text mutableCopy];
    [copy addAttribute:NSForegroundColorAttributeName
                 value:color
                 range:NSMakeRange(0, copy.length)];
    return copy;
}

static void LGDisableLockscreenStackDimming(id controller) {
    // stack dimming belongs to notifications and not top banners
    if (!controller || LGIsTopBannerPresentation([controller isKindOfClass:[UIViewController class]]
                                                   ? ((UIViewController *)controller).view : nil)) return;
    @try {
        id preview = [controller valueForKey:@"viewForPreview"];
        UIView *dimming = [preview valueForKey:@"stackDimmingOverlayView"];
        if (!dimming) {
            id contentSizeManager = [controller valueForKey:@"contentSizeManagingView"];
            dimming = [contentSizeManager valueForKey:@"stackDimmingView"];
        }
        if (dimming) dimming.hidden = lgHostEnabled(@"Notification");
    } @catch (__unused NSException *exception) {

    }
}

static CGFloat LGActionButtonRadius(UIView *material) {
    UIView *button = material;
    for (UIView *v = material; v; v = v.superview)
        if ([NSStringFromClass(v.class) isEqualToString:@"PLPlatterActionButton"]) {
            button = v;
            break;
        }
    if (button.layer.cornerRadius > 0.5) return button.layer.cornerRadius;
    if (material.layer.cornerRadius > 0.5) return material.layer.cornerRadius;
    return CGRectGetHeight(button.bounds) * 0.5;
}

static void LGUpdatePlatterGlass(UIView *material) {
    // one platter class serves banners notifications and action buttons

    if (!material.window) return;

    if (LGIsPlatterMaterial(material)) {
        BOOL topBanner = LGIsTopBannerPresentation(material);
        NSString *prefix = topBanner ? @"Banner" : @"Notification";
        NSString *previous = objc_getAssociatedObject(material, kLGPlatterClassificationKey);
        if (previous && ![previous isEqualToString:prefix]) {
            LGRemoveGlassFromMaterial(material, kGlassKey);
        }
        if (![previous isEqualToString:prefix]) {
            objc_setAssociatedObject(material, kLGPlatterClassificationKey, prefix,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        LGLiveBackdropView *glassView = LGInstallRegisteredGlassInMaterial(material, kGlassKey, prefix,
                                           UIEdgeInsetsZero, -1.0, nil);

        // Trigger fade-in animation for top banners
        if (topBanner && glassView && LGBannerSmoothAnimationEnabled()) {
            NSNumber *alreadyAnimated = objc_getAssociatedObject(material, kLGBannerGlassAnimatedKey);
            if (!alreadyAnimated || !alreadyAnimated.boolValue) {
                objc_setAssociatedObject(material, kLGBannerGlassAnimatedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(material, kLGBannerGlassViewKey, glassView, OBJC_ASSOCIATION_ASSIGN);
                LGBannerAnimateGlassIn((UIView *)glassView);
            }
        }
    } else if (LGIsPlatterActionMaterial(material)) {

        LGInstallRegisteredGlassInMaterial(material, kGlassKey, @"Notification",
                                           UIEdgeInsetsZero,
                                           LGActionButtonRadius(material), nil);
    }
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) {
        LGUpdatePlatterGlass(self_);
    } else {
        // Trigger fade-out animation for top banners when removed from window
        if (LGIsTopBannerPresentation(self_) && LGBannerSmoothAnimationEnabled()) {
            LGLiveBackdropView *glassView = objc_getAssociatedObject(self_, kLGBannerGlassViewKey);
            if (glassView) {
                LGBannerAnimateGlassOut((UIView *)glassView, nil);
                objc_setAssociatedObject(self_, kLGBannerGlassAnimatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}
- (void)layoutSubviews {
    %orig;
    LGUpdatePlatterGlass((UIView *)self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (forced) color = forced;
    %orig(color);
}
- (void)setAttributedText:(NSAttributedString *)text {
    text = LGAttributedTextWithColor(text, LGForcedPlatterTextColor((UIView *)self));
    %orig(text);
}
- (void)didMoveToWindow {
    %orig;
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (!forced) return;
    if (self.attributedText.length) self.attributedText = LGAttributedTextWithColor(self.attributedText, forced);
    self.textColor = forced;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (!forced) return;
    if (self.attributedText.length) self.attributedText = LGAttributedTextWithColor(self.attributedText, forced);
    self.textColor = forced;
}
%end

%hook NCNotificationShortLookViewController
- (void)viewDidLoad {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
%end
