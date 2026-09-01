#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>
#import <string.h>
#import "../LiquidAssPrefs/LGPrefsLiquidSlider.h"
#import "../LiquidAssPrefs/LGPrefsLiquidSwitch.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGLiquidMotion.h"

static void *kLGSettingsSwitchOverlayKey = &kLGSettingsSwitchOverlayKey;
static void *kLGSettingsSliderOverlayKey = &kLGSettingsSliderOverlayKey;
static void *kLGSettingsSliderVisualHostKey = &kLGSettingsSliderVisualHostKey;
static void *kLGSettingsSegmentGlassKey = &kLGSettingsSegmentGlassKey;
static void *kLGSettingsSegmentTouchXKey = &kLGSettingsSegmentTouchXKey;
static void *kLGSettingsSegmentActiveKey = &kLGSettingsSegmentActiveKey;
static void *kLGSettingsSegmentReleasedKey = &kLGSettingsSegmentReleasedKey;
static void *kLGSettingsSegmentVelocityKey = &kLGSettingsSegmentVelocityKey;
static void *kLGSettingsSegmentLastXKey = &kLGSettingsSegmentLastXKey;
static void *kLGSettingsSegmentLastTimeKey = &kLGSettingsSegmentLastTimeKey;
static void *kLGSettingsSegmentRenderedKey = &kLGSettingsSegmentRenderedKey;
static void *kLGSettingsSegmentDisplayLinkKey = &kLGSettingsSegmentDisplayLinkKey;
static void *kLGSettingsSegmentOriginalTintKey = &kLGSettingsSegmentOriginalTintKey;
static void *kLGSettingsSegmentFrameDeltaKey = &kLGSettingsSegmentFrameDeltaKey;
static void *kLGSettingsSegmentLastDisplayTimeKey = &kLGSettingsSegmentLastDisplayTimeKey;
static void *kLGSettingsSegmentFadingKey = &kLGSettingsSegmentFadingKey;
static void *kLGSettingsTopFadeKey = &kLGSettingsTopFadeKey;
static void *kLGSettingsBackButtonKey = &kLGSettingsBackButtonKey;
static void *kLGLiquidAssEntryFooterKey = &kLGLiquidAssEntryFooterKey;
static void *kLGSettingsBarBackgroundStateKey =
    &kLGSettingsBarBackgroundStateKey;
static void *kLGSettingsStockBackStateKey = &kLGSettingsStockBackStateKey;
static BOOL gLGSettingsControlsEnabled = NO;
static BOOL gLGSwitchControlsEnabled = NO;
static BOOL gLGSliderControlsEnabled = NO;
static BOOL gLGSegmentControlsEnabled = NO;
static BOOL gLGControlsDiagnosticsEnabled = NO;

static id LGPreferenceSpecifierProperty(id specifier, NSString *key) {
    SEL selector = NSSelectorFromString(@"propertyForKey:");
    if (!specifier || ![specifier respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(specifier, selector, key);
}

static BOOL LGIsLiquidAssPreferenceLoaderCell(UITableViewCell *cell) {
    id specifier = nil;
    if ([cell respondsToSelector:NSSelectorFromString(@"specifier")]) {
        specifier = ((id (*)(id, SEL))objc_msgSend)(cell,
                                                    NSSelectorFromString(@"specifier"));
    }
    for (NSString *key in @[@"lazy-bundle", @"bundle", @"bundlePath"]) {
        id value = LGPreferenceSpecifierProperty(specifier, key);
        if ([[value description] containsString:@"LiquidAssPrefs"]) return YES;
    }

    NSString *title = cell.textLabel.text ?: LGPreferenceSpecifierProperty(specifier, @"label");
    id detail = LGPreferenceSpecifierProperty(specifier, @"detail");
    return [title isEqualToString:@"Ai液态玻璃"] &&
           [[detail description] containsString:@"LGPRootListController"];
}

static void LGUpdateLiquidAssEntryFooter(UITableViewCell *cell) {
    UILabel *footer = objc_getAssociatedObject(cell, kLGLiquidAssEntryFooterKey);
    if (!gLGSettingsControlsEnabled) {
        footer.hidden = YES;
        return;
    }
    if (!LGIsLiquidAssPreferenceLoaderCell(cell)) {
        footer.hidden = YES;
        return;
    }
    if (!footer) {
        footer = [[UILabel alloc] initWithFrame:CGRectZero];
        footer.text = @"Ai";
        footer.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
        footer.textColor = UIColor.tertiaryLabelColor;
        footer.textAlignment = NSTextAlignmentRight;
        footer.userInteractionEnabled = NO;
        footer.accessibilityElementsHidden = YES;
        [cell.contentView addSubview:footer];
        objc_setAssociatedObject(cell, kLGLiquidAssEntryFooterKey, footer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    footer.hidden = NO;
    [cell.contentView bringSubviewToFront:footer];
    CGFloat width = MIN(120.0, CGRectGetWidth(cell.contentView.bounds) * 0.42);
    footer.frame = CGRectMake(CGRectGetWidth(cell.contentView.bounds) - width - 8.0,
                              CGRectGetHeight(cell.contentView.bounds) - 14.0,
                              width, 12.0);
}

typedef NS_ENUM(NSUInteger, LGControlsDiagnosticKind) {
    LGControlsDiagnosticSwitch,
    LGControlsDiagnosticSlider,
    LGControlsDiagnosticSegment,
    LGControlsDiagnosticKindCount,
};

typedef struct {
    NSUInteger calls;
    NSUInteger created;
    double totalMilliseconds;
    double maximumMilliseconds;
} LGControlsDiagnosticBucket;

static LGControlsDiagnosticBucket gLGControlsDiagnosticBuckets[LGControlsDiagnosticKindCount];
static CFTimeInterval gLGControlsDiagnosticWindowStart = 0.0;
static NSUInteger gLGControlsSliderTrackingCalls = 0;
static NSUInteger gLGControlsSliderOwnerMoves = 0;
static NSUInteger gLGControlsSliderOwnerLayouts = 0;
static NSUInteger gLGControlsSliderOverlayMoves = 0;
static NSUInteger gLGControlsSliderOverlayLayouts = 0;
static NSUInteger gLGControlsSliderVisualMoves = 0;
static NSUInteger gLGControlsSliderVisualLayouts = 0;
static NSUInteger gLGControlsSliderSetters = 0;
static NSUInteger gLGControlsSwitchMoves = 0;
static NSUInteger gLGControlsSwitchLayouts = 0;
static NSUInteger gLGControlsModernSwitchMoves = 0;
static NSUInteger gLGControlsModernSwitchLayouts = 0;
static NSUInteger gLGControlsModernSwitchAlphaSets = 0;

static void LGRecordControlsDiagnostic(LGControlsDiagnosticKind kind,
                                       CFTimeInterval started,
                                       BOOL created) {
    if (!gLGControlsDiagnosticsEnabled) return;
    double milliseconds = (CACurrentMediaTime() - started) * 1000.0;
    LGControlsDiagnosticBucket *bucket = &gLGControlsDiagnosticBuckets[kind];
    bucket->calls++;
    bucket->created += created ? 1 : 0;
    bucket->totalMilliseconds += milliseconds;
    bucket->maximumMilliseconds = MAX(bucket->maximumMilliseconds, milliseconds);
    CFTimeInterval now = CACurrentMediaTime();
    if (gLGControlsDiagnosticWindowStart == 0.0) gLGControlsDiagnosticWindowStart = now;
    if (now - gLGControlsDiagnosticWindowStart < 1.0) return;
    LGControlsDiagnosticBucket *sw = &gLGControlsDiagnosticBuckets[LGControlsDiagnosticSwitch];
    LGControlsDiagnosticBucket *sl = &gLGControlsDiagnosticBuckets[LGControlsDiagnosticSlider];
    LGControlsDiagnosticBucket *sg = &gLGControlsDiagnosticBuckets[LGControlsDiagnosticSegment];
    LGLog(@"[GlobalControlsPerf] switch calls=%lu created=%lu total=%.2fms max=%.2fms; slider calls=%lu created=%lu total=%.2fms max=%.2fms tracking=%lu; segment calls=%lu created=%lu total=%.2fms max=%.2fms",
               (unsigned long)sw->calls, (unsigned long)sw->created,
               sw->totalMilliseconds, sw->maximumMilliseconds,
               (unsigned long)sl->calls, (unsigned long)sl->created,
               sl->totalMilliseconds, sl->maximumMilliseconds,
               (unsigned long)gLGControlsSliderTrackingCalls,
               (unsigned long)sg->calls, (unsigned long)sg->created,
               sg->totalMilliseconds, sg->maximumMilliseconds);
    LGLog(@"[GlobalControlsSources] switch move=%lu layout=%lu modernMove=%lu modernLayout=%lu modernAlpha=%lu; slider ownerMove=%lu ownerLayout=%lu overlayMove=%lu overlayLayout=%lu visualMove=%lu visualLayout=%lu setters=%lu",
               (unsigned long)gLGControlsSwitchMoves,
               (unsigned long)gLGControlsSwitchLayouts,
               (unsigned long)gLGControlsModernSwitchMoves,
               (unsigned long)gLGControlsModernSwitchLayouts,
               (unsigned long)gLGControlsModernSwitchAlphaSets,
               (unsigned long)gLGControlsSliderOwnerMoves,
               (unsigned long)gLGControlsSliderOwnerLayouts,
               (unsigned long)gLGControlsSliderOverlayMoves,
               (unsigned long)gLGControlsSliderOverlayLayouts,
               (unsigned long)gLGControlsSliderVisualMoves,
               (unsigned long)gLGControlsSliderVisualLayouts,
               (unsigned long)gLGControlsSliderSetters);
    memset(gLGControlsDiagnosticBuckets, 0, sizeof(gLGControlsDiagnosticBuckets));
    gLGControlsSliderTrackingCalls = 0;
    gLGControlsSliderOwnerMoves = gLGControlsSliderOwnerLayouts = 0;
    gLGControlsSliderOverlayMoves = gLGControlsSliderOverlayLayouts = 0;
    gLGControlsSliderVisualMoves = gLGControlsSliderVisualLayouts = 0;
    gLGControlsSliderSetters = 0;
    gLGControlsSwitchMoves = gLGControlsSwitchLayouts = 0;
    gLGControlsModernSwitchMoves = gLGControlsModernSwitchLayouts = 0;
    gLGControlsModernSwitchAlphaSets = 0;
    gLGControlsDiagnosticWindowStart = now;
}

@interface LGSettingsLowBlurView : UIView
@end

@implementation LGSettingsLowBlurView
+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: CALayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    [self lg_configure];
    return self;
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self lg_configure]; }
- (void)layoutSubviews { [super layoutSubviews]; [self lg_configure]; }
- (void)lg_configure {
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    if (!backdrop || ![self.layer isKindOfClass:backdrop]) return;
    @try {
        [self.layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [self.layer setValue:@YES forKey:@"windowServerAware"];
        if (![self.layer valueForKey:@"groupName"])
            [self.layer setValue:NSUUID.UUID.UUIDString forKey:@"groupName"];
        Class filterClass = NSClassFromString(@"CAFilter");
        SEL selector = NSSelectorFromString(@"filterWithName:");
        id filter = filterClass && [filterClass respondsToSelector:selector]
            ? ((id (*)(Class, SEL, NSString *))objc_msgSend)
                (filterClass, selector, @"gaussianBlur") : nil;
        if (filter) {
            [filter setValue:@3.0 forKey:@"inputRadius"];
            [filter setValue:@YES forKey:@"inputNormalizeEdges"];
            self.layer.filters = @[ filter ];
        }
    } @catch (__unused NSException *exception) {}
}
@end

@interface LGSettingsTopFadeView : UIView
@end

@implementation LGSettingsTopFadeView {
    LGSettingsLowBlurView *_blur;
    CAGradientLayer *_mask;
    CAGradientLayer *_tint;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _blur = [[LGSettingsLowBlurView alloc] initWithFrame:self.bounds];
    _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;
    [self addSubview:_blur];
    _mask = [CAGradientLayer layer];
    _mask.startPoint = CGPointMake(0.5, 0.0);
    _mask.endPoint = CGPointMake(0.5, 1.0);
    _mask.colors = @[
        (__bridge id)UIColor.blackColor.CGColor,
        (__bridge id)[UIColor.blackColor colorWithAlphaComponent:0.82].CGColor,
        (__bridge id)UIColor.clearColor.CGColor
    ];
    _mask.locations = @[ @0.0, @0.55, @1.0 ];
    _blur.layer.mask = _mask;
    _tint = [CAGradientLayer layer];
    _tint.startPoint = _mask.startPoint;
    _tint.endPoint = _mask.endPoint;
    _tint.locations = _mask.locations;
    _tint.opacity = 0.5f;
    [self.layer addSublayer:_tint];
    [self lg_updateTint];
    return self;
}

- (void)lg_updateTint {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIColor *tint = dark ? UIColor.blackColor : UIColor.whiteColor;
    _tint.colors = @[
        (__bridge id)tint.CGColor,
        (__bridge id)[tint colorWithAlphaComponent:0.82].CGColor,
        (__bridge id)[tint colorWithAlphaComponent:0.0].CGColor
    ];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _blur.frame = self.bounds;
    _mask.frame = self.bounds;
    _tint.frame = self.bounds;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (!previous || previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle)
        [self lg_updateTint];
}
@end

@interface LGSettingsBackButton : UIControl
@property (nonatomic, strong) LGLiveBackdropView *glass;
@property (nonatomic, strong) UIImageView *glyph;
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, weak) UIView *stockButton;
@property (nonatomic, strong) UIViewPropertyAnimator *pressAnimator;
@end

@implementation LGSettingsBackButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    _glass = LGCreateRegisteredGlass(self.bounds, nil, @"PrefsButton");
    _glass.userInteractionEnabled = NO;
    [self addSubview:_glass];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:24
                                                        weight:UIImageSymbolWeightRegular];
    _glyph = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.left" withConfiguration:configuration]];
    _glyph.tintColor = UIColor.labelColor;
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    [self addTarget:self action:@selector(lg_pop) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.glass.frame = self.bounds;
    self.glass.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    self.glass.layer.cornerCurve = kCACornerCurveContinuous;
    self.glass.layer.masksToBounds = YES;
    self.glyph.frame = self.bounds;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    CALayer *presentation = self.layer.presentationLayer;
    if (presentation) self.transform = CATransform3DGetAffineTransform(presentation.transform);
    [self.pressAnimator stopAnimation:YES];
    CGFloat mass = 0.8;
    CGFloat stiffness = 300.0;
    CGFloat damping = highlighted ? 18.0 : 12.0;
    CGFloat velocity = highlighted ? 0.5 : 1.0;
    CGFloat duration = highlighted ? 0.3 : 0.5;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc]
        initWithMass:mass stiffness:stiffness damping:damping
        initialVelocity:CGVectorMake(velocity, velocity)];
    self.pressAnimator = [[UIViewPropertyAnimator alloc]
        initWithDuration:duration timingParameters:timing];
    __weak typeof(self) weakSelf = self;
    [self.pressAnimator addAnimations:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;

        strongSelf.transform = highlighted ? CGAffineTransformMakeScale(1.16, 1.16)
                                            : CGAffineTransformIdentity;
    }];
    [self.pressAnimator startAnimation];
}
- (BOOL)lg_invokeView:(UIView *)view {
    if ([view isKindOfClass:UIControl.class] &&
        ((UIControl *)view).allTargets.count > 0) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        NSArray *targets = nil;
        @try { targets = [recognizer valueForKey:@"_targets"]; }
        @catch (__unused NSException *exception) {}
        for (id targetAction in targets) {
            id target = nil;
            NSString *actionName = nil;
            @try {
                target = [targetAction valueForKey:@"target"];
                actionName = [targetAction valueForKey:@"action"];
            } @catch (__unused NSException *exception) {}
            SEL action = NSSelectorFromString(actionName);
            if (target && action && [target respondsToSelector:action]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
                return YES;
            }
        }
    }
    for (UIView *subview in view.subviews)
        if ([self lg_invokeView:subview]) return YES;
    return NO;
}
- (void)lg_pop {
    if (![self lg_invokeView:self.stockButton])
        [self.navigationController popViewControllerAnimated:YES];
}
@end

static BOOL LGSettingsFeatureEnabled(void) {
    id settings = LGGlassPreferenceValue(@"SettingsControls.Enabled");

    return ![settings respondsToSelector:@selector(boolValue)] ||
           [settings boolValue];
}

static BOOL LGGlobalControlPreferenceEnabled(NSString *key, BOOL fallback) {
    id value = LGGlassPreferenceValue(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static BOOL LGProcessIsExcludedFromGlobalControls(void) {
    id stored = LGGlassPreferenceValue(@"GlobalControls.Exclusions");
    NSString *exclusions = [stored isKindOfClass:NSString.class]
        ? (NSString *)stored : @"NewTerm\nFilza\nTikTok\nDiscord\ncom.spotify.client";
    if (!exclusions.length) return NO;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n,;"];
    for (NSString *rawEntry in [exclusions componentsSeparatedByCharactersInSet:separators]) {
        NSString *entry = [rawEntry stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (!entry.length || [entry hasPrefix:@"#"]) continue;
        if ([entry isEqualToString:bundleID] || [entry isEqualToString:executable] ||
            [entry isEqualToString:processName]) return YES;
    }
    return NO;
}

static void LGRefreshGlobalControlEnablement(void) {
    gLGSettingsControlsEnabled = LGSettingsFeatureEnabled();
    BOOL allowed = gLGSettingsControlsEnabled && !LGProcessIsExcludedFromGlobalControls();
    gLGSwitchControlsEnabled = allowed &&
        LGGlobalControlPreferenceEnabled(@"GlobalControls.Switches.Enabled", YES);
    gLGSliderControlsEnabled = allowed &&
        LGGlobalControlPreferenceEnabled(@"GlobalControls.Sliders.Enabled", NO);
    gLGSegmentControlsEnabled = allowed &&
        LGGlobalControlPreferenceEnabled(@"GlobalControls.Segmented.Enabled", NO);
}

static BOOL LGInsideLiquidAssPrefs(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        NSBundle *bundle = [NSBundle bundleForClass:r.class];
        if ([bundle.bundleIdentifier isEqualToString:@"dylv.liquidassprefs"] ||
            [NSStringFromClass(r.class) hasPrefix:@"LG"]) return YES;
    }
    return NO;
}

static BOOL LGControllerContainsLiquidAssPrefs(UIViewController *controller) {
    if (!controller) return NO;
    if ([[NSBundle bundleForClass:controller.class].bundleIdentifier
         isEqualToString:@"dylv.liquidassprefs"] ||
        [NSStringFromClass(controller.class) hasPrefix:@"LG"]) return YES;
    for (UIViewController *child in controller.childViewControllers)
        if (LGControllerContainsLiquidAssPrefs(child)) return YES;
    return controller.presentedViewController &&
           LGControllerContainsLiquidAssPrefs(controller.presentedViewController);
}

static BOOL LGSettingsChromeEnabledForView(UIView *view) {
    if (gLGSettingsControlsEnabled) return YES;
    if (LGInsideLiquidAssPrefs(view)) return YES;
    return LGControllerContainsLiquidAssPrefs(view.window.rootViewController);
}

static BOOL LGSettingsWrapperIsScreenSized(UIView *wrapper) {
    UIWindow *window = wrapper.window;
    if (!window || CGRectIsEmpty(wrapper.bounds)) return NO;
    CGRect frame = [wrapper convertRect:wrapper.bounds toView:window];
    CGRect screen = window.bounds;
    return fabs(CGRectGetWidth(frame) - CGRectGetWidth(screen)) <= 1.0 &&
           fabs(CGRectGetHeight(frame) - CGRectGetHeight(screen)) <= 1.0;
}

static BOOL LGSettingsWrapperIsClosestToWindow(UIView *wrapper) {
    Class wrapperClass = NSClassFromString(@"UIViewControllerWrapperView");
    if (!wrapper.window || !wrapperClass) return NO;
    for (UIView *ancestor = wrapper.superview; ancestor && ancestor != wrapper.window;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:wrapperClass]) return NO;
    }
    return YES;
}

static void LGUpdateSettingsTopFade(UIView *wrapper) {
    if (!LGSettingsChromeEnabledForView(wrapper) ||
        !LGSettingsWrapperIsScreenSized(wrapper) ||
        !LGSettingsWrapperIsClosestToWindow(wrapper)) {
        [objc_getAssociatedObject(wrapper, kLGSettingsTopFadeKey) removeFromSuperview];
        objc_setAssociatedObject(wrapper, kLGSettingsTopFadeKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    LGSettingsTopFadeView *fade =
        objc_getAssociatedObject(wrapper, kLGSettingsTopFadeKey);
    if (!fade) {
        fade = [[LGSettingsTopFadeView alloc] initWithFrame:CGRectZero];
        [wrapper addSubview:fade];
        objc_setAssociatedObject(wrapper, kLGSettingsTopFadeKey, fade,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat height = MAX(60.0, wrapper.safeAreaInsets.top + 16.0);
    fade.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(wrapper.bounds), height);
    fade.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleBottomMargin;
    [wrapper bringSubviewToFront:fade];
}

static void LGHideSettingsNavigationBarBackground(UINavigationBar *bar) {
    Class backgroundClass = NSClassFromString(@"_UIBarBackground");
    if (!backgroundClass) return;
    BOOL chromeEnabled = LGSettingsChromeEnabledForView(bar);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:bar.subviews];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:backgroundClass]) {
            NSDictionary *original = objc_getAssociatedObject(
                view, kLGSettingsBarBackgroundStateKey);
            if (!chromeEnabled) {
                if (original) {
                    view.hidden = [original[@"hidden"] boolValue];
                    view.alpha = [original[@"alpha"] doubleValue];
                    view.userInteractionEnabled =
                        [original[@"interaction"] boolValue];
                    objc_setAssociatedObject(
                        view, kLGSettingsBarBackgroundStateKey, nil,
                        OBJC_ASSOCIATION_ASSIGN);
                }
                continue;
            }
            if (!original) {
                objc_setAssociatedObject(
                    view, kLGSettingsBarBackgroundStateKey,
                    @{@"hidden": @(view.hidden),
                      @"alpha": @(view.alpha),
                      @"interaction": @(view.userInteractionEnabled)},
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
            continue;
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void LGHideStockControlContents(UIView *control, UIView *except) {
    for (UIView *subview in control.subviews)
        if (subview != except) subview.alpha = 0.0;
}

static BOOL LGViewTreeHasSpeechRateEndpoints(UIView *root);

static UISlider *LGSettingsSliderOwnerForVisualElement(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview)
        if ([candidate isKindOfClass:UISlider.class]) return (UISlider *)candidate;
    return nil;
}

static void LGSetNativeSliderTreeSuppressed(UIView *view, BOOL preserve) {
    if (!view) return;
    view.hidden = NO;
    view.userInteractionEnabled = NO;
    view.alpha = preserve ? 1.0 : 0.0;
    for (UIView *subview in view.subviews) {
        BOOL preserveSubview = preserve || [subview isKindOfClass:UILabel.class];
        LGSetNativeSliderTreeSuppressed(subview, preserveSubview);
    }
}

static void LGSuppressNativeSliderContents(UISlider *owner,
                                           LGPrefsLiquidSlider *overlay) {
    UIView *visualHost = objc_getAssociatedObject(owner,
                                                   kLGSettingsSliderVisualHostKey);
    UIView *root = visualHost ?: owner;
    for (UIView *subview in root.subviews) {
        if (subview == overlay) continue;
        LGSetNativeSliderTreeSuppressed(subview,
            [subview isKindOfClass:UILabel.class]);
    }
}

static UIView *LGSettingsSliderOverlayContainer(UISlider *owner) {
    // mount outside the stock slider so value labels stay untouched
    UIView *start = owner.superview ?: owner;
    UIView *container = start;
    for (UIView *candidate = start; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIScrollView.class]) break;
        container = candidate;
    }
    return container;
}

static CGRect LGSettingsSliderOverlayFrame(UISlider *owner, UIView *container) {
    UIView *host = objc_getAssociatedObject(owner, kLGSettingsSliderVisualHostKey);
    CGRect contentFrame = CGRectNull;
    CGRect labelFrame = CGRectNull;
    for (UIView *subview in host.subviews) {
        if (CGRectIsEmpty(subview.bounds)) continue;
        CGRect frame = [subview convertRect:subview.bounds toView:container];
        if ([subview isKindOfClass:UILabel.class]) {
            labelFrame = CGRectIsNull(labelFrame) ? frame : CGRectUnion(labelFrame, frame);
        } else {
            contentFrame = CGRectIsNull(contentFrame) ? frame : CGRectUnion(contentFrame, frame);
        }
    }
    if (CGRectIsNull(contentFrame) || CGRectIsEmpty(contentFrame))
        contentFrame = [owner convertRect:owner.bounds toView:container];
    if (!CGRectIsNull(labelFrame) &&
        CGRectGetMinX(labelFrame) > CGRectGetMinX(contentFrame)) {
        CGFloat maximumX = CGRectGetMinX(labelFrame) - 6.0;
        if (maximumX > CGRectGetMinX(contentFrame))
            contentFrame.size.width = maximumX - CGRectGetMinX(contentFrame);
    }
    return contentFrame;
}

static void LGInstallSettingsSwitch(UISwitch *owner) {
    if (!gLGSwitchControlsEnabled || !owner.window ||
        [owner isKindOfClass:LGPrefsLiquidSwitch.class] ||
        LGInsideLiquidAssPrefs(owner)) return;

    LGPrefsLiquidSwitch *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey);
    if (!overlay) {
        overlay = [[LGPrefsLiquidSwitch alloc] initWithFrame:owner.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
        __weak UISwitch *weakOwner = owner;
        [overlay addAction:[UIAction actionWithHandler:^(UIAction *action) {
            UISwitch *strongOwner = weakOwner;
            LGPrefsLiquidSwitch *sender = (LGPrefsLiquidSwitch *)action.sender;
            if (!strongOwner) return;
            [strongOwner setOn:sender.isOn animated:NO];
            [strongOwner sendActionsForControlEvents:UIControlEventValueChanged];
        }] forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(owner, kLGSettingsSwitchOverlayKey, overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [owner addSubview:overlay];
    }

    owner.clipsToBounds = NO;
    owner.layer.masksToBounds = NO;
    overlay.frame = CGRectMake(-8.0, 0.0,
                               CGRectGetWidth(owner.bounds) + 8.0,
                               CGRectGetHeight(owner.bounds));
    if (overlay.isOn != owner.isOn) [overlay setOn:owner.isOn animated:NO];
    overlay.enabled = owner.enabled;
    LGHideStockControlContents(owner, overlay);
    [owner bringSubviewToFront:overlay];
}

static void LGInstallSettingsSlider(UISlider *owner) {
    if (!gLGSliderControlsEnabled || !owner.window ||
        [owner isKindOfClass:LGPrefsLiquidSlider.class] ||
        LGInsideLiquidAssPrefs(owner)) return;
    for (UIView *candidate = owner; candidate; candidate = candidate.superview) {
        if (LGViewTreeHasSpeechRateEndpoints(candidate)) return;
        if ([candidate isKindOfClass:UITableViewCell.class]) break;
    }

    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    if (!overlay) {
        overlay = [[LGPrefsLiquidSlider alloc] initWithFrame:CGRectZero];
        __weak UISlider *weakOwner = owner;
        [overlay addAction:[UIAction actionWithHandler:^(UIAction *action) {
            UISlider *strongOwner = weakOwner;
            LGPrefsLiquidSlider *sender = (LGPrefsLiquidSlider *)action.sender;
            if (!strongOwner) return;
            [strongOwner setValue:sender.value animated:NO];
            [strongOwner sendActionsForControlEvents:UIControlEventValueChanged];
        }] forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(owner, kLGSettingsSliderOverlayKey, overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *container = LGSettingsSliderOverlayContainer(owner);
    if (overlay.superview != container) {
        [overlay removeFromSuperview];
        [container addSubview:overlay];
    }
    CGRect overlayFrame = LGSettingsSliderOverlayFrame(owner, container);
    if (!CGRectEqualToRect(overlay.frame, overlayFrame)) overlay.frame = overlayFrame;
    if (fabsf(overlay.minimumValue - owner.minimumValue) > FLT_EPSILON)
        overlay.minimumValue = owner.minimumValue;
    if (fabsf(overlay.maximumValue - owner.maximumValue) > FLT_EPSILON)
        overlay.maximumValue = owner.maximumValue;
    if (overlay.enabled != owner.enabled) overlay.enabled = owner.enabled;

    id specifier = nil;
    for (UIView *candidate = owner; candidate && !specifier;
         candidate = candidate.superview) {
        @try {
            if ([candidate respondsToSelector:NSSelectorFromString(@"specifier")])
                specifier = [candidate valueForKey:@"specifier"];
        } @catch (__unused NSException *exception) {}
    }
    BOOL segmented = NO;
    NSInteger segmentCount = 0;
    if (specifier) {
        @try {
            segmented = [[specifier propertyForKey:@"isSegmented"] boolValue] ||
                        [[specifier propertyForKey:@"locksToSegment"] boolValue] ||
                        [[specifier propertyForKey:@"snapsToSegment"] boolValue];
            segmentCount = [[specifier propertyForKey:@"segmentCount"] integerValue];
        } @catch (__unused NSException *exception) {}
    }
    float range = owner.maximumValue - owner.minimumValue;
    float roundedRange = roundf(range);
    if (segmented && segmentCount <= 0 &&
        fabsf(range - roundedRange) <= 0.001f &&
        roundedRange >= 1.0f && roundedRange <= 24.0f)
        segmentCount = (NSInteger)roundedRange;
    objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentedKey, @(segmented),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCountKey,
                             @(segmentCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *minimumTint = segmented ? UIColor.clearColor :
        (owner.minimumTrackTintColor ?: owner.tintColor ?: UIColor.systemBlueColor);
    UIColor *maximumTint = segmented ? UIColor.clearColor : owner.maximumTrackTintColor;
    if (![overlay.minimumTrackTintColor isEqual:minimumTint])
        overlay.minimumTrackTintColor = minimumTint;
    if ((overlay.maximumTrackTintColor || maximumTint) &&
        ![overlay.maximumTrackTintColor isEqual:maximumTint])
        overlay.maximumTrackTintColor = maximumTint;

    CGRect track = [owner trackRectForBounds:owner.bounds];
    CGRect minThumb = [owner thumbRectForBounds:owner.bounds trackRect:track
                                          value:owner.minimumValue];
    CGRect maxThumb = [owner thumbRectForBounds:owner.bounds trackRect:track
                                          value:owner.maximumValue];
    CGPoint minimumCenter = [owner convertPoint:
        CGPointMake(CGRectGetMidX(minThumb), CGRectGetMidY(minThumb)) toView:container];
    CGPoint maximumCenter = [owner convertPoint:
        CGPointMake(CGRectGetMidX(maxThumb), CGRectGetMidY(maxThumb)) toView:container];
    minimumCenter = [overlay convertPoint:minimumCenter fromView:container];
    maximumCenter = [overlay convertPoint:maximumCenter fromView:container];
    NSArray *endpoints = @[ @(minimumCenter.x), @(maximumCenter.x) ];
    objc_setAssociatedObject(overlay, kLGPrefsSliderEndpointCentersKey, endpoints,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (segmented && segmentCount > 0) {
        NSMutableArray *centers = [NSMutableArray arrayWithCapacity:segmentCount + 1];
        for (NSInteger index = 0; index <= segmentCount; index++) {
            float value = owner.minimumValue +
                ((float)index / (float)segmentCount) * range;
            CGRect thumb = [owner thumbRectForBounds:owner.bounds trackRect:track
                                               value:value];
            CGPoint center = [owner convertPoint:
                CGPointMake(CGRectGetMidX(thumb), CGRectGetMidY(thumb)) toView:container];
            center = [overlay convertPoint:center fromView:container];
            [centers addObject:@(center.x)];
        }
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCentersKey, centers,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(overlay, kLGPrefsSliderSegmentCentersKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (fabsf(overlay.value - owner.value) > FLT_EPSILON)
        [overlay setValue:owner.value animated:NO];
    LGSuppressNativeSliderContents(owner, overlay);
    [container bringSubviewToFront:overlay];
}

static UIView *LGDescendantNamed(UIView *root, NSString *name) {
    for (UIView *subview in root.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:name]) return subview;
        UIView *found = LGDescendantNamed(subview, name);
        if (found) return found;
    }
    return nil;
}

static void LGUpdateSettingsBackButton(UINavigationBar *bar) {
    if (!bar.window) return;
    BOOL insideLiquidAssPrefs = LGInsideLiquidAssPrefs(bar);
    UIView *content = nil;
    for (UIView *subview in bar.subviews)
        if ([NSStringFromClass(subview.class) isEqualToString:@"_UINavigationBarContentView"]) {
            content = subview;
            break;
        }
    if (!content) return;
    LGSettingsBackButton *installed =
        objc_getAssociatedObject(content, kLGSettingsBackButtonKey);
    if (!gLGSettingsControlsEnabled) {
        UIView *stock = installed.stockButton;
        NSDictionary *original = stock
            ? objc_getAssociatedObject(stock, kLGSettingsStockBackStateKey)
            : nil;
        if (stock && original) {
            stock.hidden = [original[@"hidden"] boolValue];
            stock.alpha = [original[@"alpha"] doubleValue];
            stock.userInteractionEnabled = [original[@"interaction"] boolValue];
            objc_setAssociatedObject(stock, kLGSettingsStockBackStateKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
        [installed removeFromSuperview];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    UINavigationController *navigation = nil;
    for (UIResponder *r = bar; r; r = r.nextResponder)
        if ([r isKindOfClass:UINavigationController.class]) {
            navigation = (UINavigationController *)r;
            break;
        }
    if (!navigation || navigation.viewControllers.count <= 1 || !bar.backItem) {
        [objc_getAssociatedObject(content, kLGSettingsBackButtonKey) removeFromSuperview];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *navigationClass = NSStringFromClass(navigation.class);
    if (insideLiquidAssPrefs || LGControllerContainsLiquidAssPrefs(navigation) ||
        [[NSBundle bundleForClass:navigation.class].bundleIdentifier
            isEqualToString:@"dylv.liquidassprefs"] ||
        [navigationClass hasPrefix:@"LG"]) {
        [objc_getAssociatedObject(content, kLGSettingsBackButtonKey) removeFromSuperview];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    UIView *stock = nil;
    for (UIView *candidate in content.subviews)
        if ([NSStringFromClass(candidate.class) isEqualToString:@"_UIButtonBarButton"] &&
            LGDescendantNamed(candidate, @"_UIBackButtonMaskView")) {
            stock = candidate;
            break;
        }
    if (!stock) return;
    LGSettingsBackButton *button =
        objc_getAssociatedObject(content, kLGSettingsBackButtonKey);
    if (!button) {
        button = [[LGSettingsBackButton alloc] initWithFrame:CGRectMake(16, 0, 44, 44)];
        [content addSubview:button];
        objc_setAssociatedObject(content, kLGSettingsBackButtonKey, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    button.navigationController = navigation;
    button.stockButton = stock;
    if (!objc_getAssociatedObject(stock, kLGSettingsStockBackStateKey)) {
        objc_setAssociatedObject(
            stock, kLGSettingsStockBackStateKey,
            @{@"hidden": @(stock.hidden),
              @"alpha": @(stock.alpha),
              @"interaction": @(stock.userInteractionEnabled)},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat leading = MAX(16.0, bar.safeAreaInsets.left + 8.0);
    CGFloat y = floor(CGRectGetMidY(content.bounds) - 22.0);
    button.frame = CGRectMake(floor(leading), y, 44.0, 44.0);
    stock.hidden = YES;
    stock.alpha = 0.0;
    stock.userInteractionEnabled = NO;
    [content bringSubviewToFront:button];
}

static BOOL LGViewTreeHasSpeechRateEndpoints(UIView *root) {
    NSInteger matches = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        if ([label isEqualToString:@"increase speed"] ||
            [label isEqualToString:@"decrease speed"]) {
            matches++;
            if (matches >= 2) return YES;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return NO;
}

static void LGInstallSettingsSegmentGlass(UISegmentedControl *control) {
    if (!gLGSegmentControlsEnabled || !control.window ||
        LGInsideLiquidAssPrefs(control)) return;
    NSInteger count = control.numberOfSegments;
    if (count <= 0 || control.selectedSegmentIndex < 0 ||
        control.selectedSegmentIndex >= count) return;
    LGLiveBackdropView *glass =
        objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(CGRectZero, nil, @"PrefsSegment");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        [control addSubview:glass];
        objc_setAssociatedObject(control, kLGSettingsSegmentGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glass.hidden = YES;
        glass.alpha = 0.0;
    }
    control.clipsToBounds = NO;
    control.layer.masksToBounds = NO;
    control.layer.cornerRadius = CGRectGetHeight(control.bounds) * 0.5;
    CGFloat segmentWidth = CGRectGetWidth(control.bounds) / (CGFloat)count;
    CGFloat selectedCenter = (control.selectedSegmentIndex + 0.5) * segmentWidth;
    NSNumber *touchX = objc_getAssociatedObject(control, kLGSettingsSegmentTouchXKey);
    BOOL active = [objc_getAssociatedObject(control, kLGSettingsSegmentActiveKey) boolValue];
    BOOL released = [objc_getAssociatedObject(control, kLGSettingsSegmentReleasedKey) boolValue];
    if ([objc_getAssociatedObject(control, kLGSettingsSegmentFadingKey) boolValue]) return;
    if (!active && !released) {
        id original = objc_getAssociatedObject(control, kLGSettingsSegmentOriginalTintKey);
        control.selectedSegmentTintColor = original == NSNull.null ? nil : original;
        glass.hidden = YES;
        glass.alpha = 0.0;
        objc_setAssociatedObject(control, kLGSettingsSegmentRenderedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!objc_getAssociatedObject(control, kLGSettingsSegmentOriginalTintKey)) {
        id original = control.selectedSegmentTintColor ?: NSNull.null;
        objc_setAssociatedObject(control, kLGSettingsSegmentOriginalTintKey, original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    control.selectedSegmentTintColor = UIColor.clearColor;

    CGFloat targetTouch = touchX ? touchX.doubleValue : selectedCenter;

    if (released) targetTouch = selectedCenter;
    CGFloat velocity = [objc_getAssociatedObject(control, kLGSettingsSegmentVelocityKey)
        doubleValue];
    CGSize baseSize = CGSizeMake(segmentWidth, CGRectGetHeight(control.bounds) - 4.0);
    LGLiquidDragState drag = LGLiquidDragStateMake(targetTouch,
        segmentWidth * 0.5 - 3.0,
        CGRectGetWidth(control.bounds) - segmentWidth * 0.5 + 3.0,
        baseSize, released ? 0.0 : velocity, 33.0);
    LGLiquidRenderedState targetState =
        LGLiquidRenderedStateMake(drag.centerX, CGSizeMake(drag.width, drag.height));
    NSValue *renderedValue = objc_getAssociatedObject(control, kLGSettingsSegmentRenderedKey);
    LGLiquidRenderedState rendered = targetState;
    if (renderedValue) {
        CGRect old = renderedValue.CGRectValue;
        rendered = LGLiquidRenderedStateMake(CGRectGetMidX(old), old.size);
        CGFloat delta = [objc_getAssociatedObject(control, kLGSettingsSegmentFrameDeltaKey)
            doubleValue];
        rendered = LGLiquidRenderedStateStep(rendered, targetState, active,
                                              delta > 0.0 ? delta : 1.0 / 60.0);
    }
    CGRect target = CGRectMake(rendered.centerX - rendered.width * 0.5,
                               CGRectGetMidY(control.bounds) - rendered.height * 0.5,
                               rendered.width, rendered.height);
    objc_setAssociatedObject(control, kLGSettingsSegmentRenderedKey,
                             [NSValue valueWithCGRect:target],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    glass.frame = target;
    glass.hidden = NO;
    if (glass.alpha < 1.0)
        [UIView animateWithDuration:0.14 animations:^{ glass.alpha = 1.0; }];
    CGFloat glassRadius = CGRectGetHeight(glass.bounds) * 0.5;
    control.layer.cornerRadius = glassRadius;
    glass.layer.cornerRadius = glassRadius;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    Class segmentClass = NSClassFromString(@"UISegment");
    for (UIView *subview in control.subviews)
        if (subview != glass && segmentClass && [subview isKindOfClass:segmentClass]) {

            subview.backgroundColor = UIColor.clearColor;
            subview.layer.backgroundColor = UIColor.clearColor.CGColor;
            [control bringSubviewToFront:subview];
        }
    [control bringSubviewToFront:glass];
    glass.layer.zPosition = 100.0;
}

static void LGProfiledInstallSettingsSwitch(UISwitch *owner) {
    if (!gLGControlsDiagnosticsEnabled) {
        LGInstallSettingsSwitch(owner);
        return;
    }
    BOOL existed = objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey) != nil;
    CFTimeInterval started = CACurrentMediaTime();
    LGInstallSettingsSwitch(owner);
    BOOL created = !existed && objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey) != nil;
    LGRecordControlsDiagnostic(LGControlsDiagnosticSwitch, started, created);
    if (created)
        LGLog(@"[GlobalControlsCreate] switch owner=%s super=%s frame=%s",
                   NSStringFromClass(owner.class).UTF8String,
                   NSStringFromClass(owner.superview.class).UTF8String,
                   NSStringFromCGRect(owner.frame).UTF8String);
}

static void LGProfiledInstallSettingsSlider(UISlider *owner) {
    if (!gLGControlsDiagnosticsEnabled) {
        LGInstallSettingsSlider(owner);
        return;
    }
    BOOL existed = objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey) != nil;
    CFTimeInterval started = CACurrentMediaTime();
    LGInstallSettingsSlider(owner);
    LGPrefsLiquidSlider *overlay = objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    BOOL created = !existed && overlay != nil;
    LGRecordControlsDiagnostic(LGControlsDiagnosticSlider, started, created);
    if (created)
        LGLog(@"[GlobalControlsCreate] slider owner=%s visual=%s super=%s frame=%s segmented=%d count=%ld",
                   NSStringFromClass(owner.class).UTF8String,
                   NSStringFromClass(((UIView *)objc_getAssociatedObject(owner, kLGSettingsSliderVisualHostKey)).class).UTF8String,
                   NSStringFromClass(owner.superview.class).UTF8String,
                   NSStringFromCGRect(owner.frame).UTF8String,
                   [objc_getAssociatedObject(overlay, kLGPrefsSliderSegmentedKey) boolValue],
                   (long)[objc_getAssociatedObject(overlay, kLGPrefsSliderSegmentCountKey) integerValue]);
}

static void LGProfiledLayoutSettingsSlider(UISlider *owner) {
    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(owner, kLGSettingsSliderOverlayKey);
    if (!overlay) {
        LGProfiledInstallSettingsSlider(owner);
        return;
    }
    CFTimeInterval started = gLGControlsDiagnosticsEnabled ? CACurrentMediaTime() : 0.0;

    if (gLGControlsDiagnosticsEnabled)
        LGRecordControlsDiagnostic(LGControlsDiagnosticSlider, started, NO);
}

static void LGProfiledInstallSettingsSegmentGlass(UISegmentedControl *control) {
    if (!gLGControlsDiagnosticsEnabled) {
        LGInstallSettingsSegmentGlass(control);
        return;
    }
    BOOL existed = objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey) != nil;
    CFTimeInterval started = CACurrentMediaTime();
    LGInstallSettingsSegmentGlass(control);
    BOOL created = !existed && objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey) != nil;
    LGRecordControlsDiagnostic(LGControlsDiagnosticSegment, started, created);
    if (created)
        LGLog(@"[GlobalControlsCreate] segment owner=%s super=%s frame=%s count=%ld",
                   NSStringFromClass(control.class).UTF8String,
                   NSStringFromClass(control.superview.class).UTF8String,
                   NSStringFromCGRect(control.frame).UTF8String,
                   (long)control.numberOfSegments);
}

@interface UISegmentedControl (LGLiquidSettingsSegment)
- (void)lg_settingsSegmentTick:(CADisplayLink *)link;
- (void)lg_segmentBegin:(UITouch *)touch;
- (void)lg_segmentMove:(UITouch *)touch;
- (void)lg_segmentEnd;
- (void)lg_segmentCancel;
@end

static void LGStartSettingsSegmentDisplayLink(UISegmentedControl *control) {
    if (objc_getAssociatedObject(control, kLGSettingsSegmentDisplayLinkKey) ||
        !control.window) return;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:control
        selector:@selector(lg_settingsSegmentTick:)];
    link.preferredFramesPerSecond = UIScreen.mainScreen.maximumFramesPerSecond ?: 60;
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(control, kLGSettingsSegmentDisplayLinkKey, link,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGStopSettingsSegmentDisplayLink(UISegmentedControl *control) {
    CADisplayLink *link =
        objc_getAssociatedObject(control, kLGSettingsSegmentDisplayLinkKey);
    [link invalidate];
    objc_setAssociatedObject(control, kLGSettingsSegmentDisplayLinkKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGFinishSettingsSegmentRelease(UISegmentedControl *control) {
    if ([objc_getAssociatedObject(control, kLGSettingsSegmentFadingKey) boolValue]) return;
    LGLiveBackdropView *glass = objc_getAssociatedObject(control, kLGSettingsSegmentGlassKey);
    if (!glass) return;
    id original = objc_getAssociatedObject(control, kLGSettingsSegmentOriginalTintKey);
    control.selectedSegmentTintColor = original == NSNull.null ? nil : original;
    objc_setAssociatedObject(control, kLGSettingsSegmentFadingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [UIView animateWithDuration:0.18 delay:0.0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
        animations:^{
            glass.alpha = 0.0;
            glass.transform = CGAffineTransformMakeScale(0.94, 0.94);
        } completion:^(__unused BOOL finished) {
            glass.hidden = YES;
            glass.alpha = 0.0;
            glass.transform = CGAffineTransformIdentity;
            objc_setAssociatedObject(control, kLGSettingsSegmentFadingKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(control, kLGSettingsSegmentReleasedKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(control, kLGSettingsSegmentTouchXKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(control, kLGSettingsSegmentRenderedKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LGInstallSettingsSegmentGlass(control);
            LGStopSettingsSegmentDisplayLink(control);
        }];
}

static BOOL LGSettingsShouldModifyCell(UIView *cell) {
    Class segmentCell = NSClassFromString(@"PSSegmentTableCell");
    Class sliderCell = NSClassFromString(@"PSSliderTableCell");
    return !(segmentCell && [cell isKindOfClass:segmentCell]) &&
           !(sliderCell && [cell isKindOfClass:sliderCell]);
}

static void LGUpdateSettingsCell(UITableViewCell *cell) {
    if (!gLGSettingsControlsEnabled) return;
    UIEdgeInsets inset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    cell.separatorInset = inset;
    cell.layoutMargins = inset;
    cell.preservesSuperviewLayoutMargins = NO;
    if (!LGSettingsShouldModifyCell(cell)) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (fabs(view.layer.cornerRadius - 10.0) <= 0.25 &&
            CGRectGetHeight(view.bounds) > 0.0)
            view.layer.cornerRadius = 27.0;
        [stack addObjectsFromArray:view.subviews];
    }
}

%group LiquidAssGlobalControls

static UISwitch *LGSettingsOwnerForModernSwitchElement(UIView *element) {
    for (UIView *candidate = element.superview; candidate;
         candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISwitch.class])
            return (UISwitch *)candidate;
    }
    return nil;
}

static BOOL LGSettingsShouldSuppressModernSwitchElement(UIView *element) {
    UISwitch *owner = LGSettingsOwnerForModernSwitchElement(element);
    if (!owner || !gLGSwitchControlsEnabled) return NO;
    return [owner isKindOfClass:LGPrefsLiquidSwitch.class] ||
        objc_getAssociatedObject(owner, kLGSettingsSwitchOverlayKey) != nil;
}

static void LGSettingsSuppressModernSwitchElementIfNeeded(UIView *element) {
    if (LGSettingsShouldSuppressModernSwitchElement(element) && element.alpha != 0.0)
        element.alpha = 0.0;
}

%hook UISwitchModernVisualElement
- (void)didMoveToSuperview {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchMoves++;
    LGSettingsSuppressModernSwitchElementIfNeeded((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchMoves++;
    LGSettingsSuppressModernSwitchElementIfNeeded((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchLayouts++;
    LGSettingsSuppressModernSwitchElementIfNeeded((UIView *)self);
}
- (void)setAlpha:(CGFloat)alpha {
    if (gLGControlsDiagnosticsEnabled) gLGControlsModernSwitchAlphaSets++;
    BOOL suppress = LGSettingsShouldSuppressModernSwitchElement((UIView *)self);
    %orig(suppress ? 0.0 : alpha);
}
%end

%hook UISwitch
- (void)didMoveToWindow {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSwitchMoves++;
    LGProfiledInstallSettingsSwitch((UISwitch *)self);
}
- (void)layoutSubviews {
    %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSwitchLayouts++;
    LGProfiledInstallSettingsSwitch((UISwitch *)self);
}
- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    LGPrefsLiquidSwitch *overlay =
        objc_getAssociatedObject(self, kLGSettingsSwitchOverlayKey);
    if (overlay && overlay.isOn != on) [overlay setOn:on animated:animated];
}
%end

%hook _UISlideriOSVisualElement
- (void)didMoveToWindow {
    %orig;
    UISlider *owner = LGSettingsSliderOwnerForVisualElement((UIView *)self);
    if (!owner || [owner isKindOfClass:LGPrefsLiquidSlider.class]) return;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSliderVisualMoves++;
    objc_setAssociatedObject(owner, kLGSettingsSliderVisualHostKey, self,
                             OBJC_ASSOCIATION_ASSIGN);
    LGProfiledLayoutSettingsSlider(owner);
}
- (void)layoutSubviews {
    %orig;
    UISlider *owner = LGSettingsSliderOwnerForVisualElement((UIView *)self);
    if (!owner || [owner isKindOfClass:LGPrefsLiquidSlider.class]) return;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSliderVisualLayouts++;
    objc_setAssociatedObject(owner, kLGSettingsSliderVisualHostKey, self,
                             OBJC_ASSOCIATION_ASSIGN);
    LGProfiledInstallSettingsSlider(owner);
}
%end

%hook UISlider
- (void)didMoveToWindow {
    %orig;
    if (gLGControlsDiagnosticsEnabled) {
        if ([self isKindOfClass:LGPrefsLiquidSlider.class]) gLGControlsSliderOverlayMoves++;
        else gLGControlsSliderOwnerMoves++;
    }
    if (![self isKindOfClass:LGPrefsLiquidSlider.class])
        LGProfiledLayoutSettingsSlider((UISlider *)self);
}
- (void)layoutSubviews {
    %orig;
    if (gLGControlsDiagnosticsEnabled) {
        if ([self isKindOfClass:LGPrefsLiquidSlider.class]) gLGControlsSliderOverlayLayouts++;
        else gLGControlsSliderOwnerLayouts++;
    }
    if (![self isKindOfClass:LGPrefsLiquidSlider.class])
        LGProfiledInstallSettingsSlider((UISlider *)self);
}
- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    LGPrefsLiquidSlider *overlay =
        objc_getAssociatedObject(self, kLGSettingsSliderOverlayKey);
    if (overlay && fabsf(overlay.value - value) > FLT_EPSILON)
        [overlay setValue:value animated:animated];
}
- (void)setMinimumValue:(float)value {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setMaximumValue:(float)value {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setEnabled:(BOOL)enabled {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setMinimumTrackTintColor:(UIColor *)color {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (void)setMaximumTrackTintColor:(UIColor *)color {
    %orig;
    if (![self isKindOfClass:LGPrefsLiquidSlider.class]) {
        if (gLGControlsDiagnosticsEnabled) gLGControlsSliderSetters++;
        LGProfiledInstallSettingsSlider((UISlider *)self);
    }
}
- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsTrack] begin class=%s overlay=%d super=%s frame=%s",
                   NSStringFromClass(self.class).UTF8String,
                   [self isKindOfClass:LGPrefsLiquidSlider.class],
                   NSStringFromClass(((UIView *)self).superview.class).UTF8String,
                   NSStringFromCGRect(((UIView *)self).frame).UTF8String);
    return result;
}
- (BOOL)continueTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    if (gLGControlsDiagnosticsEnabled) gLGControlsSliderTrackingCalls++;
    return result;
}
- (void)endTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsTrack] end class=%s overlay=%d value=%.4f",
                   NSStringFromClass(self.class).UTF8String,
                   [self isKindOfClass:LGPrefsLiquidSlider.class], self.value);
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsTrack] cancel class=%s overlay=%d",
                   NSStringFromClass(self.class).UTF8String,
                   [self isKindOfClass:LGPrefsLiquidSlider.class]);
}
%end

%hook UISegmentedControl
%new
- (void)lg_settingsSegmentTick:(CADisplayLink *)link {
    if ([objc_getAssociatedObject(self, kLGSettingsSegmentFadingKey) boolValue]) return;
    NSNumber *previousTime = objc_getAssociatedObject(self, kLGSettingsSegmentLastDisplayTimeKey);
    CFTimeInterval delta = previousTime ? link.timestamp - previousTime.doubleValue : 1.0 / 60.0;
    objc_setAssociatedObject(self, kLGSettingsSegmentLastDisplayTimeKey, @(link.timestamp),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentFrameDeltaKey,
                             @(fmin(fmax(delta, 1.0 / 240.0), 1.0 / 20.0)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *velocity = objc_getAssociatedObject(self, kLGSettingsSegmentVelocityKey);
    if (velocity) {
        objc_setAssociatedObject(self, kLGSettingsSegmentVelocityKey,
                                 @(velocity.doubleValue * 0.82),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGProfiledInstallSettingsSegmentGlass((UISegmentedControl *)self);
    if (![objc_getAssociatedObject(self, kLGSettingsSegmentReleasedKey) boolValue]) return;
    NSValue *renderedValue = objc_getAssociatedObject(self, kLGSettingsSegmentRenderedKey);
    UISegmentedControl *control = (UISegmentedControl *)self;
    CGFloat width = CGRectGetWidth(control.bounds) / MAX(control.numberOfSegments, 1);
    CGFloat selectedCenter = (MAX(control.selectedSegmentIndex, 0) + 0.5) * width;
    CGRect rendered = renderedValue.CGRectValue;
    if (renderedValue && fabs(CGRectGetMidX(rendered) - selectedCenter) < 0.35 &&
        fabs(CGRectGetWidth(rendered) - width) < 0.35 &&
        fabs(CGRectGetHeight(rendered) - (CGRectGetHeight(control.bounds) - 4.0)) < 0.35) {
        LGFinishSettingsSegmentRelease(control);
    }
}
- (void)didMoveToWindow {
    %orig;
    if (!self.window) LGStopSettingsSegmentDisplayLink((UISegmentedControl *)self);
    LGProfiledInstallSettingsSegmentGlass((UISegmentedControl *)self);
}
- (void)layoutSubviews {
    %orig;
    // 优化5: layoutSubviews 节流到 30fps
    static CFTimeInterval sLastLayoutTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastLayoutTime < 0.033) return;
    sLastLayoutTime = now;
    LGProfiledInstallSettingsSegmentGlass((UISegmentedControl *)self);
}
- (void)setSelectedSegmentIndex:(NSInteger)index {
    %orig;
    LGProfiledInstallSettingsSegmentGlass((UISegmentedControl *)self);
}
%new
- (void)lg_segmentBegin:(UITouch *)touch {
    if ([objc_getAssociatedObject(self, kLGSettingsSegmentActiveKey) boolValue]) return;
    UISegmentedControl *control = (UISegmentedControl *)self;
    CGFloat width = CGRectGetWidth(control.bounds) / MAX(control.numberOfSegments, 1);
    CGFloat startX = (MAX(control.selectedSegmentIndex, 0) + 0.5) * width;
    CGPoint point = [touch locationInView:control];
    objc_setAssociatedObject(self, kLGSettingsSegmentActiveKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentReleasedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentFadingKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentTouchXKey, @(startX),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentLastXKey, @(point.x),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentLastTimeKey,
                             @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentVelocityKey, @0.0,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGStartSettingsSegmentDisplayLink(control);
    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGSettingsSegmentGlassKey);
    glass.transform = CGAffineTransformIdentity;
    LGProfiledInstallSettingsSegmentGlass(control);
}
%new
- (void)lg_segmentMove:(UITouch *)touch {
    if (![objc_getAssociatedObject(self, kLGSettingsSegmentActiveKey) boolValue]) return;
    CGPoint point = [touch locationInView:(UISegmentedControl *)self];
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastX = objc_getAssociatedObject(self, kLGSettingsSegmentLastXKey);
    NSNumber *lastTime = objc_getAssociatedObject(self, kLGSettingsSegmentLastTimeKey);
    if (lastX && lastTime) {
        CGFloat raw = (point.x - lastX.doubleValue) /
                      MAX(now - lastTime.doubleValue, 0.001);
        CGFloat previous = [objc_getAssociatedObject(self, kLGSettingsSegmentVelocityKey)
            doubleValue];
        objc_setAssociatedObject(self, kLGSettingsSegmentVelocityKey,
                                 @(LGLiquidFilteredVelocity(previous, raw)),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(self, kLGSettingsSegmentLastXKey, @(point.x),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentLastTimeKey, @(now),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentTouchXKey, @(point.x),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%new
- (void)lg_segmentEnd {
    if (![objc_getAssociatedObject(self, kLGSettingsSegmentActiveKey) boolValue]) return;
    objc_setAssociatedObject(self, kLGSettingsSegmentActiveKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentReleasedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentVelocityKey, @0.0,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentTouchXKey,
                             @((MAX(self.selectedSegmentIndex, 0) + 0.5) *
                               (CGRectGetWidth(self.bounds) / MAX(self.numberOfSegments, 1))),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGProfiledInstallSettingsSegmentGlass((UISegmentedControl *)self);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([objc_getAssociatedObject(self, kLGSettingsSegmentReleasedKey) boolValue] &&
            ![objc_getAssociatedObject(self, kLGSettingsSegmentActiveKey) boolValue])
            LGFinishSettingsSegmentRelease((UISegmentedControl *)self);
    });
}
%new
- (void)lg_segmentCancel {
    objc_setAssociatedObject(self, kLGSettingsSegmentActiveKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentTouchXKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentReleasedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLGSettingsSegmentFadingKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGSettingsSegmentGlassKey);
    glass.transform = CGAffineTransformIdentity;
    LGProfiledInstallSettingsSegmentGlass((UISegmentedControl *)self);
    LGStopSettingsSegmentDisplayLink((UISegmentedControl *)self);
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    [self lg_segmentBegin:touch];
    return result;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL result = %orig;
    [self lg_segmentMove:touch];
    return result;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    [self lg_segmentEnd];
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    [self lg_segmentCancel];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    [self lg_segmentBegin:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    [self lg_segmentMove:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    [self lg_segmentEnd];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    [self lg_segmentCancel];
}
%end

%end

%group LiquidAssPreferencesChrome

%hook UIViewControllerWrapperView
- (void)didMoveToWindow {
    %orig;
    LGUpdateSettingsTopFade((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsTopFade((UIView *)self);
}
%end

%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    LGHideSettingsNavigationBarBackground((UINavigationBar *)self);
    LGUpdateSettingsBackButton((UINavigationBar *)self);
}
- (void)layoutSubviews {
    %orig;
    LGHideSettingsNavigationBarBackground((UINavigationBar *)self);
    LGUpdateSettingsBackButton((UINavigationBar *)self);
}
%end

%hook PSTableCell
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize result = %orig;
    if (gLGSettingsControlsEnabled &&
        LGSettingsShouldModifyCell((UIView *)self) &&
        result.height >= 44.0 && result.height <= 55.0) result.height = 54.0;
    return result;
}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)target
       withHorizontalFittingPriority:(UILayoutPriority)horizontal
             verticalFittingPriority:(UILayoutPriority)vertical {
    CGSize result = %orig;
    if (gLGSettingsControlsEnabled &&
        LGSettingsShouldModifyCell((UIView *)self) &&
        result.height >= 44.0 && result.height <= 55.0) result.height = 54.0;
    return result;
}
- (void)layoutSubviews {
    %orig;
    LGUpdateSettingsCell((UITableViewCell *)self);
    LGUpdateLiquidAssEntryFooter((UITableViewCell *)self);
}
%end

%hook PSSliderTableCell
- (void)layoutSubviews {
    %orig;
    if (gLGSettingsControlsEnabled)
        ((UIView *)self).layer.cornerRadius = 24.5;
}
%end

%end

%ctor {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";

    if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

    LGRefreshGlobalControlEnablement();
    gLGControlsDiagnosticsEnabled = NO;
    LGLog(@"global controls ctor bundle=%s enabled=%d",
               bundleIdentifier.UTF8String, gLGSettingsControlsEnabled);
    if (gLGControlsDiagnosticsEnabled)
        LGLog(@"[GlobalControlsPerf] diagnostics enabled bundle=%s",
                   bundleIdentifier.UTF8String);

    %init(LiquidAssGlobalControls);

    if ([bundleIdentifier isEqualToString:@"com.apple.Preferences"])
        %init(LiquidAssPreferencesChrome);

    lgObservePreferenceReload(^{
        LGRefreshGlobalControlEnablement();
        LGLog(@"global controls reload bundle=%s enabled=%d",
                   bundleIdentifier.UTF8String, gLGSettingsControlsEnabled);
    });
}
