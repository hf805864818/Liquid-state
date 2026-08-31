#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static const void *kLGNotificationCenterGlassKey = &kLGNotificationCenterGlassKey;

static BOOL LGHasMaterialAncestorBefore(UIView *material, NSString *stopClassName) {
    Class stopCls = NSClassFromString(stopClassName);
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        if (stopCls && [v isKindOfClass:stopCls]) return NO;
        if (materialClass && [v isKindOfClass:materialClass]) return YES;
    }
    return NO;
}

static BOOL LGNotificationCenterEnabled(void) {
    return lgHostEnabled(@"NotificationCenter");
}

static BOOL LGIsNotificationCenterView(UIView *view) {
    if (!view || !view.window) return NO;

    // Check for notification list view controllers
    if (hasAncestorOfClassName(view, @"NCNotificationListViewController")) return YES;
    if (hasAncestorOfClassName(view, @"NCNotificationMasterListViewController")) return YES;

    // Check for notification center container
    if (hasAncestorOfClassName(view, @"SBNotificationCenterViewController")) return YES;

    return NO;
}

static BOOL LGIsNotificationCenterMaterial(UIView *material) {
    if (!LGNotificationCenterEnabled()) return NO;
    if (!LGIsNotificationCenterView(material)) return NO;

    // Only target the main background material, not individual notification platers
    // Individual notifications are handled by the Notification host
    if (hasAncestorOfClassName(material, @"PLPlatterView")) return NO;
    if (hasAncestorOfClassName(material, @"NCNotificationShortLookView")) return NO;
    if (hasAncestorOfClassName(material, @"NCNotificationLongLookView")) return NO;

    // Check it's a top-level material in the notification center
    if (!hasAncestorOfClassName(material, @"MTMaterialView")) return YES;

    return !LGHasMaterialAncestorBefore(material, nil);
}

static void LGUpdateNotificationCenterGlass(UIView *material) {
    if (!material.window) return;
    if (!LGIsNotificationCenterMaterial(material)) return;

    LGInstallRegisteredGlassInMaterial(material, kLGNotificationCenterGlassKey,
                                       @"NotificationCenter",
                                       UIEdgeInsetsZero, -1.0, nil);
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window && LGIsNotificationCenterView(self_)) {
        LGUpdateNotificationCenterGlass(self_);
    }
}
- (void)layoutSubviews {
    %orig;
    if (LGIsNotificationCenterView((UIView *)self)) {
        LGUpdateNotificationCenterGlass((UIView *)self);
    }
}
%end

%ctor {
    lgObservePreferenceReload(^{
        // Glass will be updated on next layout pass
    });
}
