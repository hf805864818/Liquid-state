#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

#pragma mark - taxonomy

static CGFloat sCCSmallModuleRadius = 0.0;

static UIView *ccModuleAncestor(UIView *v) {
    for (UIView *a = v.superview; a; a = a.superview)
        if (isExactClass(a, @"CCUIContentModuleContainerView")) return a;
    return nil;
}

static BOOL ccIsModuleCandidate(UIView *module) {
    CGSize s = module.bounds.size;
    CGFloat mn = fmin(s.width, s.height), mx = fmax(s.width, s.height);
    if (mn < 20.0) return NO;
    return mx <= mn * 1.25;
}

static CGFloat ccModuleCornerRadius(UIView *module) {
    CGFloat h = CGRectGetHeight(module.bounds);
    if (h <= 0.0) return 0.0;
    CGFloat r = h * 0.5;
    if (h < 100.0) { sCCSmallModuleRadius = r; return r; }
    return sCCSmallModuleRadius > 0.0 ? sCCSmallModuleRadius : r;
}

static BOOL ccIsInsideSlider(UIView *mat) {
    return hasAncestorOfClassName(mat, @"CCUIContinuousSliderView") ||
           hasAncestorOfClassName(mat, @"MRUContinuousSliderView");
}

static CGFloat ccPillRadius(UIView *v) {
    return fmin(CGRectGetWidth(v.bounds), CGRectGetHeight(v.bounds)) * 0.5;
}

static CGFloat ccGlassRadiusForMaterial(UIView *mat) {
    if (!isExactClass(mat, @"MTMaterialView")) return -1.0;
    if (!hasAncestorOfClassName(mat, @"CCUIContentModuleContainerView")) return -1.0;

    CGFloat w = CGRectGetWidth(mat.bounds), h = CGRectGetHeight(mat.bounds);
    if (w < 30.0 || h < 30.0) return -1.0;

    if (ccIsInsideSlider(mat)) {
        if (isExactClass(mat.superview, @"MRUContinuousSliderView")) return ccPillRadius(mat);
        // For CCUIContinuousSliderView, also apply glass radius
        return ccPillRadius(mat);
    }

    UIView *module = ccModuleAncestor(mat);
    if (module && ccIsModuleCandidate(module)) return ccModuleCornerRadius(module);
    if (w > 100.0 && h < 100.0) return h * 0.5;
    if (h > 100.0 && w < 100.0) return w * 0.5;
    return ccPillRadius(mat);
}

#pragma mark - fullscreen backdrop styling

static void *kCCFullscreenBlurCapKey = &kCCFullscreenBlurCapKey;
static void *kCCFullscreenDimViewKey = &kCCFullscreenDimViewKey;
static void *kCCFullscreenMaterialKey = &kCCFullscreenMaterialKey;
static void *kCCFullscreenOverlayRootKey = &kCCFullscreenOverlayRootKey;
static NSHashTable<UIView *> *sCCOverlayRoots;

static CFTimeInterval sCCFullscreenDimSyncDeadline = 0.0;
static CFTimeInterval sCCFullscreenDimSyncHardDeadline = 0.0;

static NSHashTable<UIView *> *ccOverlayRoots(void) {
    if (!sCCOverlayRoots) sCCOverlayRoots = [NSHashTable weakObjectsHashTable];
    return sCCOverlayRoots;
}

static CGFloat ccFullscreenBlurRadius(void) {
    return fmax(0.0, LG_prefFloat(@"ControlCenter.FullscreenBackdropBlurRadius", 8.0));
}

static UIColor *ccColorFromRGBAHex(NSString *hex, NSString *fallback) {
    NSString *source = [hex isKindOfClass:NSString.class] && hex.length ? hex : fallback;
    NSString *value = [[[source ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (value.length != 6 && value.length != 8) {
        NSString *fallbackSource = fallback.length ? fallback : @"#00000033";
        value = [[[fallbackSource stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString] copy];
    }
    if (value.length != 6 && value.length != 8) return [UIColor colorWithWhite:0.0 alpha:0.20];

    unsigned parsed = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexInt:&parsed]) return [UIColor colorWithWhite:0.0 alpha:0.20];

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 1.0;
    if (value.length == 6) {
        red = ((parsed >> 16) & 0xff) / 255.0;
        green = ((parsed >> 8) & 0xff) / 255.0;
        blue = (parsed & 0xff) / 255.0;
    } else {
        red = ((parsed >> 24) & 0xff) / 255.0;
        green = ((parsed >> 16) & 0xff) / 255.0;
        blue = ((parsed >> 8) & 0xff) / 255.0;
        alpha = (parsed & 0xff) / 255.0;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

static UIColor *ccFullscreenDimColor(void) {
    NSString *fallback = @"#00000033";
    return ccColorFromRGBAHex(LG_prefString(@"ControlCenter.FullscreenBackdropDimColor", fallback), fallback);
}

static CGFloat ccFullscreenDimTargetAlpha(void) {
    return CGColorGetAlpha(ccFullscreenDimColor().CGColor);
}

static UIColor *ccFullscreenDimBaseColor(void) {
    UIColor *color = ccFullscreenDimColor();
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
    }
    return [color colorWithAlphaComponent:1.0];
}

static BOOL ccIsBlurRadiusKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    return [key isEqualToString:@"inputRadius"] ||
           [key isEqualToString:@"radius"] ||
           [key isEqualToString:@"inputBlurRadius"] ||
           [key isEqualToString:@"blurRadius"];
}

static id ccClampedBlurRadiusValue(id value, CGFloat radius) {
    if (![value respondsToSelector:@selector(doubleValue)]) return value;
    return [value doubleValue] > radius ? @(radius) : value;
}

static void ccSetBlurCapMarker(id object, BOOL enabled) {
    if (!object) return;
    objc_setAssociatedObject(object,
                             kCCFullscreenBlurCapKey,
                             enabled ? @YES : nil,
                             enabled ? OBJC_ASSOCIATION_RETAIN_NONATOMIC
                                     : OBJC_ASSOCIATION_ASSIGN);
}

static BOOL ccObjectHasBlurCap(id object) {
    return object && [objc_getAssociatedObject(object, kCCFullscreenBlurCapKey) boolValue];
}

static void ccClampBlurFilter(id filter, CGFloat radius) {
    // blur radius keys changed names across ios releases
    if (!filter) return;
    ccSetBlurCapMarker(filter, YES);
    for (NSString *key in @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"]) {
        @try {
            id value = [filter valueForKey:key];
            id clamped = ccClampedBlurRadiusValue(value, radius);
            if (clamped != value) [filter setValue:clamped forKey:key];
        } @catch (__unused NSException *exception) {
        }
    }
}

static void ccSetBlurCapOnFilters(id filters, BOOL enabled, CGFloat radius) {
    if (![filters isKindOfClass:NSArray.class]) return;
    for (id filter in (NSArray *)filters) {
        if (enabled) ccClampBlurFilter(filter, radius);
        else ccSetBlurCapMarker(filter, NO);
    }
}

static void ccAssociateOverlayRootWithFilters(id filters, UIView *overlayRoot) {
    if (![filters isKindOfClass:NSArray.class]) return;
    for (id filter in (NSArray *)filters) {
        objc_setAssociatedObject(filter,
                                 kCCFullscreenOverlayRootKey,
                                 overlayRoot,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

static void ccSetBlurCapOnLayerTree(CALayer *layer, BOOL enabled, CGFloat radius) {
    if (!layer) return;
    ccSetBlurCapMarker(layer, enabled);
    ccSetBlurCapOnFilters(layer.filters, enabled, radius);
    @try {
        ccSetBlurCapOnFilters([layer valueForKey:@"backgroundFilters"], enabled, radius);
    } @catch (__unused NSException *exception) {
    }
    for (CALayer *sublayer in layer.sublayers) {
        ccSetBlurCapOnLayerTree(sublayer, enabled, radius);
    }
}

static void ccClampBlurAnimation(CAAnimation *animation, CGFloat radius) {
    // stock transitions can restore blur after the model value is clamped
    if (!animation) return;

    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation *child in ((CAAnimationGroup *)animation).animations) {
            ccClampBlurAnimation(child, radius);
        }
        return;
    }

    NSString *keyPath = nil;
    @try { keyPath = [animation valueForKey:@"keyPath"]; }
    @catch (__unused NSException *exception) {}
    if (![keyPath isKindOfClass:NSString.class]) return;

    NSString *lower = keyPath.lowercaseString;
    if (![lower containsString:@"radius"] && ![lower containsString:@"blur"]) return;

    if ([animation isKindOfClass:CABasicAnimation.class]) {
        CABasicAnimation *basic = (CABasicAnimation *)animation;
        basic.fromValue = ccClampedBlurRadiusValue(basic.fromValue, radius);
        basic.toValue = ccClampedBlurRadiusValue(basic.toValue, radius);
        basic.byValue = ccClampedBlurRadiusValue(basic.byValue, radius);
    } else if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
        CAKeyframeAnimation *keyframe = (CAKeyframeAnimation *)animation;
        if (!keyframe.values.count) return;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:keyframe.values.count];
        for (id value in keyframe.values) {
            [values addObject:ccClampedBlurRadiusValue(value, radius) ?: value];
        }
        keyframe.values = values;
    }
}

static BOOL ccIsFullscreenBackdropMaterial(UIView *material, UIView *overlayRoot) {
    if (!material || !overlayRoot) return NO;
    if (!isExactClass(material, @"MTMaterialView")) return NO;
    if (material.superview != overlayRoot) return NO;

    CGRect bounds = material.bounds;
    if (CGRectGetWidth(bounds) < 100.0 || CGRectGetHeight(bounds) < 100.0) return NO;

    return CGRectContainsRect(CGRectInset(overlayRoot.bounds, -2.0, -2.0), material.frame);
}

static CGFloat ccBlurRadiusFromFilters(id filters) {
    if (![filters isKindOfClass:NSArray.class]) return -1.0;

    CGFloat found = -1.0;
    for (id filter in (NSArray *)filters) {
        for (NSString *key in @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"]) {
            @try {
                id value = [filter valueForKey:key];
                if ([value respondsToSelector:@selector(doubleValue)]) {
                    found = fmax(found, (CGFloat)[value doubleValue]);
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }
    return found;
}

static CGFloat ccPresentedBlurRadiusInLayerTree(CALayer *layer) {
    if (!layer) return -1.0;

    CALayer *sampleLayer = layer.presentationLayer ?: layer;
    CGFloat found = ccBlurRadiusFromFilters(sampleLayer.filters);
    @try {
        found = fmax(found, ccBlurRadiusFromFilters([sampleLayer valueForKey:@"backgroundFilters"]));
    } @catch (__unused NSException *exception) {
    }

    for (CALayer *sublayer in layer.sublayers) {
        found = fmax(found, ccPresentedBlurRadiusInLayerTree(sublayer));
    }
    return found;
}

static CGFloat ccModelBlurRadiusInLayerTree(CALayer *layer) {
    if (!layer) return -1.0;

    CGFloat found = ccBlurRadiusFromFilters(layer.filters);
    @try {
        found = fmax(found, ccBlurRadiusFromFilters([layer valueForKey:@"backgroundFilters"]));
    } @catch (__unused NSException *exception) {
    }
    for (CALayer *sublayer in layer.sublayers) {
        found = fmax(found, ccModelBlurRadiusInLayerTree(sublayer));
    }
    return found;
}

static UIView *ccFullscreenDimView(UIView *backdropMaterial, BOOL create) {
    if (!backdropMaterial) return nil;

    UIView *dimView = objc_getAssociatedObject(backdropMaterial, kCCFullscreenDimViewKey);
    if (!dimView && create) {
        dimView = [[UIView alloc] initWithFrame:backdropMaterial.bounds];
        dimView.userInteractionEnabled = NO;
        dimView.accessibilityElementsHidden = YES;
        dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dimView.backgroundColor = UIColor.clearColor;
        dimView.alpha = 0.0;
        dimView.opaque = NO;
        objc_setAssociatedObject(backdropMaterial,
                                 kCCFullscreenDimViewKey,
                                 dimView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return dimView;
}

#pragma mark - fullscreen backdrop diagnostics

static void ccApplyFullscreenBackdropStyle(UIView *overlayRoot) {
    if (!overlayRoot) return;
    [ccOverlayRoots() addObject:overlayRoot];

    BOOL enabled = lgHostEnabled(@"ControlCenter");
    CGFloat radius = ccFullscreenBlurRadius();
    UIView *previousBackdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    UIView *backdropMaterial = nil;

    for (UIView *subview in [overlayRoot.subviews copy]) {
        if (!ccIsFullscreenBackdropMaterial(subview, overlayRoot)) continue;
        if (!backdropMaterial) backdropMaterial = subview;
        ccSetBlurCapOnLayerTree(subview.layer, enabled, radius);
    }

    if (!backdropMaterial) {
        if (previousBackdropMaterial) {
            LGLog(@"[CCFSDBG][target] lost fullscreen material root=%@:%p previous=%@:%p",
                  NSStringFromClass(overlayRoot.class), overlayRoot,
                  NSStringFromClass(previousBackdropMaterial.class), previousBackdropMaterial);
        }
        objc_setAssociatedObject(overlayRoot,
                                 kCCFullscreenMaterialKey,
                                 nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    if (previousBackdropMaterial != backdropMaterial) {
        LGLog(@"[CCFSDBG][target] fullscreen material root=%@:%p material=%@:%p frame=%@ bounds=%@",
              NSStringFromClass(overlayRoot.class), overlayRoot,
              NSStringFromClass(backdropMaterial.class), backdropMaterial,
              NSStringFromCGRect(backdropMaterial.frame), NSStringFromCGRect(backdropMaterial.bounds));
    }

    objc_setAssociatedObject(overlayRoot,
                             kCCFullscreenMaterialKey,
                             backdropMaterial,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(backdropMaterial.layer,
                             kCCFullscreenOverlayRootKey,
                             overlayRoot,
                             OBJC_ASSOCIATION_ASSIGN);
    ccAssociateOverlayRootWithFilters(backdropMaterial.layer.filters, overlayRoot);
    @try {
        ccAssociateOverlayRootWithFilters([backdropMaterial.layer valueForKey:@"backgroundFilters"],
                                          overlayRoot);
    } @catch (__unused NSException *exception) {
    }

    CGFloat targetAlpha = ccFullscreenDimTargetAlpha();
    UIView *dimView = ccFullscreenDimView(backdropMaterial,
                                           enabled && targetAlpha > 0.001);
    if (!dimView) return;

    if (!enabled || targetAlpha <= 0.001) {
        dimView.hidden = YES;
        dimView.backgroundColor = UIColor.clearColor;
        return;
    }

    if (dimView.superview != backdropMaterial) {
        [dimView removeFromSuperview];
        [backdropMaterial addSubview:dimView];
    } else {
        [backdropMaterial bringSubviewToFront:dimView];
    }

    dimView.frame = backdropMaterial.bounds;
    dimView.backgroundColor = ccFullscreenDimBaseColor();
    dimView.hidden = NO;
}

static void ccSyncFullscreenDimForRoot(UIView *overlayRoot) {
    if (!overlayRoot) return;

    UIView *backdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    if (!backdropMaterial || backdropMaterial.superview != overlayRoot) {
        ccApplyFullscreenBackdropStyle(overlayRoot);
        backdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    }
    if (!backdropMaterial) return;

    UIView *dimView = ccFullscreenDimView(backdropMaterial, NO);
    if (!dimView) return;

    CGFloat targetAlpha = lgHostEnabled(@"ControlCenter")
        ? ccFullscreenDimTargetAlpha()
        : 0.0;
    if (targetAlpha <= 0.001) {
        dimView.alpha = 0.0;
        dimView.hidden = YES;
        return;
    }

    dimView.hidden = NO;

    CGFloat cap = ccFullscreenBlurRadius();
    CGFloat presentedRadius = ccPresentedBlurRadiusInLayerTree(backdropMaterial.layer);
    CGFloat progress = 1.0;
    if (cap > 0.001 && presentedRadius >= 0.0) {
        progress = fmin(1.0, fmax(0.0, presentedRadius / cap));
    }

    dimView.alpha = targetAlpha * progress;
}

static void ccSetFullscreenDimAlpha(UIView *overlayRoot, CGFloat alpha) {
    if (!overlayRoot) return;
    UIView *backdropMaterial = objc_getAssociatedObject(overlayRoot, kCCFullscreenMaterialKey);
    UIView *dimView = ccFullscreenDimView(backdropMaterial, NO);
    if (!dimView) return;
    dimView.alpha = fmin(1.0, fmax(0.0, alpha));
}

@interface LGCCFullscreenDimSyncDriver : NSObject
@property (nonatomic, weak) UIView *overlayRoot;
@end

static LGCCFullscreenDimSyncDriver *sCCFullscreenDimSyncDriver;
static CADisplayLink *sCCFullscreenDimDisplayLink;

static void ccStopFullscreenDimSync(UIView *overlayRoot);

@implementation LGCCFullscreenDimSyncDriver
- (void)tick:(CADisplayLink *)displayLink {
    (void)displayLink;
    UIView *root = self.overlayRoot;
    if (!root) {
        if (sCCFullscreenDimDisplayLink) sCCFullscreenDimDisplayLink.paused = YES;
        return;
    }

    ccSyncFullscreenDimForRoot(root);

    UIView *material = objc_getAssociatedObject(root, kCCFullscreenMaterialKey);
    CGFloat modelRadius = material ? ccModelBlurRadiusInLayerTree(material.layer) : -1.0;
    CGFloat presentedRadius = material ? ccPresentedBlurRadiusInLayerTree(material.layer) : -1.0;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL settled = (modelRadius >= 0.0 && presentedRadius >= 0.0 &&
                    fabs(modelRadius - presentedRadius) <= 0.025);

    if ((now >= sCCFullscreenDimSyncDeadline && settled) ||
        now >= sCCFullscreenDimSyncHardDeadline) {

        ccSyncFullscreenDimForRoot(root);
        ccStopFullscreenDimSync(root);
    }
}
@end

static void ccStartFullscreenDimSync(UIView *overlayRoot) {
    if (!overlayRoot) return;

    if (!sCCFullscreenDimSyncDriver) {
        sCCFullscreenDimSyncDriver = [LGCCFullscreenDimSyncDriver new];
    }
    sCCFullscreenDimSyncDriver.overlayRoot = overlayRoot;

    if (!sCCFullscreenDimDisplayLink) {
        sCCFullscreenDimDisplayLink = [CADisplayLink displayLinkWithTarget:sCCFullscreenDimSyncDriver
                                                                   selector:@selector(tick:)];
        [sCCFullscreenDimDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                                           forMode:NSRunLoopCommonModes];
    }
    sCCFullscreenDimDisplayLink.paused = NO;
}

static void ccKickFullscreenDimSync(UIView *overlayRoot) {
    if (!overlayRoot) return;
    CFTimeInterval now = CACurrentMediaTime();

    sCCFullscreenDimSyncDeadline = now + 0.18;
    sCCFullscreenDimSyncHardDeadline = now + 1.25;
    ccStartFullscreenDimSync(overlayRoot);
}

static void ccStopFullscreenDimSync(UIView *overlayRoot) {
    (void)overlayRoot;
    if (sCCFullscreenDimDisplayLink) sCCFullscreenDimDisplayLink.paused = YES;
}

static void ccScheduleFullscreenBackdropStyle(UIView *overlayRoot) {
    if (!overlayRoot) return;
    ccApplyFullscreenBackdropStyle(overlayRoot);
    __weak UIView *weakRoot = overlayRoot;
    dispatch_async(dispatch_get_main_queue(), ^{ ccApplyFullscreenBackdropStyle(weakRoot); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ccApplyFullscreenBackdropStyle(weakRoot); });
}

#pragma mark - round-only fills

static void *kCCRoundOriginalRadiusKey = &kCCRoundOriginalRadiusKey;
static void *kCCRoundOriginalCurveKey = &kCCRoundOriginalCurveKey;
static void *kCCRoundOriginalMasksKey = &kCCRoundOriginalMasksKey;
static NSHashTable<UIView *> *sCCRoundedViews;

static NSHashTable<UIView *> *ccRoundedViews(void) {
    if (!sCCRoundedViews) sCCRoundedViews = [NSHashTable weakObjectsHashTable];
    return sCCRoundedViews;
}

static void ccRememberOriginalRoundState(UIView *view) {
    if (!view || objc_getAssociatedObject(view, kCCRoundOriginalRadiusKey)) return;

    [ccRoundedViews() addObject:view];
    objc_setAssociatedObject(view, kCCRoundOriginalRadiusKey,
                             @(view.layer.cornerRadius),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kCCRoundOriginalCurveKey,
                             view.layer.cornerCurve ?: (id)[NSNull null],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kCCRoundOriginalMasksKey,
                             @(view.layer.masksToBounds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ccRestoreRoundState(UIView *view) {
    if (!view) return;

    NSNumber *radius = objc_getAssociatedObject(view, kCCRoundOriginalRadiusKey);
    id curve = objc_getAssociatedObject(view, kCCRoundOriginalCurveKey);
    NSNumber *masks = objc_getAssociatedObject(view, kCCRoundOriginalMasksKey);
    if (!radius || !curve || !masks) return;

    view.layer.cornerRadius = radius.doubleValue;
    view.layer.cornerCurve = curve == [NSNull null] ? nil : curve;
    view.layer.masksToBounds = masks.boolValue;

    objc_setAssociatedObject(view, kCCRoundOriginalRadiusKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kCCRoundOriginalCurveKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kCCRoundOriginalMasksKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [sCCRoundedViews removeObject:view];
}

static void ccRestoreAllRoundedViews(void) {
    for (UIView *view in ccRoundedViews().allObjects)
        ccRestoreRoundState(view);
}

static void lgRound(UIView *v, CGFloat r) {
    if (!v) return;
    if (!lgHostEnabled(@"ControlCenter")) {
        ccRestoreRoundState(v);
        return;
    }
    if (CGRectGetWidth(v.bounds) < 2.0 || CGRectGetHeight(v.bounds) < 2.0) {
        ccRestoreRoundState(v);
        return;
    }

    ccRememberOriginalRoundState(v);
    if (fabs(v.layer.cornerRadius - r) > 0.5) v.layer.cornerRadius = r;
    v.layer.cornerCurve   = kCACornerCurveContinuous;
    v.layer.masksToBounds = YES;
}

static void ccApplyOrRestoreRound(UIView *view, CGFloat radius, BOOL eligible) {
    if (!eligible || !lgHostEnabled(@"ControlCenter")) {
        ccRestoreRoundState(view);
        return;
    }
    lgRound(view, radius);
}

static void roundContinuousSliderFill(UIView *slider) {
    BOOL eligible = YES;
    CGFloat customRadius = LG_prefFloat(@"ControlCenter.SliderCornerRadius", -1.0);
    for (UIView *child in slider.subviews) {
        if (!isExactClass(child, @"UIView")) continue;
        for (UIView *gc in child.subviews) {
            if (isExactClass(gc, @"MTMaterialView")) {
                CGFloat r = (customRadius >= 0.0) ? customRadius : ccPillRadius(gc);
                ccApplyOrRestoreRound(gc, r, eligible);
            }
        }
    }
}

static void roundMRUSliderFill(UIView *slider) {
    BOOL eligible = YES;
    CGFloat customRadius = LG_prefFloat(@"ControlCenter.SliderCornerRadius", -1.0);
    for (UIView *child in slider.subviews) {
        if (!isExactClass(child, @"UIView")) continue;
        for (UIView *gc in child.subviews) {
            if (isExactClass(gc, @"MTMaterialView")) {
                CGFloat r = (customRadius >= 0.0) ? customRadius : ccPillRadius(gc);
                ccApplyOrRestoreRound(gc, r, eligible);
            }
        }
    }
}

#pragma mark - Slider Percentage Display

static const void *kCCSliderPercentLabelKey = &kCCSliderPercentLabelKey;

static BOOL ccSliderPercentEnabled(void) {
    return LG_prefBool(@"ControlCenter.SliderPercent.Enabled", YES);
}

// Forward declaration - defined in the Slider Haptic Feedback section below
static CGFloat ccSliderGetNormalizedValue(UIView *slider);

static UILabel *ccSliderGetOrCreatePercentLabel(UIView *slider) {
    UILabel *label = objc_getAssociatedObject(slider, kCCSliderPercentLabelKey);
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.backgroundColor = [UIColor clearColor];
        // Subtle shadow for readability on any background
        label.layer.shadowColor = [UIColor blackColor].CGColor;
        label.layer.shadowOffset = CGSizeMake(0, 1);
        label.layer.shadowRadius = 2.0;
        label.layer.shadowOpacity = 0.6;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.hidden = YES;
        [slider addSubview:label];
        objc_setAssociatedObject(slider, kCCSliderPercentLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return label;
}

static void ccSliderUpdatePercentLabel(UIView *slider) {
    if (!ccSliderPercentEnabled()) {
        UILabel *label = objc_getAssociatedObject(slider, kCCSliderPercentLabelKey);
        if (label) label.hidden = YES;
        return;
    }
    CGFloat value = ccSliderGetNormalizedValue(slider);
    NSInteger percent = (NSInteger)round(value * 100.0);
    UILabel *label = ccSliderGetOrCreatePercentLabel(slider);
    label.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    label.hidden = NO;

    // Size to fit text
    [label sizeToFit];
    CGFloat labelWidth = CGRectGetWidth(label.bounds) + 4;
    CGFloat labelHeight = CGRectGetHeight(label.bounds) + 2;
    CGFloat sliderWidth = CGRectGetWidth(slider.bounds);
    CGFloat sliderHeight = CGRectGetHeight(slider.bounds);

    // Always center the label both horizontally and vertically
    CGFloat labelX = (sliderWidth - labelWidth) / 2.0;
    CGFloat labelY = (sliderHeight - labelHeight) / 2.0;
    label.frame = CGRectMake(labelX, labelY, labelWidth, labelHeight);
}

#pragma mark - Slider Haptic Feedback

static const void *kCCSliderHapticLastValueKey = &kCCSliderHapticLastValueKey;
static const void *kCCSliderHapticAtMinKey = &kCCSliderHapticAtMinKey;
static const void *kCCSliderHapticAtMaxKey = &kCCSliderHapticAtMaxKey;
static const void *kCCSliderHapticLastHapticTimeKey = &kCCSliderHapticLastHapticTimeKey;
static const void *kCCSliderHapticFeedbackKey = &kCCSliderHapticFeedbackKey;

static BOOL ccSliderHapticsEnabled(void) {
    return LG_prefBool(@"ControlCenter.SliderHaptics.Enabled", YES);
}

static CGFloat ccSliderHapticIntensity(void) {
    return LG_prefFloat(@"ControlCenter.SliderHaptics.Intensity", 0.5);
}

static BOOL ccSliderEdgeFeedbackEnabled(void) {
    return LG_prefBool(@"ControlCenter.SliderHaptics.EdgeFeedback", YES);
}

static UIImpactFeedbackGenerator *ccSliderHapticGenerator(UIView *slider) {
    UIImpactFeedbackGenerator *gen = objc_getAssociatedObject(slider, kCCSliderHapticFeedbackKey);
    if (!gen) {
        gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        objc_setAssociatedObject(slider, kCCSliderHapticFeedbackKey, gen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gen prepare];
    return gen;
}

// 动态属性缓存: 避免每次调用都枚举所有属性
static NSMutableDictionary<NSString *, NSString *> *sSliderValuePropertyCache = nil;

static NSString *ccSliderFindValueProperty(Class cls) {
    if (!sSliderValuePropertyCache) {
        sSliderValuePropertyCache = [NSMutableDictionary dictionary];
    }
    NSString *className = NSStringFromClass(cls);
    NSString *cached = sSliderValuePropertyCache[className];
    if (cached) return cached.length > 0 ? cached : nil;
    
    // 动态枚举所有属性，找到返回 0-1 范围 float 的属性
    unsigned int outCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &outCount);
    NSString *foundKey = nil;
    
    // 优先尝试常见的值属性名
    NSArray *commonKeys = @[@"value", @"_value", @"normalizedValue", @"_normalizedValue",
                            @"sliderValue", @"_sliderValue", @"continuousValue",
                            @"_continuousValue", @"rawValue", @"_rawValue",
                            @"representedValue", @"_representedValue"];
    
    for (NSString *key in commonKeys) {
        BOOL found = NO;
        for (unsigned int i = 0; i < outCount; i++) {
            const char *propName = property_getName(props[i]);
            if (strcmp(propName, key.UTF8String) == 0) {
                found = YES;
                break;
            }
        }
        if (found) {
            // 验证该属性确实返回有效值
            @try {
                id val = [[cls alloc] performSelector:NSSelectorFromString(key)];
                if ([val isKindOfClass:[NSNumber class]]) {
                    CGFloat v = [val floatValue];
                    if (v >= 0.0 && v <= 1.0) {
                        foundKey = key;
                        break;
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    
    // 如果常见属性没找到，枚举所有属性
    if (!foundKey) {
        for (unsigned int i = 0; i < outCount; i++) {
            const char *propName = property_getName(props[i]);
            NSString *key = [NSString stringWithUTF8String:propName];
            @try {
                id val = [[cls alloc] performSelector:NSSelectorFromString(key)];
                if ([val isKindOfClass:[NSNumber class]]) {
                    CGFloat v = [val floatValue];
                    if (v >= 0.0 && v <= 1.0) {
                        foundKey = key;
                        break;
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    
    free(props);
    sSliderValuePropertyCache[className] = foundKey ?: @"";
    return foundKey;
}

static CGFloat ccSliderGetNormalizedValue(UIView *slider) {
    if (!slider) return 0.5;

    // Method 1: 动态属性枚举 + 缓存
    NSString *valueKey = ccSliderFindValueProperty([slider class]);
    if (valueKey) {
        @try {
            id val = [slider valueForKey:valueKey];
            if ([val isKindOfClass:[NSNumber class]]) {
                CGFloat v = [val floatValue];
                if (v >= 0.0 && v <= 1.0) return v;
                if (v > 1.0 && v <= 100.0) return v / 100.0;
            }
        } @catch (__unused NSException *e) {}
    }

    // Method 2: Find MTMaterialView fill view (the actual visible fill)
    CGFloat sliderW = CGRectGetWidth(slider.bounds);
    CGFloat sliderH = CGRectGetHeight(slider.bounds);
    if (sliderW <= 0 || sliderH <= 0) return 0.5;
    BOOL isVertical = sliderH >= sliderW;

    // Look for MTMaterialView in the slider's subview hierarchy
    // Structure: CCUIContinuousSliderView > UIView > MTMaterialView (fill)
    for (UIView *child in slider.subviews) {
        // Direct MTMaterialView
        if (isExactClass(child, @"MTMaterialView")) {
            CGRect frameInSlider = [child.superview convertRect:child.frame toView:slider];
            CGFloat fw = CGRectGetWidth(frameInSlider);
            CGFloat fh = CGRectGetHeight(frameInSlider);
            if (isVertical && fh > 0 && fh <= sliderH) {
                return MIN(1.0, MAX(0.0, fh / sliderH));
            }
            if (!isVertical && fw > 0 && fw <= sliderW) {
                return MIN(1.0, MAX(0.0, fw / sliderW));
            }
        }
        // Nested: UIView > MTMaterialView
        for (UIView *gc in child.subviews) {
            if (isExactClass(gc, @"MTMaterialView")) {
                CGRect gcFrame = [gc.superview convertRect:gc.frame toView:slider];
                CGFloat gfw = CGRectGetWidth(gcFrame);
                CGFloat gfh = CGRectGetHeight(gcFrame);
                if (isVertical && gfh > 0) {
                    return MIN(1.0, MAX(0.0, gfh / sliderH));
                }
                if (!isVertical && gfw > 0) {
                    return MIN(1.0, MAX(0.0, gfw / sliderW));
                }
            }
            // Check one more level deep
            for (UIView *ggc in gc.subviews) {
                if (isExactClass(ggc, @"MTMaterialView")) {
                    CGRect ggcFrame = [ggc.superview convertRect:ggc.frame toView:slider];
                    CGFloat ggfw = CGRectGetWidth(ggcFrame);
                    CGFloat ggfh = CGRectGetHeight(ggcFrame);
                    if (isVertical && ggfh > 0) {
                        return MIN(1.0, MAX(0.0, ggfh / sliderH));
                    }
                    if (!isVertical && ggfw > 0) {
                        return MIN(1.0, MAX(0.0, ggfw / sliderW));
                    }
                }
            }
        }
    }

    // Method 3: Fallback - find any subview with fractional dimension
    for (UIView *subview in slider.subviews) {
        CGRect frameInSlider = [subview.superview convertRect:subview.frame toView:slider];
        CGFloat fw = CGRectGetWidth(frameInSlider);
        CGFloat fh = CGRectGetHeight(frameInSlider);
        if (isVertical && fh > 0 && fh <= sliderH * 0.99) {
            return MIN(1.0, MAX(0.0, fh / sliderH));
        }
        if (!isVertical && fw > 0 && fw <= sliderW * 0.99) {
            return MIN(1.0, MAX(0.0, fw / sliderW));
        }
        for (UIView *gc in subview.subviews) {
            CGRect gcFrame = [gc.superview convertRect:gc.frame toView:slider];
            CGFloat gfw = CGRectGetWidth(gcFrame);
            CGFloat gfh = CGRectGetHeight(gcFrame);
            if (isVertical && gfh > 0 && gfh <= sliderH * 0.99) {
                return MIN(1.0, MAX(0.0, gfh / sliderH));
            }
            if (!isVertical && gfw > 0 && gfw <= sliderW * 0.99) {
                return MIN(1.0, MAX(0.0, gfw / sliderW));
            }
        }
    }
    return 0.5;
}

static void ccSliderTriggerHaptic(UIView *slider, BOOL isEdge) {
    if (!ccSliderHapticsEnabled()) return;

    CGFloat intensity = ccSliderHapticIntensity();

    if (isEdge && ccSliderEdgeFeedbackEnabled()) {
        // Edge feedback: strong haptic + system sound
        UIImpactFeedbackGenerator *gen = ccSliderHapticGenerator(slider);
        [gen impactOccurredWithIntensity:MIN(1.0, intensity * 2.0)];
        // Fallback: also play system sound
        AudioServicesPlaySystemSound(1519); // strong tick
    } else if (!isEdge) {
        // Throttle continuous haptics (reduced from 0.08 to 0.04 for better responsiveness)
        NSNumber *lastTimeNum = objc_getAssociatedObject(slider, kCCSliderHapticLastHapticTimeKey);
        NSTimeInterval lastTime = lastTimeNum ? lastTimeNum.doubleValue : 0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastTime < 0.04) return; // ~25Hz max
        objc_setAssociatedObject(slider, kCCSliderHapticLastHapticTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Use full intensity instead of 0.6x for noticeable feedback
        UIImpactFeedbackGenerator *gen = ccSliderHapticGenerator(slider);
        [gen impactOccurredWithIntensity:MAX(0.2, intensity)];
        // Fallback: also play system sound for guaranteed feedback
        AudioServicesPlaySystemSound(1520); // weak tick
    }
}

static void ccSliderUpdateHapticState(UIView *slider) {
    if (!ccSliderHapticsEnabled()) return;

    CGFloat currentValue = ccSliderGetNormalizedValue(slider);
    NSNumber *lastValueNum = objc_getAssociatedObject(slider, kCCSliderHapticLastValueKey);
    CGFloat lastValue = lastValueNum ? lastValueNum.doubleValue : currentValue;

    if (fabs(currentValue - lastValue) < 0.001) return;

    BOOL wasAtMin = [objc_getAssociatedObject(slider, kCCSliderHapticAtMinKey) boolValue];
    BOOL wasAtMax = [objc_getAssociatedObject(slider, kCCSliderHapticAtMaxKey) boolValue];

    BOOL isAtMin = currentValue <= 0.01;
    BOOL isAtMax = currentValue >= 0.99;

    // Edge feedback
    if (isAtMin && !wasAtMin) {
        ccSliderTriggerHaptic(slider, YES);
    } else if (isAtMax && !wasAtMax) {
        ccSliderTriggerHaptic(slider, YES);
    } else if (!isAtMin && !isAtMax) {
        // Continuous haptic based on step size (lowered threshold from 0.02 to 0.008)
        CGFloat step = fabs(currentValue - lastValue);
        if (step > 0.008) {
            ccSliderTriggerHaptic(slider, NO);
        }
    }

    objc_setAssociatedObject(slider, kCCSliderHapticLastValueKey, @(currentValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, kCCSliderHapticAtMinKey, @(isAtMin), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, kCCSliderHapticAtMaxKey, @(isAtMax), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void roundToggleFills(UIView *buttonModule) {
    UIView *module = ccModuleAncestor(buttonModule);
    BOOL eligible = module && ccIsModuleCandidate(module);
    CGFloat r = eligible ? ccModuleCornerRadius(module) : 0.0;
    for (UIView *child in buttonModule.subviews)
        if (isExactClass(child, @"UIView")) ccApplyOrRestoreRound(child, r, eligible);
}

static void roundModuleContainer(UIView *module) {
    if (!isExactClass(module, @"CCUIContentModuleContainerView")) return;
    BOOL eligible = ccIsModuleCandidate(module);
    CGFloat r = eligible ? ccModuleCornerRadius(module) : 0.0;
    ccApplyOrRestoreRound(module, r, eligible);
    for (UIView *sub in module.subviews)
        if (isExactClass(sub, @"CCUIContentModuleContentContainer") ||
            isExactClass(sub, @"CCUIContentModuleContentContainerView"))
            ccApplyOrRestoreRound(sub, r, eligible);
}

#pragma mark - hooks

%hook CCUIContentModuleContainerView
- (void)layoutSubviews {
    %orig;
    // 优化5: layoutSubviews 节流到 30fps
    static CFTimeInterval sLastLayoutTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastLayoutTime < 0.033) return;
    sLastLayoutTime = now;
    roundModuleContainer((UIView *)self);
}
- (void)didMoveToWindow { %orig; roundModuleContainer((UIView *)self); }
%end

%hook CCUIButtonModuleView
- (void)layoutSubviews {
    %orig;
    // 优化5: layoutSubviews 节流到 30fps
    static CFTimeInterval sLastLayoutTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastLayoutTime < 0.033) return;
    sLastLayoutTime = now;
    roundToggleFills((UIView *)self);
}
- (void)didMoveToWindow { %orig; roundToggleFills((UIView *)self); }
%end

// Display link for real-time slider value polling (catches changes not triggered by layout)
static const void *kCCSliderDisplayLinkKey = &kCCSliderDisplayLinkKey;

@interface ControlCenterDisplayLinkTarget : NSObject
+ (void)tick:(CADisplayLink *)link;
@end

@implementation ControlCenterDisplayLinkTarget
+ (void)tick:(CADisplayLink *)link {
    UIView *slider = objc_getAssociatedObject(link, kCCSliderDisplayLinkKey);
    if (!slider || !slider.window) {
        [link invalidate];
        return;
    }
    ccSliderUpdateHapticState(slider);
    ccSliderUpdatePercentLabel(slider);
}
@end

static void ccSliderUpdateAll(UIView *slider) {
    ccSliderUpdateHapticState(slider);
    ccSliderUpdatePercentLabel(slider);
}

static void ccSliderStartDisplayLink(UIView *slider) {
    CADisplayLink *existing = objc_getAssociatedObject(slider, kCCSliderDisplayLinkKey);
    if (existing && !existing.isPaused) return;
    [existing invalidate];

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:[ControlCenterDisplayLinkTarget class]
                                                      selector:@selector(tick:)];
    objc_setAssociatedObject(link, kCCSliderDisplayLinkKey, slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, kCCSliderDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    link.preferredFramesPerSecond = 30; // 30fps polling to save battery
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void ccSliderStopDisplayLink(UIView *slider) {
    CADisplayLink *link = objc_getAssociatedObject(slider, kCCSliderDisplayLinkKey);
    if (link) {
        [link invalidate];
        objc_setAssociatedObject(slider, kCCSliderDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook CCUIContinuousSliderView
- (void)layoutSubviews {
    %orig;
    // 优化5: layoutSubviews 节流到 30fps
    static CFTimeInterval sLastLayoutTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastLayoutTime < 0.033) return;
    sLastLayoutTime = now;
    roundContinuousSliderFill((UIView *)self);
    ccSliderUpdateAll((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    roundContinuousSliderFill((UIView *)self);
    ccSliderUpdatePercentLabel((UIView *)self);
    if (![(UIView *)self window]) {
        ccSliderStopDisplayLink((UIView *)self);
    }
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderStartDisplayLink((UIView *)self);
    ccSliderUpdateAll((UIView *)self);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderUpdateAll((UIView *)self);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderUpdateAll((UIView *)self);
    // Keep the display link running briefly for any final animation, then stop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ccSliderStopDisplayLink((UIView *)self);
    });
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderUpdateAll((UIView *)self);
    ccSliderStopDisplayLink((UIView *)self);
}
- (void)dealloc {
    ccSliderStopDisplayLink((UIView *)self);
    %orig;
}
%end

%hook MRUContinuousSliderView
- (void)layoutSubviews {
    %orig;
    // 优化5: layoutSubviews 节流到 30fps
    static CFTimeInterval sLastLayoutTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastLayoutTime < 0.033) return;
    sLastLayoutTime = now;
    roundMRUSliderFill((UIView *)self);
    ccSliderUpdateAll((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    roundMRUSliderFill((UIView *)self);
    ccSliderUpdatePercentLabel((UIView *)self);
    if ([(UIView *)self window]) {
        ccSliderStartDisplayLink((UIView *)self);
    } else {
        ccSliderStopDisplayLink((UIView *)self);
    }
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderStartDisplayLink((UIView *)self);
    ccSliderUpdateAll((UIView *)self);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderUpdateAll((UIView *)self);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderUpdateAll((UIView *)self);
    // For volume HUD: keep the display link running as long as the HUD is visible
    // (volume buttons can still change the value after touch ends)
    if (![(UIView *)self window]) {
        ccSliderStopDisplayLink((UIView *)self);
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    ccSliderUpdateAll((UIView *)self);
    // Only stop if the HUD is no longer visible
    if (![(UIView *)self window]) {
        ccSliderStopDisplayLink((UIView *)self);
    }
}
- (void)dealloc {
    ccSliderStopDisplayLink((UIView *)self);
    %orig;
}
%end

%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccScheduleFullscreenBackdropStyle(root);

    ccSetFullscreenDimAlpha(root, 0.0);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccApplyFullscreenBackdropStyle(root);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccApplyFullscreenBackdropStyle(root);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;

}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    ccApplyFullscreenBackdropStyle(root);
}

%end

%hook CAFilter

- (void)setValue:(id)value forKey:(NSString *)key {
    UIView *overlayRoot = nil;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && ccIsBlurRadiusKey(key)) {
        overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
        value = ccClampedBlurRadiusValue(value, ccFullscreenBlurRadius());
    }
    %orig(value, key);
    if (overlayRoot) ccKickFullscreenDimSync(overlayRoot);
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    UIView *overlayRoot = nil;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && [keyPath isKindOfClass:NSString.class]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (ccIsBlurRadiusKey(lastKey)) {
            overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
            value = ccClampedBlurRadiusValue(value, ccFullscreenBlurRadius());
        }
    }
    %orig(value, keyPath);
    if (overlayRoot) ccKickFullscreenDimSync(overlayRoot);
}

%end

%hook CALayer

- (void)setFilters:(NSArray *)filters {
    UIView *overlayRoot = nil;
    CGFloat incomingBlurRadius = -1.0;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter")) {
        overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
        incomingBlurRadius = ccBlurRadiusFromFilters(filters);
        ccAssociateOverlayRootWithFilters(filters, overlayRoot);
        ccSetBlurCapOnFilters(filters, YES, ccFullscreenBlurRadius());
    }
    %orig(filters);

    if (overlayRoot && incomingBlurRadius >= 0.0) {
        ccKickFullscreenDimSync(overlayRoot);
    }
}

- (void)setValue:(id)value forKey:(NSString *)key {
    UIView *overlayRoot = nil;
    CGFloat incomingBlurRadius = -1.0;
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && [key isEqualToString:@"backgroundFilters"]) {
        overlayRoot = objc_getAssociatedObject(self, kCCFullscreenOverlayRootKey);
        incomingBlurRadius = ccBlurRadiusFromFilters(value);
        ccAssociateOverlayRootWithFilters(value, overlayRoot);
        ccSetBlurCapOnFilters(value, YES, ccFullscreenBlurRadius());
    }
    %orig(value, key);
    if (overlayRoot && incomingBlurRadius >= 0.0) {
        ccKickFullscreenDimSync(overlayRoot);
    }
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter") && [keyPath isKindOfClass:NSString.class]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (ccIsBlurRadiusKey(lastKey)) {
            value = ccClampedBlurRadiusValue(value, ccFullscreenBlurRadius());
        }
    }
    %orig(value, keyPath);
}

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    if (ccObjectHasBlurCap(self) && lgHostEnabled(@"ControlCenter")) {
        ccClampBlurAnimation(animation, ccFullscreenBlurRadius());
    }
    %orig(animation, key);
}

%end

%ctor {
    lgObservePreferenceReload(^{
        if (!lgHostEnabled(@"ControlCenter")) ccRestoreAllRoundedViews();
        for (UIView *root in ccOverlayRoots().allObjects) {
            ccApplyFullscreenBackdropStyle(root);
            ccKickFullscreenDimSync(root);
        }
    });

    LGRegisterMaterialHost(@"ControlCenter", 110, ^BOOL(UIView *material) {
        return ccGlassRadiusForMaterial(material) >= 0.0;
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {
        return ccGlassRadiusForMaterial(material);
    }, nil, nil);
}
