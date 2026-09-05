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
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
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

// 运行时扫描所有包含 "Expanded" 或 "Extension" 的类名（用于发现展开模块的实际类）
static void ccbgLogExpandedClasses() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class *classes = NULL;
        unsigned int numClasses = objc_getClassList(NULL, 0);
        if (numClasses > 0) {
            classes = (Class *)malloc(sizeof(Class) * numClasses);
            numClasses = objc_getClassList(classes, numClasses);
            NSMutableArray *expandedClasses = [NSMutableArray array];
            for (unsigned int i = 0; i < numClasses; i++) {
                NSString *name = NSStringFromClass(classes[i]);
                if ([name rangeOfString:@"Expanded" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [name rangeOfString:@"Extension" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [expandedClasses addObject:name];
                }
            }
            ccbg_log(@"runtime classes with Expanded/Extension: %@", expandedClasses);
            free(classes);
        }
    });
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

// 【修复连接模块模糊】追踪已管理的模块视图
// 原因：ccbgIsInsideManagedModule 依赖类名匹配 "ContentModuleContainer"，
//       但连接模块的 MTMaterialView 可能不在该类名的视图内，
//       或 ccbgIsConnectModule 在容器视图上检测失败（不同 iOS 版本关键词不同）。
//       通过追踪 handleModuleView: 已处理的视图，提供可靠的 fallback。
static NSHashTable<UIView *> *sCCBgManagedModules(void) {
    static NSHashTable<UIView *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static void ccbgRegisterManagedModule(UIView *moduleView) {
    if (!moduleView) return;
    [sCCBgManagedModules() addObject:moduleView];
}

static BOOL ccbgIsDescendantOfManagedModule(UIView *view) {
    if (!view) return NO;
    UIView *v = view;
    NSInteger depth = 0;
    while (v && depth < 25) {
        if ([sCCBgManagedModules() containsObject:v]) return YES;
        v = v.superview;
        depth++;
    }
    return NO;
}

// 【修复问题2&3】隐藏 MTMaterialView 同级的 LGLiveBackdropView（液态玻璃）
// 原因：LiquidAss 通过 LGInjectGlassIntoMaterialGroupType 将 LGLiveBackdropView
//       作为 MTMaterialView 的【兄弟视图】插入到父视图中（aboveSubview:mat），
//       而非子视图。因此隐藏 MTMaterialView 不会影响 LGLiveBackdropView，
//       液态玻璃继续渲染模糊+折射，导致自定义背景看起来模糊不清。
static void ccbgHideGlassSiblingsOf(UIView *materialView) {
    UIView *parent = materialView.superview;
    if (!parent) return;
    for (UIView *sibling in parent.subviews) {
        NSString *siblingClass = NSStringFromClass([sibling class]);
        if ([siblingClass containsString:@"LGLiveBackdropView"] ||
            [siblingClass containsString:@"LGLiveBackdrop"]) {
            sibling.hidden = YES;
            sibling.layer.opacity = 0.0f;
            sibling.layer.hidden = YES;
        }
    }
}

// 递归查找模块内部所有 MTMaterialView 并直接隐藏
// MTMaterialView 使用私有渲染管线，CAFilter 无法访问其模糊值
// 直接隐藏是最可靠的方式：隐藏后系统模糊消失
// 自定义背景在模块视图下方，隐藏 MTMaterialView 后仍然可见
// 模块内容（图标/文字）在 MTMaterialView 上方，也不受影响
// 【修复问题2&3】同时隐藏同级的 LGLiveBackdropView 液态玻璃
static void ccbgHideMaterialBlurInModule(UIView *view) {
    if (!view) return;
    NSString *className = NSStringFromClass([view class]);
    if ([className containsString:@"MTMaterialView"]) {
        // 直接隐藏，三重保障
        view.hidden = YES;
        view.layer.opacity = 0.0f;
        view.layer.hidden = YES;
        // 【修复问题2&3】同时隐藏同级的液态玻璃兄弟视图
        ccbgHideGlassSiblingsOf(view);
        return; // MTMaterialView 内部不需要继续递归
    }
    for (UIView *subview in view.subviews) {
        ccbgHideMaterialBlurInModule(subview);
    }
}

// 延迟重新隐藏模块内 MTMaterialView
// 系统会在布局后重新显示 MTMaterialView，需要延迟再次隐藏
static void ccbgScheduleMaterialBlurClamp(UIView *moduleView) {
    if (!moduleView) return;
    __weak UIView *weakModule = moduleView;
    // 【修复连接模块模糊】增加更多重隐藏时间点
    // 覆盖系统在模块动画/布局后重新显示 MTMaterialView 的更长时间窗口
    CGFloat delays[] = {0.05, 0.15, 0.3, 0.5, 1.0, 2.0};
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *m = weakModule;
            if (m && m.window) ccbgHideMaterialBlurInModule(m);
        });
    }
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
                     @"com.apple.controlcenter.connectivity",
                     // iOS 17+ 模块标识
                     @"airplane-mode",
                     @"wifi",
                     @"bluetooth",
                     @"cellular",
                     @"personal-hotspot",
                     @"vpn",
                     @"connectivity",
                     // 额外关键词
                     @"Radio", @"Antenna", @"Modem",
                     // 展开模块标识
                     @"expandedConnectivity",
                     @"ConnectivityModule"];
    });
    return keywords;
}

// 播放控制模块类名关键词（更全面）
static NSArray *ccbgMediaModuleKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Media", @"NowPlaying", @"Playback", @"Music",
                     @"Player", @"NowPlayingInfo",
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

// 媒体模块排除关键词（防止音量、亮度等被误匹配）
// 注意：不能用 mediaremote，因为真正的播放控制模块 ID 也可能包含 mediaremote
static NSArray *ccbgMediaModuleExcludeKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Volume", @"Brightness", @"Mirroring",
                     @"ScreenMirror", @"AirPlayReceiver",
                     @"volume", @"brightness", @"mirroring",
                     // 音量模块特定排除（MRU = MediaRemote Volume）
                     @"MRUVolume", @"MRUContinuousSlider",
                     @"cc-volume-slider", @"cc-secondary-volume-slider",
                     @"cc-volume-stepper", @"cc-brightness-slider",
                     // 音量模块 ID 特定排除
                     @"controlcenter.audio",
                     // 模块标识符排除
                     @"com.apple.controlcenter.volume",
                     @"com.apple.controlcenter.brightness",
                     @"com.apple.controlcenter.mirroring",
                     @"com.apple.controlcenter.airplay",
                     @"com.apple.controlcenter.flashlight",
                     @"com.apple.controlcenter.calculator",
                     @"com.apple.controlcenter.camera",
                     // iOS 17+ 标识排除
                     @"volume-control",
                     @"brightness-control",
                     @"screen-mirroring",
                     @"airplay",
                     @"flashlight",
                     @"calculator",
                     @"camera"];
    });
    return keywords;
}

// 连接模块排除关键词
static NSArray *ccbgConnectModuleExcludeKeywords() {
    static NSArray *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"Volume", @"Brightness", @"Mirroring",
                     @"Media", @"NowPlaying", @"Playback",
                     @"Music", @"Player"];
    });
    return keywords;
}

// 检查是否包含排除关键词
static BOOL ccbgContainsExcludeKeyword(NSString *string, NSArray *excludeKeywords) {
    if (!string || !excludeKeywords) return NO;
    for (NSString *keyword in excludeKeywords) {
        if ([string rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// 递归检查视图树中是否包含关键词（最多 depth 层）
static BOOL ccbgCheckViewTreeForKeywords(UIView *view, NSArray *keywords, NSInteger depth, NSArray *excludeKeywords) {
    if (!view || depth < 0) return NO;
    NSString *className = NSStringFromClass([view class]);
    // 先检查排除关键词
    if (ccbgContainsExcludeKeyword(className, excludeKeywords)) return NO;
    for (NSString *keyword in keywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    // 额外检查 accessibilityIdentifier
    if (view.accessibilityIdentifier) {
        if (ccbgContainsExcludeKeyword(view.accessibilityIdentifier, excludeKeywords)) return NO;
        for (NSString *keyword in keywords) {
            if ([view.accessibilityIdentifier rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    // 额外检查 accessibilityLabel
    if (view.accessibilityLabel) {
        if (ccbgContainsExcludeKeyword(view.accessibilityLabel, excludeKeywords)) return NO;
        for (NSString *keyword in keywords) {
            if ([view.accessibilityLabel rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    // 检查 restorationIdentifier
    if (view.restorationIdentifier) {
        if (ccbgContainsExcludeKeyword(view.restorationIdentifier, excludeKeywords)) return NO;
        for (NSString *keyword in keywords) {
            if ([view.restorationIdentifier rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        if (ccbgCheckViewTreeForKeywords(subview, keywords, depth - 1, excludeKeywords)) {
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
    NSArray *excludeKeywords = ccbgConnectModuleExcludeKeywords();

    // 方案1: 优先通过模块标识符检测（最准确）
    NSString *moduleID = ccbgGetModuleIdentifier(view);
    if (moduleID) {
        // 先检查排除关键词
        if (ccbgContainsExcludeKeyword(moduleID, excludeKeywords)) return NO;
        for (NSString *keyword in keywords) {
            if ([moduleID rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }

    // 检查自身类名
    NSString *className = NSStringFromClass([view class]);
    if (ccbgContainsExcludeKeyword(className, excludeKeywords)) return NO;
    for (NSString *keyword in keywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    // 检查父视图类名
    UIView *superview = view.superview;
    if (superview) {
        NSString *superClassName = NSStringFromClass([superview class]);
        if (!ccbgContainsExcludeKeyword(superClassName, excludeKeywords)) {
            for (NSString *keyword in keywords) {
                if ([superClassName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    return YES;
                }
            }
        }
    }
    // 递归检查子视图（最多 6 层）—— iOS 17 模块容器类名相同，内容视图在子视图中
    return ccbgCheckViewTreeForKeywords(view, keywords, 6, excludeKeywords);
}

// 判断是否为播放控制模块（优先通过模块标识符，其次递归检查子视图类名）
static BOOL ccbgIsMediaModule(UIView *view) {
    if (!view) return NO;
    NSArray *keywords = ccbgMediaModuleKeywords();
    NSArray *excludeKeywords = ccbgMediaModuleExcludeKeywords();

    // 方案1: 优先通过模块标识符检测（最准确）
    NSString *moduleID = ccbgGetModuleIdentifier(view);
    if (moduleID) {
        // 先检查排除关键词
        if (ccbgContainsExcludeKeyword(moduleID, excludeKeywords)) return NO;
        for (NSString *keyword in keywords) {
            if ([moduleID rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
    }

    // 检查自身类名
    NSString *className = NSStringFromClass([view class]);
    if (ccbgContainsExcludeKeyword(className, excludeKeywords)) return NO;
    for (NSString *keyword in keywords) {
        if ([className rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    // 检查父视图类名
    UIView *superview = view.superview;
    if (superview) {
        NSString *superClassName = NSStringFromClass([superview class]);
        if (!ccbgContainsExcludeKeyword(superClassName, excludeKeywords)) {
            for (NSString *keyword in keywords) {
                if ([superClassName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    return YES;
                }
            }
        }
    }
    // 递归检查子视图（最多 6 层）
    return ccbgCheckViewTreeForKeywords(view, keywords, 6, excludeKeywords);
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
@property (nonatomic, strong) AVQueuePlayer *ownPlayer;
@property (nonatomic, strong) AVPlayerLooper *ownLooper;
@property (nonatomic, copy) NSString *currentVideoPath;    // 跟踪当前视频路径，URL变更时重建player
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)updateWithVideoURL:(NSURL *)videoURL blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius;
- (void)setVideoLayerHidden:(BOOL)hidden;
- (void)play;
- (void)pause;
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
        // 设置不透明背景色，防止全屏背景透过模块背景显示
        _containerLayer.backgroundColor = [UIColor blackColor].CGColor;
    }
    return self;
}

- (void)play {
    if (_ownPlayer && _ownPlayer.rate == 0) {
        [_ownPlayer play];
    }
}

- (void)pause {
    if (_ownPlayer) {
        [_ownPlayer pause];
    }
}

// 图片模式: 始终显示原始清晰图片
- (void)updateWithImage:(UIImage *)image blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius {
    _containerLayer.frame = frame;
    _containerLayer.cornerRadius = radius;

    // 移除视频层
    if (_playerLayer) {
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    }

    // 【修复图片模糊】始终显示原始图片，不使用 blurredImage
    // 原因：blurredImage 是 blurAlpha * 20px 的预渲染模糊图，
    //   - 视频模式：playerLayer 覆盖在 blurredImage 上方 → 视频清晰
    //   - 图片模式：只有 imageLayer，显示 blurredImage → 图片模糊
    // 修复：图片模式始终用原始图片；blurredImage 仅用于视频加载前的占位
    UIImage *displayImage = image;
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

// 视频模式: 每个模块背景独立的 player，避免共享冲突
- (void)updateWithVideoURL:(NSURL *)videoURL blurredImage:(UIImage *)blurredImage frame:(CGRect)frame cornerRadius:(CGFloat)radius {
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

    // 检查视频URL是否变更，变更时重建player
    NSString *newPath = videoURL.path;
    BOOL urlChanged = !_currentVideoPath || ![_currentVideoPath isEqualToString:newPath];

    if (!_ownPlayer || urlChanged) {
        // 清理旧 player
        if (_ownPlayer) {
            [_ownPlayer pause];
        }
        _ownLooper = nil;
        _ownPlayer = nil;
        if (_playerLayer) {
            [_playerLayer removeFromSuperlayer];
            _playerLayer = nil;
        }

        // 创建新 player
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoURL];
        _ownPlayer = [AVQueuePlayer queuePlayerWithItems:@[item]];
        _ownPlayer.muted = YES;
        _ownPlayer.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
        _ownLooper = [AVPlayerLooper playerLooperWithPlayer:_ownPlayer templateItem:item];

        _currentVideoPath = [newPath copy];

        if (!_playerLayer) {
            _playerLayer = [AVPlayerLayer layer];
            _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            [_containerLayer addSublayer:_playerLayer];
        }
        _playerLayer.player = _ownPlayer;
    }
    _playerLayer.frame = _containerLayer.bounds;
}

- (void)setVideoLayerHidden:(BOOL)hidden {
    if (_playerLayer) {
        _playerLayer.hidden = hidden;
    }
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
    if (_ownLooper) {
        _ownLooper = nil;
    }
    if (_ownPlayer) {
        [_ownPlayer pause];
        _ownPlayer = nil;
    }
    _currentVideoPath = nil;
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

// 展开模块背景（每种类型一个，因为同一时间只展开一个模块）
@property (nonatomic, strong) CCBgModuleBackground *expandedConnectBackground;
@property (nonatomic, strong) CCBgModuleBackground *expandedMediaBackground;
@property (nonatomic, assign) BOOL expandedModuleActive; // 是否有模块处于展开状态
@property (nonatomic, strong) NSTimer *cleanupTimer; // 延迟清理视频资源

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
- (void)handleExpandedModuleViewController:(UIViewController *)vc type:(CCBgType)type;
- (UIView *)findExpandedPlatterViewInViewController:(UIViewController *)vc;
- (void)hideAllSmallModuleBackgroundsForType:(CCBgType)type;
- (void)showAllSmallModuleBackgroundsForType:(CCBgType)type;
- (void)cleanupExpandedBackgroundForType:(CCBgType)type;
- (CGFloat)calculateCornerRadiusForView:(UIView *)moduleView;
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

        // 暂停每个模块的独立播放器并隐藏视频层
        for (CCBgModuleBackground *bg in strongSelf.connectModuleBackgrounds.allValues) {
            [bg pause];
            [bg setVideoLayerHidden:YES];
        }
        for (CCBgModuleBackground *bg in strongSelf.mediaModuleBackgrounds.allValues) {
            [bg pause];
            [bg setVideoLayerHidden:YES];
        }
        if (strongSelf.expandedConnectBackground) {
            [strongSelf.expandedConnectBackground pause];
        }
        if (strongSelf.expandedMediaBackground) {
            [strongSelf.expandedMediaBackground pause];
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
            self.originalMaterialView.layer.opacity = 0.0f;
            self.originalMaterialView.layer.hidden = YES;
        }
        if (self.fullscreenEnabled) {
            // 如果 bgContainerView 被移除了（关闭时 removeFromSuperview），重新加回
            if (self.hostView && self.bgContainerView.superview == nil) {
                if (self.originalMaterialView && self.originalMaterialView.superview) {
                    [self.hostView insertSubview:self.bgContainerView belowSubview:self.originalMaterialView];
                } else {
                    [self.hostView insertSubview:self.bgContainerView atIndex:0];
                }
                // 确保帧正确
                self.bgContainerView.frame = self.hostView.bounds;
            }
            // 恢复可见
            self.bgContainerView.layer.opacity = 1.0f;
            self.bgContainerView.layer.hidden = NO;
            self.bgContainerView.hidden = NO;
            if (self.videoView) [self.videoView play];
            else if ([self hasVideoForType:kCCBgTypeFullscreen]) {
                [self updateBackgroundView];
            }
        }

        // --- 模块背景 ---
        BOOL hasModuleBg = self.connectEnabled || self.mediaEnabled;
        if (hasModuleBg) {
            // 恢复所有模块背景可见
            for (CCBgModuleBackground *bg in self.connectModuleBackgrounds.allValues) {
                [bg setHidden:NO];
            }
            for (CCBgModuleBackground *bg in self.mediaModuleBackgrounds.allValues) {
                [bg setHidden:NO];
            }
            if (self.expandedConnectBackground) {
                [self.expandedConnectBackground setHidden:NO];
            }
            if (self.expandedMediaBackground) {
                [self.expandedMediaBackground setHidden:NO];
            }

            // 播放所有启用的模块视频
            NSArray *allModuleBgs = @[];
            if (self.connectEnabled) {
                allModuleBgs = [allModuleBgs arrayByAddingObjectsFromArray:self.connectModuleBackgrounds.allValues];
            }
            if (self.mediaEnabled) {
                allModuleBgs = [allModuleBgs arrayByAddingObjectsFromArray:self.mediaModuleBackgrounds.allValues];
            }

            if (allModuleBgs.count > 0) {
                // 每个模块背景有独立的 player，直接调用 play
                for (CCBgModuleBackground *bg in allModuleBgs) {
                    [bg play];
                    [bg setVideoLayerHidden:NO];
                }
            }
            // 展开模块背景也需要播放
            if (self.expandedConnectBackground) {
                [self.expandedConnectBackground play];
            }
            if (self.expandedMediaBackground) {
                [self.expandedMediaBackground play];
            }
        }
    } else {
        // 控制中心不可见:立即隐藏背景
        // 关键：不调用 removeFromSuperview，而是直接隐藏
        // 因为 removeFromSuperview 会导致 bgContainerView.superview 变为 nil，
        // 之后 layoutSubviews 触发 attachToHostView: 时检测到 superview 为 nil，
        // 会重新创建并添加 bgContainerView，导致背景延迟关闭

        // --- 全屏背景 ---
        if (self.fullscreenEnabled) {
            if (self.videoView) [self.videoView pause];
            // 直接隐藏，不移除，保持 bgContainerView 在视图层级中
            // 这样 attachToHostView 的 superview 检查会通过，不会重新创建
            self.bgContainerView.layer.opacity = 0.0f;
            self.bgContainerView.layer.hidden = YES;
            self.bgContainerView.hidden = YES;
            // 不恢复系统毛玻璃，保持隐藏状态
            // 否则关闭动画期间会闪现系统模糊
        }

        // --- 模块背景 ---
        for (CCBgModuleBackground *bg in self.connectModuleBackgrounds.allValues) {
            [bg pause];
            [bg setHidden:YES];
        }
        for (CCBgModuleBackground *bg in self.mediaModuleBackgrounds.allValues) {
            [bg pause];
            [bg setHidden:YES];
        }
        if (self.expandedConnectBackground) {
            [self.expandedConnectBackground pause];
            [self.expandedConnectBackground setHidden:YES];
        }
        if (self.expandedMediaBackground) {
            [self.expandedMediaBackground pause];
            [self.expandedMediaBackground setHidden:YES];
        }

        // 兜底：下一个 runloop 确保隐藏（不移除）
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.fullscreenEnabled && self.bgContainerView) {
                self.bgContainerView.layer.opacity = 0.0f;
                self.bgContainerView.layer.hidden = YES;
                self.bgContainerView.hidden = YES;
            }
        });

        // 优化 H: 延迟释放视频资源（只释放资源，不控制可见性）
        [self scheduleDeferredRelease];
    }
}

#pragma mark - 全屏背景

- (void)attachToHostView:(UIView *)view {
    // 全屏背景未开启则不挂载
    if (!self.fullscreenEnabled) {
        [self detachFullscreenViews];
        return;
    }

    // 【修复问题1】控制中心正在关闭时，直接返回不重建背景
    // 原因：关闭动画期间 layoutSubviews 仍会触发 attachToHostView:，
    //       如果此时 bgContainerView.superview != view（视图层级正在拆除），
    //       会走 detachFullscreenViews → 恢复系统毛玻璃(hidden=NO) → 重建背景，
    //       导致系统模糊闪现 + 自定义背景延迟关闭
    if (!self.isControlCenterVisible && self.bgContainerView) {
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
        self.bgContainerView.layer.opacity = 0.0f;
        self.bgContainerView.layer.hidden = YES;
        self.bgContainerView.hidden = YES;
        [self detachMediaViews];
        return;
    }
    if (!self.isControlCenterVisible) {
        self.bgContainerView.layer.opacity = 0.0f;
        self.bgContainerView.layer.hidden = YES;
        self.bgContainerView.hidden = YES;
        return;
    }
    self.bgContainerView.layer.opacity = 1.0f;
    self.bgContainerView.layer.hidden = NO;
    self.bgContainerView.hidden = NO;

    // 每次更新都强制重新隐藏系统毛玻璃层
    // 系统会在布局过程中重新显示 MTMaterialView，导致模糊覆盖在自定义背景上
    if (self.originalMaterialView) {
        self.originalMaterialView.hidden = YES;
        self.originalMaterialView.layer.opacity = 0.0f;
        self.originalMaterialView.layer.hidden = YES;
    }
    // 延迟再次隐藏，防止系统在布局后重新显示
    __weak UIView *weakMat = self.originalMaterialView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *mat = weakMat;
        if (mat) {
            mat.hidden = YES;
            mat.layer.opacity = 0.0f;
            mat.layer.hidden = YES;
        }
    });

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
    // 【修复问题1】控制中心不可见时（关闭动画期间）不恢复系统毛玻璃
    // 否则 detachFullscreenViews 会将 originalMaterialView.hidden = NO，
    // 导致系统模糊在关闭动画期间闪现
    if (self.originalMaterialView && self.isControlCenterVisible) {
        self.originalMaterialView.hidden = NO;
    }
    self.originalMaterialView = nil;
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

    // 【修复连接模块模糊】追踪已管理的模块视图
    // 使 ccbgIsInsideManagedModule 的 MTMaterialView 持久隐藏 hook 能正确识别
    if (isConnect || isMedia) {
        ccbgRegisterManagedModule(moduleView);
    }

    // 调试日志（按 moduleID 去重，因为所有模块类名相同）
    NSMutableSet *loggedModules = sCCBgLoggedModules();
    NSString *clsName = NSStringFromClass([moduleView class]);
    NSString *moduleID = ccbgGetModuleIdentifier(moduleView);
    NSString *dedupKey = moduleID ?: clsName;
    @synchronized(loggedModules) {
        if (![loggedModules containsObject:dedupKey]) {
            [loggedModules addObject:dedupKey];
            ccbg_log(@"module detected: class=%@ isConnect=%d isMedia=%d (connectEnabled=%d mediaEnabled=%d) moduleID=%@ frame=%@",
                  clsName, isConnect, isMedia, self.connectEnabled, self.mediaEnabled,
                  moduleID ?: @"nil", NSStringFromCGRect(moduleView.frame));
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

    // 只处理看起来像模块容器的视图
    NSString *className = NSStringFromClass([view class]);
    BOOL isModuleContainer = [className rangeOfString:@"Module" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [className rangeOfString:@"Container" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [className rangeOfString:@"Platter" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [className rangeOfString:@"Expanded" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [className rangeOfString:@"Extension" options:NSCaseInsensitiveSearch].location != NSNotFound;

    // 必须有一定尺寸和子视图，或者本身就是模块容器类
    BOOL isContainerLike = isModuleContainer &&
                           view.subviews.count > 0 &&
                           CGRectGetWidth(view.bounds) > 40 &&
                           CGRectGetHeight(view.bounds) > 40;

    if (isContainerLike) {
        // 尝试用模块检测逻辑判断
        BOOL isConnect = self.connectEnabled && ccbgIsConnectModule(view);
        BOOL isMedia = self.mediaEnabled && ccbgIsMediaModule(view);

        if (isConnect || isMedia) {
            ccbg_log(@"scanView found module: class=%@ isConnect=%d isMedia=%d frame=%@",
                  className, isConnect, isMedia, NSStringFromCGRect(view.frame));
            [self handleModuleView:view];
        }
    }

    // 继续扫描子视图
    for (UIView *subview in view.subviews) {
        [self scanView:subview depth:depth + 1 maxDepth:maxDepth];
    }
}

// MARK: 展开模块背景 - 新方案
// 在展开模块 VC 中查找实际的卡片视图
// VC 的 view 是全屏的，实际卡片是内部的某个子视图（有圆角、尺寸较大）
- (UIView *)findExpandedPlatterViewInViewController:(UIViewController *)vc {
    UIView *rootView = vc.view;
    if (!rootView) return nil;
    return [self findPlatterViewForExpanded:rootView depth:0 maxDepth:6];
}

- (UIView *)findPlatterViewForExpanded:(UIView *)view depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (!view || depth > maxDepth) return nil;

    // 查找有圆角且尺寸合理的视图（展开模块的卡片特征）
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    CGFloat radius = view.layer.cornerRadius;

    if (radius > 10 && width > 150 && height > 150 && width < 500 && height < 800) {
        // 排除全屏视图
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        if (width < CGRectGetWidth(screenBounds) - 20 || height < CGRectGetHeight(screenBounds) - 20) {
            return view;
        }
    }

    for (UIView *subview in view.subviews) {
        UIView *found = [self findPlatterViewForExpanded:subview depth:depth + 1 maxDepth:maxDepth];
        if (found) return found;
    }
    return nil;
}

// 通过 CCUIContentModuleContainerViewController 的 isExpanded 判断展开状态
// 背景直接加到 VC 的 view 上，不需要 hook PLExpandedPlatterView
- (void)handleExpandedModuleViewController:(UIViewController *)vc type:(CCBgType)type {
    UIView *moduleView = vc.view;
    if (!moduleView || !moduleView.window) return;

    // 【修复连接模块模糊】追踪已管理的展开模块视图
    ccbgRegisterManagedModule(moduleView);

    // 找到展开模块内部实际的卡片视图（不是 VC 的全屏 view）
    // 展开后 VC 的 view 是全屏的，实际卡片是内部的 platter/content view
    UIView *platterView = [self findExpandedPlatterViewInViewController:vc];
    UIView *targetView = platterView ?: moduleView;
    UIView *superview = targetView.superview ?: moduleView;

    // 用卡片视图的 frame（转换到 superview 坐标系）
    CGRect bgFrame;
    if (platterView) {
        bgFrame = [targetView convertRect:targetView.bounds toView:superview];
    } else {
        bgFrame = moduleView.frame;
    }

    // 模块还没布局好，跳过
    if (CGRectGetWidth(bgFrame) < 50 || CGRectGetHeight(bgFrame) < 50) return;

    // 获取或创建展开背景
    CCBgModuleBackground *bg = (type == kCCBgTypeConnect) ? self.expandedConnectBackground : self.expandedMediaBackground;

    // 计算圆角和模糊
    CGFloat cornerRadius = platterView ? platterView.layer.cornerRadius : [self calculateCornerRadiusForView:targetView];
    if (cornerRadius < 1) cornerRadius = [self calculateCornerRadiusForView:targetView];
    CGFloat blurAlpha = (type == kCCBgTypeConnect) ? self.connectBlurAlpha : self.mediaBlurAlpha;

    ccbg_log(@"expanded VC bg: type=%ld platterClass=%@ frame=%@ cornerRadius=%.1f",
          (long)type, NSStringFromClass([targetView class]), NSStringFromCGRect(bgFrame), cornerRadius);

    if (!bg) {
        bg = [[CCBgModuleBackground alloc] init];
        [superview.layer insertSublayer:bg.containerLayer below:targetView.layer];

        if (type == kCCBgTypeConnect) {
            self.expandedConnectBackground = bg;
        } else {
            self.expandedMediaBackground = bg;
        }

        // 展开时隐藏对应的小模块背景
        [self hideAllSmallModuleBackgroundsForType:type];
        self.expandedModuleActive = YES;

        ccbg_log(@"expanded VC bg CREATED: type=%ld", (long)type);
    } else {
        // 父视图变了则重新挂载
        if (bg.containerLayer.superlayer != superview.layer) {
            [bg.containerLayer removeFromSuperlayer];
            [superview.layer insertSublayer:bg.containerLayer below:targetView.layer];
        }
    }

    // 更新背景内容
    UIImage *image = [self getImageForType:type];
    NSURL *videoURL = [self getVideoURLForType:type];
    BOOL hasVideo = videoURL != nil;
    BOOL hasImage = image != nil;

    UIImage *blurredImage = nil;
    if (blurAlpha > 0.01 && hasImage) {
        blurredImage = [self getBlurredImageForType:type blurAlpha:blurAlpha];
    }

    if (hasVideo) {
        [bg updateWithVideoURL:videoURL blurredImage:blurredImage frame:bgFrame cornerRadius:cornerRadius];
        if (self.isControlCenterVisible) {
            [bg play];
        }
    } else if (hasImage) {
        [bg updateWithImage:image blurredImage:blurredImage frame:bgFrame cornerRadius:cornerRadius];
    }
    
    // 隐藏展开模块内 MTMaterialView，消除系统模糊
    ccbgHideMaterialBlurInModule(moduleView);
    ccbgScheduleMaterialBlurClamp(moduleView);
}

// 隐藏指定类型的所有小模块背景（展开时调用）
- (void)hideAllSmallModuleBackgroundsForType:(CCBgType)type {
    NSDictionary *bgDict = (type == kCCBgTypeConnect) ? self.connectModuleBackgrounds : self.mediaModuleBackgrounds;
    for (CCBgModuleBackground *bg in bgDict.allValues) {
        bg.containerLayer.hidden = YES;
    }
    ccbg_log(@"hidden all small module backgrounds for type=%ld (%lu modules)", (long)type, (unsigned long)bgDict.count);
}

// 显示指定类型的所有小模块背景（收起时调用）
- (void)showAllSmallModuleBackgroundsForType:(CCBgType)type {
    NSDictionary *bgDict = (type == kCCBgTypeConnect) ? self.connectModuleBackgrounds : self.mediaModuleBackgrounds;
    for (CCBgModuleBackground *bg in bgDict.allValues) {
        bg.containerLayer.hidden = NO;
    }
    ccbg_log(@"shown all small module backgrounds for type=%ld (%lu modules)", (long)type, (unsigned long)bgDict.count);
}

// 清理展开模块背景（收起时调用）
- (void)cleanupExpandedBackgroundForType:(CCBgType)type {
    CCBgModuleBackground *bg = (type == kCCBgTypeConnect) ? self.expandedConnectBackground : self.expandedMediaBackground;
    if (bg) {
        [bg cleanup];
        if (type == kCCBgTypeConnect) {
            self.expandedConnectBackground = nil;
        } else {
            self.expandedMediaBackground = nil;
        }
        ccbg_log(@"cleaned up expanded module background for type=%ld", (long)type);
    }

    // 恢复小模块背景显示
    [self showAllSmallModuleBackgroundsForType:type];

    // 检查是否还有展开的模块
    if (!self.expandedConnectBackground && !self.expandedMediaBackground) {
        self.expandedModuleActive = NO;
    }
}

// 在模块视图中查找真正的卡片视图（CCUIContentModuleBackgroundView）
// 模块容器比实际卡片大，有内边距，所以需要找到真正的卡片来对齐背景
- (UIView *)findPlatterViewInModule:(UIView *)moduleView {
    // 直接查找 CCUIContentModuleBackgroundView
    for (UIView *subview in moduleView.subviews) {
        if ([NSStringFromClass([subview class]) isEqualToString:@"CCUIContentModuleBackgroundView"]) {
            return subview;
        }
        UIView *found = [self findPlatterViewInSubviews:subview depth:0 maxDepth:5];
        if (found) return found;
    }
    return nil;
}

- (UIView *)findPlatterViewInSubviews:(UIView *)view depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (!view || depth > maxDepth) return nil;
    
    NSString *clsName = NSStringFromClass([view class]);
    if ([clsName isEqualToString:@"CCUIContentModuleBackgroundView"]) {
        return view;
    }
    
    for (UIView *subview in view.subviews) {
        UIView *found = [self findPlatterViewInSubviews:subview depth:depth + 1 maxDepth:maxDepth];
        if (found) return found;
    }
    return nil;
}

// 智能计算模块圆角（处理胶囊形滑块等特殊形状）
- (CGFloat)calculateCornerRadiusForView:(UIView *)moduleView {
    CGFloat viewRadius = moduleView.layer.cornerRadius;
    CGFloat width = CGRectGetWidth(moduleView.bounds);
    CGFloat height = CGRectGetHeight(moduleView.bounds);
    CGFloat minDim = fmin(width, height);
    CGFloat maxDim = fmax(width, height);

    // 方案1: 视图本身有 cornerRadius，直接用
    if (viewRadius > 0) {
        return viewRadius;
    }

    // 方案2: 递归查找子视图的 cornerRadius（系统模块常把圆角设在内容子视图上）
    CGFloat subviewRadius = [self findMaxCornerRadiusInSubviews:moduleView depth:0 maxDepth:4];
    if (subviewRadius > 0) {
        return subviewRadius;
    }

    // 方案3: 根据形状判断
    CGFloat ratio = maxDim / minDim;

    // 胶囊形状（长宽比 > 2:1），比如亮度、音量滑块
    if (ratio > 2.0 && minDim > 20) {
        // 胶囊形：圆角等于短边的一半
        return minDim * 0.5;
    }

    // 普通方形/长方形模块，使用 25% 圆角
    return minDim * 0.25;
}

// 递归查找子视图中的最大 cornerRadius
- (CGFloat)findMaxCornerRadiusInSubviews:(UIView *)view depth:(NSInteger)depth maxDepth:(NSInteger)maxDepth {
    if (!view || depth > maxDepth) return 0;
    CGFloat maxRadius = view.layer.cornerRadius;

    // 如果找到一个接近胶囊形状的圆角（约等于短边的一半），直接返回
    CGFloat minDim = fmin(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));
    if (maxRadius > 0 && fabs(maxRadius - minDim * 0.5) < 2.0) {
        return maxRadius;
    }

    for (UIView *subview in view.subviews) {
        CGFloat subRadius = [self findMaxCornerRadiusInSubviews:subview depth:depth + 1 maxDepth:maxDepth];
        if (subRadius > maxRadius) {
            maxRadius = subRadius;
            // 找到胶囊形圆角就直接返回
            CGFloat subMinDim = fmin(CGRectGetWidth(subview.bounds), CGRectGetHeight(subview.bounds));
            if (fabs(subRadius - subMinDim * 0.5) < 2.0) {
                return maxRadius;
            }
        }
    }

    return maxRadius;
}

// 更新单个模块背景
- (void)updateModuleBackground:(UIView *)moduleView forType:(CCBgType)type {
    NSMutableDictionary *bgDict = (type == kCCBgTypeConnect) ? self.connectModuleBackgrounds : self.mediaModuleBackgrounds;
    CGFloat blurAlpha = (type == kCCBgTypeConnect) ? self.connectBlurAlpha : self.mediaBlurAlpha;

    NSNumber *key = [NSNumber numberWithUnsignedLong:(unsigned long)moduleView];
    CCBgModuleBackground *bg = bgDict[key];

    // 找到模块内部真正的卡片背景视图（CCUIContentModuleBackgroundView）
    UIView *platterView = [self findPlatterViewInModule:moduleView];
    UIView *superview = moduleView.superview;
    if (!superview) return;
    
    // 背景 frame：优先用 platterView 的 frame（转换到 superview 坐标系）
    // 黑色 backgroundColor 已确保不会透出全屏背景
    CGRect bgFrame;
    CGFloat cornerRadius;

    if (platterView) {
        bgFrame = [moduleView convertRect:platterView.frame toView:superview];
        cornerRadius = platterView.layer.cornerRadius;
        if (cornerRadius < 1) {
            cornerRadius = [self calculateCornerRadiusForView:platterView];
        }
    } else {
        bgFrame = moduleView.frame;
        cornerRadius = [self calculateCornerRadiusForView:moduleView];
    }

    // 模块还没布局好（frame 为 0），跳过
    if (CGRectGetWidth(bgFrame) < 10 || CGRectGetHeight(bgFrame) < 10) {
        return;
    }

    if (!bg) {
        bg = [[CCBgModuleBackground alloc] init];
        [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
        bgDict[key] = bg;
        ccbg_log(@"module bg CREATED: type=%ld platterClass=%@ frame=%@ cornerRadius=%.1f hasImage=%d hasVideo=%d",
              (long)type, NSStringFromClass([platterView class] ?: [moduleView class]),
              NSStringFromCGRect(bgFrame), cornerRadius,
              (type == kCCBgTypeConnect) ? self.cachedConnectHasImage : self.cachedMediaHasImage,
              (type == kCCBgTypeConnect) ? self.cachedConnectHasVideo : self.cachedMediaHasVideo);
    } else {
        // 宿主变了或被移除了则重新挂载
        if (bg.containerLayer.superlayer != superview.layer) {
            [bg.containerLayer removeFromSuperlayer];
            [superview.layer insertSublayer:bg.containerLayer below:moduleView.layer];
        }
    }

    // 节流：尺寸和圆角没变就跳过渲染更新
    if (CGRectEqualToRect(bg.containerLayer.frame, bgFrame) &&
        fabs(bg.containerLayer.cornerRadius - cornerRadius) < 0.1) {
        [bg setHidden:moduleView.hidden];
        [bg setAlpha:moduleView.alpha];
        return;
    }

    UIImage *blurredImage = [self getBlurredImageForType:type blurAlpha:blurAlpha];

    if ([self hasVideoForType:type]) {
        NSURL *videoURL = [self getVideoURLForType:type];
        if (videoURL) {
            [bg updateWithVideoURL:videoURL blurredImage:blurredImage frame:bgFrame cornerRadius:cornerRadius];
            if (self.isControlCenterVisible) {
                [bg play];
            }
            BOOL isVisible = [self isModuleViewVisible:moduleView];
            [bg setVideoLayerHidden:!isVisible];
        }
    } else {
        UIImage *image = [self getImageForType:type];
        if (image) {
            [bg updateWithImage:image blurredImage:blurredImage frame:bgFrame cornerRadius:cornerRadius];
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
    
    // 隐藏模块内 MTMaterialView，消除系统模糊
    // 这样自定义背景图片能清晰显示
    ccbgHideMaterialBlurInModule(moduleView);
    ccbgScheduleMaterialBlurClamp(moduleView);
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
    // 同时清理展开模块背景
    [self cleanupExpandedBackgroundForType:kCCBgTypeConnect];
    [self cleanupExpandedBackgroundForType:kCCBgTypeMedia];
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

// MARK: - MTMaterialView 管理辅助

// 检查 MTMaterialView 是否位于连接模块或播放控制模块内部
// 用于 hook MTMaterialView 的 layoutSubviews / setHidden: 持续隐藏系统模糊
// 替代之前延迟重新隐藏的方案（延迟方案无法对抗系统持续布局）
static BOOL ccbgIsInsideManagedModule(UIView *materialView) {
    if (!materialView) return NO;

    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    if (!(mgr.connectEnabled || mgr.mediaEnabled)) return NO;
    if (!mgr.isControlCenterVisible) return NO;

    // 快速窗口过滤：不在控制中心窗口内的 MTMaterialView 直接跳过
    // 避免对 Banner/Folder/Widget 等非控制中心的 MTMaterialView 做无谓的层级遍历
    if (mgr.hostView && materialView.window != mgr.hostView.window) return NO;

    // 【修复连接模块模糊】优先检查是否在已追踪的管理模块内
    // handleModuleView: 和 handleExpandedModuleViewController: 已成功检测的模块视图
    // 会注册到 sCCBgManagedModules，这里通过祖先链查找匹配
    // 这比类名匹配更可靠，因为不依赖 iOS 版本特定的类名/关键词
    if (ccbgIsDescendantOfManagedModule(materialView)) return YES;

    // 向上遍历视图层级，查找模块容器
    UIView *v = materialView;
    NSInteger depth = 0;
    while (v && depth < 20) {
        NSString *cls = NSStringFromClass([v class]);
        // 找到模块容器视图
        if ([cls containsString:@"ContentModuleContainer"] ||
            [cls containsString:@"ModuleContainerView"]) {
            // 用完整的模块检测逻辑判断是否为连接/媒体模块
            if (mgr.connectEnabled && ccbgIsConnectModule(v)) return YES;
            if (mgr.mediaEnabled && ccbgIsMediaModule(v)) return YES;
            return NO; // 是模块容器但不是连接/媒体模块
        }
        v = v.superview;
        depth++;
    }
    return NO;
}

// MARK: - Hooks

// 主 hook: 控制中心 overlay controller
%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ccbg_log(@"CC overlay viewWillAppear");
    ccbgLogExpandedClasses();
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:YES];
    UIView *root = [(UIViewController *)self view];
    [[CustomCCBgManager sharedInstance] attachToHostView:root];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ccbg_log(@"CC overlay viewDidAppear");
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:YES];
}

// 最早期信号：view 移出窗口时立即隐藏背景
// 这比 viewWillDisappear 更早，能和控制中心关闭动画同步
- (void)viewWillDisappear:(BOOL)animated {
    // 先隐藏背景，再执行 orig（orig 会触发关闭动画）
    // 用 CATransaction 确保 layer 属性立即生效，不被系统动画捕获
    ccbg_log(@"CC overlay viewWillDisappear → instant remove");
    [CATransaction begin];
    [CATransaction setAnimationDuration:0];
    [CATransaction setDisableActions:YES];
    [[CustomCCBgManager sharedInstance] setControlCenterVisible:NO];
    [CATransaction commit];
    %orig;
}

// 兜底：viewDidDisappear 确保已关闭
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
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
    // 不再扫描子视图寻找模块
    // CCUIContentModuleContainerViewController hook 已足够可靠地检测模块
    // 扫描可能找到不同层级的视图（和 VC 的 view 指针不同），导致重复背景
}

%end

// 模块背景 hook: 控制中心模块容器（展开状态也可能使用这个类）
// MARK: - 模块视图控制器 hook
// 核心：hook CCUIContentModuleContainerViewController
// 这个 VC 同时管理小模块和展开模块两种状态，通过 isExpanded 判断
// 不需要 hook PLExpandedPlatterView 等 NotificationCenterUI 的类
%hook CCUIContentModuleContainerViewController

// 模块视图加载到窗口时处理
- (void)viewDidLayoutSubviews {
    %orig;

    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    UIView *view = [(UIViewController *)self view];
    if (!view) return;

    // 检测是否是连接/媒体模块
    BOOL isConnect = mgr.connectEnabled && ccbgIsConnectModule(view);
    BOOL isMedia = mgr.mediaEnabled && ccbgIsMediaModule(view);

    if (!isConnect && !isMedia) return;

    // 判断模块是否展开
    BOOL isExpanded = NO;
    if ([(id)self respondsToSelector:@selector(isExpanded)]) {
        isExpanded = [(id)self isExpanded];
    }

    CCBgType bgType = isConnect ? kCCBgTypeConnect : kCCBgTypeMedia;

    if (isExpanded) {
        // 展开状态：显示大模块背景，隐藏小模块背景
        [mgr handleExpandedModuleViewController:(UIViewController *)self type:bgType];
    } else {
        // 收起状态：显示小模块背景，清理展开背景
        [mgr cleanupExpandedBackgroundForType:bgType];
        [mgr handleModuleView:view];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
    UIView *view = [(UIViewController *)self view];
    if (!view) return;

    BOOL isConnect = mgr.connectEnabled && ccbgIsConnectModule(view);
    BOOL isMedia = mgr.mediaEnabled && ccbgIsMediaModule(view);

    if (isConnect || isMedia) {
        ccbg_log(@"CCUIContentModuleContainerViewController viewWillAppear: moduleID=%@ isExpanded=%d",
              ccbgGetModuleIdentifier(view) ?: @"nil",
              [(id)self respondsToSelector:@selector(isExpanded)] ? [(id)self isExpanded] : NO);
    }
}

%end

// 仅保留 willMoveToWindow 用于检测控制中心关闭
// 不再在 layoutSubviews / didMoveToWindow 中调用 handleModuleView:
// 因为 CCUIContentModuleContainerView 和 VC 的 view 是不同对象，
// 同时调用 handleModuleView: 会以不同指针为 key 创建两个背景
%hook CCUIContentModuleContainerView

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) {
        CustomCCBgManager *mgr = [CustomCCBgManager sharedInstance];
        if (mgr.isControlCenterVisible) {
            ccbg_log(@"willMoveToWindow:nil → CC closing, hide bg immediately");
            [mgr setControlCenterVisible:NO];
        }
    }
}

%end

// MARK: - MTMaterialView 持续隐藏 hook
// 核心方案：hook MTMaterialView 的 layoutSubviews / setHidden: / setAlpha:
// 每次系统布局后或尝试显示时，如果该 MTMaterialView 在连接或媒体模块内，立即隐藏
// 这能彻底解决系统持续重新显示 MTMaterialView 导致的模糊问题
// 比 ccbgScheduleMaterialBlurClamp 的延迟方案更可靠
// 注意：MTMaterialView 是私有类，编译器不知道其继承链
// 需要将 self 强转为 UIView * 才能访问 hidden / layer 等属性
%hook MTMaterialView

// 系统布局完成后立即检查并隐藏
- (void)layoutSubviews {
    %orig;
    UIView *selfView = (UIView *)self;
    if (ccbgIsInsideManagedModule(selfView)) {
        selfView.hidden = YES;
        selfView.layer.opacity = 0.0f;
        selfView.layer.hidden = YES;
        // 【修复问题2&3】同时隐藏同级的液态玻璃
        ccbgHideGlassSiblingsOf(selfView);
    }
}

// 拦截系统尝试显示 MTMaterialView 的操作
- (void)setHidden:(BOOL)hidden {
    UIView *selfView = (UIView *)self;
    // 如果系统试图显示（hidden=NO），且该 MTMaterialView 在管理模块内，强制保持隐藏
    if (!hidden && ccbgIsInsideManagedModule(selfView)) {
        // 调用原始实现设置 hidden=YES，绕过我们的 hook 避免递归
        %orig(YES);
        selfView.layer.opacity = 0.0f;
        selfView.layer.hidden = YES;
        // 【修复问题2&3】同时隐藏同级的液态玻璃
        ccbgHideGlassSiblingsOf(selfView);
        return;
    }
    %orig;
}

// 拦截系统通过 alpha 属性显示 MTMaterialView 的操作
- (void)setAlpha:(CGFloat)alpha {
    UIView *selfView = (UIView *)self;
    if (alpha > 0.01 && ccbgIsInsideManagedModule(selfView)) {
        %orig(0.0f);
        selfView.layer.opacity = 0.0f;
        selfView.layer.hidden = YES;
        // 【修复问题2&3】同时隐藏同级的液态玻璃
        ccbgHideGlassSiblingsOf(selfView);
        return;
    }
    %orig;
}

// MTMaterialView 被添加到窗口时检查
- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    if (ccbgIsInsideManagedModule(selfView)) {
        selfView.hidden = YES;
        selfView.layer.opacity = 0.0f;
        selfView.layer.hidden = YES;
        // 【修复问题2&3】同时隐藏同级的液态玻璃
        ccbgHideGlassSiblingsOf(selfView);
    }
}

%end

// MARK: - 构造函数

%ctor {
    // 初始化所有 hook
    %init;

    // 确保 CustomCCBgManager 单例延迟初始化
    dispatch_async(dispatch_get_main_queue(), ^{
        [CustomCCBgManager sharedInstance];
    });
}
