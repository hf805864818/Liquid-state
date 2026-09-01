// CustomCCBg - 自定义控制中心背景
// 支持:图片背景 / 循环视频背景 / 毛玻璃强度调节
// 两种模式: 全屏背景 (0) / 模块级背景 (1)
// 性能优化:
//   A. 图片背景: 预渲染模糊,用静态图替代 UIVisualEffectView 实时模糊
//   B. 视频背景: 限制 30fps,降低解码+渲染功耗
//   C. 模块级模式: 离屏模块不渲染视频层
//   D. layoutSubviews: 节流去重,避免重复更新
//   E. 模糊图降采样: 模糊前先缩放到 1/2,GPU 计算量减少 75%
//   H. 延迟释放: 控制中心关闭 30 秒后释放视频资源,降低后台功耗

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreImage/CoreImage.h>
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

// 优化 B: 视频目标帧率 30fps,观感几乎无差别,解码+渲染功耗降低约40%
static const NSInteger kCCBgTargetVideoFPS = 30;

// MARK: - 图片预渲染模糊工具

// 优化 E: 模糊前降采样 — 先缩放到 1/2 再模糊，GPU 计算量减少 75%，视觉几乎无差异
static const CGFloat kCCBgBlurDownscaleFactor = 0.5;

static UIImage *ccbgBlurredImage(UIImage *image, CGFloat blurRadius) {
    if (!image || blurRadius <= 0.01) return image;

    @autoreleasepool {
        // 优化 E: 降采样后再模糊，大幅减少 GPU 计算量和内存占用
        CGFloat scale = kCCBgBlurDownscaleFactor;
        CGSize originalSize = image.size;
        CGSize downscaledSize = CGSizeMake(originalSize.width * scale, originalSize.height * scale);
        CGFloat scaledRadius = blurRadius * scale; // 模糊半径按比例缩放

        // 第一步：将原图缩放到目标尺寸
        UIGraphicsBeginImageContextWithOptions(downscaledSize, YES, 1.0);
        [image drawInRect:CGRectMake(0, 0, downscaledSize.width, downscaledSize.height)];
        UIImage *downscaledImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (!downscaledImage) return image;

        // 第二步：对缩小后的图做模糊
        CIImage *inputImage = [CIImage imageWithCGImage:downscaledImage.CGImage];
        if (!inputImage) return image;

        CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
        if (!blurFilter) return image;

        [blurFilter setValue:inputImage forKey:kCIInputImageKey];
        [blurFilter setValue:@(scaledRadius) forKey:kCIInputRadiusKey];

        CIImage *outputImage = blurFilter.outputImage;
        if (!outputImage) return image;

        CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        CGRect extent = [inputImage extent];
        CGImageRef cgImage = [context createCGImage:outputImage fromRect:extent];
        if (!cgImage) return image;

        UIImage *blurredSmall = [UIImage imageWithCGImage:cgImage scale:image.scale orientation:image.imageOrientation];
        CGImageRelease(cgImage);

        if (!blurredSmall) return image;

        // 第三步：放大回原尺寸（模糊后放大几乎看不出失真）
        UIGraphicsBeginImageContextWithOptions(originalSize, YES, image.scale);
        [blurredSmall drawInRect:CGRectMake(0, 0, originalSize.width, originalSize.height)];
        UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        return result ?: image;
    }
}

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

    // 优化 B: 限制视频帧率到 30fps
    // 使用运行时 KVC + NSValue 封装,兼容低版本 SDK
    if ([item respondsToSelector:NSSelectorFromString(@"setPreferredFrameRateRange:")]) {
        // AVFrameRateRange 结构体: minFrameRate(float) + maxFrameRate(float)
        typedef struct {
            float min;
            float max;
        } CCFrameRateRange;
        CCFrameRateRange range;
        range.min = 1.0f;
        range.max = (float)kCCBgTargetVideoFPS;
        NSValue *rangeValue = [NSValue valueWithBytes:&range objCType:@encode(CCFrameRateRange)];
        [item setValue:rangeValue forKey:@"preferredFrameRateRange"];
    }

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
@property (nonatomic, strong) UIImageView *imageView; // 预渲染后的模糊图 或 静态图
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
// 移除 blurOverlay,改用预渲染模糊图替代实时模糊
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)updateWithPlayer:(AVQueuePlayer *)player blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)setVideoLayerHidden:(BOOL)hidden; // 优化 C: 离屏模块隐藏视频层
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

// 图片模式: 使用预渲染模糊图替代 UIVisualEffectView 实时模糊
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    self.containerView.frame = frame;
    self.containerView.layer.cornerRadius = radius;
    self.containerView.layer.masksToBounds = YES;

    // 移除视频层
    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }

    // 显示预渲染模糊图(或原图,如果 blurAlpha=0)
    UIImage *displayImage = blurredImage ?: image;
    if (!_imageView) {
        _imageView = [[UIImageView alloc] init];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [_containerView insertSubview:_imageView atIndex:0];
    }
    if (_imageView.image != displayImage) {
        _imageView.image = displayImage;
    }
    _imageView.frame = _containerView.bounds;
}

// 视频模式: 视频层 + 底部一层静态模糊图(替代 UIVisualEffectView)
- (void)updateWithPlayer:(AVQueuePlayer *)player blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    self.containerView.frame = frame;
    self.containerView.layer.cornerRadius = radius;
    self.containerView.layer.masksToBounds = YES;

    // 优化 C: 确保有 imageView 作为底层(离屏隐藏视频层时也能显示静态模糊图)
    if (!_imageView) {
        _imageView = [[UIImageView alloc] init];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [_containerView insertSubview:_imageView atIndex:0];
    }
    if (blurredImage && _imageView.image != blurredImage) {
        _imageView.image = blurredImage;
    }
    _imageView.frame = _containerView.bounds;

    // 视频层
    if (!_playerLayer) {
        _playerLayer = [AVPlayerLayer layer];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [_containerView.layer addSublayer:_playerLayer];
    }
    _playerLayer.frame = _containerView.bounds;
    if (_playerLayer.player != player) {
        _playerLayer.player = player;
    }
}

- (void)setVideoLayerHidden:(BOOL)hidden {
    _playerLayer.hidden = hidden;
    // 隐藏视频层时 imageView 自动显示作为占位(已经在底下了)
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
// 移除 blurOverlayView,改用预渲染模糊图

// 模块级模式属性
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CCBgModuleBackground *> *moduleBackgrounds;
@property (nonatomic, strong) AVQueuePlayer *sharedVideoPlayer;
@property (nonatomic, strong) AVPlayerLooper *sharedLooper;

// 缓存属性
@property (nonatomic, strong) UIImage *cachedImage;
@property (nonatomic, strong) UIImage *cachedBlurredImage; // 优化 A: 预渲染模糊图缓存
@property (nonatomic, assign) CGFloat cachedBlurRadius;
@property (nonatomic, assign) BOOL cachedHasImage;
@property (nonatomic, assign) BOOL cachedHasVideo;
@property (nonatomic, strong) NSURL *cachedVideoURL;
@property (nonatomic, assign) BOOL mediaCacheValid;

// 状态
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat blurAlpha;
@property (nonatomic, assign) CCBgMode backgroundMode;
@property (nonatomic, assign) BOOL isControlCenterVisible;
// 优化 H: 控制中心关闭后延迟释放视频资源
@property (nonatomic, strong) dispatch_source_t deferredReleaseTimer;

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
    self.cachedBlurredImage = nil; // 模糊缓存也失效
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
    self.cachedImage = nil;
    self.cachedBlurredImage = nil;
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

// 优化 A: 获取预渲染模糊图
// blurRadius 映射: blurAlpha 0~1 → 模糊半径 0~20
- (UIImage *)getCachedBlurredImage {
    [self ensureMediaCacheValid];
    if (!self.cachedHasImage) return nil;

    CGFloat targetRadius = self.blurAlpha * 20.0; // 最大 20px 模糊

    // 如果已有缓存且模糊半径匹配,直接返回
    if (self.cachedBlurredImage && fabs(self.cachedBlurRadius - targetRadius) < 0.5) {
        return self.cachedBlurredImage;
    }

    UIImage *original = [self getCachedImage];
    if (!original) return nil;

    // 预渲染模糊
    self.cachedBlurredImage = ccbgBlurredImage(original, targetRadius);
    self.cachedBlurRadius = targetRadius;
    return self.cachedBlurredImage;
}

- (AVQueuePlayer *)getSharedVideoPlayer {
    [self ensureMediaCacheValid];
    if (!self.cachedHasVideo) return nil;

    if (!self.sharedVideoPlayer) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.cachedVideoURL];
        // 优化 B: 限制视频帧率到 30fps
        // 使用运行时 KVC + NSValue 封装,兼容低版本 SDK
        if ([item respondsToSelector:NSSelectorFromString(@"setPreferredFrameRateRange:")]) {
            typedef struct {
                float min;
                float max;
            } CCFrameRateRange;
            CCFrameRateRange range;
            range.min = 1.0f;
            range.max = (float)kCCBgTargetVideoFPS;
            NSValue *rangeValue = [NSValue valueWithBytes:&range objCType:@encode(CCFrameRateRange)];
            [item setValue:rangeValue forKey:@"preferredFrameRateRange"];
        }
        self.sharedVideoPlayer = [AVQueuePlayer queuePlayerWithItems:@[item]];
        self.sharedVideoPlayer.muted = YES;
        self.sharedVideoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        self.sharedLooper = [AVPlayerLooper playerLooperWithPlayer:self.sharedVideoPlayer templateItem:item];
    }
    return self.sharedVideoPlayer;
}

#pragma mark - 可见性控制

// 优化 H: 控制中心关闭后延迟释放视频的时间（秒）
static const NSTimeInterval kCCBgDeferredReleaseDelay = 30.0;

- (void)cancelDeferredRelease {
    if (self.deferredReleaseTimer) {
        dispatch_source_cancel(self.deferredReleaseTimer);
        self.deferredReleaseTimer = nil;
    }
}

- (void)scheduleDeferredRelease {
    [self cancelDeferredRelease];
    if (!self.cachedHasVideo) return;

    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCCBgDeferredReleaseDelay * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.isControlCenterVisible) return;

        // 延迟释放：完全销毁视频资源，降低后台内存和解码器功耗
        if (strongSelf.backgroundMode == kCCBgModeFullscreen) {
            [strongSelf detachVideoView];
        } else {
            if (strongSelf.sharedVideoPlayer) {
                [strongSelf.sharedVideoPlayer pause];
                strongSelf.sharedVideoPlayer = nil;
            }
            strongSelf.sharedLooper = nil;
            // 隐藏所有模块视频层（保留 imageView 作为静态占位）
            for (CCBgModuleBackground *bg in strongSelf.moduleBackgrounds.allValues) {
                [bg setVideoLayerHidden:YES];
            }
        }
        strongSelf.deferredReleaseTimer = nil;
    });
    dispatch_resume(timer);
    self.deferredReleaseTimer = timer;
}

- (void)setControlCenterVisible:(BOOL)visible {
    if (self.isControlCenterVisible == visible) return;
    self.isControlCenterVisible = visible;

    if (visible) {
        // 控制中心可见:取消延迟释放，恢复播放
        [self cancelDeferredRelease];
        if (self.backgroundMode == kCCBgModeFullscreen) {
            if (self.videoView && self.isEnabled) [self.videoView play];
            else if (self.isEnabled && self.cachedHasVideo) {
                // 视频已被延迟释放，重新加载
                [self updateBackgroundView];
            }
        } else {
            // 模块级模式
            if (self.sharedVideoPlayer && self.isEnabled && self.sharedVideoPlayer.rate == 0) {
                [self.sharedVideoPlayer play];
            } else if (self.isEnabled && self.cachedHasVideo && !self.sharedVideoPlayer) {
                // 视频已被延迟释放，重新加载共享 player
                AVQueuePlayer *player = [self getSharedVideoPlayer];
                if (player) {
                    [player play];
                    // 更新所有模块的视频层
                    for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                        [bg setVideoLayerHidden:NO];
                    }
                }
            }
            // 优化 C: 确保所有模块视频层可见
            for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                [bg setVideoLayerHidden:NO];
            }
        }
    } else {
        // 控制中心不可见:暂停视频，并安排延迟释放
        if (self.backgroundMode == kCCBgModeFullscreen) {
            if (self.videoView) [self.videoView pause];
        } else {
            if (self.sharedVideoPlayer) [self.sharedVideoPlayer pause];
        }
        // 优化 H: 30秒后仍未打开控制中心，则释放视频资源
        [self scheduleDeferredRelease];
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
        [self.videoView loadVideoFromURL:self.cachedVideoURL];
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
        // 优化 A: 显示预渲染模糊图替代实时模糊
        UIImage *displayImage = [self getCachedBlurredImage] ?: [self getCachedImage];
        if (self.imageView.image != displayImage) {
            self.imageView.image = displayImage;
        }
    } else {
        [self detachMediaViews];
    }
}

- (void)detachFullscreenViews {
    [self detachMediaViews];
    if (self.bgContainerView) {
        [self.bgContainerView removeFromSuperview];
        self.bgContainerView = nil;
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
    UIView *superview = moduleView.superview;
    if (!superview) return;

    if (!bg) {
        bg = [[CCBgModuleBackground alloc] init];
        // 背景放到模块的父视图中，层级在模块下面
        [superview insertSubview:bg.containerView belowSubview:moduleView];
        self.moduleBackgrounds[key] = bg;
    }

    // 如果父视图变了，重新挂载
    if (bg.containerView.superview != superview) {
        [bg.containerView removeFromSuperview];
        [superview insertSubview:bg.containerView belowSubview:moduleView];
    }

    // 背景 frame 是模块在父视图中的 frame（模块后面，尺寸位置与模块一致）
    CGRect moduleFrameInSuperview = moduleView.frame;
    CGFloat cornerRadius = moduleView.layer.cornerRadius;
    if (cornerRadius <= 0) {
        CGFloat minDim = fmin(CGRectGetWidth(moduleView.bounds), CGRectGetHeight(moduleView.bounds));
        cornerRadius = minDim * 0.25;
    }

    // 优化 D: 如果尺寸和圆角都没变，跳过更新
    if (CGRectEqualToRect(bg.containerView.frame, moduleFrameInSuperview) &&
        fabs(bg.containerView.layer.cornerRadius - cornerRadius) < 0.1) {
        // 尺寸未变,只确保播放状态正确
        if (self.cachedHasVideo && self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
            [self.sharedVideoPlayer play];
        }
        // 优化 C: 检查是否在可见区域内
        BOOL isVisible = [self isModuleViewVisible:moduleView];
        [bg setVideoLayerHidden:!isVisible];
        // 同步隐藏状态
        bg.containerView.hidden = moduleView.hidden;
        bg.containerView.alpha = moduleView.alpha;
        return;
    }

    // 优化 A: 获取预渲染模糊图
    UIImage *blurredImage = [self getCachedBlurredImage];

    if (self.cachedHasVideo) {
        AVQueuePlayer *player = [self getSharedVideoPlayer];
        if (player) {
            [bg updateWithPlayer:player blurredImage:blurredImage frame:moduleFrameInSuperview cornerRadius:cornerRadius];
            if (self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
                [self.sharedVideoPlayer play];
            }
            // 优化 C: 离屏模块隐藏视频层
            BOOL isVisible = [self isModuleViewVisible:moduleView];
            [bg setVideoLayerHidden:!isVisible];
        }
    } else if (self.cachedHasImage) {
        UIImage *image = [self getCachedImage];
        if (image) {
            [bg updateWithImage:image blurredImage:blurredImage frame:moduleFrameInSuperview cornerRadius:cornerRadius];
        }
    } else {
        [bg cleanup];
        [self.moduleBackgrounds removeObjectForKey:key];
    }

    // 同步隐藏/透明度
    bg.containerView.hidden = moduleView.hidden;
    bg.containerView.alpha = moduleView.alpha;
}

// 优化 C: 判断模块是否在控制中心可见区域内
- (BOOL)isModuleViewVisible:(UIView *)moduleView {
    if (!moduleView.window) return NO;
    UIView *rootView = self.hostView ?: moduleView.superview;
    while (rootView.superview) rootView = rootView.superview;
    CGRect moduleFrame = [moduleView convertRect:moduleView.bounds toView:rootView];
    CGRect rootBounds = rootView.bounds;
    // 模块有 30% 以上在可见区域内就算可见
    CGRect intersection = CGRectIntersection(moduleFrame, rootBounds);
    CGFloat visibleArea = intersection.size.width * intersection.size.height;
    CGFloat totalArea = moduleFrame.size.width * moduleFrame.size.height;
    if (totalArea <= 0) return NO;
    return (visibleArea / totalArea) > 0.3;
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
    self.cachedBlurredImage = nil;
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

// MARK: - 构造函数

%ctor {
    // 确保 CustomCCBgManager 单例延迟初始化
    dispatch_async(dispatch_get_main_queue(), ^{
        [CustomCCBgManager sharedInstance];
    });
}
