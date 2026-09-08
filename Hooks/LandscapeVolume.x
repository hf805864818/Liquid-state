#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

// Vibrance view: sits on top of glass, boosts saturation/contrast for visual richness
@interface LGVolumeVibranceView : UIView
@end

@implementation LGVolumeVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingNone;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;
        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;
        NSMutableArray *filters = [NSMutableArray array];
        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }
        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }
        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

static const void * const kLGLandscapeVolumeGlassKey = &kLGLandscapeVolumeGlassKey;
static const void * const kLGLandscapeVolumeVibranceKey = &kLGLandscapeVolumeVibranceKey;
static const void * const kLGVolumeHUDGlassKey = &kLGVolumeHUDGlassKey;
static const void * const kLGVolumeHUDVibranceKey = &kLGVolumeHUDVibranceKey;

#pragma mark - Preference helpers

static BOOL LGLandscapeVolumeGlassEnabled(void) {
    return LG_prefBool(@"LandscapeVolumeGlass.Enabled", NO);
}

static CGFloat LGLandscapeVolumeGlassCornerRadius(void) {
    return LG_prefFloat(@"LandscapeVolumeGlass.CornerRadius", 16.0);
}

static CGFloat LGLandscapeVolumeGlassBlur(void) {
    return LG_prefFloat(@"LandscapeVolumeGlass.Blur", 20.0);
}

static BOOL LGVolumeHUDGlassEnabled(void) {
    return LG_prefBool(@"VolumeHUDGlass.Enabled", NO);
}

static CGFloat LGVolumeHUDGlassCornerRadius(void) {
    return LG_prefFloat(@"VolumeHUDGlass.CornerRadius", 20.0);
}

static CGFloat LGVolumeHUDGlassBlur(void) {
    return LG_prefFloat(@"VolumeHUDGlass.Blur", 15.0);
}

#pragma mark - System material view helpers

// Find and hide/show system MTMaterialView subviews
static void LGHideSystemMaterialViews(UIView *view, BOOL hide) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    if (!materialClass) return;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:materialClass]) {
            subview.hidden = hide;
        }
    }
}

#pragma mark - Landscape volume (SBVolumePressBand)

static void LGLandscapeVolumeApplyGlassToView(UIView *view) {
    if (!LGLandscapeVolumeGlassEnabled() || !view) return;

    // Hide system material views so our glass is visible
    LGHideSystemMaterialViews(view, YES);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGLandscapeVolumeGlassKey);
    if (!glassView) {
        glassView = LGCreateRegisteredGlass(view.bounds, nil, @"LandscapeVolume");
        if (!glassView) return;
        objc_setAssociatedObject(view, kLGLandscapeVolumeGlassKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glassView, @"LandscapeVolume", view);
        // Insert on top so it's visible above remaining system subviews
        [view addSubview:glassView];
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    CGFloat radius = LGLandscapeVolumeGlassCornerRadius();
    glassView.frame = view.bounds;
    glassView.layer.cornerRadius = radius;
    glassView.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glassView.hidden = NO;
    [glassView applyFilters];

    // Add vibrance layer on top of glass
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGLandscapeVolumeVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeVibranceView alloc] initWithFrame:view.bounds];
        if (vibrance) {
            objc_setAssociatedObject(view, kLGLandscapeVolumeVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view addSubview:vibrance];
            vibrance.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
    }
    if (vibrance) {
        vibrance.frame = view.bounds;
        vibrance.layer.cornerRadius = radius;
        vibrance.layer.masksToBounds = YES;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.hidden = NO;
    }

    // Apply corner radius to the host view itself
    view.layer.cornerRadius = radius;
    view.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static void LGLandscapeVolumeRemoveGlassFromView(UIView *view) {
    if (!view) return;
    // Restore system material views
    LGHideSystemMaterialViews(view, NO);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGLandscapeVolumeGlassKey);
    if (glassView) {
        glassView.hidden = YES;
        [glassView removeFromSuperview];
        objc_setAssociatedObject(view, kLGLandscapeVolumeGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGLandscapeVolumeVibranceKey);
    if (vibrance) {
        vibrance.hidden = YES;
        [vibrance removeFromSuperview];
        objc_setAssociatedObject(view, kLGLandscapeVolumeVibranceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Portrait volume HUD (SBVolumeHUDView)

static void LGVolumeHUDApplyGlassToView(UIView *view) {
    if (!LGVolumeHUDGlassEnabled() || !view) return;

    // Hide system material views so our glass is visible
    LGHideSystemMaterialViews(view, YES);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGVolumeHUDGlassKey);
    if (!glassView) {
        glassView = LGCreateRegisteredGlass(view.bounds, nil, @"VolumeHUD");
        if (!glassView) return;
        objc_setAssociatedObject(view, kLGVolumeHUDGlassKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glassView, @"VolumeHUD", view);
        // Insert on top so it's visible above remaining system subviews
        [view addSubview:glassView];
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    CGFloat radius = LGVolumeHUDGlassCornerRadius();
    glassView.frame = view.bounds;
    glassView.layer.cornerRadius = radius;
    glassView.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glassView.hidden = NO;
    [glassView applyFilters];

    // Add vibrance layer on top of glass
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGVolumeHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeVibranceView alloc] initWithFrame:view.bounds];
        if (vibrance) {
            objc_setAssociatedObject(view, kLGVolumeHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view addSubview:vibrance];
            vibrance.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
    }
    if (vibrance) {
        vibrance.frame = view.bounds;
        vibrance.layer.cornerRadius = radius;
        vibrance.layer.masksToBounds = YES;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.hidden = NO;
    }

    // Apply corner radius to the host view itself
    view.layer.cornerRadius = radius;
    view.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static void LGVolumeHUDRemoveGlassFromView(UIView *view) {
    if (!view) return;
    // Restore system material views
    LGHideSystemMaterialViews(view, NO);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGVolumeHUDGlassKey);
    if (glassView) {
        glassView.hidden = YES;
        [glassView removeFromSuperview];
        objc_setAssociatedObject(view, kLGVolumeHUDGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGVolumeHUDVibranceKey);
    if (vibrance) {
        vibrance.hidden = YES;
        [vibrance removeFromSuperview];
        objc_setAssociatedObject(view, kLGVolumeHUDVibranceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Hooks

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
    UIView *selfView = (UIView *)self;
    if (selfView.window && LGLandscapeVolumeGlassEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGLandscapeVolumeApplyGlassToView(selfView);
        });
    } else if (!selfView.window) {
        LGLandscapeVolumeRemoveGlassFromView(selfView);
    }
}

%end

// Portrait volume HUD view
%hook SBVolumeHUDView

- (void)layoutSubviews {
    %orig;
    if (LGVolumeHUDGlassEnabled()) {
        LGVolumeHUDApplyGlassToView((UIView *)self);
    } else {
        LGVolumeHUDRemoveGlassFromView((UIView *)self);
    }
}

- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (selfView.window && LGVolumeHUDGlassEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGVolumeHUDApplyGlassToView(selfView);
        });
    } else if (!selfView.window) {
        LGVolumeHUDRemoveGlassFromView(selfView);
    }
}

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    lgObservePreferenceReload(^{
        // Glass views will update on next layout pass
    });
}
