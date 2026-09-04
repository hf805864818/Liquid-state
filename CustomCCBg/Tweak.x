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

// 背景类型
typedef NS_ENUM(NSInteger, CCBgType) {
    kCCBgTypeFullscreen = 0,  // 全屏背景
    kCCBgTypeConnect    = 1,  // 连接模块背景
    kCCBgTypeMedia      = 2,  // 播放控制模块背景
};

static NSString * const kCCBgPreferencesDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";
static NSString * const kCCBgBaseMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
static NSString * const kCCBgImageFileName = @"background.jpg";
static NSString * const kCCBgVideoFileName = @"background.mp4";

// 三种独立背景的偏好设置 key
static NSString * const kCCBgFullscreenEnabledKey = @"FullscreenBgEnabled";
static NSString * const kCCBgFullscreenBlurAlphaKey = @"FullscreenBlurAlpha";
static NSString * const kCCBgConnectEnabledKey = @"ConnectModuleBgEnabled";
static NSString * const kCCBgConnectBlurAlphaKey = @"ConnectModuleBlurAlpha";
static NSString * const kCCBgMediaEnabledKey = @"MediaModuleBgEnabled";
static NSString * const kCCBgMediaBlurAlphaKey = @"MediaModuleBlurAlpha";

// 优化 B: 视频目标帧率 30fps,观感几乎无差别,解码+渲染功耗降低约40%
static const NSInteger kCCBgTargetVideoFPS = 30;

// 视频静音（默认静音，避免与系统媒体音量冲突）
static const BOOL kCCBgVideoMuted = YES;

// 控制中心收起动画时长（用于延迟恢复系统背景）
static const NSTimeInterval kCCBgCCDismissAnimationDuration = 0.35;

// MARK: - 媒体路径辅助

static NSString *ccbgMediaDirForType(CCBgType type) {
    NSString *typeName = @"fullscreen";
    if (type == kCCBgTypeConnect) typeName = @"connect";
    else if (type == kCCBgTypeMedia) typeName = @"media";
    return [kCCBgBaseMediaDirectory stringByAppendingPathComponent:typeName];
}

static NSString *ccbgImagePathForType(CCBgType type) {
    return [ccbgMediaDirForType(type) stringByAppendingPathComponent:kCCBgImageFileName];
}

static NSString *ccbgVideoPathForType(CCBgType type) {
    return [ccbgMediaDirForType(type) stringByAppendingPathComponent:kCCBgVideoFileName];
}

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
// MARK: - 模块标识符检测（运行时）

// 尝试从视图或其响应者链中获取模块标识符
static NSString *ccbgGetModuleIdentifier(UIView *view) {
    if (!view) return nil;

    // 尝试直接从视图获取模块相关属性
    NSArray *propertyNames = @[@"moduleIdentifier", @"_moduleIdentifier",
                               @"moduleID", @"_moduleID",
                               @"identifier", @"_identifier",
                               @"module", @"_module",
                               @"contentModule", @"_contentModule"];

    for (NSString *propName in propertyNames) {
        @try {
            if ([view respondsToSelector:NSSelectorFromString(propName)]) {
                id value = [view valueForKey:propName];
                if (value && [value isKindOfClass:[NSString class]]) {
                    return (NSString *)value;
                }
                // 如果属性是一个对象，尝试从该对象中获取 identifier
                if (value && ![value isKindOfClass:[NSNumber class]] && ![value isKindOfClass:[NSString class]]) {
                    for (NSString *innerProp in @[@"identifier", @"moduleIdentifier", @"ID"]) {
                        SEL innerSel = NSSelectorFromString(innerProp);
                        if ([value respondsToSelector:innerSel]) {
                            id innerValue = [value valueForKey:innerProp];
                            if (innerValue && [innerValue isKindOfClass:[NSString class]]) {
                                return (NSString *)innerValue;
                            }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            continue;
        }
    }

    // 尝试通过响应者链找视图控制器
    UIResponder *responder = view.nextResponder;
    NSInteger attempts = 0;
    while (responder && attempts < 10) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)responder;
            for (NSString *propName in propertyNames) {
                @try {
                    if ([vc respondsToSelector:NSSelectorFromString(propName)]) {
                        id value = [vc valueForKey:propName];
                        if (value && [value isKindOfClass:[NSString class]]) {
                            return (NSString *)value;
                        }
                        if (value && ![value isKindOfClass:[NSNumber class]] && ![value isKindOfClass:[NSString class]]) {
                            for (NSString *innerProp in @[@"identifier", @"moduleIdentifier", @"ID"]) {
                                SEL innerSel = NSSelectorFromString(innerProp);
                                if ([value respondsToSelector:innerSel]) {
                                    id innerValue = [value valueForKey:innerProp];
                                    if (innerValue && [innerValue isKindOfClass:[NSString class]]) {
                                        return (NSString *)innerValue;
                                    }
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {
                    continue;
                }
            }
        }
        responder = responder.nextResponder;
        attempts++;
    }

    return nil;
}

// 连接模块类名关键词（更全面）
static NSArray *ccbgConnectModuleKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Network", @"Connect", @"WiFi", @"Airplane", @"Cellular",
                     @"Bluetooth", @"Hotspot", @"VPN", @"Connectivity", @"Signal",
                     @"AirPort", @"Wifi", @"Tethering", @"DataNetwork",
                     // 模块标识符关键词
                     @"com.apple.controlcenter.airplane",
                     @"com.apple.controlcenter.wifi",
                     @"com.apple.controlcenter.bluetooth",
                     @"com.apple.controlcenter.cellular",
                     @"com.apple.controlcenter.hotspot",
                     @"com.apple.controlcenter.vpn",
                     // iOS 17+ 模块标识
                     @"airplane-mode",
                     @"wifi",
                     @"bluetooth",
                     @"cellular",
                     @"personal-hotspot",
                     @"vpn",
                     // 额外关键词
                     @"Radio", @"Antenna", @"Modem"];
    });
    return keywords;
}

// 播放控制模块类名关键词（更全面）
static NSArray *ccbgMediaModuleKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Media", @"NowPlaying", @"Playback", @"Audio", @"Music",
                     @"Player", @"Volume", @"Sound", @"NowPlayingInfo",
                     // 模块标识符关键词
                     @"com.apple.controlcenter.media",
                     @"com.apple.controlcenter.nowplaying",
                     @"com.apple.mediapicker",
                     // iOS 17+ 模块标识
                     @"now-playing",
                     @"media-player",
                     @"music",
                     // 额外关键词
                     @"PlaybackControl",
                     @"MediaControl",
                     @"AVPlayer",
                     @"MPMedia",
                     @"MPNowPlaying"];
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
    // 额外检查 accessibilityIdentifier
    if (view.accessibilityIdentifier) {
        for (NSString *keyword in keywords) {
            if ([view.accessibilityIdentifier rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    // 额外检查 accessibilityLabel
    if (view.accessibilityLabel) {
        for (NSString *keyword in keywords) {
            if ([view.accessibilityLabel rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    // 检查 restorationIdentifier
    if (view.restorationIdentifier) {
        for (NSString *keyword in keywords) {
            if ([view.restorationIdentifier rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
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
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@", indent, NSStringFromClass([view class])];
    // 额外信息：accessibilityIdentifier
    if (view.accessibilityIdentifier) {
        [line appendFormat:@" [id=%@]", view.accessibilityIdentifier];
    }
    if (view.accessibilityLabel) {
        [line appendFormat:@" [label=%@]", view.accessibilityLabel];
    }
    [output appendFormat:@"%@\n", line];
    // 增加到 10 层深度
    if (view.subviews.count > 0 && indent.length < 20) {
        for (UIView *sub in view.subviews) {
            ccbgDumpSubviewTree(sub, [indent stringByAppendingString:@"  "], output);
        }
    }
}

// 判断是否为连接模块（优先通过模块标识符，其次递归检查子视图类名）
static BOOL ccbgIsConnectModule(UIView *view) {
    if (!view) return NO;
    NSArray *keywords = ccbgConnectModuleKeywords();

    // 方案1: 优先通过模块标识符检测（最准确）
    NSString *moduleID = ccbgGetModuleIdentifier(view);
    if (moduleID) {
        for (NSString *keyword in keywords) {
            if ([moduleID rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }

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
    // 递归检查子视图（最多 6 层）—— iOS 17 模块容器类名相同，内容视图在子视图中
    return ccbgCheckViewTreeForKeywords(view, keywords, 6);
}

// 判断是否为播放控制模块（优先通过模块标识符，其次递归检查子视图类名）
static BOOL ccbgIsMediaModule(UIView *view) {
    if (!view) return NO;
    NSArray *keywords = ccbgMediaModuleKeywords();

    // 方案1: 优先通过模块标识符检测（最准确）
    NSString *moduleID = ccbgGetModuleIdentifier(view);
    if (moduleID) {
        for (NSString *keyword in keywords) {
            if ([moduleID rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }

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
    // 递归检查子视图（最多 6 层）
    return ccbgCheckViewTreeForKeywords(view, keywords, 6);
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

// 全屏背景属性
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIView *bgContainerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CustomCCBgVideoView *videoView;
@property (nonatomic, strong) UIVisualEffectView *videoBlurView;
@property (nonatomic, weak) UIView *originalMaterialView;

// 模块背景：每种类型独立管理
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CCBgModuleBackground *> *connectModuleBackgrounds;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CCBgModuleBackground *> *mediaModuleBackgrounds;
@property (nonatomic, strong) AVQueuePlayer *sharedModuleVideoPlayer;
@property (nonatomic, strong) AVPlayerLooper *sharedModuleLooper;

// 每种类型的媒体缓存
@property (nonatomic, strong) UIImage *cachedFullscreenImage;
@property (nonatomic, strong) UIImage *cachedFullscreenBlurredImage;
@property (nonatomic, assign) BOOL fullscreenCacheValid;
@property (nonatomic, assign) BOOL cachedFullscreenHasImage;
@property (nonatomic, assign) BOOL cachedFullscreenHasVideo;
@property (nonatomic, strong) NSURL *cachedFullscreenVideoURL;

@property (nonatomic, strong) UIImage *cachedConnectImage;
@property (nonatomic, strong) UIImage *cachedConnectBlurredImage;
@property (nonatomic, assign) BOOL connectCacheValid;
@property (nonatomic, assign) BOOL cachedConnectHasImage;
@property (nonatomic, assign) BOOL cachedConnectHasVideo;
@property (nonatomic, strong) NSURL *cachedConnectVideoURL;

@property (nonatomic, strong) UIImage *cachedMediaImage;
@property (nonatomic, strong) UIImage *cachedMediaBlurredImage;
@property (nonatomic, assign) BOOL mediaCacheValid;
@property (nonatomic, assign) BOOL cachedMediaHasImage;
@property (nonatomic, assign) BOOL cachedMediaHasVideo;
@property (nonatomic, strong) NSURL *cachedMediaVideoURL;

// 每种类型的设置
@property (nonatomic, assign) BOOL fullscreenEnabled;
@property (nonatomic, assign) CGFloat fullscreenBlurAlpha;
@property (nonatomic, assign) BOOL connectEnabled;
@property (nonatomic, assign) CGFloat connectBlurAlpha;
@property (nonatomic, assign) BOOL mediaEnabled;
@property (nonatomic, assign) CGFloat mediaBlurAlpha;

// 状态
@property (nonatomic, assign) BOOL isControlCenterVisible;
// 优化 H: 控制中心关闭后延迟释放视频资源
@property (nonatomic, strong) dispatch_source_t deferredReleaseTimer;

+ (instancetype)sharedInstance;
- (void)reloadPreferences;
- (void)attachToHostView:(UIView *)view;
- (void)handleModuleView:(UIView *)moduleView;
- (void)scanForModulesInView:(UIView *)rootView;
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
        _connectModuleBackgrounds = [NSMutableDictionary dictionary];
        _mediaModuleBackgrounds = [NSMutableDictionary dictionary];
        _isControlCenterVisible = NO;
        [self reloadPreferences];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadPreferences {
    // 使用 CFPreferences 读取，确保与设置界面写入方式一致，避免跨进程缓存问题
    CFStringRef domain = (__bridge CFStringRef)kCCBgPreferencesDomain;

    // 读取三种独立背景的设置
    Boolean fullscreenEnabled = CFPreferencesGetAppBooleanValue(
        (__bridge CFStringRef)kCCBgFullscreenEnabledKey, domain, NULL);
    self.fullscreenEnabled = fullscreenEnabled;

    CFNumberRef fullscreenBlurNum = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kCCBgFullscreenBlurAlphaKey, domain);
    if (fullscreenBlurNum) {
        CFNumberGetValue(fullscreenBlurNum, kCFNumberCGFloatType, &_fullscreenBlurAlpha);
        CFRelease(fullscreenBlurNum);
    } else {
        self.fullscreenBlurAlpha = 0.3; // 默认值
    }

    Boolean connectEnabled = CFPreferencesGetAppBooleanValue(
        (__bridge CFStringRef)kCCBgConnectEnabledKey, domain, NULL);
    self.connectEnabled = connectEnabled;

    CFNumberRef connectBlurNum = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kCCBgConnectBlurAlphaKey, domain);
    if (connectBlurNum) {
        CFNumberGetValue(connectBlurNum, kCFNumberCGFloatType, &_connectBlurAlpha);
        CFRelease(connectBlurNum);
    } else {
        self.connectBlurAlpha = 0.3;
    }

    Boolean mediaEnabled = CFPreferencesGetAppBooleanValue(
        (__bridge CFStringRef)kCCBgMediaEnabledKey, domain, NULL);
    self.mediaEnabled = mediaEnabled;

    CFNumberRef mediaBlurNum = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kCCBgMediaBlurAlphaKey, domain);
    if (mediaBlurNum) {
        CFNumberGetValue(mediaBlurNum, kCFNumberCGFloatType, &_mediaBlurAlpha);
        CFRelease(mediaBlurNum);
    } else {
        self.mediaBlurAlpha = 0.3;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    ccbg_log(@"reloadPrefs: fullscreen=%d(blur=%.2f) connect=%d(blur=%.2f) media=%d(blur=%.2f)",
          self.fullscreenEnabled, self.fullscreenBlurAlpha,
          self.connectEnabled, self.connectBlurAlpha,
          self.mediaEnabled, self.mediaBlurAlpha);
    ccbg_log(@"  media: fullscreen img=%d vid=%d | connect img=%d vid=%d | media img=%d vid=%d",
          [fm fileExistsAtPath:ccbgImagePathForType(kCCBgTypeFullscreen)],
          [fm fileExistsAtPath:ccbgVideoPathForType(kCCBgTypeFullscreen)],
          [fm fileExistsAtPath:ccbgImagePathForType(kCCBgTypeConnect)],
          [fm fileExistsAtPath:ccbgVideoPathForType(kCCBgTypeConnect)],
          [fm fileExistsAtPath:ccbgImagePathForType(kCCBgTypeMedia)],
          [fm fileExistsAtPath:ccbgVideoPathForType(kCCBgTypeMedia)]);

    // 使所有媒体缓存失效
    self.fullscreenCacheValid = NO;
    self.cachedFullscreenImage = nil;
    self.cachedFullscreenBlurredImage = nil;
    self.cachedFullscreenVideoURL = nil;

    self.connectCacheValid = NO;
    self.cachedConnectImage = nil;
    self.cachedConnectBlurredImage = nil;
    self.cachedConnectVideoURL = nil;

    self.mediaCacheValid = NO;
    self.cachedMediaImage = nil;
    self.cachedMediaBlurredImage = nil;
    self.cachedMediaVideoURL = nil;

    // 重置模块检测日志集合
    extern NSMutableSet *sCCBgLoggedModules(void);
    NSMutableSet *logged = sCCBgLoggedModules();
    @synchronized(logged) {
        [logged removeAllObjects];
    }

    // 全屏背景关闭则清理全屏资源
    if (!self.fullscreenEnabled) {
        [self detachFullscreenViews];
    }
    // 模块背景关闭则清理对应模块资源
    if (!self.connectEnabled) {
        [self detachConnectModules];
    }
    if (!self.mediaEnabled) {
        [self detachMediaModules];
    }
    // 如果两种模块背景都关了，释放共享视频播放器
    if (!self.connectEnabled && !self.mediaEnabled) {
        if (self.sharedModuleVideoPlayer) {
            [self.sharedModuleVideoPlayer pause];
            self.sharedModuleVideoPlayer = nil;
        }
        self.sharedModuleLooper = nil;
    }

    // 全屏背景已挂载的话，更新显示
    if (self.bgContainerView && self.fullscreenEnabled) {
        [self updateBackgroundView];
    }
}

#pragma mark - 媒体缓存（按类型独立缓存）

- (void)ensureCacheValidForType:(CCBgType)type {
    if (type == kCCBgTypeFullscreen && self.fullscreenCacheValid) return;
    if (type == kCCBgTypeConnect && self.connectCacheValid) return;
    if (type == kCCBgTypeMedia && self.mediaCacheValid) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *imagePath = ccbgImagePathForType(type);
    NSString *videoPath = ccbgVideoPathForType(type);
    BOOL hasImage = [fm fileExistsAtPath:imagePath];
    BOOL hasVideo = [fm fileExistsAtPath:videoPath];
    NSURL *videoURL = hasVideo ? [NSURL fileURLWithPath:videoPath] : nil;

    if (type == kCCBgTypeFullscreen) {
        self.cachedFullscreenHasImage = hasImage;
        self.cachedFullscreenHasVideo = hasVideo;
        self.cachedFullscreenVideoURL = videoURL;
        self.cachedFullscreenImage = nil;
        self.cachedFullscreenBlurredImage = nil;
        self.fullscreenCacheValid = YES;
    } else if (type == kCCBgTypeConnect) {
        self.cachedConnectHasImage = hasImage;
        self.cachedConnectHasVideo = hasVideo;
        self.cachedConnectVideoURL = videoURL;
        self.cachedConnectImage = nil;
        self.cachedConnectBlurredImage = nil;
        self.connectCacheValid = YES;
    } else {
        self.cachedMediaHasImage = hasImage;
        self.cachedMediaHasVideo = hasVideo;
        self.cachedMediaVideoURL = videoURL;
        self.cachedMediaImage = nil;
        self.cachedMediaBlurredImage = nil;
        self.mediaCacheValid = YES;
    }
}

- (UIImage *)getImageForType:(CCBgType)type {
    [self ensureCacheValidForType:type];

    if (type == kCCBgTypeFullscreen) {
        if (_cachedFullscreenImage) return _cachedFullscreenImage;
        if (self.cachedFullscreenHasImage) {
            _cachedFullscreenImage = [UIImage imageWithContentsOfFile:ccbgImagePathForType(type)];
        }
        return _cachedFullscreenImage;
    } else if (type == kCCBgTypeConnect) {
        if (_cachedConnectImage) return _cachedConnectImage;
        if (self.cachedConnectHasImage) {
            _cachedConnectImage = [UIImage imageWithContentsOfFile:ccbgImagePathForType(type)];
        }
        return _cachedConnectImage;
    } else {
        if (_cachedMediaImage) return _cachedMediaImage;
        if (self.cachedMediaHasImage) {
            _cachedMediaImage = [UIImage imageWithContentsOfFile:ccbgImagePathForType(type)];
        }
        return _cachedMediaImage;
    }
}

- (UIImage *)getBlurredImageForType:(CCBgType)type blurAlpha:(CGFloat)blurAlpha {
    [self ensureCacheValidForType:type];

    BOOL hasImage = (type == kCCBgTypeFullscreen) ? self.cachedFullscreenHasImage :
                     (type == kCCBgTypeConnect) ? self.cachedConnectHasImage :
                     self.cachedMediaHasImage;
    if (!hasImage) return nil;

    // 模糊度为 0 时直接返回 nil,调用方会显示清晰原图
    if (blurAlpha <= 0.001) return nil;

    UIImage *cachedBlurred = nil;
    if (type == kCCBgTypeFullscreen) cachedBlurred = self.cachedFullscreenBlurredImage;
    else if (type == kCCBgTypeConnect) cachedBlurred = self.cachedConnectBlurredImage;
    else cachedBlurred = self.cachedMediaBlurredImage;

    CGFloat targetRadius = blurAlpha * 20.0; // 最大 20px 模糊

    // 已有模糊缓存则直接用（简单缓存，不单独存 radius）
    if (cachedBlurred) return cachedBlurred;

    UIImage *original = [self getImageForType:type];
    if (!original) return nil;

    UIImage *blurred = ccbgBlurredImage(original, targetRadius);
    if (type == kCCBgTypeFullscreen) self.cachedFullscreenBlurredImage = blurred;
    else if (type == kCCBgTypeConnect) self.cachedConnectBlurredImage = blurred;
    else self.cachedMediaBlurredImage = blurred;
    return blurred;
}

- (NSURL *)getVideoURLForType:(CCBgType)type {
    [self ensureCacheValidForType:type];
    if (type == kCCBgTypeFullscreen) return self.cachedFullscreenVideoURL;
    if (type == kCCBgTypeConnect) return self.cachedConnectVideoURL;
    return self.cachedMediaVideoURL;
}

- (BOOL)hasVideoForType:(CCBgType)type {
    [self ensureCacheValidForType:type];
    if (type == kCCBgTypeFullscreen) return self.cachedFullscreenHasVideo;
    if (type == kCCBgTypeConnect) return self.cachedConnectHasVideo;
    return self.cachedMediaHasVideo;
}

// 模块背景共享视频播放器（连接和媒体模块共用一个播放器，节省资源）
- (AVQueuePlayer *)getSharedModuleVideoPlayerForType:(CCBgType)type {
    NSURL *videoURL = [self getVideoURLForType:type];
    if (!videoURL) return nil;

    // 已有播放器且 URL 匹配则复用
    if (self.sharedModuleVideoPlayer &&
        [self.sharedModuleVideoPlayer.currentItem.asset isKindOfClass:[AVURLAsset class]]) {
        AVURLAsset *asset = (AVURLAsset *)self.sharedModuleVideoPlayer.currentItem.asset;
        if ([asset.URL isEqual:videoURL]) {
            return self.sharedModuleVideoPlayer;
        }
    }

    // 创建新播放器
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoURL];
    if ([item respondsToSelector:NSSelectorFromString(@"setPreferredFrameRateRange:")]) {
        typedef struct { float min; float max; } CCFrameRateRange;
        CCFrameRateRange range;
        range.min = 1.0f;
        range.max = (float)kCCBgTargetVideoFPS;
        NSValue *rangeValue = [NSValue valueWithBytes:&range objCType:@encode(CCFrameRateRange)];
        [item setValue:rangeValue forKey:@"preferredFrameRateRange"];
    }
    self.sharedModuleVideoPlayer = [AVQueuePlayer queuePlayerWithItems:@[item]];
    self.sharedModuleVideoPlayer.muted = kCCBgVideoMuted;
    self.sharedModuleVideoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.sharedModuleLooper = [AVPlayerLooper playerLooperWithPlayer:self.sharedModuleVideoPlayer templateItem:item];
    return self.sharedModuleVideoPlayer;
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
    // 任何一种背景有视频就需要延迟释放
    BOOL hasAnyVideo = [self hasVideoForType:kCCBgTypeFullscreen] ||
                       [self hasVideoForType:kCCBgTypeConnect] ||
                       [self hasVideoForType:kCCBgTypeMedia];
    if (!hasAnyVideo) return;

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
        // 全屏视频
        [strongSelf detachVideoView];

        // 模块共享视频
        if (strongSelf.sharedModuleVideoPlayer) {
            [strongSelf.sharedModuleVideoPlayer pause];
            strongSelf.sharedModuleVideoPlayer = nil;
        }
        strongSelf.sharedModuleLooper = nil;

        // 隐藏所有模块视频层
        for (CCBgModuleBackground *bg in strongSelf.connectModuleBackgrounds.allValues) {
            [bg setVideoLayerHidden:YES];
        }
        for (CCBgModuleBackground *bg in strongSelf.mediaModuleBackgrounds.allValues) {
            [bg setVideoLayerHidden:YES];
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
        // 控制中心可见:取消延迟释放
        [self cancelDeferredRelease];

        // --- 全屏背景 ---
        if (self.fullscreenEnabled && self.originalMaterialView) {
            self.originalMaterialView.hidden = YES;
        }
        if (self.fullscreenEnabled) {
            self.bgContainerView.hidden = NO;
            if (self.videoView) [self.videoView play];
            else if ([self hasVideoForType:kCCBgTypeFullscreen]) {
                [self updateBackgroundView];
            }
        }

        // --- 模块背景 ---
        BOOL hasModuleBg = self.connectEnabled || self.mediaEnabled;
        if (hasModuleBg) {
            // 播放所有启用的模块视频
            NSArray *allModuleBgs = @[];
            if (self.connectEnabled) {
                allModuleBgs = [allModuleBgs arrayByAddingObjectsFromArray:self.connectModuleBackgrounds.allValues];
            }
            if (self.mediaEnabled) {
                allModuleBgs = [allModuleBgs arrayByAddingObjectsFromArray:self.mediaModuleBackgrounds.allValues];
            }

            if (allModuleBgs.count > 0) {
                // 确定使用哪个类型的视频（优先媒体模块，其次连接模块）
                CCBgType videoType = kCCBgTypeMedia;
                if (!self.mediaEnabled || ![self hasVideoForType:kCCBgTypeMedia]) {
                    videoType = kCCBgTypeConnect;
                }
                if ([self hasVideoForType:videoType]) {
                    AVQueuePlayer *player = [self getSharedModuleVideoPlayerForType:videoType];
                    if (player && player.rate == 0) {
                        [player play];
                    }
                }
                for (CCBgModuleBackground *bg in allModuleBgs) {
                    [bg setVideoLayerHidden:NO];
                }
            }
        }
    } else {
        // 控制中心不可见:立即隐藏背景，暂停视频

        // --- 全屏背景 ---
        if (self.fullscreenEnabled) {
            self.bgContainerView.hidden = YES;
            if (self.videoView) [self.videoView pause];
        }

        // --- 模块背景 ---
        if (self.sharedModuleVideoPlayer) {
            [self.sharedModuleVideoPlayer pause];
        }

        // 延迟恢复系统毛玻璃（等收起动画结束）
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCCBgCCDismissAnimationDuration * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf.isControlCenterVisible && strongSelf.originalMaterialView) {
                strongSelf.originalMaterialView.hidden = NO;
            }
        });

        // 优化 H: 延迟释放视频资源
        [self scheduleDeferredRelease];
    }
}

#pragma mark - 全屏背景

- (void)attachToHostView:(UIView *)view {
    // 全屏背景未开启则不挂载
    if (!self.fullscreenEnabled) {
        [self detachFullscreenViews];
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

    // 诊断：dump 控制中心根视图层级（仅首次）
    static dispatch_once_t dumpOnce;
    dispatch_once(&dumpOnce, ^{
        NSMutableString *tree = [NSMutableString string];
        ccbgDumpSubviewTree(view, @"", tree);
        ccbg_log(@"CC root view hierarchy:\n%@", tree);
    });

    if (self.fullscreenEnabled) {
        self.bgContainerView = [[UIView alloc] initWithFrame:view.bounds];
        self.bgContainerView.userInteractionEnabled = NO;
        self.bgContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // 将背景插入到 MTMaterialView 同一层级（在它下面），并隐藏 MTMaterialView
        if (materialView) {
            materialView.hidden = YES;
            [view insertSubview:self.bgContainerView belowSubview:materialView];
        } else {
            [view insertSubview:self.bgContainerView atIndex:0];
        }

        [self updateBackgroundView];
    }
}

- (void)updateBackgroundView {
    if (!self.bgContainerView || !self.hostView) return;

    self.bgContainerView.frame = self.hostView.bounds;

    // 功能关闭 → 隐藏并清理媒体
    if (!self.fullscreenEnabled) {
        self.bgContainerView.hidden = YES;
        [self detachMediaViews];
        return;
    }
    if (!self.isControlCenterVisible) {
        self.bgContainerView.hidden = YES;
        return;
    }
    self.bgContainerView.hidden = NO;

    [self ensureCacheValidForType:kCCBgTypeFullscreen];

    if ([self hasVideoForType:kCCBgTypeFullscreen]) {
        [self detachImageView];
        if (!self.videoView) {
            self.videoView = [[CustomCCBgVideoView alloc] initWithFrame:self.bgContainerView.bounds];
            self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView insertSubview:self.videoView atIndex:0];
        }
        self.videoView.frame = self.bgContainerView.bounds;
        [self.videoView loadVideoFromURL:[self getVideoURLForType:kCCBgTypeFullscreen]];
        if (self.isControlCenterVisible) {
            [self.videoView play];
        }

        // 视频模糊叠加层
        if (self.fullscreenBlurAlpha > 0.01) {
            if (!self.videoBlurView) {
                UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
                self.videoBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
                self.videoBlurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                self.videoBlurView.userInteractionEnabled = NO;
                [self.bgContainerView insertSubview:self.videoBlurView aboveSubview:self.videoView];
            }
            self.videoBlurView.frame = self.bgContainerView.bounds;
            self.videoBlurView.alpha = self.fullscreenBlurAlpha;
        } else if (self.videoBlurView) {
            [self.videoBlurView removeFromSuperview];
            self.videoBlurView = nil;
        }
    } else if (self.cachedFullscreenHasImage) {
        [self detachVideoView];
        if (!self.imageView) {
            self.imageView = [[UIImageView alloc] init];
            self.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.imageView.clipsToBounds = YES;
            self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.bgContainerView insertSubview:self.imageView atIndex:0];
        }
        self.imageView.frame = self.bgContainerView.bounds;
        UIImage *displayImage = [self getBlurredImageForType:kCCBgTypeFullscreen blurAlpha:self.fullscreenBlurAlpha]
                                ?: [self getImageForType:kCCBgTypeFullscreen];
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

#pragma mark - 模块背景（连接模块 / 播放控制模块，独立设置）

// 统一处理模块视图（判断类型并更新对应背景）
- (void)handleModuleView:(UIView *)moduleView {
    if (!self.connectEnabled && !self.mediaEnabled) return;
    if (!moduleView.window) return;

    BOOL isConnect = self.connectEnabled && ccbgIsConnectModule(moduleView);
    BOOL isMedia = self.mediaEnabled && ccbgIsMediaModule(moduleView);

    // 调试日志（首次出现的模块类名）
    NSMutableSet *loggedModules = sCCBgLoggedModules();
    NSString *clsName = NSStringFromClass([moduleView class]);
    @synchronized(loggedModules) {
        if (![loggedModules containsObject:clsName]) {
            [loggedModules addObject:clsName];
            // 获取模块标识符（调试用）
            NSString *moduleID = ccbgGetModuleIdentifier(moduleView);
            ccbg_log(@"module detected: class=%@ isConnect=%d isMedia=%d (connectEnabled=%d mediaEnabled=%d) moduleID=%@",
                  clsName, isConnect, isMedia, self.connectEnabled, self.mediaEnabled,
                  moduleID ?: @"nil");
            // 查找所有可能的标识信息
            NSMutableString *identifiers = [NSMutableString string];
            if (moduleView.accessibilityIdentifier) {
                [identifiers appendFormat:@"  accessibilityID=%@\n", moduleView.accessibilityIdentifier];
            }
            if (moduleView.accessibilityLabel) {
                [identifiers appendFormat:@"  accessibilityLabel=%@\n", moduleView.accessibilityLabel];
            }
            if (moduleView.restorationIdentifier) {
                [identifiers appendFormat:@"  restorationID=%@\n", moduleView.restorationIdentifier];
            }
            if (identifiers.length > 0) {
                ccbg_log(@"  identifiers:\n%@", identifiers);
            }
            NSMutableString *tree = [NSMutableString string];
            ccbgDumpSubviewTree(moduleView, @"  ", tree);
            ccbg_log(@"  subtree:\n%@", tree);
        }
    }

    // 连接模块
    if (isConnect) {
        [self updateModuleBackground:moduleView forType:kCCBgTypeConnect];
    } else {
        // 不是连接模块，清理可能存在的连接背景
        NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
        CCBgModuleBackground *bg = self.connectModuleBackgrounds[key];
        if (bg) {
            [bg cleanup];
            [self.connectModuleBackgrounds removeObjectForKey:key];
        }
    }

    // 媒体模块
    if (isMedia) {
        [self updateModuleBackground:moduleView forType:kCCBgTypeMedia];
    } else {
        NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
        CCBgModuleBackground *bg = self.mediaModuleBackgrounds[key];
        if (bg) {
            [bg cleanup];
            [self.mediaModuleBackgrounds removeObjectForKey:key];
        }
    }
}

// 递归扫描视图树中的所有模块候选视图（备用机制）
- (void)scanForModulesInView:(UIView *)rootView {
    if (!rootView) return;
    [self scanView:rootView depth:0 maxDepth:8];
}

- (void)scanView:(UIView *)view depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (!view || depth > maxDepth) return;

    // 只处理看起来像模块容器的视图（有一定尺寸，有子视图）
    BOOL isContainerLike = view.subviews.count > 0 &&
                           CGRectGetWidth(view.bounds) > 40 &&
                           CGRectGetHeight(view.bounds) > 40;

    if (isContainerLike) {
        // 尝试用模块检测逻辑判断
        BOOL isConnect = self.connectEnabled && ccbgIsConnectModule(view);
        BOOL isMedia = self.mediaEnabled && ccbgIsMediaModule(view);

        if (isConnect || isMedia) {
            [self handleModuleView:view];
        }
    }

    // 继续扫描子视图
    for (UIView *subview in view.subviews) {
        [self scanView:subview depth:depth + 1 maxDepth:maxDepth];
    }
}

// 更新单个模块背景
- (void)updateModuleBackground:(UIView *)moduleView forType:(CCBgType)type {
    UIView *superview = moduleView.superview;
    if (!superview) return;

    NSMutableDictionary *bgDict = (type == kCCBgTypeConnect) ? self.connectModuleBackgrounds : self.mediaModuleBackgrounds;
    CGFloat blurAlpha = (type == kCCBgTypeConnect) ? self.connectBlurAlpha : self.mediaBlurAlpha;

    NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
    CCBgModuleBackground *bg = bgDict[key];

    CGRect moduleFrame = moduleView.frame;
    CGFloat cornerRadius = moduleView.layer.cornerRadius;
    if (cornerRadius <= 0) {
        CGFloat minDim = fmin(CGRectGetWidth(moduleView.bounds), CGRectGetHeight(moduleView.bounds));
        cornerRadius = minDim * 0.25;
    }

    if (!bg) {
        bg = [[CCBgModuleBackground alloc] init];
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
        bgDict[key] = bg;
        ccbg_log(@"module bg CREATED: type=%ld class=%@ frame=%@ hasImage=%d hasVideo=%d",
              (long)type, NSStringFromClass([moduleView class]),
              NSStringFromCGRect(moduleFrame),
              (type == kCCBgTypeConnect) ? self.cachedConnectHasImage : self.cachedMediaHasImage,
              (type == kCCBgTypeConnect) ? self.cachedConnectHasVideo : self.cachedMediaHasVideo);
    }

    // 父视图变了则重新挂载
    if (bg.containerLayer.superlayer != superview.layer) {
        [bg.containerLayer removeFromSuperlayer];
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
    }

    // 节流：尺寸和圆角没变就跳过渲染更新
    if (CGRectEqualToRect(bg.containerLayer.frame, moduleFrame) &&
        fabs(bg.containerLayer.cornerRadius - cornerRadius) < 0.1) {
        [bg setHidden:moduleView.hidden];
        [bg setAlpha:moduleView.alpha];
        return;
    }

    UIImage *blurredImage = [self getBlurredImageForType:type blurAlpha:blurAlpha];

    if ([self hasVideoForType:type]) {
        AVQueuePlayer *player = [self getSharedModuleVideoPlayerForType:type];
        if (player) {
            [bg updateWithPlayer:player blurredImage:blurredImage frame:moduleFrame cornerRadius:cornerRadius];
            if (self.isControlCenterVisible && player.rate == 0) {
                [player play];
            }
            BOOL isVisible = [self isModuleViewVisible:moduleView];
            [bg setVideoLayerHidden:!isVisible];
        }
    } else {
        UIImage *image = [self getImageForType:type];
        if (image) {
            [bg updateWithImage:image blurredImage:blurredImage frame:moduleFrame cornerRadius:cornerRadius];
        } else {
            ccbg_log(@"module bg CLEANUP: type=%ld class=%@ - no image/video found",
                  (long)type, NSStringFromClass([moduleView class]));
            [bg cleanup];
            [bgDict removeObjectForKey:key];
            return;
        }
    }

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

- (void)detachConnectModules {
    for (NSNumber *key in self.connectModuleBackgrounds.allKeys) {
        CCBgModuleBackground *bg = self.connectModuleBackgrounds[key];
        [bg cleanup];
    }
    [self.connectModuleBackgrounds removeAllObjects];
}

- (void)detachMediaModules {
    for (NSNumber *key in self.mediaModuleBackgrounds.allKeys) {
        CCBgModuleBackground *bg = self.mediaModuleBackgrounds[key];
        [bg cleanup];
    }
    [self.mediaModuleBackgrounds removeAllObjects];
}

- (void)detachAllModules {
    [self detachConnectModules];
    [self detachMediaModules];
    if (self.sharedModuleVideoPlayer) {
        [self.sharedModuleVideoPlayer pause];
        self.sharedModuleVideoPlayer = nil;
    }
    self.sharedModuleLooper = nil;
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

// 备用 hook: CC 容器视图
%hook CCUIModularControlCenterContainerView

- (void)layoutSubviews {
    %orig;
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    UIView *host = [(UIView *)self superview];
    if (host) {
        [mgr attachToHostView:host];
    }
    // 备用：扫描所有子视图寻找模块（防止 CCUIContentModuleContainerView hook 不生效）
    if (mgr.connectEnabled || mgr.mediaEnabled) {
        static NSTimeInterval lastScanTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastScanTime > 0.5) { // 节流：最多每 0.5 秒扫描一次
            lastScanTime = now;
            [mgr scanForModulesInView:(UIView *)self];
        }
    }
}

%end

// 模块背景 hook: 控制中心模块容器
%hook CCUIContentModuleContainerView

- (void)layoutSubviews {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ccbg_log(@"hook fired: CCUIContentModuleContainerView layoutSubviews, actual class=%@", NSStringFromClass([(id)self class]));
    });
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    [mgr handleModuleView:(UIView *)self];
}

- (void)didMoveToWindow {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ccbg_log(@"hook fired: CCUIContentModuleContainerView didMoveToWindow, actual class=%@", NSStringFromClass([(id)self class]));
    });
    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if ([(UIView *)self window]) {
        [mgr handleModuleView:(UIView *)self];
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
