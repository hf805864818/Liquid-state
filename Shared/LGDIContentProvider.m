// =============================================================================
//  LGDIContentProvider.m — 灵动岛内容 Provider 机制（阶段 3）
// -----------------------------------------------------------------------------
//  内置提供者：
//    DIMusicContentProvider    — NowPlaying/音乐实时活动（专辑封面、波形/频谱、
//                                播放控件），只剥容器黑底、保护封面内容本体
//    DIVolumeContentProvider   — 系统音量实时活动（音量条容器）
//    DIGenericFallbackProvider — 通用近黑剥离路径（历史行为），保证新 App 开箱即用
//
//  仅做视图树签名匹配（类名子串 + 可选 bundle 提示），不调用任何未验证的
//  私有 API，因此不会因 iOS 小版本类名差异崩溃：匹配不到就回退 fallback。
// =============================================================================

#import <UIKit/UIKit.h>

#import "LGDIContentProvider.h"

#pragma mark - Base

@interface DIContentProviderBase : NSObject <DIContentProviding>
@end

@implementation DIContentProviderBase

- (NSString *)identifier { return @"base"; }
- (NSArray<NSString *> *)classKeywords { return @[]; }
- (NSArray<NSString *> *)bundleKeywords { return @[]; }

- (NSInteger)keywordHitCountForClassName:(NSString *)className {
    if (className.length == 0) return 0;
    NSString *lower = className.lowercaseString;
    NSInteger hits = 0;
    for (NSString *kw in self.classKeywords) {
        if (kw.length && [lower containsString:kw]) hits++;
    }
    return hits;
}

- (BOOL)matchesBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return NO;
    NSString *lower = bundleID.lowercaseString;
    for (NSString *kw in self.bundleKeywords) {
        if (kw.length && [lower containsString:kw]) return YES;
    }
    return NO;
}

- (NSInteger)scoreExpandedCandidate:(UIView *)view {
    // 基类不参与打分（专用提供者子类 override）
    return 0;
}

- (BOOL)shouldStripNearBlackBackgroundForView:(UIView *)view {
    return YES;
}

@end

#pragma mark - Music（NowPlaying / 媒体播放）

@interface DIMusicContentProvider : DIContentProviderBase
@end

@implementation DIMusicContentProvider

- (NSString *)identifier { return @"music"; }

// iOS 17 媒体实时活动相关类名签名（MediaRemote / NowPlaying / 波形频谱等）。
// 关键词保持足够特异，避免误伤其它活动容器。
- (NSArray<NSString *> *)classKeywords {
    static NSArray *kw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[
            @"nowplaying", @"playback", @"mediaremote", @"mediacontrols",
            @"artwork", @"mru", @"equalizer", @"spectrum",
            @"waveform", @"waveview", @"audiovisualizer",
        ];
    });
    return kw;
}

// 任意 App 都可能通过 NowPlaying 播放媒体，不做 bundle 限定
- (NSArray<NSString *> *)bundleKeywords { return @[]; }

- (NSInteger)scoreExpandedCandidate:(UIView *)view {
    NSInteger hits = [self keywordHitCountForClassName:NSStringFromClass(view.class)];
    if (hits == 0) return 0;
    NSInteger score = hits * 10;
    // 容器特征：带少量子视图（封面/标题/控件），而非叶子图片层
    NSUInteger subs = view.subviews.count;
    if (subs >= 1 && subs <= 30) score += 2;
    if ([view isKindOfClass:UIImageView.class]) score -= 20; // 封面是内容，不是卡片容器
    return score;
}

- (BOOL)shouldStripNearBlackBackgroundForView:(UIView *)view {
    // 专辑封面 / 内容图片：即便带近黑背景也绝不剥离（黑胶、深色封面很常见）
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image != nil) {
        return NO;
    }
    return YES;
}

@end

#pragma mark - Volume（系统音量实时活动）

@interface DIVolumeContentProvider : DIContentProviderBase
@end

@implementation DIVolumeContentProvider

- (NSString *)identifier { return @"volume"; }

- (NSArray<NSString *> *)classKeywords {
    static NSArray *kw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[ @"volume" ];  // 音量条/音量实时活动类名均含 Volume
    });
    return kw;
}

- (NSArray<NSString *> *)bundleKeywords { return @[]; }

- (NSInteger)scoreExpandedCandidate:(UIView *)view {
    NSInteger hits = [self keywordHitCountForClassName:NSStringFromClass(view.class)];
    if (hits == 0) return 0;
    NSInteger score = hits * 10;
    if (view.subviews.count >= 1) score += 2;
    if ([view isKindOfClass:UIImageView.class]) score -= 20;
    return score;
}

@end

#pragma mark - Generic fallback（历史通用行为）

@interface DIGenericFallbackProvider : DIContentProviderBase
@end

@implementation DIGenericFallbackProvider

- (NSString *)identifier { return @"generic"; }

// 与 DynamicIsland.x 历史内容关键词保持一致：
// 命中即给 1 分，让"像内容容器"的候选在同分面积比较前获得微弱优先
- (NSArray<NSString *> *)classKeywords {
    static NSArray *kw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[
            @"element", @"presenter", @"content", @"scene", @"compact",
            @"expanded", @"leading", @"trailing", @"hero", @"attachment",
            @"custom", @"activity", @"viewcontroller",
        ];
    });
    return kw;
}

- (NSInteger)scoreExpandedCandidate:(UIView *)view {
    if ([view isKindOfClass:UIImageView.class]) return 0;
    return [self keywordHitCountForClassName:NSStringFromClass(view.class)] > 0 ? 1 : 0;
}

@end

#pragma mark - Registry

@interface DIContentProviderRegistry ()
@property (nonatomic, strong) NSArray<id<DIContentProviding>> *providers;
@property (nonatomic, strong) id<DIContentProviding> fallback;
@property (nonatomic, strong) id<DIContentProviding> music;
@property (nonatomic, strong) id<DIContentProviding> volume;
@end

@implementation DIContentProviderRegistry

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _music = [DIMusicContentProvider new];
    _volume = [DIVolumeContentProvider new];
    _fallback = [DIGenericFallbackProvider new];
    // 匹配顺序：越特异越靠前；fallback 永远垫底
    _providers = @[ _music, _volume ];
    return self;
}

- (id<DIContentProviding>)fallbackProvider { return self.fallback; }
- (id<DIContentProviding>)musicProvider { return self.music; }
- (id<DIContentProviding>)volumeProvider { return self.volume; }

- (id<DIContentProviding>)providerForView:(UIView *)view
                             hintBundleID:(NSString *)bundleID {
    if (!view) return self.fallback;

    NSString *className = NSStringFromClass(view.class);
    id<DIContentProviding> best = nil;
    NSInteger bestHits = 0;
    for (id<DIContentProviding> p in self.providers) {
        NSInteger hits = [p keywordHitCountForClassName:className];
        if ([p matchesBundleID:bundleID]) hits += 4;  // bundle 强命中加权
        if (hits > bestHits) { bestHits = hits; best = p; }
    }
    return best ?: self.fallback;
}

- (id<DIContentProviding>)providerForContentTree:(UIView *)root
                                    hintBundleID:(NSString *)bundleID {
    if (!root) return self.fallback;

    // bundle 强命中直接选定（视图类名可能尚未加载完成）
    if (bundleID.length) {
        for (id<DIContentProviding> p in self.providers) {
            if ([p matchesBundleID:bundleID]) return p;
        }
    }

    NSMutableDictionary<NSNumber *, NSNumber *> *scores = [NSMutableDictionary dictionary];
    NSMutableArray<id<DIContentProviding>> *specialists = [NSMutableArray array];

    __block __weak void (^weakWalk)(UIView *, NSUInteger);
    void (^walk)(UIView *, NSUInteger) = ^(UIView *v, NSUInteger depth) {
        if (!v || depth > 10) return;
        NSString *cn = NSStringFromClass(v.class);
        NSUInteger idx = 0;
        for (id<DIContentProviding> p in self.providers) {
            NSInteger hits = [p keywordHitCountForClassName:cn];
            if (hits > 0) {
                NSNumber *key = @(idx);
                NSInteger cur = scores[key].integerValue;
                scores[key] = @(cur + hits);
                if (![specialists containsObject:p]) [specialists addObject:p];
            }
            idx++;
        }
        for (UIView *sub in v.subviews) weakWalk(sub, depth + 1);
    };
    weakWalk = walk;
    walk(root, 0);

    id<DIContentProviding> best = nil;
    NSInteger bestHits = 0;
    NSUInteger idx = 0;
    for (id<DIContentProviding> p in self.providers) {
        NSInteger hits = scores[@(idx)].integerValue;
        if (hits > bestHits) { bestHits = hits; best = p; }
        idx++;
    }
    return best ?: self.fallback;
}

- (BOOL)shouldStripNearBlackBackgroundForView:(UIView *)view {
    if (!view) return NO;
    return [[self providerForView:view hintBundleID:nil]
        shouldStripNearBlackBackgroundForView:view];
}

@end
