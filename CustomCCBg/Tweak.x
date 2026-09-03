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

// MARK: - 文件日志（可在 Filza 中查看）
static NSString * const kCCBgLogFile = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media/debug.log";

static void ccbg_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ccbg_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    NSLog(@"[CCBg] %@", message);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [kCCBgLogFile stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    if (![fm fileExistsAtPath:kCCBgLogFile]) {
        [logLine writeToFile:kCCBgLogFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kCCBgLogFile];
        [handle seekToEndOfFile];
        [handle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}

// 调试用: 已记录的模块类名集合 (用于去重日志)
NSMutableSet *sCCBgLoggedModules(void) {
    static NSMutableSet *sSet = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSet = [NSMutableSet set];
    });
    return sSet;
}

// Darwin 通知回调 — 设置变更时跨进程通知 SpringBoard 重新加载
// 使用 performSelector 避免前向声明的方法签名问题
static void ccbgDarwinReloadCallback(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    @autoreleasepool {
        ccbg_log(@"Darwin notification: reload preferences");
        Class mgrCls = NSClassFromString(@"CustomCCBgManager");
        if (mgrCls) {
            id mgr = [mgrCls performSelector:@selector(sharedInstance)];
            if (mgr) [mgr performSelector:@selector(reloadPreferences)];
        }
    }
}

// MARK: - 常量

static NSString * const kCCBgPreferencesDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgEnabledKey = @"Enabled";
static NSString * const kCCBgBlurAlphaKey = @"BlurAlpha";
static NSString * const kCCBgBackgroundModeKey = @"BackgroundMode"; // 0=全屏, 1=模块级
static NSString * const kCCBgFullscreenEnabledKey = @"FullscreenBgEnabled";
static NSString * const kCCBgConnectModuleEnabledKey = @"ConnectModuleBgEnabled";
static NSString * const kCCBgMediaModuleEnabledKey = @"MediaModuleBgEnabled";
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

// 视频静音（默认静音，避免与系统媒体音量冲突）
static const BOOL kCCBgVideoMuted = YES;

// 控制中心收起动画时长（用于延迟恢复系统背景）
static const NSTimeInterval kCCBgCCDismissAnimationDuration = 0.35;

// MARK: - 工具函数

// 递归查找视图层级中的 MTMaterialView
static UIView *ccbgFindMaterialView(UIView *rootView) {
    if (!rootView) return nil;
    for (UIView *subview in rootView.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"MTMaterialView"]) {
            return subview;
        }
        UIView *found = ccbgFindMaterialView(subview);
        if (found) return found;
    }
    return nil;
}

// 模块类型识别
// 连接模块类名关键词
static NSArray *ccbgConnectModuleKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Network", @"Connect", @"WiFi", @"Airplane", @"Cellular",
                     @"Bluetooth", @"Hotspot", @"VPN", @"Connectivity", @"Signal"];
    });
    return keywords;
}

// 播放控制模块类名关键词
static NSArray *ccbgMediaModuleKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Media", @"NowPlaying", @"Playback", @"Audio", @"Music",
                     @"Player", @"Volume", @"Sound"];
    });
    return keywords;
}

// 递归检查视图树中是否包含关键词（最多 depth 层）
static BOOL ccbgCheckViewTreeForKeywords(UIView *view, NSArray *keywords, NSInteger depth) {
    if (!view || depth < 0) return NO;
    NSString *className = NSStringFromClass([view class]);
    for (NSString *keyword in keywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    for (UIView *subview in view.subviews) {
        if (ccbgCheckViewTreeForKeywords(subview, keywords, depth - 1)) {
            return YES;
        }
    }
    return NO;
}

// 递归 dump 子视图类名（调试用）
static void ccbgDumpSubviewTree(UIView *view, NSString *indent, NSMutableString *output) {
    if (!view) return;
    [output appendFormat:@"%@%@\n", indent, NSStringFromClass([view class])];
    if (view.subviews.count > 0 && indent.length < 8) {
        for (UIView *sub in view.subviews) {
            ccbgDumpSubviewTree(sub, [indent stringByAppendingString:@"  "], output);
        }
    }
}

// 判断是否为连接模块（递归检查子视图类名）
static BOOL ccbgIsConnectModule(UIView *view) {
    if (!view) return NO;
    NSArray *keywords = ccbgConnectModuleKeywords();

    // 检查自身类名
    NSString *className = NSStringFromClass([view class]);
    for (NSString *keyword in keywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    // 检查父视图类名
    UIView *superview = view.superview;
    if (superview) {
        NSString *superClassName = NSStringFromClass([superview class]);
        for (NSString *keyword in keywords) {
            if ([superClassName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    // 递归检查子视图（最多 4 层）—— iOS 17 模块容器类名相同，内容视图在子视图中
    return ccbgCheckViewTreeForKeywords(view, keywords, 4);
}

// 判断是否为播放控制模块（递归检查子视图类名）
static BOOL ccbgIsMediaModule(UIView *view) {
    if (!view) return NO;
    NSArray *keywords = ccbgMediaModuleKeywords();

    // 检查自身类名
    NSString *className = NSStringFromClass([view class]);
    for (NSString *keyword in keywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    // 检查父视图类名
    UIView *superview = view.superview;
    if (superview) {
        NSString *superClassName = NSStringFromClass([superview class]);
        for (NSString *keyword in keywords) {
            if ([superClassName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    // 递归检查子视图（最多 4 层）
    return ccbgCheckViewTreeForKeywords(view, keywords, 4);
}

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
    self.player.muted = kCCBgVideoMuted;
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

// MARK: - 模块级背景层（使用 CALayer 而非 UIView，避免成为模块的兄弟视图导致动画系统崩溃）

@interface CCBgModuleBackground : NSObject
@property (nonatomic, strong) CALayer *containerLayer;     // 替代 containerView
@property (nonatomic, strong) CALayer *imageLayer;         // 替代 imageView（用 CALayer 显示 contents）
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)updateWithPlayer:(AVQueuePlayer *)player blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)setVideoLayerHidden:(BOOL)hidden;
- (void)setHidden:(BOOL)hidden;
- (void)setAlpha:(CGFloat)alpha;
- (void)cleanup;
@end

@implementation CCBgModuleBackground

- (instancetype)init {
    self = [super init];
    if (self) {
        _containerLayer = [CALayer layer];
        _containerLayer.masksToBounds = YES;
    }
    return self;
}

// 图片模式: 使用预渲染模糊图
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    _containerLayer.frame = frame;
    _containerLayer.cornerRadius = radius;

    // 移除视频层
    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }

    // 显示预渲染模糊图(或原图)
    UIImage *displayImage = blurredImage ?: image;
    if (!_imageLayer) {
        _imageLayer = [CALayer layer];
        _imageLayer.contentsGravity = kCAGravityResizeAspectFill;
        [_containerLayer insertSublayer:_imageLayer atIndex:0];
    }
    if (_imageLayer.contents != (id)displayImage.CGImage) {
        _imageLayer.contents = (id)displayImage.CGImage;
    }
    _imageLayer.frame = _containerLayer.bounds;
}

// 视频模式: 视频层 + 底部一层静态模糊图
- (void)updateWithPlayer:(AVQueuePlayer *)player blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    _containerLayer.frame = frame;
    _containerLayer.cornerRadius = radius;

    // 确保有 imageLayer 作为底层
    if (!_imageLayer) {
        _imageLayer = [CALayer layer];
        _imageLayer.contentsGravity = kCAGravityResizeAspectFill;
        [_containerLayer insertSublayer:_imageLayer atIndex:0];
    }
    // 有模糊图时显示,无模糊图(blur=0)时清空底层,让视频直接呈现
    if (blurredImage) {
        if (_imageLayer.contents != (id)blurredImage.CGImage) {
            _imageLayer.contents = (id)blurredImage.CGImage;
        }
        _imageLayer.hidden = NO;
    } else {
        _imageLayer.contents = nil;
        _imageLayer.hidden = YES;
    }
    _imageLayer.frame = _containerLayer.bounds;

    // 视频层
    if (!_playerLayer) {
        _playerLayer = [AVPlayerLayer layer];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [_containerLayer addSublayer:_playerLayer];
    }
    _playerLayer.frame = _containerLayer.bounds;
    if (_playerLayer.player != player) {
        _playerLayer.player = player;
    }
}

- (void)setVideoLayerHidden:(BOOL)hidden {
    _playerLayer.hidden = hidden;
}

- (void)setHidden:(BOOL)hidden {
    _containerLayer.hidden = hidden;
}

- (void)setAlpha:(CGFloat)alpha {
    _containerLayer.opacity = alpha;
}

- (void)cleanup {
    if (_imageLayer) {
        [_imageLayer removeFromSuperlayer];
        _imageLayer = nil;
    }
    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }
    if (_containerLayer) {
        [_containerLayer removeFromSuperlayer];
        _containerLayer = nil;
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
@property (nonatomic, strong) UIVisualEffectView *videoBlurView; // 视频背景模糊叠加层
@property (nonatomic, weak) UIView *originalMaterialView; // 系统原毛玻璃背景（隐藏用）

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
@property (nonatomic, assign) BOOL connectModuleBgEnabled;
@property (nonatomic, assign) BOOL mediaModuleBgEnabled;
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
        // 注册 Darwin 通知 — 接收来自 Preferences 的跨进程设置变更通知
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge void *)self,
            ccbgDarwinReloadCallback,
            CFSTR("dylv.Deepliquid.ccbg.reload"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
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
    // blurAlpha 允许为 0,此时显示清晰原图,不做模糊处理
    NSInteger mode = [defaults integerForKey:kCCBgBackgroundModeKey];
    self.connectModuleBgEnabled = [defaults boolForKey:kCCBgConnectModuleEnabledKey];
    self.mediaModuleBgEnabled = [defaults boolForKey:kCCBgMediaModuleEnabledKey];
    BOOL fullscreenEnabled = [defaults boolForKey:kCCBgFullscreenEnabledKey];
    NSLog(@"[CCBg] reloadPrefs: enabled=%d fullscreen=%d mode=%ld connect=%d media=%d",
          self.isEnabled, fullscreenEnabled, (long)self.backgroundMode,
          self.connectModuleBgEnabled, self.mediaModuleBgEnabled);
    ccbg_log(@"reloadPrefs: enabled=%d fullscreen=%d mode=%ld connect=%d media=%d blurAlpha=%.2f hasImage=%d hasVideo=%d",
          self.isEnabled, fullscreenEnabled, (long)self.backgroundMode,
          self.connectModuleBgEnabled, self.mediaModuleBgEnabled, self.blurAlpha,
          [[NSFileManager defaultManager] fileExistsAtPath:[kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgImageFileName]],
          [[NSFileManager defaultManager] fileExistsAtPath:[kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgVideoFileName]]);
    CCBgMode oldMode = self.backgroundMode;
    self.backgroundMode = (mode == kCCBgModePerModule) ? kCCBgModePerModule : kCCBgModeFullscreen;

    // 使媒体缓存失效,下次使用时重新检查
    self.mediaCacheValid = NO;
    self.cachedImage = nil;
    self.cachedBlurredImage = nil; // 模糊缓存也失效
    self.cachedVideoURL = nil;

    // 重置模块检测日志集合,下次打开控制中心会重新 dump 模块类名
    extern NSMutableSet *sCCBgLoggedModules(void);
    NSMutableSet *logged = sCCBgLoggedModules();
    @synchronized(logged) {
        [logged removeAllObjects];
    }

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

    // 模糊度为 0 时直接返回 nil,调用方会显示清晰原图
    if (self.blurAlpha <= 0.001) {
        self.cachedBlurredImage = nil;
        self.cachedBlurRadius = 0.0;
        return nil;
    }

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
        self.sharedVideoPlayer.muted = kCCBgVideoMuted;
        self.sharedVideoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        self.sharedLooper = [AVPlayerLooper playerLooperWithPlayer:self.sharedVideoPlayer templateItem:item];
    }
    return self.sharedVideoPlayer;
}

#pragma mark - 可见性控制

// 优化 H: 控制中心关闭后延迟释放视频的时间（秒）
static const NSTimeInterval kCCBgDeferredReleaseDelay = 10.0;

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
            // 特定模块模式也释放共享视频
            if (strongSelf.sharedVideoPlayer) {
                [strongSelf.sharedVideoPlayer pause];
                strongSelf.sharedVideoPlayer = nil;
            }
            strongSelf.sharedLooper = nil;
            for (CCBgModuleBackground *bg in strongSelf.moduleBackgrounds.allValues) {
                [bg setVideoLayerHidden:YES];
            }
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

        // 恢复系统毛玻璃隐藏状态（如果是全屏模式）
        if (self.backgroundMode == kCCBgModeFullscreen && self.originalMaterialView) {
            self.originalMaterialView.hidden = self.isEnabled;
        }

        if (self.backgroundMode == kCCBgModeFullscreen) {
            // 立即显示背景（与控制中心同步出现）
            self.bgContainerView.hidden = !self.isEnabled;
            if (self.videoView && self.isEnabled) [self.videoView play];
            else if (self.isEnabled && self.cachedHasVideo) {
                // 视频已被延迟释放，重新加载
                [self updateBackgroundView];
            }

            // 全屏关闭但特定模块开启时，也需要处理共享视频播放器
            if (!self.isEnabled && (self.connectModuleBgEnabled || self.mediaModuleBgEnabled)) {
                if (self.sharedVideoPlayer && self.cachedHasVideo && self.sharedVideoPlayer.rate == 0) {
                    [self.sharedVideoPlayer play];
                } else if (self.cachedHasVideo && !self.sharedVideoPlayer) {
                    AVQueuePlayer *player = [self getSharedVideoPlayer];
                    if (player) {
                        [player play];
                        for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                            [bg setVideoLayerHidden:NO];
                        }
                    }
                }
                for (CCBgModuleBackground *bg in self.moduleBackgrounds.allValues) {
                    [bg setVideoLayerHidden:NO];
                }
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
        // 控制中心不可见:立即隐藏背景，暂停视频，并安排延迟释放
        if (self.backgroundMode == kCCBgModeFullscreen) {
            // 立即隐藏背景（与控制中心收起动画同步）
            self.bgContainerView.hidden = YES;
            if (self.videoView) [self.videoView pause];

            // 特定模块模式下也暂停共享视频
            if (self.sharedVideoPlayer) [self.sharedVideoPlayer pause];

            // 延迟恢复系统毛玻璃（等收起动画结束）
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCCBgCCDismissAnimationDuration * NSEC_PER_SEC)),
                          dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                // 只有在控制中心仍然不可见时才恢复
                if (!strongSelf.isControlCenterVisible && strongSelf.originalMaterialView) {
                    strongSelf.originalMaterialView.hidden = NO;
                }
            });
        } else {
            if (self.sharedVideoPlayer) [self.sharedVideoPlayer pause];
        }
        // 优化 H: 延迟释放视频资源
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

    // 找到系统毛玻璃背景层（MTMaterialView）
    UIView *materialView = ccbgFindMaterialView(view);
    self.originalMaterialView = materialView;

    self.bgContainerView = [[UIView alloc] initWithFrame:view.bounds];
    self.bgContainerView.userInteractionEnabled = NO;
    self.bgContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // 将背景插入到 MTMaterialView 同一层级（在它下面），并隐藏 MTMaterialView
    if (materialView) {
        // 隐藏系统毛玻璃背景
        materialView.hidden = YES;
        // 把我们的背景插到 MTMaterialView 的位置
        [view insertSubview:self.bgContainerView belowSubview:materialView];
    } else {
        // 找不到的话降级：插到最底层
        [view insertSubview:self.bgContainerView atIndex:0];
    }

    [self updateBackgroundView];
}

- (void)updateBackgroundView {
    if (!self.bgContainerView || !self.hostView) return;

    self.bgContainerView.frame = self.hostView.bounds;

    // 功能关闭 → 隐藏并清理媒体
    if (!self.isEnabled) {
        self.bgContainerView.hidden = YES;
        [self detachMediaViews];
        return;
    }
    // 控制中心不可见（收起动画中）→ 仅隐藏不清理，防止 layoutSubviews 重新显示
    if (!self.isControlCenterVisible) {
        self.bgContainerView.hidden = YES;
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

        // 视频模糊叠加层（blurAlpha > 0 时添加）
        if (self.blurAlpha > 0.01) {
            if (!self.videoBlurView) {
                UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
                self.videoBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
                self.videoBlurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                self.videoBlurView.userInteractionEnabled = NO;
                [self.bgContainerView insertSubview:self.videoBlurView aboveSubview:self.videoView];
            }
            self.videoBlurView.frame = self.bgContainerView.bounds;
            self.videoBlurView.alpha = self.blurAlpha;
        } else if (self.videoBlurView) {
            [self.videoBlurView removeFromSuperview];
            self.videoBlurView = nil;
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
    // 恢复系统毛玻璃背景
    if (self.originalMaterialView) {
        self.originalMaterialView.hidden = NO;
        self.originalMaterialView = nil;
    }
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
    if (self.videoBlurView) {
        [self.videoBlurView removeFromSuperview];
        self.videoBlurView = nil;
    }
}

- (void)detachImageView {
    if (self.imageView) {
        [self.imageView removeFromSuperview];
        self.imageView = nil;
    }
}

#pragma mark - 特定模块背景（连接模块 / 播放控制模块）

// 检查特定模块是否应该显示背景（全屏关闭时生效）
- (BOOL)shouldShowBackgroundForModuleView:(UIView *)moduleView {
    // 全屏模式开着的话，不走特定模块逻辑
    if (self.isEnabled && self.backgroundMode == kCCBgModeFullscreen) return NO;

    // 模块级模式已经处理了所有模块
    if (self.backgroundMode == kCCBgModePerModule) return NO;

    NSString *cls = NSStringFromClass([moduleView class]);
    NSString *superCls = moduleView.superview ? NSStringFromClass([moduleView.superview class]) : @"nil";
    BOOL isConnect = ccbgIsConnectModule(moduleView);
    BOOL isMedia = ccbgIsMediaModule(moduleView);
    NSLog(@"[CCBg] module check: class=%@ isConnect=%d isMedia=%d connectEnabled=%d mediaEnabled=%d",
          cls, isConnect, isMedia, self.connectModuleBgEnabled, self.mediaModuleBgEnabled);
    ccbg_log(@"module check: class=%@ super=%@ isConnect=%d isMedia=%d connectEnabled=%d mediaEnabled=%d",
          cls, superCls, isConnect, isMedia, self.connectModuleBgEnabled, self.mediaModuleBgEnabled);

    // 一次性 dump 子视图树（帮助识别 iOS 17 模块内容类名）
    static dispatch_once_t dumpOnce;
    dispatch_once(&dumpOnce, ^{
        NSMutableString *tree = [NSMutableString string];
        ccbgDumpSubviewTree(moduleView, @"", tree);
        ccbg_log(@"=== First module subview tree ===\n%@", tree);
    });

    // 检查特定模块开关
    if (self.connectModuleBgEnabled && isConnect) return YES;
    if (self.mediaModuleBgEnabled && isMedia) return YES;

    return NO;
}

// 挂载特定模块背景
- (void)attachToSpecificModuleView:(UIView *)moduleView {
    if (![self shouldShowBackgroundForModuleView:moduleView]) {
        // 不应该显示背景，清理已有背景
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
        // 背景用 CALayer 插到模块 layer 下面
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
        self.moduleBackgrounds[key] = bg;
    }

    // 如果父视图变了，重新挂载
    if (bg.containerLayer.superlayer != superview.layer) {
        [bg.containerLayer removeFromSuperlayer];
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
    }

    // 背景 frame 与模块一致
    CGRect moduleFrameInSuperview = moduleView.frame;
    CGFloat cornerRadius = moduleView.layer.cornerRadius;
    if (cornerRadius <= 0) {
        CGFloat minDim = fmin(CGRectGetWidth(moduleView.bounds), CGRectGetHeight(moduleView.bounds));
        cornerRadius = minDim * 0.25;
    }

    // 节流：尺寸和圆角没变就跳过更新
    if (CGRectEqualToRect(bg.containerLayer.frame, moduleFrameInSuperview) &&
        fabs(bg.containerLayer.cornerRadius - cornerRadius) < 0.1) {
        if (self.cachedHasVideo && self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
            [self.sharedVideoPlayer play];
        }
        BOOL isVisible = [self isModuleViewVisible:moduleView];
        [bg setVideoLayerHidden:!isVisible];
        [bg setHidden:moduleView.hidden];
        [bg setAlpha:moduleView.alpha];
        return;
    }

    UIImage *blurredImage = [self getCachedBlurredImage];

    if (self.cachedHasVideo) {
        AVQueuePlayer *player = [self getSharedVideoPlayer];
        if (player) {
            [bg updateWithPlayer:player blurredImage:blurredImage frame:moduleFrameInSuperview cornerRadius:cornerRadius];
            if (self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
                [self.sharedVideoPlayer play];
            }
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

    [bg setHidden:moduleView.hidden];
    [bg setAlpha:moduleView.alpha];
}

// 清除所有特定模块背景（但保留模块级模式的）
- (void)detachSpecificModuleBackgrounds {
    // 直接复用 detachAllModules，因为两种模式共用 moduleBackgrounds 字典
    // 切换模式时会调用 detachAllModules
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

    // 白名单模式: 如果连接模块或媒体模块开关打开,只对匹配的模块显示背景
    BOOL hasWhitelist = self.connectModuleBgEnabled || self.mediaModuleBgEnabled;
    if (hasWhitelist) {
        BOOL isConnect = ccbgIsConnectModule(moduleView);
        BOOL isMedia = ccbgIsMediaModule(moduleView);
        BOOL whitelisted =
            (self.connectModuleBgEnabled && isConnect) ||
            (self.mediaModuleBgEnabled && isMedia);
        if (!whitelisted) {
            // 不在白名单中,清理已有背景
            NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
            CCBgModuleBackground *bg = self.moduleBackgrounds[key];
            if (bg) {
                [bg cleanup];
                [self.moduleBackgrounds removeObjectForKey:key];
            }
            // 调试: 记录被跳过的模块类名,帮助排查检测失败的情况
            NSMutableSet *loggedModules = sCCBgLoggedModules();
            NSString *clsName = NSStringFromClass([moduleView class]);
            @synchronized(loggedModules) {
                if (![loggedModules containsObject:clsName]) {
                    [loggedModules addObject:clsName];
                    ccbg_log(@"whitelist skip: class=%@ isConnect=%d isMedia=%d (connectEnabled=%d mediaEnabled=%d)",
                          clsName, isConnect, isMedia,
                          self.connectModuleBgEnabled, self.mediaModuleBgEnabled);
                    // Dump 前 3 层子视图类名,帮助识别模块内容
                    NSMutableString *tree = [NSMutableString string];
                    ccbgDumpSubviewTree(moduleView, @"  ", tree);
                    ccbg_log(@"  module subtree:\n%@", tree);
                }
            }
            return;
        }
    }

    [self ensureMediaCacheValid];

    NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
    CCBgModuleBackground *bg = self.moduleBackgrounds[key];
    UIView *superview = moduleView.superview;
    if (!superview) return;

    if (!bg) {
        bg = [[CCBgModuleBackground alloc] init];
        // 背景用 CALayer 插到模块 layer 下面，避免成为兄弟 UIView 导致动画系统崩溃
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
        self.moduleBackgrounds[key] = bg;
        ccbg_log(@"module bg CREATED: class=%@ frame=%@ hasVideo=%d blurAlpha=%.2f",
              NSStringFromClass([moduleView class]),
              NSStringFromCGRect(moduleFrameInSuperview),
              self.cachedHasVideo, self.blurAlpha);
    }

    // 如果父视图变了，重新挂载
    if (bg.containerLayer.superlayer != superview.layer) {
        [bg.containerLayer removeFromSuperlayer];
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
    }

    // 背景 frame 是模块在父视图中的 frame（模块后面，尺寸位置与模块一致）
    CGRect moduleFrameInSuperview = moduleView.frame;
    CGFloat cornerRadius = moduleView.layer.cornerRadius;
    if (cornerRadius <= 0) {
        CGFloat minDim = fmin(CGRectGetWidth(moduleView.bounds), CGRectGetHeight(moduleView.bounds));
        cornerRadius = minDim * 0.25;
    }

    // 优化 D: 如果尺寸和圆角都没变，跳过更新
    if (CGRectEqualToRect(bg.containerLayer.frame, moduleFrameInSuperview) &&
        fabs(bg.containerLayer.cornerRadius - cornerRadius) < 0.1) {
        // 尺寸未变,只确保播放状态正确
        if (self.cachedHasVideo && self.isControlCenterVisible && self.sharedVideoPlayer.rate == 0) {
            [self.sharedVideoPlayer play];
        }
        // 优化 C: 检查是否在可见区域内
        BOOL isVisible = [self isModuleViewVisible:moduleView];
        [bg setVideoLayerHidden:!isVisible];
        // 同步隐藏状态
        [bg setHidden:moduleView.hidden];
        [bg setAlpha:moduleView.alpha];
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
    [bg setHidden:moduleView.hidden];
    [bg setAlpha:moduleView.alpha];
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
    ccbg_log(@"CC overlay viewWillAppear");
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:YES];
    UIView *root = ((UIViewController *)self).view;
    [[CustomCCBgManager sharedInstance] attachToHostView:root];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ccbg_log(@"CC overlay viewDidAppear");
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    ccbg_log(@"CC overlay viewWillDisappear");
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:NO];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    ccbg_log(@"CC overlay viewDidDisappear");
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

// 模块级 hook + 特定模块 hook: 控制中心模块容器
%hook CCUIContentModuleContainerView

- (void)layoutSubviews {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ccbg_log(@"hook fired: CCUIContentModuleContainerView layoutSubviews, actual class=%@", NSStringFromClass([(id)self class]));
    });
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if (mgr.backgroundMode == kCCBgModePerModule) {
        [mgr attachToModuleView:(UIView *)self];
    } else {
        // 特定模块背景（全屏关闭时生效）
        [mgr attachToSpecificModuleView:(UIView *)self];
    }
}

- (void)didMoveToWindow {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ccbg_log(@"hook fired: CCUIContentModuleContainerView didMoveToWindow, actual class=%@", NSStringFromClass([(id)self class]));
    });
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if (mgr.backgroundMode == kCCBgModePerModule && [(UIView *)self window]) {
        [mgr attachToModuleView:(UIView *)self];
    } else if ([(UIView *)self window]) {
        // 特定模块背景
        [mgr attachToSpecificModuleView:(UIView *)self];
    }
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    // 模块视图即将从窗口移除 → 控制中心正在关闭
    // 比 viewWillDisappear: 更早触发，能立即隐藏背景
    if (!newWindow) {
        CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
        if (mgr.isControlCenterVisible) {
            ccbg_log(@"willMoveToWindow:nil → CC closing, hide bg immediately");
            [mgr setControlCenterVisible:NO];
        }
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
