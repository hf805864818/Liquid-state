// CustomCCBg - 自定义控制中心背景
// clean-room implementation
// 支持:图片背景 / 循环视频背景 / 毛玻璃强度调节
// 注入点:SpringBoard 的 CC 背景视图(类名需真机确认)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// MARK: - 常量

static NSString * const kCCBgPreferencesDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgEnabledKey = @"Enabled";
static NSString * const kCCBgBlurAlphaKey = @"BlurAlpha";
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";
static NSString * const kCCBgMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
static NSString * const kCCBgImageFileName = @"background.jpg";
static NSString * const kCCBgVideoFileName = @"background.mp4";
static NSString * const kCCBgMediaTypeKey = @"MediaType"; // "image" / "video" / "none"

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
@property (nonatomic, strong) UIView *backgroundContainerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CustomCCBgVideoView *videoView;
@property (nonatomic, strong) UIView *blurOverlayView;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat blurAlpha;
+ (instancetype)sharedInstance;
- (void)reloadPreferences;
- (void)attachToContainerView:(UIView *)view;
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
    if (self.blurAlpha <= 0) self.blurAlpha = 0.3; // 默认值
    
    if (self.backgroundContainerView) {
        [self updateBackgroundView];
    }
}

- (void)attachToContainerView:(UIView *)view {
    if (self.backgroundContainerView == view) return;
    [self detach];
    self.backgroundContainerView = view;
    [self updateBackgroundView];
}

- (void)detach {
    if (self.imageView) {
        [self.imageView removeFromSuperview];
        self.imageView = nil;
    }
    if (self.videoView) {
        [self.videoView pause];
        [self.videoView removeFromSuperview];
        self.videoView = nil;
    }
    if (self.blurOverlayView) {
        [self.blurOverlayView removeFromSuperview];
        self.blurOverlayView = nil;
    }
    self.backgroundContainerView = nil;
}

- (void)updateBackgroundView {
    if (!self.backgroundContainerView) return;
    
    if (!self.isEnabled) {
        [self detach];
        return;
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mediaDir = kCCBgMediaDirectory;
    NSString *imagePath = [mediaDir stringByAppendingPathComponent:kCCBgImageFileName];
    NSString *videoPath = [mediaDir stringByAppendingPathComponent:kCCBgVideoFileName];
    
    BOOL hasImage = [fm fileExistsAtPath:imagePath];
    BOOL hasVideo = [fm fileExistsAtPath:videoPath];
    
    // 优先视频,其次图片
    if (hasVideo) {
        if (!self.videoView) {
            self.videoView = [[CustomCCBgVideoView alloc] init];
            [self.backgroundContainerView insertSubview:self.videoView atIndex:0];
        }
        if (self.imageView) {
            [self.imageView removeFromSuperview];
            self.imageView = nil;
        }
        self.videoView.frame = self.backgroundContainerView.bounds;
        [self.videoView loadVideoFromURL:[NSURL fileURLWithPath:videoPath]];
        [self.videoView play];
    } else if (hasImage) {
        if (!self.imageView) {
            self.imageView = [[UIImageView alloc] init];
            self.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.imageView.clipsToBounds = YES;
            [self.backgroundContainerView insertSubview:self.imageView atIndex:0];
        }
        if (self.videoView) {
            [self.videoView pause];
            [self.videoView removeFromSuperview];
            self.videoView = nil;
        }
        self.imageView.frame = self.backgroundContainerView.bounds;
        self.imageView.image = [UIImage imageWithContentsOfFile:imagePath];
    } else {
        // 没有媒体文件,只显示模糊叠加层作为占位
        if (self.imageView) { [self.imageView removeFromSuperview]; self.imageView = nil; }
        if (self.videoView) { [self.videoView pause]; [self.videoView removeFromSuperview]; self.videoView = nil; }
    }
    
    // 模糊叠加层
    if (!self.blurOverlayView && self.isEnabled) {
        self.blurOverlayView = [[UIView alloc] init];
        self.blurOverlayView.backgroundColor = [UIColor blackColor];
        [self.backgroundContainerView addSubview:self.blurOverlayView];
    }
    self.blurOverlayView.frame = self.backgroundContainerView.bounds;
    self.blurOverlayView.alpha = self.blurAlpha;
    // 把 blur 叠在最上层,但在 CC 内容之下
    // 注意:实际层级关系需要根据注入的具体 view 调整
}

@end

// MARK: - Hook
// 注意:以下类名是候选,需真机调试确认准确类名
// iOS 16+: CCUIModularControlCenterContainerView 或 CCUILayoutView
// iOS 15-: CCUIBackdropView

%hook CCUIModularControlCenterContainerView

- (void)layoutSubviews {
    %orig;
    [[CustomCCBgManager sharedInstance] attachToContainerView:(UIView *)self];
}

- (void)dealloc {
    [[CustomCCBgManager sharedInstance] detach];
    %orig;
}

%end

// 备用 hook:如果 CCUIModularControlCenterContainerView 不对,试这个
// %hook CCUIBackdropView
// - (void)didMoveToWindow {
//     %orig;
//     if (self.window) {
//         [[CustomCCBgManager sharedInstance] attachToContainerView:self];
//     }
// }
// - (void)dealloc {
//     [[CustomCCBgManager sharedInstance] detach];
//     %orig;
// }
// %end
