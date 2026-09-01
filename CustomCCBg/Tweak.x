// CustomCCBg - 自定义控制中心背景
// 支持:图片背景 / 循环视频背景 / 毛玻璃强度调节
// 两种模式: 全屏背景 (0) / 模块级背景 (1)
// 性能优化: 缓存媒体文件、延迟加载、不可见时暂停视频

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import "../Shared/LGSharedSupport.h"

// MARK: - 常量

static NSString * const kCCBgPreferencesDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgEnabledKey = @"Enabled";
static NSString * const kCCBgBlurAlphaKey = @"BlurAlpha";
static NSString * const kCCBgBackgroundModeKey = @"BackgroundMode"; // 0=全屏, 1=模块级
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";
static NSString * const kCCBgMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
static NSString * const kCCBgImageFileName = @"background.jpg";
static NSString * const kCCBgVideoFileName = @"background.mp4";

// 模式枚举
typedef NS_ENUM(NSInteger, CCBgMode) {
    kCCBgModeFullscreen = 0,
    kCCBgModePerModule  = 1,
};

// MARK: - 自定义视频背景 View

@interface CustomCCBgVideoView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, copy) NSURL *loadedURL;
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
    // 如果已经加载了同一个 URL,不重复加载
    if (self.loadedURL && [self.loadedURL isEqual:url] && self.player) return;

    [self.looper disableLooping];
    self.looper = nil;
    self.player = nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
    self.playerLayer.player = self.player;
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
    self.loadedURL = [url copy];
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

// MARK: - 模块级背景视图

@interface CCBgModuleBackground : NSObject
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIVisualEffectView *blurOverlay;
- (void)updateWithImage:(UIImage *)image blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)updateWithPlayer:(AVQueuePlayer *)player blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)setBlurHidden:(BOOL)hidden;
- (void)cleanup;
@end

@implementation CCBgModuleBackground

- (instancetype)init {
    self = [super init];
    if (self) {
        _containerView = [[UIView alloc] init];
        _containerView.userInteractionEnabled = NO;
        _containerView.clipsToBounds = YES;
    }
    return self;
}

- (void)updateWithImage:(UIImage *)image blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    self.containerView.frame = frame;
    self.containerView.layer.cornerRadius = radius;
    self.containerView.layer.masksToBounds = YES;

    if (!_imageView) {
        _imageView = [[UIImageView alloc] init];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [_containerView insertSubview:_imageView atIndex:0];
    }
    // 只在图片不同时更新
    if (_imageView.image != image) {
        _imageView.image = image;
    }
    _imageView.frame = _containerView.bounds;

    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }

    if (!_blurOverlay) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blurOverlay = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurOverlay.userInteractionEnabled = NO;
        [_containerView addSubview:_blurOverlay];
    }
    _blurOverlay.frame = _containerView.bounds;
    _blurOverlay.alpha = blurAlpha;
}

- (void)updateWithPlayer:(AVQueuePlayer *)player blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    self.containerView.frame = frame;
    self.containerView.layer.cornerRadius = radius;
    self.containerView.layer.masksToBounds = YES;

    if (_imageView) {
        [_imageView removeFromSuperview];
        _imageView = nil;
    }

    if (!_playerLayer) {
        _playerLayer = [AVPlayerLayer layer];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [_containerView.layer insertSublayer:_playerLayer atIndex:0];
    }
    _playerLayer.frame = _containerView.bounds;
    // 只在 player 变化时更新
    if (_playerLayer.player != player) {
        _playerLayer.player = player;
    }

    if (!_blurOverlay) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blurOverlay = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurOverlay.userInteractionEnabled = NO;
        [_containerView addSubview:_blurOverlay];
    }
    _blurOverlay.frame = _containerView.bounds;
    _blurOverlay.alpha = blurAlpha;
}

- (void)setBlurHidden:(BOOL)hidden {
    _blurOverlay.hidden = hidden;
}

- (void)cleanup {
    if (_imageView) {
        [_imageView removeFromSuperview];
        _imageView = nil;
    }
    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }
    if (_blurOverlay) {
        [_blurOverlay removeFromSuperview];
        _blurOverlay = nil;
    }
    if (_containerView) {
        [_containerView removeFromSuperview];
        _containerView = nil;
    }
}

@end

// MARK: - 背景管理器

@interface CustomCCBgManager : NSObject

// 全屏模式属性
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIView *bgContainerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CustomCCBgVideoView *videoView;
@property (nonatomic, strong) UIVisualEffectView *blurOverlayView;

// 模块级模式属性
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CCBgModuleBackground *> *moduleBackgrounds;
@property (nonatomic, strong) AVQueuePlayer *sharedVideoPlayer;
@property (nonatomic, strong) AVPlayerLooper *sharedLooper;

// 缓存属性
@property (nonatomic, strong) UIImage *cachedImage;
@property (nonatomic, assign) BOOL cachedHasImage;
@property (nonatomic, assign) BOOL cachedHasVideo;
@property (nonatomic, strong) NSURL *cachedVideoURL;
@property (nonatomic, assign) BOOL mediaCacheValid;

// 状态
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat blurAlpha;
@property (nonatomic, assign) CCBgMode backgroundMode;
@property (nonatomic, assign) BOOL isControlCenterVisible;

+ (instancetype)sharedInstance;
- (void)reloadPreferences;
- (void)attachToHostView:(UIView *)view;
- (void)attachToModuleView:(UIView *)moduleView;
- (void)setControlCenterVisible:(BOOL)visible;
- (void)detachAllModules;
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
        _moduleBackgrounds = [NSMutableDictionary dictionary];
        _isControlCenterVisible = NO;
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
    NSInteger mode = [defaults integerForKey:kCCBgBackgroundModeKey];
    CCBgMode oldMode = self.backgroundMode;
    self.backgroundMode = (mode == kCCBgModePerModule) ? kCCBgModePerModule : kCCBgModeFullscreen;

    // 使媒体缓存失效,下次使用时重新检查
    self.mediaCacheValid = NO;
    self.cachedImage = nil;
    self.cachedVideoURL = nil;

    // 如果切换了模式,需要清理旧模式的资源
    if (oldMode != self.backgroundMode) {
        if (self.backgroundMode == kCCBgModePerModule) {
            [self detachFullscreenViews];
        } else {
            [self detachAllModules];
        }
    }

    if (self.bgContainerView && self.backgroundMode == kCCBgModeFullscreen) {
        [self updateBackgroundView];
    }
}

#pragma mark - 媒体缓存

- (void)ensureMediaCacheValid {
    if (self.mediaCacheValid) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *imagePath = [kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgImageFileName];
    NSString *videoPath = [kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgVideoFileName];

    self.cachedHasImage = [fm fileExistsAtPath:imagePath];
    self.cachedHasVideo = [fm fileExistsAtPath:videoPath];
    if (self.cachedHasVideo) {
        self.cachedVideoURL = [NSURL fileURLWithPath:videoPath];
    } else {
        self.cachedVideoURL = nil;
    }
    // 清除图片缓存,下次访问时重新加载
    self.cachedImage = nil;
    self.mediaCacheValid = YES;
}

- (UIImage *)getCachedImage {
    if (self.cachedImage) return self.cachedImage;
    [self ensureMediaCacheValid];
    if (self.cachedHasImage) {
        NSString *imagePath = [kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgImageFileName];
        self.cachedImage = [UIImage imageWithContentsOfFile:imagePath];
    }
    return self.cachedImage;
}

- (AVQueuePlayer *)getSharedVideoPlayer {
    [self ensureMediaCacheValid];
    if (!self.cachedHasVideo) return nil;

    if (!self.sharedVideoPlayer) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.cachedVideoURL];
        self.sharedVideoPlayer = [AVQueuePlayer queuePlayerWithItems:@[item]];
        self.sharedVideoPlayer.muted = YES;
        self.sharedVideoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        self.sharedLooper = [AVPlayerLooper playerLooperWithPlayer:self.sharedVideoPlayer templateItem:item];
    }
    return self.sharedVideoPlayer;
}

#pragma mark - 可见性控制

- (void)setControlCenterVisible:(BOOL)visible {
    if (self.isControlCenterVisible == visible) return;
    self.isControlCenterVisible = visible;

    if (visible) {
        // 控制中心可见:恢复播放
        if (self.backgroundMode == kCCBgModeFullscreen) {
            if (self.videoView && self.isEnabled) [self.videoView play];
            if (self.blurOverlayView) self.blurOverlayView.hidden = NO;
        } else {
            // 模块级模式
            if (self.sharedVideoPlayer && self.isEnabled && self.sharedVideoPlayer.rate == 0) {
                [self.sharedVideoPlayer play];
            }
            for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                [bg setBlurHidden:NO];
            }
        }
    } else {
        // 控制中心不可见:暂停视频,隐藏模糊
        if (self.backgroundMode == kCCBgModeFullscreen) {
            if (self.videoView) [self.videoView pause];
            if (self.blurOverlayView) self.blurOverlayView.hidden = YES;
        } else {
            if (self.sharedVideoPlayer) [self.sharedVideoPlayer pause];
            for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                [bg setBlurHidden:YES];
            }
        }
    }
}

#pragma mark - 全屏模式

- (void)attachToHostView:(UIView *)view {
    if (self.backgroundMode == kCCBgModePerModule) {
        [self detachFullscreenViews];
        return;
    }

    if (self.hostView == view && self.bgContainerView.superview == view) {
        [self updateBackgroundView];
        return;
    }
    [self detachFullscreenViews];
    self.hostView = view;

    self.bgContainerView = [[UIView alloc] initWithFrame:view.bounds];
    self.bgContainerView.userInteractionEnabled = NO;
    self.bgContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view insertSubview:self.bgContainerView atIndex:0];

    [self updateBackgroundView];
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

    [self ensureMediaCacheValid];

    if (self.cachedHasVideo) {
        [self detachImageView];
        if (!self.videoView) {
            self.videoView = [[CustomCCBgVideoView alloc] initWithFrame:self.bgContainerView.bounds];
            self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView insertSubview:self.videoView atIndex:0];
        }
        self.videoView.frame = self.bgContainerView.bounds;
        // 只加载一次,后续不再重复加载
        [self.videoView loadVideoFromURL:self.cachedVideoURL];
        // 只在控制中心可见时播放
        if (self.isControlCenterVisible) {
            [self.videoView play];
        }
    } else if (self.cachedHasImage) {
        [self detachVideoView];
        if (!self.imageView) {
            self.imageView = [[UIImageView alloc] init];
            self.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.imageView.clipsToBounds = YES;
            self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView insertSubview:self.imageView atIndex:0];
        }
        self.imageView.frame = self.bgContainerView.bounds;
        // 使用缓存图片,不重复读取磁盘
        UIImage *image = [self getCachedImage];
        if (self.imageView.image != image) {
            self.imageView.image = image;
        }
    } else {
        [self detachMediaViews];
    }

    // 毛玻璃叠加层
    if (!self.blurOverlayView) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        self.blurOverlayView = [[UIVisualEffectView alloc] initWithEffect:blur];
        self.blurOverlayView.userInteractionEnabled = NO;
        self.blurOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.bgContainerView addSubview:self.blurOverlayView];
    }
    self.blurOverlayView.frame = self.bgContainerView.bounds;
    self.blurOverlayView.alpha = self.blurAlpha;
    // 不可见时隐藏模糊层以节省 GPU
    self.blurOverlayView.hidden = !self.isControlCenterVisible;
}

- (void)detachFullscreenViews {
    [self detachMediaViews];
    if (self.bgContainerView) {
        [self.bgContainerView removeFromSuperview];
        self.bgContainerView = nil;
    }
    if (self.blurOverlayView) {
        [self.blurOverlayView removeFromSuperview];
        self.blurOverlayView = nil;
    }
    self.hostView = nil;
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

#pragma mark - 模块级模式

- (void)attachToModuleView:(UIView *)moduleView {
    if (self.backgroundMode != kCCBgModePerModule) return;

    if (!self.isEnabled) {
        NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
        CCBgModuleBackground *bg = self.moduleBackgrounds[key];
        if (bg) {
            [bg cleanup];
            [self.moduleBackgrounds removeObjectForKey:key];
        }
        return;
    }

    [self ensureMediaCacheValid];

    NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
    CCBgModuleBackground *bg = self.moduleBackgrounds[key];
    if (!bg) {
        bg = [[CCBgModuleBackground alloc] init];
        [moduleView insertSubview:bg.containerView atIndex:0];
        self.moduleBackgrounds[key] = bg;
    }

    if (bg.containerView.superview != moduleView) {
        [moduleView insertSubview:bg.containerView atIndex:0];
    }

    // 如果尺寸没有变化,跳过更新
    CGRect frame = moduleView.bounds;
    if (CGRectEqualToRect(bg.containerView.frame, frame) && bg.containerView.layer.cornerRadius > 0) {
        // 尺寸未变,只确保播放状态正确
        if (self.cachedHasVideo && self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
            [self.sharedVideoPlayer play];
        }
        return;
    }

    CGFloat cornerRadius = moduleView.layer.cornerRadius;
    if (cornerRadius <= 0) {
        CGFloat minDim = fmin(CGRectGetWidth(moduleView.bounds), CGRectGetHeight(moduleView.bounds));
        cornerRadius = minDim * 0.25;
    }

    if (self.cachedHasVideo) {
        AVQueuePlayer *player = [self getSharedVideoPlayer];
        if (player) {
            [bg updateWithPlayer:player blurAlpha:self.blurAlpha frame:frame cornerRadius:cornerRadius];
            if (self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
                [self.sharedVideoPlayer play];
            }
        }
    } else if (self.cachedHasImage) {
        UIImage *image = [self getCachedImage];
        if (image) {
            [bg updateWithImage:image blurAlpha:self.blurAlpha frame:frame cornerRadius:cornerRadius];
        }
    } else {
        [bg cleanup];
        [self.moduleBackgrounds removeObjectForKey:key];
    }
}

- (void)detachAllModules {
    for (NSNumber *key in self.moduleBackgrounds.allKeys) {
        CCBgModuleBackground *bg = self.moduleBackgrounds[key];
        [bg cleanup];
    }
    [self.moduleBackgrounds removeAllObjects];

    if (self.sharedVideoPlayer) {
        [self.sharedVideoPlayer pause];
        self.sharedVideoPlayer = nil;
    }
    self.sharedLooper = nil;
    self.cachedImage = nil;
}

- (void)detach {
    [self detachFullscreenViews];
    [self detachAllModules];
}

@end

// MARK: - Hooks

// 主 hook: 控制中心 overlay controller
%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:YES];
    UIView *root = ((UIViewController *)self).view;
    [[CustomCCBgManager sharedInstance] attachToHostView:root];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:NO];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:NO];
}

- (void)dealloc {
    [[CustomCCBgManager sharedInstance] detach];
    %orig;
}

%end

// 备用 hook: CC 容器视图 (仅全屏模式)
%hook CCUIModularControlCenterContainerView

- (void)layoutSubviews {
    %orig;
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if (mgr.backgroundMode == kCCBgModeFullscreen) {
        UIView *host = [(UIView *)self superview];
        if (host) {
            [mgr attachToHostView:host];
        }
    }
}

%end

// 模块级 hook: 控制中心模块容器 (仅模块级模式)
%hook CCUIContentModuleContainerView

- (void)layoutSubviews {
    %orig;
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if (mgr.backgroundMode == kCCBgModePerModule) {
        [mgr attachToModuleView:(UIView *)self];
    }
}

- (void)didMoveToWindow {
    %orig;
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if (mgr.backgroundMode == kCCBgModePerModule && [(UIView *)self window]) {
        [mgr attachToModuleView:(UIView *)self];
    }
}

%end
