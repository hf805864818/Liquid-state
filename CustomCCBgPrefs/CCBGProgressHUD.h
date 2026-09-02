#import <UIKit/UIKit.h>

@interface CCBGProgressHUD : UIView

+ (void)showInView:(UIView *)view text:(NSString *)text;
+ (void)dismissFromView:(UIView *)view;

@end
