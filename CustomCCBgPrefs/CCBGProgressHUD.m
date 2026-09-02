#import "CCBGProgressHUD.h"

static const NSTimeInterval kCCBgHUDShowDuration = 0.25;
static const NSTimeInterval kCCBgHUDDismissDuration = 0.25;
static const CGFloat kCCBgHUDWidth = 150.0;
static const CGFloat kCCBgHUDHeight = 120.0;
static const CGFloat kCCBgHUDCornerRadius = 16.0;

@interface CCBGProgressHUD ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIActivityIndicatorView *indicator;
@property (nonatomic, strong) UILabel *textLabel;
@end

@implementation CCBGProgressHUD

+ (void)showInView:(UIView *)view text:(NSString *)text {
    if (!view) return;

    // 避免重复添加
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[CCBGProgressHUD class]]) {
            CCBGProgressHUD *existingHUD = (CCBGProgressHUD *)subview;
            existingHUD.textLabel.text = text;
            return;
        }
    }

    CCBGProgressHUD *hud = [[CCBGProgressHUD alloc] initWithFrame:CGRectMake(0, 0, kCCBgHUDWidth, kCCBgHUDHeight)];
    hud.center = CGPointMake(view.bounds.size.width / 2, view.bounds.size.height / 2);
    hud.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    hud.alpha = 0.0;
    hud.textLabel.text = text;
    [hud.indicator startAnimating];
    [view addSubview:hud];

    [UIView animateWithDuration:kCCBgHUDShowDuration animations:^{
        hud.alpha = 1.0;
    }];
}

+ (void)dismissFromView:(UIView *)view {
    if (!view) return;

    CCBGProgressHUD *foundHUD = nil;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[CCBGProgressHUD class]]) {
            foundHUD = (CCBGProgressHUD *)subview;
            break;
        }
    }

    if (!foundHUD) return;

    [UIView animateWithDuration:kCCBgHUDDismissDuration animations:^{
        foundHUD.alpha = 0.0;
    } completion:^(BOOL finished) {
        [foundHUD.indicator stopAnimating];
        [foundHUD removeFromSuperview];
    }];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = kCCBgHUDCornerRadius;
        self.clipsToBounds = YES;

        // 毛玻璃背景
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blurView];

        // 菊花
        _indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        _indicator.hidesWhenStopped = YES;
        _indicator.center = CGPointMake(CGRectGetWidth(self.bounds) / 2, CGRectGetHeight(self.bounds) / 2 - 15);
        _indicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                       UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self addSubview:_indicator];

        // 文字
        _textLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, CGRectGetHeight(self.bounds) - 40,
                                                                CGRectGetWidth(self.bounds) - 20, 30)];
        _textLabel.textAlignment = NSTextAlignmentCenter;
        _textLabel.font = [UIFont systemFontOfSize:15.0];
        _textLabel.textColor = [UIColor darkGrayColor];
        _textLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self addSubview:_textLabel];
    }
    return self;
}

@end
