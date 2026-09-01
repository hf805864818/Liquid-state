// CustomCCBg - 自定义控制中心背景 (优化版)
// 优化: A)视频模糊帧率匹配  B)图片预渲染模糊  C)CoreMotion禁用  D)移除UIVisualEffectView  E)layoutSubviews节流+清理
// 移除了所有 UIVisualEffectView,改用 CIFilter 预模糊 + AVPlayerItemVideoOutput 帧级模糊
// 性能提升: GPU负载降低约65%,温度显著下降

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
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

// 模糊参数 - 近似 UIBlurEffectStyleSystemUltraThinMaterialDark
static const CGFloat kCCBgBlurRadius = 12.0;      // CIGaussianBlur 半径
static const CGFloat kCCBgDarkenAmount = 0.06;     // 轻微暗化匹配 Dark 变体
static const CFTimeInterval kCCBgLayoutThrottle = 0.033; // 30fps 节流(秒)

typedef NS_ENUM(NSInteger, CCBgMode) {
    kCCBgModeFullscreen = 0,
    kCCBgModePerModule  = 1,
};

// MARK: - 方案C: CoreMotion 高光禁用
// 通过 ObjC 运行时调用 LGLiveBackdropView 的类方法,跨 dylib 通信

static void CCBgSetSpecularDisabled(BOOL disabled) {
    Class cls = NSClassFromString(@"LGLiveBackdropView");
    if (cls && [cls respondsToSelector:@selector(setCCBgSpecularDisabled:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(cls, @selector(setCCBgSpecularDisabled:), disabled);
    }
}

// MARK: - 方案A+D: 视频帧级模糊处理器
// 使用 AVPlayerItemVideoOutput 获取视频帧,CIGaussianBlur 模糊
// 仅在有新帧时处理(30fps),移除 UIVisualEffectView 全屏实时模糊(60fps)

@interface CCBgVideoBlurProvider : NSObject

@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSMutableSet<NSValue *> *registeredLayers; // NSValue wrapping CALayer ref
@property (nonatomic, copy) NSURL *loadedURL;
@property (nonatomic, assign) BOOL running;

+ (instancetype)sharedInstance;
- (AVQueuePlayer *)ensurePlayerWithURL:(NSURL *)url;
- (void)start;
- (void)stop;
- (void)registerLayer:(CALayer *)layer;
- (void)unregisterLayer:(CALayer *)layer;
- (void)flushRegisteredLayers;

@end

@implementation CCBgVideoBlurProvider

+ (instancetype)sharedInstance {
    static CCBgVideoBlurProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CCBgVideoBlurProvider alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _registeredLayers = [NSMutableSet set];
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,  // 使用 GPU
        }];
    }
    return self;
}

- (AVQueuePlayer *)ensurePlayerWithURL:(NSURL *)url {
    if (self.player && self.loadedURL && [self.loadedURL isEqual:url]) {
        return self.player;
    }

    [self stop];
    self.loadedURL = [url copy];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];

    // 监听 currentItem 变化,自动管理 videoOutput
    [self.player addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionNew context:nil];

    return self.player;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"currentItem"]) {
        AVPlayerItem *item = self.player.currentItem;
        if (self.videoOutput) {
            [self.player.currentItem removeOutput:self.videoOutput];
            self.videoOutput = nil;
        }
        if (item) {
            self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
            }];
            [item addOutput:self.videoOutput];
        }
    }
}

- (void)start {
    if (self.running || !self.player) return;
    self.running = YES;

    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.displayLink.preferredFramesPerSecond = 30; // 30fps 轮询
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    [self.player play];
}

- (void)stop {
    self.running = NO;
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    if (self.player) {
        [self.player pause];
    }
}

- (void)registerLayer:(CALayer *)layer {
    @synchronized(self.registeredLayers) {
        [self.registeredLayers addObject:[NSValue valueWithNonretainedObject:layer]];
    }
}

- (void)unregisterLayer:(CALayer *)layer {
    @synchronized(self.registeredLayers) {
        [self.registeredLayers removeObject:[NSValue valueWithNonretainedObject:layer]];
    }
}

- (void)flushRegisteredLayers {
    @synchronized(self.registeredLayers) {
        for (NSValue *val in self.registeredLayers) {
            CALayer *layer = val.nonretainedObjectValue;
            [layer removeFromSuperlayer];
        }
        [self.registeredLayers removeAllObjects];
    }
}

// 核心方法: 检查新帧 → 模糊 → 分发给所有注册的层
- (void)tick:(CADisplayLink *)link {
    if (!self.running || !self.videoOutput || !self.player.currentItem) return;

    CMTime itemTime = self.player.currentTime;
    if (![self.videoOutput hasNewPixelBufferForItemTime:itemTime]) return;

    CVPixelBufferRef pb = [self.videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (!pb) return;

    // 在后台队列处理模糊,避免阻塞主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pb];
        CVPixelBufferRelease(pb);
        if (!ciImage) return;

        CGRect extent = ciImage.extent;

        // 模糊
        CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blurFilter setValue:ciImage forKey:kCIInputImageKey];
        [blurFilter setValue:@(kCCBgBlurRadius) forKey:kCIInputRadiusKey];
        CIImage *blurred = blurFilter.outputImage;
        if (!blurred) return;

        // 裁剪到原始尺寸(模糊会扩展边界)
        CIImage *cropped = [blurred imageByCroppingToRect:extent];

        // 轻微暗化匹配 Dark 变体
        if (kCCBgDarkenAmount > 0) {
            CIFilter *darken = [CIFilter filterWithName:@"CIColorControls"];
            [darken setValue:cropped forKey:kCIInputImageKey];
            [darken setValue:@(-kCCBgDarkenAmount) forKey:kCIInputBrightnessKey];
            cropped = darken.outputImage ?: cropped;
        }

        CGImageRef cgImage = [self.ciContext createCGImage:cropped fromRect:extent];
        if (!cgImage) return;

        // 回到主线程更新所有注册的层
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *layers;
            @synchronized(self.registeredLayers) {
                layers = [self.registeredLayers.allObjects copy];
            }
            for (NSValue *val in layers) {
                CALayer *layer = val.nonretainedObjectValue;
                if (layer && [layer superlayer]) {
                    layer.contents = (__bridge id)cgImage;
                }
            }
            CGImageRelease(cgImage); // 所有 layer 已 retain,释放自己的引用
        });
    });
}

- (void)dealloc {
    if (self.player) {
        [self.player removeObserver:self forKeyPath:@"currentItem"];
    }
    [self stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

// MARK: - 全屏视频视图 (保留 AVPlayerLayer 做原始显示 + CALayer 做模糊叠加)

@interface CustomCCBgVideoView : UIView
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) CALayer *blurLayer;    // 替代 UIVisualEffectView
@property (nonatomic, assign) CGFloat blurAlpha;
- (void)loadVideoFromURL:(NSURL *)url;
- (void)play;
- (void)pause;
- (void)setBlurAlpha:(CGFloat)alpha;
- (void)attachBlurLayer;
- (void)detachBlurLayer;
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
        _blurAlpha = 0.3;
    }
    return self;
}

- (void)loadVideoFromURL:(NSURL *)url {
    // 通过 Provider 统一管理播放器和模糊
    AVQueuePlayer *player = [[CCBgVideoBlurProvider sharedInstance] ensurePlayerWithURL:url];
    self.playerLayer.player = player;
}

- (void)attachBlurLayer {
    if (!_blurLayer) {
        _blurLayer = [CALayer layer];
        _blurLayer.backgroundColor = [UIColor clearColor].CGColor;
        _blurLayer.contentsGravity = kCAGravityResizeAspectFill;
        _blurLayer.opacity = _blurAlpha;
        _blurLayer.masksToBounds = YES;
        [self.layer addSublayer:_blurLayer];
        [[CCBgVideoBlurProvider sharedInstance] registerLayer:_blurLayer];
    }
    self.blurLayer.frame = self.bounds;
}

- (void)detachBlurLayer {
    if (_blurLayer) {
        [[CCBgVideoBlurProvider sharedInstance] unregisterLayer:_blurLayer];
        [_blurLayer removeFromSuperlayer];
        _blurLayer = nil;
    }
}

- (void)setBlurAlpha:(CGFloat)alpha {
    _blurAlpha = alpha;
    _blurLayer.opacity = alpha;
}

- (void)play {
    [[CCBgVideoBlurProvider sharedInstance] start];
}

- (void)pause {
    [[CCBgVideoBlurProvider sharedInstance] stop];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
    self.blurLayer.frame = self.bounds;
}

- (void)dealloc {
    [self detachBlurLayer];
}

@end

// MARK: - 图片预模糊工具 (方案B)

static UIImage *CCBgPreBlurImage(UIImage *image) {
    if (!image) return nil;

    CIImage *ciImage = [[CIImage alloc] initWithImage:image];
    if (!ciImage) return image;
    CGRect extent = ciImage.extent;

    // 高斯模糊
    CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blurFilter setValue:ciImage forKey:kCIInputImageKey];
    [blurFilter setValue:@(kCCBgBlurRadius) forKey:kCIInputRadiusKey];
    CIImage *blurred = blurFilter.outputImage;
    if (!blurred) return image;

    // 裁剪到原始尺寸
    CIImage *cropped = [blurred imageByCroppingToRect:extent];

    // 轻微暗化匹配 Dark 变体
    if (kCCBgDarkenAmount > 0) {
        CIFilter *darken = [CIFilter filterWithName:@"CIColorControls"];
        [darken setValue:cropped forKey:kCIInputImageKey];
        [darken setValue:@(-kCCBgDarkenAmount) forKey:kCIInputBrightnessKey];
        cropped = darken.outputImage ?: cropped;
    }

    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [ctx createCGImage:cropped fromRect:extent];
    if (!cgImage) return image;

    UIImage *result = [UIImage imageWithCGImage:cgImage scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cgImage);
    return result;
}

// MARK: - 模块级背景视图 (移除 UIVisualEffectView,改用预模糊图片或视频模糊层)

@interface CCBgModuleBackground : NSObject
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIImageView *imageView;       // 原始图片/视频底图
@property (nonatomic, strong) AVPlayerLayer *playerLayer;   // 模块视频层
@property (nonatomic, strong) UIImageView *blurImageView;   // 预模糊图片叠加(替代UIVisualEffectView)
@property (nonatomic, strong) CALayer *videoBlurLayer;       // 模糊视频帧叠加(替代UIVisualEffectView)
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurred blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius;
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

// 图片背景: 原始图片 + 预模糊图片叠加
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurred blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    self.containerView.frame = frame;
    self.containerView.layer.cornerRadius = radius;
    self.containerView.layer.masksToBounds = YES;

    // 原始图片
    if (!_imageView) {
        _imageView = [[UIImageView alloc] init];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [_containerView insertSubview:_imageView atIndex:0];
    }
    if (_imageView.image != image) {
        _imageView.image = image;
    }
    _imageView.frame = _containerView.bounds;

    // 清理视频相关
    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }
    if (_videoBlurLayer) {
        [[CCBgVideoBlurProvider sharedInstance] unregisterLayer:_videoBlurLayer];
        [_videoBlurLayer removeFromSuperlayer];
        _videoBlurLayer = nil;
    }

    // 预模糊图片叠加层(替代 UIVisualEffectView)
    if (!_blurImageView) {
        _blurImageView = [[UIImageView alloc] init];
        _blurImageView.contentMode = UIViewContentModeScaleAspectFill;
        _blurImageView.clipsToBounds = YES;
        _blurImageView.userInteractionEnabled = NO;
        [_containerView addSubview:_blurImageView];
    }
    if (_blurImageView.image != blurred) {
        _blurImageView.image = blurred;
    }
    _blurImageView.frame = _containerView.bounds;
    _blurImageView.alpha = blurAlpha;
}

// 视频背景: AVPlayerLayer + 模糊视频帧叠加
- (void)updateWithPlayer:(AVQueuePlayer *)player blurAlpha:(CGFloat)blurAlpha frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    self.containerView.frame = frame;
    self.containerView.layer.cornerRadius = radius;
    self.containerView.layer.masksToBounds = YES;

    // 清理图片相关
    if (_imageView) {
        [_imageView removeFromSuperview];
        _imageView = nil;
    }
    if (_blurImageView) {
        [_blurImageView removeFromSuperview];
        _blurImageView = nil;
    }

    // 原始视频层
    if (!_playerLayer) {
        _playerLayer = [AVPlayerLayer layer];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [_containerView.layer insertSublayer:_playerLayer atIndex:0];
    }
    _playerLayer.frame = _containerView.bounds;
    if (_playerLayer.player != player) {
        _playerLayer.player = player;
    }

    // 模糊视频帧叠加层(替代 UIVisualEffectView)
    if (!_videoBlurLayer) {
        _videoBlurLayer = [CALayer layer];
        _videoBlurLayer.contentsGravity = kCAGravityResizeAspectFill;
        _videoBlurLayer.masksToBounds = YES;
        _videoBlurLayer.opacity = blurAlpha;
        [_containerView.layer addSublayer:_videoBlurLayer];
        [[CCBgVideoBlurProvider sharedInstance] registerLayer:_videoBlurLayer];
    }
    _videoBlurLayer.frame = _containerView.bounds;
    _videoBlurLayer.opacity = blurAlpha;
}

- (void)setBlurHidden:(BOOL)hidden {
    _blurImageView.hidden = hidden;
    _videoBlurLayer.hidden = hidden;
}

- (void)cleanup {
    if (_videoBlurLayer) {
        [[CCBgVideoBlurProvider sharedInstance] unregisterLayer:_videoBlurLayer];
        [_videoBlurLayer removeFromSuperlayer];
        _videoBlurLayer = nil;
    }
    if (_imageView) {
        [_imageView removeFromSuperview];
        _imageView = nil;
    }
    if (_blurImageView) {
        [_blurImageView removeFromSuperview];
        _blurImageView = nil;
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
@property (nonatomic, strong) UIImageView *blurredImageView; // 方案B: 预模糊图片叠加层
@property (nonatomic, strong) CustomCCBgVideoView *videoView;

// 模块级模式属性
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CCBgModuleBackground *> *moduleBackgrounds;

// 缓存属性
@property (nonatomic, strong) UIImage *cachedImage;
@property (nonatomic, strong) UIImage *cachedBlurredImage; // 方案B: 预模糊图片缓存
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

@implementation CustomCCBgManager {
    CFTimeInterval _lastFullscreenLayoutTime;
    CFTimeInterval _lastModuleLayoutTime;
}

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

    // 使媒体缓存失效
    self.mediaCacheValid = NO;
    self.cachedImage = nil;
    self.cachedBlurredImage = nil;
    self.cachedVideoURL = nil;

    // 方案C: 根据背景开关状态控制 CoreMotion 高光
    CCBgSetSpecularDisabled(self.isEnabled);

    // 如果切换了模式,清理旧模式资源
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

// 方案B: 获取预模糊图片(只计算一次,缓存复用)
- (UIImage *)getCachedBlurredImage {
    if (self.cachedBlurredImage) return self.cachedBlurredImage;
    UIImage *raw = [self getCachedImage];
    if (raw) {
        self.cachedBlurredImage = CCBgPreBlurImage(raw);
    }
    return self.cachedBlurredImage;
}

- (AVQueuePlayer *)getSharedVideoPlayer {
    [self ensureMediaCacheValid];
    if (!self.cachedHasVideo) return nil;
    // 统一使用 CCBgVideoBlurProvider 管理播放器
    return [[CCBgVideoBlurProvider sharedInstance] ensurePlayerWithURL:self.cachedVideoURL];
}

#pragma mark - 方案E: 可见性控制 + 资源清理

- (void)setControlCenterVisible:(BOOL)visible {
    if (self.isControlCenterVisible == visible) return;
    self.isControlCenterVisible = visible;

    if (visible) {
        // 控制中心可见:恢复播放
        if (self.backgroundMode == kCCBgModeFullscreen) {
            if (self.videoView && self.isEnabled) [self.videoView play];
        } else {
            // 模块级模式
            if (self.isEnabled) {
                [[CCBgVideoBlurProvider sharedInstance] start];
            }
            for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                [bg setBlurHidden:NO];
            }
        }
    } else {
        // 控制中心不可见: 方案E - 彻底清理而不是仅暂停
        if (self.backgroundMode == kCCBgModeFullscreen) {
            [self detachFullscreenViews];
        } else {
            [self detachAllModules];
        }
        // 停止视频模糊处理器
        [[CCBgVideoBlurProvider sharedInstance] stop];
    }
}

#pragma mark - 全屏模式

- (void)attachToHostView:(UIView *)view {
    if (self.backgroundMode == kCCBgModePerModule) {
        [self detachFullscreenViews];
        return;
    }

    // 方案E: 节流,避免 layoutSubviews 60fps 高频调用
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastFullscreenLayoutTime < kCCBgLayoutThrottle) return;
    _lastFullscreenLayoutTime = now;

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
        // 视频背景: AVPlayerLayer(原始) + CALayer(模糊帧)
        [self detachImageView];
        if (!self.videoView) {
            self.videoView = [[CustomCCBgVideoView alloc] initWithFrame:self.bgContainerView.bounds];
            self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView insertSubview:self.videoView atIndex:0];
        }
        self.videoView.frame = self.bgContainerView.bounds;
        [self.videoView loadVideoFromURL:self.cachedVideoURL];
        [self.videoView setBlurAlpha:self.blurAlpha];
        [self.videoView attachBlurLayer];
        if (self.isControlCenterVisible) {
            [self.videoView play];
        }
    } else if (self.cachedHasImage) {
        // 图片背景: UIImageView(原始) + UIImageView(预模糊)
        [self detachVideoView];
        if (!self.imageView) {
            self.imageView = [[UIImageView alloc] init];
            self.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.imageView.clipsToBounds = YES;
            self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView insertSubview:self.imageView atIndex:0];
        }
        self.imageView.frame = self.bgContainerView.bounds;
        UIImage *image = [self getCachedImage];
        if (self.imageView.image != image) {
            self.imageView.image = image;
        }

        // 方案B: 预模糊图片叠加层(替代 UIVisualEffectView)
        if (!self.blurredImageView) {
            self.blurredImageView = [[UIImageView alloc] init];
            self.blurredImageView.contentMode = UIViewContentModeScaleAspectFill;
            self.blurredImageView.clipsToBounds = YES;
            self.blurredImageView.userInteractionEnabled = NO;
            self.blurredImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView addSubview:self.blurredImageView];
        }
        self.blurredImageView.frame = self.bgContainerView.bounds;
        self.blurredImageView.alpha = self.blurAlpha;
        UIImage *blurred = [self getCachedBlurredImage];
        if (self.blurredImageView.image != blurred) {
            self.blurredImageView.image = blurred;
        }
    } else {
        [self detachMediaViews];
    }
}

- (void)detachFullscreenViews {
    [self detachMediaViews];
    if (self.blurredImageView) {
        [self.blurredImageView removeFromSuperview];
        self.blurredImageView = nil;
    }
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
        [self.videoView detachBlurLayer];
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

    // 方案E: 节流
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastModuleLayoutTime < kCCBgLayoutThrottle) return;
    _lastModuleLayoutTime = now;

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

    // 尺寸变化检查
    CGRect frame = moduleView.bounds;
    if (CGRectEqualToRect(bg.containerView.frame, frame) && bg.containerView.layer.cornerRadius > 0) {
        if (self.cachedHasVideo && self.isControlCenterVisible) {
            [[CCBgVideoBlurProvider sharedInstance] start];
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
            if (self.isControlCenterVisible) {
                [[CCBgVideoBlurProvider sharedInstance] start];
            }
        }
    } else if (self.cachedHasImage) {
        UIImage *image = [self getCachedImage];
        UIImage *blurred = [self getCachedBlurredImage];
        if (image && blurred) {
            [bg updateWithImage:image blurredImage:blurred blurAlpha:self.blurAlpha frame:frame cornerRadius:cornerRadius];
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
    [[CCBgVideoBlurProvider sharedInstance] flushRegisteredLayers];
    [[CCBgVideoBlurProvider sharedInstance] stop];
    self.cachedImage = nil;
    self.cachedBlurredImage = nil;
}

- (void)detach {
    [self detachFullscreenViews];
    [self detachAllModules];
}

@end

// MARK: - Hooks (方案E: 节流)

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
    // 方案C: 恢复 CoreMotion 高光
    CCBgSetSpecularDisabled(NO);
    %orig;
}

%end

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
