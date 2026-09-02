#import "CCBGThumbnailButtonCell.h"

static const CGFloat kCCBgThumbSize = 36.0;
static const CGFloat kCCBgThumbCornerRadius = 18.0;
static const CGFloat kCCBgThumbRightPadding = 16.0;

@implementation CCBGThumbnailButtonCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _thumbnailView = [[UIImageView alloc] init];
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        _thumbnailView.layer.cornerRadius = kCCBgThumbCornerRadius;
        _thumbnailView.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
        _thumbnailView.hidden = YES;
        [self.contentView addSubview:_thumbnailView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat thumbSize = kCCBgThumbSize;
    CGFloat x = CGRectGetWidth(self.contentView.bounds) - thumbSize - kCCBgThumbRightPadding;
    CGFloat y = (CGRectGetHeight(self.contentView.bounds) - thumbSize) / 2;
    self.thumbnailView.frame = CGRectMake(x, y, thumbSize, thumbSize);
}

- (void)setThumbnailImage:(UIImage *)image {
    if (image) {
        self.thumbnailView.image = image;
        self.thumbnailView.hidden = NO;
    } else {
        self.thumbnailView.image = nil;
        self.thumbnailView.hidden = YES;
    }
}

@end
