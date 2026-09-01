// CustomCCBg - 自定义控制中心背景
// 支持:图片背景 / 循环视频背景 / 毛玻璃强度调节

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import "../Shared/LGSharedSupport.h"

// MARK: - 常量

static NSString * const kCCBgPreferencesDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgEnabledKey = @"Enabled";
static NSString * const kCCBgBlurAlphaKey = @"BlurAlpha";
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";
static NSString * const kCCBgMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
static NSString * const kCCBgImageFileName = @"background.jpg";
static NSString * const kCCBgVideoFileName = @"background.mp4";
static NSString * const kCCBgMediaTypeKey = @"MediaType";

// MARK: - 自定义视频背景 View

@interface CustomCCBgVideoView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
- (void)loadVideoFromURL:(NSURL *)url;
- (void)play;
- (void)pause;
@end

@implementation CustomCCBgVideoView

+ (Class)layerClass {
    return [AVPlayerLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.playerLayer = (AVPlayerLayer *)self.layer;
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)loadVideoFromURL:(NSURL *)url {
    [self.looper disableLooping];
    self.looper = nil;
    self.player = nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
    self.playerLayer.player = self.player;
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
}

- (void)play {
    [self.player play];
}

- (void)pause {
    [self.player pause];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}

@end

// MARK: - 背景管理器

@interface CustomCCBgManager : NSObject
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIView *bgContainerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CustomCCBgVideoView *videoView;
@property (nonatomic, strong) UIVisualEffectView *blurOverlayView;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat blurAlpha;
@property (nonatomic, copy) NSString *mediaType;
+ (instancetype)sharedInstance;
- (void)reloadPreferences;
- (void)attachToHostView:(UIView *)view;
- (void)detach;
@end

@implementation CustomCCBgManager

+ (instancetype)sharedInstance {
    static CustomCCBgManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CustomCCBgManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(reloadPreferences)
                                                     name:kCCBgReloadNotification
                                                   object:nil];
        [self reloadPreferences];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadPreferences {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kCCBgPreferencesDomain];
    self.isEnabled = [defaults boolForKey:kCCBgEnabledKey];
    self.blurAlpha = [defaults floatForKey:kCCBgBlurAlphaKey];
    if (self.blurAlpha <= 0) self.blurAlpha = 0.3;

    if (self.bgContainerView) {
        [self updateBackgroundView];
    }
}

- (void)attachToHostView:(UIView *)view {
    if (self.hostView == view && self.bgContainerView.superview == view) {
        [self updateBackgroundView];
        return;
    }
    [self detach];
    self.hostView = view;

    // 创建背景容器,插入到 hostView 的最底层
    self.bgContainerView = [[UIView alloc] initWithFrame:view.bounds];
    self.bgContainerView.userInteractionEnabled = NO;
    [view insertSubview:self.bgContainerView atIndex:0];

    [self updateBackgroundView];
}

- (void)detach {
    if (self.videoView) {
        [self.videoView pause];
        [self.videoView removeFromSuperview];
        self.videoView = nil;
    }
    if (self.imageView) {
        [self.imageView removeFromSuperview];
        self.imageView = nil;
    }
    if (self.blurOverlayView) {
        [self.blurOverlayView removeFromSuperview];
        self.blurOverlayView = nil;
    }
    if (self.bgContainerView) {
        [self.bgContainerView removeFromSuperview];
        self.bgContainerView = nil;
    }
    self.hostView = nil;
}

- (void)updateBackgroundView {
    if (!self.bgContainerView || !self.hostView) return;

    self.bgContainerView.frame = self.hostView.bounds;

    if (!self.isEnabled) {
        self.bgContainerView.hidden = YES;
        [self detachMediaViews];
        return;
    }
    self.bgContainerView.hidden = NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mediaDir = kCCBgMediaDirectory;
    NSString *imagePath = [mediaDir stringByAppendingPathComponent:kCCBgImageFileName];
    NSString *videoPath = [mediaDir stringByAppendingPathComponent:kCCBgVideoFileName];

    BOOL hasImage = [fm fileExistsAtPath:imagePath];
    BOOL hasVideo = [fm fileExistsAtPath:videoPath];

    if (hasVideo) {
        [self detachImageView];
        if (!self.videoView) {
            self.videoView = [[CustomCCBgVideoView alloc] initWithFrame:self.bgContainerView.bounds];
            [self.bgContainerView insertSubview:self.videoView atIndex:0];
        }
        self.videoView.frame = self.bgContainerView.bounds;
        [self.videoView loadVideoFromURL:[NSURL fileURLWithPath:videoPath]];
        [self.videoView play];
    } else if (hasImage) {
        [self detachVideoView];
        if (!self.imageView) {
            self.imageView = [[UIImageView alloc] init];
            self.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.imageView.clipsToBounds = YES;
            [self.bgContainerView insertSubview:self.imageView atIndex:0];
        }
        self.imageView.frame = self.bgContainerView.bounds;
        self.imageView.image = [UIImage imageWithContentsOfFile:imagePath];
    } else {
        [self detachMediaViews];
    }

    // 毛玻璃叠加层 - 放在背景图片/视频之上
    if (!self.blurOverlayView) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        self.blurOverlayView = [[UIVisualEffectView alloc] initWithEffect:blur];
        self.blurOverlayView.userInteractionEnabled = NO;
        [self.bgContainerView addSubview:self.blurOverlayView];
    }
    self.blurOverlayView.frame = self.bgContainerView.bounds;
    self.blurOverlayView.alpha = self.blurAlpha;
}

- (void)detachMediaViews {
    [self detachVideoView];
    [self detachImageView];
}

- (void)detachVideoView {
    if (self.videoView) {
        [self.videoView pause];
        [self.videoView removeFromSuperview];
        self.videoView = nil;
    }
}

- (void)detachImageView {
    if (self.imageView) {
        [self.imageView removeFromSuperview];
        self.imageView = nil;
    }
}

@end

// MARK: - Hooks

// 主 hook: 控制中心 overlay controller
%hook CCUIModularControlCenterOverlayViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    [[CustomCCBgManager sharedInstance] attachToHostView:root];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIView *root = ((UIViewController *)self).view;
    [[CustomCCBgManager sharedInstance] attachToHostView:root];
}

- (void)dealloc {
    [[CustomCCBgManager sharedInstance] detach];
    %orig;
}

%end

// 备用 hook: CC 容器视图
%hook CCUIModularControlCenterContainerView

- (void)layoutSubviews {
    %orig;
    UIView *host = [(UIView *)self superview];
    if (host) {
        [[CustomCCBgManager sharedInstance] attachToHostView:host];
    }
}

%end
