// Liquid Glass Control Center Quick Toggle
// CCModule bundle for toggling glass effect from Control Center

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>

// Forward declarations for CCUI protocols
@protocol CCUIContentModuleContentViewController <NSObject>
@optional
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) CGSize preferredContentSize;
- (void)viewWillTransitionToSize:(CGSize)arg1 withTransitionCoordinator:(id)arg2;
@end

@protocol CCUIContentModule <NSObject>
@required
@property (nonatomic, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@optional
@property (nonatomic, readonly) UIViewController *backgroundViewController;
- (void)setContentModuleContext:(id)context;
@end

// Preference domain (must match the main tweak)
static NSString * const kLGPrefsDomain = @"dylv.liquidass";
static NSString * const kLGQuickToggleNotification = @"dylv.liquidass/QuickToggle";

@interface LGCCToggleContentViewController : UIViewController <CCUIContentModuleContentViewController>
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, assign) BOOL isGlassEnabled;
- (void)refreshState;
- (void)toggleTapped;
@end

@implementation LGCCToggleContentViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];
    self.view.clipsToBounds = YES;
    self.view.layer.cornerRadius = 22.0;

    // Create toggle button
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = self.view.bounds;
    self.toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.toggleButton addTarget:self
                          action:@selector(toggleTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.toggleButton];

    // Create icon view - use a droplet/glass-like icon
    self.iconView = [[UIImageView alloc] init];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor whiteColor];
    [self.toggleButton addSubview:self.iconView];

    // Draw a simple glass drop icon using CoreGraphics
    [self updateIcon];

    // Refresh state
    [self refreshState];

    // Observe preference changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshState)
                                                 name:@"dylv.liquidass/PrefsChanged"
                                               object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat iconSize = MIN(CGRectGetWidth(self.view.bounds), CGRectGetHeight(self.view.bounds)) * 0.6;
    self.iconView.frame = CGRectMake((CGRectGetWidth(self.view.bounds) - iconSize) / 2,
                                     (CGRectGetHeight(self.view.bounds) - iconSize) / 2,
                                     iconSize, iconSize);
}

- (CGSize)preferredContentSize {
    return CGSizeMake(44, 44);
}

- (void)updateIcon {
    // Draw a simple droplet icon
    CGSize iconSize = CGSizeMake(40, 40);
    UIGraphicsBeginImageContextWithOptions(iconSize, NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // Drop shape
    CGRect rect = CGRectMake(4, 2, 32, 36);
    UIBezierPath *dropPath = [UIBezierPath bezierPath];
    [dropPath moveToPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))];
    [dropPath addQuadCurveToPoint:CGPointMake(CGRectGetMaxX(rect), CGRectGetMidY(rect) + 4)
                     controlPoint:CGPointMake(CGRectGetMaxX(rect) + 2, CGRectGetMidY(rect) - 4)];
    [dropPath addArcWithCenter:CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect) + 8)
                        radius:14
                    startAngle:0
                      endAngle:M_PI
                     clockwise:YES];
    [dropPath addQuadCurveToPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))
                     controlPoint:CGPointMake(CGRectGetMinX(rect) - 2, CGRectGetMidY(rect) - 4)];
    [dropPath closePath];

    CGContextAddPath(ctx, dropPath.CGPath);
    CGContextClip(ctx);

    // Gradient fill
    CGFloat colors[] = {
        1.0, 1.0, 1.0, 0.9,
        0.8, 0.9, 1.0, 0.7,
    };
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, colors, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient,
                                CGPointMake(0, 0),
                                CGPointMake(0, 40),
                                0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    // Highlight
    UIBezierPath *highlightPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(10, 6, 10, 14)];
    [[UIColor colorWithWhite:1.0 alpha:0.6] setFill];
    [highlightPath fill];

    UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    self.iconView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)refreshState {
    // Read CC toggle enabled setting
    CFBooleanRef ccEnabledRef = CFPreferencesCopyAppValue(CFSTR("QuickToggle.CCEnabled"),
                                                          (__bridge CFStringRef)kLGPrefsDomain);
    BOOL ccEnabled = (ccEnabledRef && CFBooleanGetValue(ccEnabledRef)) ? YES : YES; // default YES
    if (ccEnabledRef) CFRelease(ccEnabledRef);

    // Read current glass enabled state
    CFBooleanRef enabled = CFPreferencesCopyAppValue(CFSTR("Global.Enabled"),
                                                     (__bridge CFStringRef)kLGPrefsDomain);
    self.isGlassEnabled = (enabled && CFBooleanGetValue(enabled));
    if (enabled) CFRelease(enabled);

    dispatch_async(dispatch_get_main_queue(), ^{
        self.toggleButton.enabled = ccEnabled;
        if (ccEnabled) {
            if (self.isGlassEnabled) {
                self.view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
                self.iconView.tintColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
            } else {
                self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.3];
                self.iconView.tintColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            }
            self.iconView.alpha = 1.0;
        } else {
            // Disabled state - greyed out
            self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.15];
            self.iconView.tintColor = [UIColor colorWithWhite:0.4 alpha:1.0];
            self.iconView.alpha = 0.5;
        }
    });
}

- (void)toggleTapped {
    // Check if CC toggle is enabled in settings
    CFBooleanRef ccEnabledRef = CFPreferencesCopyAppValue(CFSTR("QuickToggle.CCEnabled"),
                                                          (__bridge CFStringRef)kLGPrefsDomain);
    BOOL ccEnabled = (ccEnabledRef && CFBooleanGetValue(ccEnabledRef)) ? YES : YES;
    if (ccEnabledRef) CFRelease(ccEnabledRef);
    if (!ccEnabled) return;

    self.isGlassEnabled = !self.isGlassEnabled;

    // Write new state to preferences
    CFPreferencesSetAppValue(CFSTR("Global.Enabled"),
                             self.isGlassEnabled ? kCFBooleanTrue : kCFBooleanFalse,
                             (__bridge CFStringRef)kLGPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLGPrefsDomain);

    // Notify the main tweak
    notify_post("dylv.liquidass/ReloadPrefs");

    // Update UI
    [self refreshState];

    // Haptic feedback
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator impactOccurred];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

@interface LGCCToggleModule : NSObject <CCUIContentModule>
@property (nonatomic, strong) LGCCToggleContentViewController *contentViewController;
@property (nonatomic, strong) id contentModuleContext;
@end

@implementation LGCCToggleModule

- (instancetype)init {
    self = [super init];
    if (self) {
        // Content view controller created lazily
    }
    return self;
}

- (void)setContentModuleContext:(id)context {
    _contentModuleContext = context;
}

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[LGCCToggleContentViewController alloc] init];
    }
    return _contentViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

@end
