// =============================================================================
//  LGDIContentProvider.h — 灵动岛内容 Provider 机制（阶段 3）
// -----------------------------------------------------------------------------
//  对标 Mango Beta7 的 MangoPillContentProvider / MangoPillContentProviders：
//  Mango 在 MangoPillElement 上为 7 个插槽各挂一个 content view provider
//  （action / leading / minimal / primary / secondary / trailing /
//   detachedMinimal），由 Provider 主动识别内容、决定背景剥离策略。
//
//  Mango 的 Provider 深度绑定 SAUIElementAssertion 内容承载管道（直接替换
//  SystemAperture 的内容下发），整套复刻需要介入 SceneAgent 私有基础设施，
//  风险与工作量都不可控。本项目采用等价但轻量的方案：
//
//    Provider 不"提供视图"，而是"识别视图树 + 定制策略"：
//      1. 展开内容容器定位（scoreExpandedCandidate:）——
//         替代 LGDIFindExpandedContentFrame 的纯几何启发式，
//         解决"部分 App 展开后液态玻璃找不到/找错容器"；
//      2. 近黑剥离保护（shouldStripNearBlackBackgroundForView:）——
//         专辑封面等内容本体不被当成黑底剥掉；
//      3. bundle 标识为 best-effort（element 上 respondsToSelector 保护），
//         拿不到时仅靠视图类名签名匹配，通用 fallback 保证开箱即用。
// =============================================================================

#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 灵动岛内容插槽（对标 Mango 7 插槽命名）
typedef NS_ENUM(NSInteger, DIContentSlot) {
    DIContentSlotUnknown = 0,
    DIContentSlotLeading,
    DIContentSlotTrailing,
    DIContentSlotMinimal,
    DIContentSlotPrimary,
    DIContentSlotSecondary,
    DIContentSlotAction,
    DIContentSlotDetachedMinimal,
};

@protocol DIContentProviding <NSObject>

// Provider 标识（日志/诊断）
@property (nonatomic, readonly) NSString *identifier;

// 命中该提供者的视图类名关键词（一律按 lowercase 子串匹配）
@property (nonatomic, readonly) NSArray<NSString *> *classKeywords;

// bundleID 关键词（可选；element 侧 best-effort 解析，为空则不参与 bundle 判定）
@property (nonatomic, readonly) NSArray<NSString *> *bundleKeywords;

// 类名命中关键词数量（0 = 不命中）
- (NSInteger)keywordHitCountForClassName:(NSString *)className;

// bundleID 命中
- (BOOL)matchesBundleID:(nullable NSString *)bundleID;

// 展开内容容器打分：在通过几何过滤的候选视图中选出"最像展开卡片容器"者。
// 分数越高优先级越高；返回 0 表示交给通用启发式（取最大面积）。
- (NSInteger)scoreExpandedCandidate:(UIView *)view;

// 近黑背景剥离策略：返回 NO 表示该视图是"内容本体"（如专辑封面 UIImageView），
// 不得剥离其背景。默认实现一律 YES（保持通用剥离行为）。
- (BOOL)shouldStripNearBlackBackgroundForView:(UIView *)view;

@end

// 注册式内容适配器注册表
@interface DIContentProviderRegistry : NSObject

+ (instancetype)shared;

// 内置提供者：音乐 / 音量 / 通用 fallback（始终非空）
@property (nonatomic, readonly) NSArray<id<DIContentProviding>> *providers;
- (id<DIContentProviding>)fallbackProvider;
- (nullable id<DIContentProviding>)musicProvider;
- (nullable id<DIContentProviding>)volumeProvider;

// 按单个视图选出最匹配的 Provider（类名签名 + bundle 提示），永不返回 nil
- (id<DIContentProviding>)providerForView:(nullable UIView *)view
                             hintBundleID:(nullable NSString *)bundleID;

// 按整棵内容子树选出最匹配的 Provider（聚合全部子视图命中数）
- (id<DIContentProviding>)providerForContentTree:(nullable UIView *)root
                                    hintBundleID:(nullable NSString *)bundleID;

// 逐视图剥离策略查询（命中专用 Provider 的保护规则，否则通用剥离）
- (BOOL)shouldStripNearBlackBackgroundForView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
