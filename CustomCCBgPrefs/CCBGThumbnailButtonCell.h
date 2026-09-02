#import <UIKit/UIKit.h>

@interface CCBGThumbnailButtonCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, copy) NSString *customTextLabelText;
- (void)setThumbnailImage:(UIImage *)image;
@end
