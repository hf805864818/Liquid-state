#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

static const void *kLGLandscapeVolumeGlassKey = &kLGLandscapeVolumeGlassKey;

static BOOL LGLandscapeVolumeGlassEnabled(void) {
    return LG_prefBool(@"LandscapeVolumeGlass.Enabled", NO);
}

static CGFloat LGLandscapeVolumeGlassCornerRadius(void) {
    return LG_prefFloat(@"LandscapeVolumeGlass.CornerRadius", 16.0);
}

static CGFloat LGLandscapeVolumeGlassBlur(void) {
    return LG_prefFloat(@"LandscapeVolumeGlass.Blur", 20.0);
}

static void LGLandscapeVolumeApplyGlassToView(UIView *view) {
    if (!LGLandscapeVolumeGlassEnabled()) return;
    if (!view) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGLandscapeVolumeGlassKey);
    if (!glassView) {
        glassView = LGCreateRegisteredGlass(@"LandscapeVolume", view.bounds);
        objc_setAssociatedObject(view, kLGLandscapeVolumeGlassKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view insertSubview:glassView atIndex:0];
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    CGFloat radius = LGLandscapeVolumeGlassCornerRadius();
    glassView.layer.cornerRadius = radius;
    glassView.clipsToBounds = YES;
    glassView.frame = view.bounds;

    // Apply custom blur
    [glassView setValue:@(LGLandscapeVolumeGlassBlur()) forKey:@"blurRadius"];
}

static void LGLandscapeVolumeRemoveGlassFromView(UIView *view) {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGLandscapeVolumeGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(view, kLGLandscapeVolumeGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// SpringBoard landscape volume press band
%hook SBVolumePressBand

- (void)layoutSubviews {
    %orig;
    if (LGLandscapeVolumeGlassEnabled()) {
        LGLandscapeVolumeApplyGlassToView((UIView *)self);
    } else {
        LGLandscapeVolumeRemoveGlassFromView((UIView *)self);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window && LGLandscapeVolumeGlassEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGLandscapeVolumeApplyGlassToView((UIView *)self);
        });
    }
}

%end

// Also handle the volume HUD view
%hook SBVolumeHUDView

- (void)layoutSubviews {
    %orig;
    // The volume HUD is different from landscape press bands,
    // but we can add glass to its background if desired
}

%end

%ctor {
    lgObservePreferenceReload(^{
        // Glass views will update on next layout pass
    });
}
