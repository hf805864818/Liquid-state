// =============================================================================
//  DynamicIsland.x — 灵动岛液态玻璃（v2 重构版）
//
//  核心思路（对照 Mango 的实际实现，不再走壁纸窗口弯路）：
//
//  1. 黑色形体来自 SpringBoard 内部多个私有视图：
//       _SBSystemApertureMagiciansCurtainView  黑色幕布（药丸/展开卡片的形变主体）
//       MTMaterialView（iOS 17 静止药丸的实际黑色材质，嵌套在容器深处）
//       _SBGainMapView                         HDR 增益压暗层
//       描边/压暗装饰视图
//     一律强制隐藏/清底，而不是去改 SBSystemApertureWindow 的透明度。
//     压制对灵动岛窗口整棵子树递归进行（深度受限），换宿主/布局迁移时不还原。
//
//  2. 玻璃（LGLiveBackdropView / CABackdropLayer + backboardd 折射滤镜）
//     直接插在灵动岛自己的层级里：幕布向上找到的「最高不裁剪祖先」
//     （优先 TouchPassThrough 容器，iOS 17 布局期深层小容器会被反复替换，
//     必须用稳定的顶层容器），insertSubview:atIndex:0，
//     位于所有实时活动内容层之下。backdrop 可以直接采样到灵动岛窗口下方的
//     实时画面（前台 App / 桌面图标 / 壁纸），这是和 Mango pillLiquidGlassView
//     相同的层级方案。
//
//  3. 几何以 curtain 为唯一真源（药丸 ↔ 展开卡片都是它在形变）。
//     setLayoutMode:reason: 触发后用 CADisplayLink 读 curtain 图层的
//     presentationLayer 逐帧跟随弹簧动画，避免玻璃与黑色形体脱节。
//
//  4. 触控：LGLiveBackdropView 初始化时已 userInteractionEnabled = NO，
//     不需要任何 hitTest 覆盖。
//
//  事件源（与 Mango 二进制中确认的 hook 点一致）：
//    - SBSystemApertureViewController  viewWillAppear: / viewDidLayoutSubviews
//    - SBFTouchPassThroughView         layoutSubviews
//    - _SBSystemApertureMagiciansCurtainView  didMoveToWindow / layoutSubviews / setHidden:
//    - _SBGainMapView                  didMoveToWindow / layoutSubviews / setHidden:
//    - SBSystemApertureSceneElement    setLayoutMode:reason:
//    - _SBSystemApertureContainerViewContentView  setBackgroundColor:（可选类，旧系统）
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <math.h>

#ifndef LIQUIDASS_DEBUG
#define LIQUIDASS_DEBUG 0
#endif

#pragma mark - Logging

static void LGDILog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDILog(NSString *fmt, ...) {
#if LIQUIDASS_DEBUG
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI] %@", s);
#else
    (void)fmt;
#endif
}

#pragma mark - Private class interfaces

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end
@interface _SBGainMapView : UIView
@end
@interface SBFTouchPassThroughView : UIView
@end
@interface SBSystemApertureViewController : UIViewController
@end
@interface SBSystemApertureSceneElement : NSObject
@end
@interface _SBSystemApertureContainerViewContentView : UIView
@end
@interface _SAUIProvidedViewContainerView : UIView
@end
@interface SBSystemApertureWindow : UIWindow
@end

#pragma mark - Constants / association keys

static NSString * const kLGDIFilterPrefix    = @"DynamicIsland";
static NSString * const kLGDIBackdropGroup   = @"dylv.liquidglass.island";

static void *kLGDIRestoreInfoKey  = &kLGDIRestoreInfoKey; // 被压制装饰视图 -> 原始状态

// 总开关（含全局开关 / 前台 App 排除）。前向声明，供本文件靠前的视图压制路径使用。
static BOOL LGDIFeatureEnabled(void);
// 阶段2.6.1：是否存在「真实实时活动」布局（compact 长药丸 / expanded 展开卡片 /
// detached）。空闲 inert/minimal 小药丸不算——它没有液态化意义，且活动进出时
// 反复建/拆玻璃正是默认小岛闪烁的根因。定义在状态机之后。
static BOOL LGDIHasActiveLayout(void);
// 压制黑幕/装饰、装玻璃的总前提：总开关开 且 当前为活动布局。
static BOOL LGDILiquidSuppressionActive(void);

// =============================================================================
//  透明化四路独立开关（对标 Mango 的 CurtainHiddenV2 / GainMapDisabledV2 /
//  ContentTransparentV2 / OutlineHiddenV2）。全部默认开启，行为与旧版
//  SingleControl（全有或全无）完全一致；任一路关闭即保留该层系统原样。
//  偏好键为 DynamicIsland.HideCurtain / RemoveGainMap / ClearContentBg /
//  HideOutline（NSNumber BOOL）。
// =============================================================================

static BOOL LGDIHideCurtain(void);      // 隐藏 _SBSystemApertureMagiciansCurtainView 黑色幕布
static BOOL LGDRemoveGainMap(void);     // 移除 _SBGainMapView HDR 压暗层
static BOOL LGDClearContentBg(void);    // 清空容器/装饰背景色
static BOOL LGDIHideOutline(void);      // 隐藏描边/高光等装饰视图

static BOOL LGDIReadBool(NSString *key, BOOL defaultValue) {
    // 与 LGGlassKit 使用同一偏好域，避免引入额外依赖
    id v = LGGlassPreferenceValue(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        return [v caseInsensitiveCompare:@"YES"] == NSOrderedSame
            || [v caseInsensitiveCompare:@"true"] == NSOrderedSame
            || [v caseInsensitiveCompare:@"1"] == NSOrderedSame;
    }
    return defaultValue;
}

static BOOL LGDIHideCurtain(void) {
    return LGDIReadBool(@"DynamicIsland.HideCurtain", YES);
}
static BOOL LGDRemoveGainMap(void) {
    return LGDIReadBool(@"DynamicIsland.RemoveGainMap", YES);
}
static BOOL LGDClearContentBg(void) {
    return LGDIReadBool(@"DynamicIsland.ClearContentBg", YES);
}
static BOOL LGDIHideOutline(void) {
    return LGDIReadBool(@"DynamicIsland.HideOutline", YES);
}

// 药丸/展开判定与尺寸门限
static const CGFloat kLGDIMinWidth  = 60.0;
static const CGFloat kLGDIMinHeight = 20.0;
static const CGFloat kLGDIMaxWidth  = 500.0;
static const CGFloat kLGDIMaxHeight = 300.0;

#pragma mark - Controller state

// SAUILayoutMode（真机日志实测）：
//   0 inert     空闲默认小药丸（无任何实时活动）—— 保持系统原样，不处理
//   1 minimal   被其他 App 抢占时的极小形态     —— 保持系统原样
//   2 compact   有实时活动的长药丸             —— 液态化
//   3 expanded  长按展开卡片                   —— 液态化
//   4 detached  分离卡片                       —— 暂不处理
static const NSInteger kLGDIModeInert    = 0;
static const NSInteger kLGDIModeMinimal  = 1;
static const NSInteger kLGDIModeCompact  = 2;
static const NSInteger kLGDIModeExpanded = 3;
static const NSInteger kLGDIModeDetached = 4;

static __weak UIView            *sLGDICurtain;   // 当前幕布（唯一）
static __weak UIView            *sLGDIHost;      // 玻璃挂载容器
static __weak LGLiveBackdropView *sLGDIGlass;    // 当前玻璃
static BOOL                      sLGDIActive;    // 已激活液态化（开关开 && 当前 compact/expanded/detached）
static BOOL                      sLGDISyncQueued;
static CADisplayLink            *sLGDILink;
static CFTimeInterval            sLGDILinkDeadline;  // 驱动硬性兜底超时
static CFTimeInterval            sLGDIMinDriverEnd;  // 几何稳定停机的“最早”时刻（弹簧进行中不提前停）

// element(weak) -> 当前 layoutMode。仅 compact/expanded 视为“有活跃内容”
static NSMapTable<id, NSNumber *> *sLGDIElementModes;

// 状态机聚合状态（阶段2）：当前最高布局模式 + 触发 reason + 交互/键盘/分屏复合态
static NSInteger sLGDIMode;              // 当前聚合布局模式（多元素取最高）
static NSInteger sLGDIModeReason;        // 最近一次布局模式的触发 reason
static BOOL      sLGDIInteractiveExpanding; // 手势交互式展开中
static BOOL      sLGDIExpandedForKeyboard;  // 因键盘弹出而展开
static BOOL      sLGDISplitExpanded;        // 因分屏而提升层级

// 阶段2.6：激活判定不再依赖"是否记录到 compact/expanded 布局"
// （旧的 LGDIModeIsLiquid / LGDIHasActiveLayout 已随多信号事件驱动改造移除），
// 改为 LGDIEngage 以「总开关 + 在屏黑色幕布」直接点亮。

static void LGDIRecordElementMode(id element, NSInteger mode) {
    if (!sLGDIElementModes) {
        sLGDIElementModes = [NSMapTable weakToStrongObjectsMapTable];
    }
    [sLGDIElementModes setObject:@(mode) forKey:element];
}

static NSString *LGDIModeName(NSInteger mode) {
    switch (mode) {
        case kLGDIModeInert:    return @"inert";
        case kLGDIModeMinimal:  return @"minimal";
        case kLGDIModeCompact:  return @"compact";
        case kLGDIModeExpanded: return @"expanded";
        case kLGDIModeDetached: return @"detached";
        default:                return [NSString stringWithFormat:@"mode%ld", (long)mode];
    }
}

// =============================================================================
//  DIElementManager — 灵动岛元素接管层（阶段1，轻量登记）
//  在既有 sLGDIElementModes 视图树路径之上，提供一个 ObjC 管理器，
//  供后续阶段（内容 Provider / 完整状态机）挂接。它暴露：
//    - 当前核心 element（优先取 expanded，其次 compact）
//    - 当前最优（最高）布局模式 + 模式名
//    - 四路透明化偏好聚合结果（供设置页 / 日志/后续阶段直接读取）
//  不替换已验证的视图树压制路径，仅作为增强与信息中枢。
// =============================================================================

@interface DIElementManager : NSObject
@end
@implementation DIElementManager

+ (id)currentLiquidElement {
    // 优先 expanded（展开卡片），否则取任一 compact 长药丸
    id expanded = nil, compact = nil;
    for (id e in sLGDIElementModes) {
        NSInteger m = [[sLGDIElementModes objectForKey:e] integerValue];
        if (m == kLGDIModeExpanded) expanded = e;
        else if (m == kLGDIModeCompact && !compact) compact = e;
    }
    return expanded ?: compact;
}

+ (NSInteger)currentPreferredMode {
    NSInteger best = kLGDIModeInert;
    for (id e in sLGDIElementModes) {
        NSInteger m = [[sLGDIElementModes objectForKey:e] integerValue];
        if (m > best) best = m;
    }
    return best;
}

#pragma mark - 四路透明化偏好（聚合读取，供后续阶段/设置页）
+ (BOOL)hideCurtain   { return LGDIHideCurtain(); }
+ (BOOL)removeGainMap { return LGDRemoveGainMap(); }
+ (BOOL)clearContentBg{ return LGDClearContentBg(); }
+ (BOOL)hideOutline   { return LGDIHideOutline(); }
+ (BOOL)isLiquidActive{ return sLGDIActive; }

#pragma mark - 诊断
+ (NSString *)debugSummary {
    return [NSString stringWithFormat:
            @"mode=%@ active=%d curtain=%@ gainMap=%@ contentBg=%@ outline=%@",
            LGDIModeName([self currentPreferredMode]), (int)sLGDIActive,
            LGDIHideCurtain() ? @"hide" : @"keep",
            LGDRemoveGainMap() ? @"remove" : @"keep",
            LGDClearContentBg() ? @"clear" : @"keep",
            LGDIHideOutline() ? @"hide" : @"keep"];
}

@end

// =============================================================================
//  DIPillStateMachine — 完整灵动岛状态机（阶段2，对标 MangoPillElement）
//  消费 setLayoutMode:reason:，聚合多元素状态，暴露当前是否展开/展开中，
//  升级逐帧驱动：直到 geometry 稳定（连续多帧 frame 几乎不变）才停止，
//  而不是硬 deadline —— 保证弹簧完成后玻璃才与系统黑岛完全对齐。
// =============================================================================

// 前向声明：DIPillStateMachine 在驱动/同步实现之前定义
// （多元素聚合用 DIElementManager.currentPreferredMode 已在后方定义）
static void LGDIReconcile(void);
static void LGDIScheduleSync(NSTimeInterval driverDuration);

typedef NS_ENUM(NSInteger, DIPillLayoutMode) {
    DIPillLayoutModeInert    = kLGDIModeInert,
    DIPillLayoutModeMinimal  = kLGDIModeMinimal,
    DIPillLayoutModeCompact  = kLGDIModeCompact,
    DIPillLayoutModeExpanded = kLGDIModeExpanded,
    DIPillLayoutModeDetached = kLGDIModeDetached,
};

@interface DIPillStateMachine : NSObject
+ (instancetype)shared;
- (void)updateLayoutMode:(DIPillLayoutMode)mode reason:(NSInteger)reason;
- (void)setInteractiveExpanding:(BOOL)expanding;  // 手势交互展开
- (void)setExpandedForKeyboard:(BOOL)expanded;  // 键盘弹出展开
- (void)setSplitExpanded:(BOOL)expanded;        // 分屏提升层级

@property (nonatomic, readonly) BOOL isExpanded;        // 展开卡片态（含交互/键盘）
@property (nonatomic, readonly) BOOL isExpanding;       // 正在展开动画中
@property (nonatomic, readonly) BOOL interactiveExpandActive; // 交互展开进行中
@property (nonatomic, readonly) DIPillLayoutMode currentMode;
- (NSString *)debugSummary;
@end

@implementation DIPillStateMachine
+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    return self;
}

- (void)updateLayoutMode:(DIPillLayoutMode)mode reason:(NSInteger)reason {
    if (mode != (DIPillLayoutMode)sLGDIMode) {
        LGDILog(@"stateMachine: mode changed %@ -> %@ reason=%ld",
               LGDIModeName(sLGDIMode), LGDIModeName((NSInteger)mode), (long)reason);
        sLGDIMode = mode;
        sLGDIModeReason = reason;
    }
    // 展开模式变化触发 reconcile + 同步
    LGDIReconcile();
    if (sLGDIActive) {
        NSTimeInterval duration = mode == DIPillLayoutModeExpanded ? 1.6 : 0.9;
        LGDIScheduleSync(duration);
    }
}

- (void)setInteractiveExpanding:(BOOL)expanding {
    sLGDIInteractiveExpanding = expanding;
    if (expanding) {
        LGDILog(@"stateMachine: interactive expanding started");
        // 交互展开全程驱动，直到手势结束
        LGDIScheduleSync(2.5);
    }
}

- (void)setExpandedForKeyboard:(BOOL)expanded {
    sLGDIExpandedForKeyboard = expanded;
    if (expanded) {
        LGDILog(@"stateMachine: expanded for keyboard");
        LGDIReconcile();
        LGDIScheduleSync(1.2);
    }
}

- (void)setSplitExpanded:(BOOL)expanded {
    sLGDISplitExpanded = expanded;
    // 分屏提升 zPosition 后续阶段处理
}

- (BOOL)isExpanded {
    return sLGDIMode >= DIPillLayoutModeExpanded || sLGDIExpandedForKeyboard;
}

- (BOOL)isExpanding {
    return sLGDIInteractiveExpanding || (sLGDILink && !sLGDILink.paused);
}

- (BOOL)interactiveExpandActive {
    return sLGDIInteractiveExpanding;
}

- (DIPillLayoutMode)currentMode {
    return (DIPillLayoutMode)sLGDIMode;
}

- (NSString *)debugSummary {
    return [NSString stringWithFormat:@"mode=%@ expanded=%d expanding=%d"
            @" interact=%d keyboard=%d split=%d",
            LGDIModeName(sLGDIMode), (int)self.isExpanded, (int)self.isExpanding,
            (int)sLGDIInteractiveExpanding, (int)sLGDIExpandedForKeyboard, (int)sLGDISplitExpanded];
}

@end

// =============================================================================
//  活动布局判定（阶段2.6.1）
// -----------------------------------------------------------------------------
//  真机日志（iOS17）证实 setLayoutMode:reason: 始终可靠上报，状态机 currentMode
//  准确反映当前形态。因此液态化严格 gate 在 compact/expanded/detached：
//    - 空闲 inert/minimal 小药丸保持系统原样（不隐藏黑幕、不建玻璃），
//      彻底消除「默认小岛无意义且活动进出时一闪一闪」；
//    - 玻璃只在真实实时活动出现时才创建，backdrop 捕获组在活动上下文建立，
//      避免在空闲空上下文建玻璃导致采样为空（黑）。
// =============================================================================
static BOOL LGDIModeIsLiquid(NSInteger mode) {
    return mode == kLGDIModeCompact || mode == kLGDIModeExpanded
        || mode == kLGDIModeDetached;
}

static BOOL LGDIHasActiveLayout(void) {
    // 以「当前仍存活的 element 集合」的实时聚合模式为准，而不能只看状态机里最后一次
    // setLayoutMode: 上报的 sLGDIMode：实时活动结束时，系统往往直接释放对应的
    // SBSystemApertureSceneElement，而不会再回调一次 setLayoutMode:inert。
    // 此时旧值会停留在 compact/expanded，若据此判定，玻璃与黑幕压制会一直残留到
    // 空闲小药丸上 —— 表现为「默认小岛发灰」。sLGDIElementModes 是
    // weakToStrong 映射表，element 释放后条目自动剔除，currentPreferredMode
    // 随之回到 inert/minimal，正好给出「此刻是否真有实时活动」的准确信号。
    NSInteger liveMode = (NSInteger)[DIElementManager currentPreferredMode];
    // 手势交互展开期间 element 必然存活且上报 compact/expanded，liveMode 已覆盖；
    // 不再额外回退到依赖 sLGDIMode 的 isExpanded（element 释放后该值会过期卡死）。
    return LGDIModeIsLiquid(liveMode);
}

static BOOL LGDILiquidSuppressionActive(void) {
    return LGDIFeatureEnabled() && LGDIHasActiveLayout();
}

// =============================================================================
//  View tree helpers
// =============================================================================

static inline BOOL LGDIIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static BOOL LGDIClassName(UIView *v, NSString *name) {
    return v && [NSStringFromClass(v.class) isEqualToString:name];
}

static BOOL LGDIInApertureWindow(UIView *v) {
    for (UIView *a = v; a; a = a.superview) {
        NSString *name = NSStringFromClass(a.class);
        if ([name containsString:@"SystemAperture"]) return YES;
    }
    return NO;
}

static UIView *LGDIFindSubviewOfClass(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *hit = LGDIFindSubviewOfClass(sub, className);
        if (hit) return hit;
    }
    return nil;
}

static UIView *LGDIFindCurtainInWindows(void) {
    Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
    if (!curtainClass) return nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *hit = LGDIFindSubviewOfClass(window,
                                                 @"_SBSystemApertureMagiciansCurtainView");
            if (hit) return hit;
        }
    }
    // 兼容老系统（connectedScenes 取不到系统窗口时回退 keyWindow/windows）
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIView *hit = LGDIFindSubviewOfClass(window,
                                             @"_SBSystemApertureMagiciansCurtainView");
        if (hit) return hit;
    }
    return nil;
}

static BOOL LGDIIsPlausibleSize(CGSize size) {
    return size.width  >= kLGDIMinWidth  && size.width  <= kLGDIMaxWidth &&
           size.height >= kLGDIMinHeight && size.height <= kLGDIMaxHeight;
}

// 选「最高（最靠近 window）的稳定不裁剪祖先」作为玻璃容器。
// 早期版本取最深的不裁剪祖先，但 iOS 17 布局期系统会反复替换深层小容器，
// 导致宿主 16ms 内连换三次、玻璃重装、已压制的黑色材质被还原。
// 顶层容器在药丸↔展开全过程身份稳定，且能把全岛黑色材质纳入同一棵压制子树。
static UIView *LGDIHostForCurtain(UIView *curtain) {
    UIWindow *window = curtain.window;
    if (!window) return nil;

    UIView *topNonClipping = nil;
    UIView *touchPassThrough = nil;
    for (UIView *a = curtain.superview; a && a != window; a = a.superview) {
        if (a.clipsToBounds) continue;
        topNonClipping = a; // 持续上移，最终保留最高者
        if ([NSStringFromClass(a.class) containsString:@"TouchPassThrough"]) {
            touchPassThrough = a;
        }
    }
    return touchPassThrough ?: topNonClipping ?: window;
}

// DEBUG：一次性打印灵动岛窗口真实层级，定位黑色形体的实际承载视图
static void LGDIDumpTree(UIView *v, NSUInteger depth, NSUInteger maxDepth) {
#if LIQUIDASS_DEBUG
    if (!v || depth > maxDepth) return;
    CGFloat r=0,g=0,b=0,a=0;
    UIColor *bg = v.backgroundColor;
    [bg getRed:&r green:&g blue:&b alpha:&a];
    NSString *cls = NSStringFromClass(v.class);
    LGDILog(@"tree %lu: %@ frame=%@ alpha=%.2f hidden=%d clip=%d bg=%@ layer=%@",
            (unsigned long)depth, cls,
            NSStringFromCGRect(v.frame), v.alpha, (int)v.hidden,
            (int)v.clipsToBounds,
            bg ? [NSString stringWithFormat:@"(%.2f,%.2f,%.2f,%.2f)", r, g, b, a]
               : @"nil",
            NSStringFromClass(v.layer.class));

    // _UIPortalView 把别处的 layer 树投影到灵动岛窗口，是黑色形体的头号嫌疑
    if ([cls containsString:@"PortalView"]) {
        @try {
            UIView *sv = nil;
            sv = [v valueForKey:@"sourceView"];
            if (sv) {
                UIWindow *srcWin = sv.window;
                CGRect inWin = srcWin ? [sv convertRect:sv.bounds toView:srcWin] : CGRectNull;
                LGDILog(@"tree %lu:   PORTAL sourceView=%@ inWindow=%@ hidden=%d "
                        @"alpha=%.2f clips=%d frameInSrcWin=%@ subviews=%lu",
                        (unsigned long)depth, NSStringFromClass(sv.class),
                        NSStringFromClass(srcWin.class), (int)sv.hidden, sv.alpha,
                        (int)sv.clipsToBounds, NSStringFromCGRect(inWin),
                        (unsigned long)sv.subviews.count);
                // 展开源视图一层子树
                for (UIView *ss in sv.subviews) {
                    LGDILog(@"tree %lu:     portalSrcSub %@ frame=%@ hidden=%d alpha=%.2f bg=%@",
                            (unsigned long)depth, NSStringFromClass(ss.class),
                            NSStringFromCGRect(ss.frame), (int)ss.hidden, ss.alpha,
                            ss.backgroundColor ? @"set" : @"nil");
                }
            }
            CALayer *sl = [v valueForKey:@"sourceLayer"];
            if (sl && sl != sv.layer) {
                LGDILog(@"tree %lu:   PORTAL sourceLayer=%@ hidden=%d opacity=%.2f sublayers=%lu",
                        (unsigned long)depth, NSStringFromClass(sl.class),
                        (int)sl.hidden, sl.opacity, (unsigned long)sl.sublayers.count);
            }
        } @catch (NSException *e) {
            LGDILog(@"tree %lu:   PORTAL introspect failed: %@",
                    (unsigned long)depth, e.reason);
        }
    }

    for (UIView *sub in v.subviews) LGDIDumpTree(sub, depth + 1, maxDepth);
#else
    (void)v; (void)depth; (void)maxDepth;
#endif
}

#if LIQUIDASS_DEBUG
static NSUInteger sLGDIDumpCount;
static void LGDIRequestDump(NSString *reason) {
    if (sLGDIDumpCount >= 8) return;
    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    UIWindow *win = curtain.window ?: (sLGDIHost.window);
    if (!win) return;
    sLGDIDumpCount++;
    LGDILog(@"===== aperture tree dump #%lu reason=%@ =====",
            (unsigned long)sLGDIDumpCount, reason);
    LGDIDumpTree(win, 0, 8);

    LGLiveBackdropView *glass = sLGDIGlass;
    if (glass) {
        CALayer *l = glass.layer;
        NSMutableArray *fdesc = [NSMutableArray array];
        for (id f in l.filters) {
            NSString *t = nil;
            @try { t = [f valueForKey:@"type"]; } @catch (...) {}
            [fdesc addObject:t ?: NSStringFromClass([f class])];
        }
        LGDILog(@"glass diag: win=%@ level=%.1f group=%@ ns=%@ scale=%@ "
                @"filters=%@ opaque=%d opacity=%.2f hidden=%d",
                NSStringFromClass(glass.window.class), glass.window.windowLevel,
                [l valueForKey:@"groupName"], [l valueForKey:@"groupNamespace"],
                [l valueForKey:@"scale"], fdesc, (int)l.opaque, l.opacity, (int)l.hidden);
    }
}
#endif

// =============================================================================
//  装饰视图压制（描边 / 压暗层 / 容器底色）
//  只动“叶子级、非交互、非内容”的视图，实时活动内容绝不碰。
// =============================================================================

static BOOL LGDIStringMatchesAny(NSString *s, NSArray<NSString *> *keywords) {
    for (NSString *k in keywords) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static BOOL LGDIIsContentSubview(UIView *v) {
    static NSArray *kContentKeywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kContentKeywords = @[
            @"Element", @"Presenter", @"Content", @"Scene", @"Compact",
            @"Expanded", @"Leading", @"Trailing", @"Hero", @"Attachment",
            @"Custom", @"Activity", @"ViewController",
        ];
    });
    return LGDIStringMatchesAny(NSStringFromClass(v.class), kContentKeywords);
}

static BOOL LGDIIsDecorSubview(UIView *v) {
    static NSArray *kDecorKeywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kDecorKeywords = @[
            @"Line", @"Outline", @"Stroke", @"Separator", @"Dim",
            @"Gradient", @"Shadow", @"Backdrop", @"Material",
            @"Background", @"Tint", @"Overlay",
        ];
    });
    return LGDIStringMatchesAny(NSStringFromClass(v.class), kDecorKeywords);
}

static BOOL LGDIIsBlackBodyMaterial(UIView *v) {
    NSString *name = NSStringFromClass(v.class);
    // iOS 17 静止药丸的黑色材质本体；展开卡片的材质底同样做液态化
    return [name isEqualToString:@"MTMaterialView"]
        || [name containsString:@"ApertureMaterial"];
}

static BOOL LGDIShouldSuppressDecor(UIView *v) {
    if (!v || v == sLGDIGlass) return NO;
    if (LGDIClassName(v, @"_SBSystemApertureMagiciansCurtainView")) return NO;
    if (LGDIClassName(v, @"_SBGainMapView")) return NO;
    if (v.userInteractionEnabled || v.gestureRecognizers.count > 0) return NO;
    // 黑色材质本体由 LGDIHideOutline 控制（幕布隐藏走 HideCurtain 开关，
    // 盖在幕布之上、随岛的黑色材质仍需跟随停止液态时还原）
    if (LGDIIsBlackBodyMaterial(v) && !LGDIIsContentSubview(v))
        return LGDIHideOutline();
    if (v.subviews.count > 2) return NO;            // 内容容器一定有子视图
    if (LGDIIsContentSubview(v)) return NO;
    // 描边/高光/阴影等装饰归入 LGDIHideOutline 开关
    return LGDIHideOutline() && LGDIIsDecorSubview(v);
}

// 灵动岛内可能嵌套多个 SBFTouchPassThroughView，每个容器的装饰压制都要
// 能在停用/换宿主时还原，因此用 weak 集合统一追踪所有被动过的视图。
static NSHashTable<UIView *> *sLGDISuppressedViews;

static void LGDIRegisterSuppressed(UIView *v, NSDictionary *info) {
    if (!sLGDISuppressedViews) {
        sLGDISuppressedViews = [NSHashTable weakObjectsHashTable];
    }
    objc_setAssociatedObject(v, kLGDIRestoreInfoKey, info,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sLGDISuppressedViews addObject:v];
}

// 记录并压制单个视图（幂等）
static void LGDISuppressOne(UIView *v) {
    if (!v || v == sLGDIGlass) return;
    if (!objc_getAssociatedObject(v, kLGDIRestoreInfoKey)) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"alpha"]  = @(v.alpha);
        info[@"hidden"] = @(v.hidden);
        if (v.backgroundColor) info[@"bg"] = v.backgroundColor;
        LGDIRegisterSuppressed(v, info);
        LGDILog(@"suppressed decor %@ frame=%@",
                NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
    }
    // 系统可能在布局中把状态改回来；等值时不重复写
    if (v.alpha != 0.0) v.alpha = 0.0;
    if (v.backgroundColor && v.backgroundColor != UIColor.clearColor) {
        v.backgroundColor = UIColor.clearColor;
    }
}

// 递归全子树压制（深度受限）。iOS 17 的黑色形体是嵌套在容器深处的
// MTMaterialView，只扫宿主直接子视图必然漏掉；换宿主时也不能还原。
static void LGDISweepView(UIView *v, NSUInteger depth) {
    if (!v || depth == 0 || v == sLGDIGlass) return;
    // GainMap 在部分版本上不是 curtain 子视图，全树兜底隐藏
    if (LGDIClassName(v, @"_SBGainMapView")) {
        if (LGDRemoveGainMap() && !v.hidden) v.hidden = YES;
    } else if (LGDIShouldSuppressDecor(v)) {
        LGDISuppressOne(v);
    }
    for (UIView *sub in v.subviews) LGDISweepView(sub, depth - 1);
}

// =============================================================================
//  近黑背景剥离（对标 Mango 的 "stripped near-black bg" / pillContentTransparent）
// -----------------------------------------------------------------------------
//  关键：玻璃以 insertSubview:atIndex:0 装在容器最底层。iOS 17 长药丸/展开卡片
//  的纯黑并不只来自 curtain——内容/呈现容器（_SAUIProvidedViewContainerView、
//  Presenter、Content 等）自身常带一块「近黑不透明 backgroundColor」，它们在
//  z-order 上盖在玻璃之上，把玻璃整片涂成黑。旧逻辑因 LGDIIsContentSubview 明确
//  跳过所有内容视图，这块黑底从未被处理 —— 这正是「玻璃一直黑、看不到液态」的
//  直接原因之一。
//
//  这里只清背景色、绝不改 alpha/hidden：视图本体与其上的实时内容（图标/文字/
//  专辑图）原样保留，仅移除把玻璃盖住的黑色漆。判定阈值与 Mango 一致：
//  alpha 足够大且 r/g/b 都很低（近黑）才剥离，彩色/浅色内容背景不受影响。
// =============================================================================

static BOOL LGDIColorIsNearBlackOpaque(UIColor *c) {
    if (!c || c == UIColor.clearColor) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0, w = 0;
    if ([c getRed:&r green:&g blue:&b alpha:&a]) {
        // 已解析为 RGBA
    } else if ([c getWhite:&w alpha:&a]) {
        r = g = b = w;  // 灰度（含黑白/灰）
    } else {
        return NO;     // 图案/图案色等无法取分量，保守不动
    }
    if (!(a > 0.4)) return NO;                 // 透明底无需剥离
    return (r < 0.25 && g < 0.25 && b < 0.25); // 近黑
}

// 仅清背景色（bg-only）。记录到同一压制集合，停用/回空闲时由 restore 统一还原。
static void LGDIStripNearBlackBackground(UIView *v) {
    if (!v || v == sLGDIGlass) return;
    // curtain / gainMap 由各自的隐藏 hook 管理，这里不重复动
    if (LGDIClassName(v, @"_SBSystemApertureMagiciansCurtainView")) return;
    if (LGDIClassName(v, @"_SBGainMapView")) return;
    UIColor *bg = v.backgroundColor;
    if (!LGDIColorIsNearBlackOpaque(bg)) return;
    // 已被装饰压制（含 alpha 记录）的视图交给 LGDISuppressOne 路径，不重复登记
    if (!objc_getAssociatedObject(v, kLGDIRestoreInfoKey)) {
        LGDIRegisterSuppressed(v, @{ @"bg": bg });  // 只记 bg → 还原时只回写背景
        LGDILog(@"stripped near-black bg on %@ frame=%@",
                NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
    }
    // 直接写图层，绕过 setBackgroundColor: hook，避免被判定回路拦截
    v.layer.backgroundColor = UIColor.clearColor.CGColor;
}

static void LGDIStripNearBlackSubtree(UIView *v, NSUInteger depth) {
    if (!v || depth == 0 || v == sLGDIGlass) return;
    LGDIStripNearBlackBackground(v);
    for (UIView *sub in v.subviews) LGDIStripNearBlackSubtree(sub, depth - 1);
}

static void LGDISuppressDecorations(UIView *host) {
    // 阶段2.6.1：仅在真实活动布局（compact/expanded）才压制装饰；空闲小岛保持原样。
    if (!host || !LGDILiquidSuppressionActive()) return;

    // 容器自身 + 整棵子树的「近黑不透明背景」剥离（由 ClearContentBg 控制）。
    // 只清背景色、不动 alpha/hidden，实时内容原样保留；这是露出底层液态玻璃的
    // 关键一路（内容/呈现容器的黑底原本盖在 atIndex:0 的玻璃之上）。
    if (LGDClearContentBg()) {
        // 从窗口根剥离：展开卡片的内容容器可能是 host 的兄弟分支，只扫 host 会漏
        UIView *stripRoot = host.window ?: host;
        LGDIStripNearBlackBackground(host);
        LGDIStripNearBlackSubtree(stripRoot, 18);
    }

    LGDISweepView(host, 12);
}

// 逐帧廉价再断言：只遍历已追踪视图，O(被压制数量)，不做递归和类名匹配
static void LGDIReassertSuppressed(void) {
    if (!sLGDIActive) return;
    for (UIView *v in [sLGDISuppressedViews allObjects]) {
        NSDictionary *info = objc_getAssociatedObject(v, kLGDIRestoreInfoKey);
        if (!info) continue;
        BOOL bgOnly = (info[@"alpha"] == nil);  // 近黑背景剥离：只清过 bg，没动 alpha

        // 尊重四路开关：若某路已关闭，则对应装饰不再被重新压制
        // （并把已被压制的还原），避免"关闭开关但效果仍在"
        BOOL gateOn;
        if (LGDIClassName(v, @"_SBGainMapView")) {
            gateOn = LGDRemoveGainMap();
        } else if (LGDIClassName(v, @"_SBSystemApertureMagiciansCurtainView")) {
            gateOn = LGDIHideCurtain();
        } else if (bgOnly || LGDIClassName(v, @"_SBSystemApertureContainerViewContentView")) {
            // 内容/容器近黑背景：归 ClearContentBg 开关
            gateOn = LGDClearContentBg();
        } else {
            gateOn = LGDIHideOutline();
        }

        if (!gateOn) {
            // 该路关闭：还原原始状态
            if (info[@"alpha"])  v.alpha = [info[@"alpha"] floatValue];
            if (info[@"hidden"]) v.hidden = [info[@"hidden"] boolValue];
            if (info[@"bg"])     v.layer.backgroundColor = [info[@"bg"] CGColor];
            objc_setAssociatedObject(v, kLGDIRestoreInfoKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }

        // 该路开启：重新断言。bg-only 视图绝不能动 alpha/hidden（否则连内容一起消失），
        // 只保证背景保持透明；装饰/黑色材质视图才整视图 alpha=0。
        if (!bgOnly) {
            if (v.alpha != 0.0) v.alpha = 0.0;
        }
        if (v.backgroundColor && v.backgroundColor != UIColor.clearColor) {
            v.layer.backgroundColor = UIColor.clearColor.CGColor;
        }
    }
}

static void LGDIRestoreAllSuppressed(void) {
    for (UIView *v in [sLGDISuppressedViews allObjects]) {
        NSDictionary *info = objc_getAssociatedObject(v, kLGDIRestoreInfoKey);
        if (!info) continue;
        if (info[@"alpha"])  v.alpha = [info[@"alpha"] floatValue];
        if (info[@"hidden"]) v.hidden = [info[@"hidden"] boolValue];
        // 直接写图层，绕过 setBackgroundColor: hook（热切换宿主时开关仍为开启状态）
        if (info[@"bg"])     v.layer.backgroundColor = [info[@"bg"] CGColor];
        objc_setAssociatedObject(v, kLGDIRestoreInfoKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"restored decor %@", NSStringFromClass(v.class));
    }
    [sLGDISuppressedViews removeAllObjects];
}

// =============================================================================
//  Geometry sync
// =============================================================================

static CGFloat LGDIFallbackCornerRadius(CGRect f) {
    // 细长药丸（宽高比 > 2.2）：完全半圆角 = 高/2
    // 展开卡片：约为高度的 1/4（系统实测 40~44pt 区间）
    if (f.size.width > f.size.height * 2.2) {
        return f.size.height / 2.0;
    }
    return MIN(MAX(f.size.height * 0.24, 36.0), 52.0);
}

static void LGDISyncGeometryFromPresentation(BOOL usePresentation) {
    LGLiveBackdropView *glass = sLGDIGlass;
    UIView *curtain = sLGDICurtain;
    UIView *host = sLGDIHost;
    if (!glass || !curtain || !host) return;

    CALayer *pl = usePresentation ? curtain.layer.presentationLayer : nil;
    CGRect targetFrame;
    CGFloat targetRadius;

    if (pl) {
        // presentationLayer.frame 位于 curtain.superview 的坐标系。
        // 注意不能用 isnormal()：原点坐标合法地可以是 0，而 isnormal(0)==false。
        CGRect pf = pl.frame;
        BOOL pfValid = isfinite(pf.origin.x) && isfinite(pf.origin.y)
                    && isfinite(pf.size.width) && isfinite(pf.size.height)
                    && !CGRectIsNull(pf) && !CGRectIsInfinite(pf)
                    && pf.size.width > 1.0 && pf.size.height > 1.0;
        if (pfValid) {
            targetFrame = [curtain.superview convertRect:pf toView:host];
            targetRadius = pl.cornerRadius > 0.5 ? pl.cornerRadius
                                                 : LGDIFallbackCornerRadius(pf);
        } else {
            pl = nil;
        }
    }
    if (!pl) {
        targetFrame = [curtain convertRect:curtain.bounds toView:host];
        targetRadius = curtain.layer.cornerRadius > 0.5
                           ? curtain.layer.cornerRadius
                           : LGDIFallbackCornerRadius(curtain.bounds);
    }

    if (!LGDIIsPlausibleSize(targetFrame.size)) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (!CGRectEqualToRect(glass.frame, targetFrame)) {
        glass.frame = targetFrame;
    }
    if (fabs(glass.layer.cornerRadius - targetRadius) > 0.25) {
        glass.layer.cornerRadius = targetRadius;
    }
    // cornerCurve / masksToBounds 安装时已固定，逐帧同步不再重复写入
    [CATransaction commit];
}

// =============================================================================
//  Transition driver — 逐帧跟随系统弹簧形变
//  阶段2：从"跑固定 deadline"升级为"几何稳定判定"——
//  连续 kLGDISteadyFrameThreshold 帧 reading presentationLayer frame 几乎不动，
//  且已过最早停机时刻 sLGDIMinDriverEnd，才认为弹簧动画结束并停机；
//  sLGDILinkDeadline 仍作为硬性兜底（防止几何一直不收敛导致永驱）。
// =============================================================================

static void LGDIStopDriver(void);

static const NSUInteger kLGDISteadyFrameThreshold = 8;  // ~130ms 持续稳定
static const CGFloat    kLGDISteadyDelta = 0.15;        // pt，单帧位移阈值
static CGRect   sLGDILastPresentationFrame;
static NSUInteger sLGDISteadyFrameCount;

static void LGDIDriverTick(CADisplayLink *link) {
    (void)link;
    @autoreleasepool {
        UIView *curtain = sLGDICurtain;
        UIView *host = sLGDIHost;
        if (!sLGDIActive || !curtain || !host || !sLGDIGlass) {
            LGDIStopDriver();
            return;
        }
        // 形变期间系统可能反复把幕布/装饰放回来，每帧重新断言
        // （四路开关各管一路，单独开关关闭后该层不再被强制隐藏）
        if (LGDIHideCurtain() && !curtain.hidden) curtain.hidden = YES;
        UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
        if (LGDRemoveGainMap() && gain && !gain.hidden) gain.hidden = YES;
        LGDIReassertSuppressed();
        LGDISyncGeometryFromPresentation(YES);

        // 几何稳定判定
        CALayer *present = curtain.layer.presentationLayer;
        CGRect f = present ? present.frame : curtain.frame;
        BOOL stable = CGRectEqualToRect(f, CGRectNull) ? NO :
            (fabs(f.origin.x - sLGDILastPresentationFrame.origin.x) < kLGDISteadyDelta
             && fabs(f.origin.y - sLGDILastPresentationFrame.origin.y) < kLGDISteadyDelta
             && fabs(f.size.width  - sLGDILastPresentationFrame.size.width)  < kLGDISteadyDelta
             && fabs(f.size.height - sLGDILastPresentationFrame.size.height) < kLGDISteadyDelta);
        sLGDILastPresentationFrame = f;
        sLGDISteadyFrameCount = stable ? sLGDISteadyFrameCount + 1 : 0;

        CFTimeInterval now = CACurrentMediaTime();
        if (sLGDISteadyFrameCount >= kLGDISteadyFrameThreshold
            && now >= sLGDIMinDriverEnd) {
            LGDISyncGeometryFromPresentation(NO);
            [[DIPillStateMachine shared] setInteractiveExpanding:NO];
            LGDIStopDriver();
            // 弹簧动画到位、实时活动布局完全稳定后，强制重建一次 backdrop 捕获：
            // 此时窗外实时画面已就绪，重采样可拿到正确内容（修复首捕为空发黑）。
            // 节流，避免同一稳定态内重复刷新。
            static CFTimeInterval sLGDILastForceRefresh = 0;
            if (sLGDIGlass && now - sLGDILastForceRefresh > 0.4) {
                sLGDILastForceRefresh = now;
                [sLGDIGlass lgForceRefreshBackdrop];
            }
            return;
        }
    }
}

#pragma mark - driver target（不能把 self 用在 C 函数里，用独立对象承载）

@interface LGDIDisplayLinkTarget : NSObject
@end
@implementation LGDIDisplayLinkTarget
- (void)tick:(CADisplayLink *)link { LGDIDriverTick(link); }
@end

static LGDIDisplayLinkTarget *sLGDILinkTarget;

static void LGDIStartDriverReal(NSTimeInterval duration) {
    if (!sLGDILinkTarget) sLGDILinkTarget = [LGDIDisplayLinkTarget new];
    if (!sLGDILink) {
        sLGDILink = [CADisplayLink displayLinkWithTarget:sLGDILinkTarget
                                                selector:@selector(tick:)];
        [sLGDILink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    sLGDILink.paused = NO;
    CFTimeInterval now = CACurrentMediaTime();
    sLGDILinkDeadline = now + duration;          // 硬性兜底
    sLGDIMinDriverEnd = now + duration * 0.6;    // 弹簧进行中不提前停
    sLGDISteadyFrameCount = 0;
    sLGDILastPresentationFrame = CGRectNull;
}

static void LGDIStopDriver(void) {
    sLGDILink.paused = YES;
}

#pragma mark - Forward declarations

static void LGDIScheduleSync(NSTimeInterval driverDuration);
static void LGDIReconcile(void);

// =============================================================================
//  Glass lifecycle
// =============================================================================

static void LGDIInstallGlass(UIView *curtain) {
    if (!sLGDIActive || !curtain || !curtain.window) return;
    if (!LGDIIsPlausibleSize(curtain.bounds.size)) return;

    UIView *host = LGDIHostForCurtain(curtain);
    if (!host) return;

    // 幕布 + GainMap 必须先于玻璃隐藏：它们和玻璃同属一个窗口层级，
    // 若幕布仍渲染黑色，backdrop 采样到的就是黑幕布而不是窗外实时画面。
    // （LGDIHideCurtain / LGDRemoveGainMap 四路开关分别控制）
    if (LGDIHideCurtain() && !curtain.hidden) curtain.hidden = YES;
    UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
    if (LGDRemoveGainMap() && gain && !gain.hidden) gain.hidden = YES;

    LGLiveBackdropView *glass = sLGDIGlass;
    if (!glass || glass.superview != host) {
        if (!glass) {
            CGRect frame = [curtain convertRect:curtain.bounds toView:host];
            glass = LGCreateRegisteredGlass(frame, kLGDIBackdropGroup, kLGDIFilterPrefix);
            if (!glass) {
                LGDILog(@"install failed: LGCreateRegisteredGlass returned nil");
                return;
            }
            sLGDIGlass = glass;
        }
        glass.layer.cornerCurve   = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        [host insertSubview:glass atIndex:0];
        LGDILog(@"glass installed in host=%@ frame=%@",
                NSStringFromClass(host.class),
                NSStringFromCGRect(glass.frame));

        // 诊断：安装后 dump 真实层级（仅 DEBUG，限次，无视觉影响）
#if LIQUIDASS_DEBUG
        dispatch_async(dispatch_get_main_queue(), ^{
            LGDIRequestDump(@"install");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGDIRequestDump(@"install+0.4s");
        });
#endif

        // 玻璃在实时活动内容/背景尚未就绪时就加入了灵动岛独立窗口，
        // CABackdropLayer 首次捕获可能为空/黑；且 applyFilters 在滤镜类型
        // 未变时会 early-return。这里在布局就绪的多个时间点强制重建 backdrop
        // 捕获组（对标 Mango refreshGlassBackdrop），使其重新采样窗外实时画面。
        __weak LGLiveBackdropView *weakGlass = glass;
        for (NSNumber *delay in @[ @0.3, @0.8, @1.6, @3.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass lgForceRefreshBackdrop];
            });
        }
    }

    sLGDICurtain = curtain;
    sLGDIHost = host;

    // 安装/迁移时从窗口根全树压制，防止黑色材质是宿主的兄弟分支；
    // 布局期的增量压制仍只扫容器自身
    if (sLGDIActive) {
        UIView *sweepRoot = host.window ?: host;
        LGDISweepView(sweepRoot, 14);
        // 近黑背景剥离同样需要全树覆盖：内容容器可能不在 host 子树内
        if (LGDClearContentBg()) LGDIStripNearBlackSubtree(sweepRoot, 16);
    }
    LGDISyncGeometryFromPresentation(NO);
    LGDIScheduleSync(0.35);
}

static void LGDITeardown(BOOL featureDisabled) {
    LGLiveBackdropView *glass = sLGDIGlass;

    LGDIStopDriver();

    if (glass) {
        [glass removeFromSuperview];
        sLGDIGlass = nil;
    }
    // 恢复所有被压制的装饰视图（可能分布在多个嵌套容器中）
    LGDIRestoreAllSuppressed();

    if (featureDisabled) {
        // 恢复系统黑色形体（setHidden: hook 在 sLGDIActive=NO 时放行）
        UIView *curtain = sLGDICurtain;
        if (!curtain) curtain = LGDIFindCurtainInWindows();
        if (curtain) {
            UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
            if (gain) gain.hidden = NO;
            curtain.hidden = NO;
        }
    }

    sLGDICurtain = nil;
    sLGDIHost = nil;
}

// =============================================================================
//  Engagement（阶段2.6：多信号事件驱动，对标 Beta6 mangoos.dylib）
// -----------------------------------------------------------------------------
//  旧设计把整条液态链 gate 在唯一的被动信号上：只有系统回调
//  SBSystemApertureSceneElement setLayoutMode:reason: 且记录到 compact/expanded，
//  sLGDIActive 才置位；一旦该回调在某些实时活动/系统小版本上未按预期到达，
//  连黑幕都不会隐藏、玻璃也不会创建 —— 表现为"完全没效果"。
//
//  Beta6 的做法（其 [Island] hook 日志实证）：curtain 的 didMoveToWindow/
//  setHidden、gainmap、touchPassthrough、viewWillAppear 任一事件都能独立驱动。
//  这里改为：只要「总开关开 && 存在一块在灵动岛窗口内、尺寸合理的在屏幕布」
//  即点亮 sLGDIActive 并安装玻璃；setLayoutMode 仅用于区分形态与驱动时长。
// =============================================================================

static BOOL LGDIFeatureEnabled(void) {
    return lgHostEnabled(kLGDIFilterPrefix);
}

static BOOL LGDICurtainReady(UIView *curtain) {
    return curtain && curtain.window
        && LGDIInApertureWindow(curtain)
        && LGDIIsPlausibleSize(curtain.bounds.size);
}

// 点亮/刷新液态化。curtain 为 nil 时自动在窗口中查找。可重入、幂等。
static void LGDIEngage(UIView *curtain) {
    if (!LGDIFeatureEnabled()) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"disengage: feature turned off, stock island restored");
        }
        return;
    }
    // 阶段2.6.1：空闲 inert/minimal 小药丸不液态化。活动结束回到空闲时，
    // 主动拆除玻璃并还原系统黑色形体，避免空闲岛残留/闪烁。
    if (!LGDIHasActiveLayout()) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"disengage: idle/inert island — keep stock, liquid removed");
        }
        return;
    }
    if (!curtain) curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (!LGDICurtainReady(curtain)) return;   // 布局未完成/已下屏：等下一个事件重试

    if (!sLGDIActive) {
        sLGDIActive = YES;
        LGDILog(@"engaged (active layout mode=%@) by curtain %@ frame=%@",
                LGDIModeName((NSInteger)[DIPillStateMachine shared].currentMode),
                NSStringFromClass(curtain.class),
                NSStringFromCGRect(curtain.bounds));
    }
    LGDIInstallGlass(curtain);
}

// =============================================================================
//  Sync scheduling
// =============================================================================

static void LGDIDoScheduledSync(void) {
    sLGDISyncQueued = NO;
    if (!LGDIFeatureEnabled()) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
        }
        return;
    }

    // 阶段2.6.1：空闲小岛不液态化（兜底，正常路径由状态机 reconcile 拆除）
    if (!LGDIHasActiveLayout()) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"scheduled sync: idle layout — liquid removed");
        }
        return;
    }

    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (!curtain || !curtain.window) return;

    // 尚未激活：以在屏幕布为信号点亮（此时必为 compact/expanded）
    if (!sLGDIActive) {
        LGDIEngage(curtain);
        return;
    }

    if (!sLGDIGlass) {
        LGDIInstallGlass(curtain);
        return;
    }

    // 弱引用可能在场景切换后丢失，找回后必须回写，否则几何同步会永久空转
    sLGDICurtain = curtain;

    // 容器可能在展开时被系统换掉：只移玻璃不还原压制（黑色材质必须继续隐藏）
    UIView *host = LGDIHostForCurtain(curtain);
    if (host && host != sLGDIHost) {
        LGDILog(@"host changed: %@ -> %@, reinstalling",
                NSStringFromClass(sLGDIHost.class), NSStringFromClass(host.class));
        [sLGDIGlass removeFromSuperview];
        sLGDIHost = nil;
        LGDIInstallGlass(curtain);
        return;
    }

    if (LGDIHideCurtain() && !curtain.hidden) curtain.hidden = YES;
    UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
    if (gain) {
        BOOL shouldHide = LGDRemoveGainMap();
        if (shouldHide && !gain.hidden) gain.hidden = YES;
        // 关闭 RemoveGainMap 后，如果此前已隐藏（系统未重设），
        // 执行一次还原以尊重用户选择：但 GainMap 通常随布局重排，
        // 这里仅在显式关闭且仍隐藏时放行系统原样。
        else if (!shouldHide && gain.hidden) gain.hidden = NO;
    }
    LGDISuppressDecorations(host);
    LGDISyncGeometryFromPresentation(NO);
}

static void LGDIScheduleSync(NSTimeInterval driverDuration) {
    if (!LGDIFeatureEnabled()) return;

    // 仅在已激活时启动逐帧驱动；未激活时只排队一次 sync（其内部会完成点亮）。
    // 点亮后 LGDIInstallGlass 尾部会再次 ScheduleSync，届时正常拉起 driver。
    if (sLGDIActive && driverDuration > 0) {
        LGDIStartDriverReal(driverDuration);
    }
    if (!sLGDISyncQueued) {
        sLGDISyncQueued = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            LGDIDoScheduledSync();
        });
    }
}

// =============================================================================
//  Reconcile（开关 / 启动 / 视图挂载）
// =============================================================================

static void LGDIReconcile(void) {
    // 阶段2.6.1：点亮/拆除统一由 LGDIEngage 裁决——
    //   总开关关            -> 拆除还原
    //   inert/minimal 空闲  -> 拆除还原（默认小岛保持系统原样，不闪）
    //   compact/expanded    -> 找到在屏幕布即装玻璃
    // LGDIEngage 内部先判布局再找 curtain，空闲态即使 curtain 暂未取到也会拆除。
    if (!LGDIFeatureEnabled()) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"disabled: stock island restored");
        }
        return;
    }
    LGDIEngage(nil);
}

static void LGDIHandleCurtainAttached(UIView *curtain) {
    // 阶段2.6：curtain 上屏本身即激活信号（对标 Beta6 curtain didMoveToWindow 驱动）。
    if (!LGDIFeatureEnabled()) return;
    if (!curtain.window || !LGDIInApertureWindow(curtain)) return;
    sLGDICurtain = curtain;
    // didMoveToWindow 时层级往往还没布局完，延后一拍再装
    dispatch_async(dispatch_get_main_queue(), ^{
        if (LGDICurtainReady(curtain)) {
            LGDIEngage(curtain);
        } else {
            // 尺寸尚未就绪：排队 sync（内部会在 curtain 就绪后点亮），并由后续
            // layoutSubviews / viewWillAppear 等事件再次触发，形成多信号冗余。
            LGDIScheduleSync(0.25);
        }
    });
}

static BOOL LGDIShouldForceHidden(UIView *view) {
    // 阶段2.6.1：仅在真实活动布局（compact/expanded）才强制隐藏黑色形体；
    // 空闲 inert/minimal 小岛放行，保持系统原样（首帧黑幕由 LGDIInstallGlass 直接隐藏）。
    if (LGDILiquidSuppressionActive() && view.window != nil && LGDIInApertureWindow(view)) {
        // 按类名把强制隐藏分派到四路开关：
        //   curtain -> HideCurtain
        //   GainMap -> RemoveGainMap
        //   其余装饰/黑色材质 -> HideOutline（或 ClearContentBg 兜底）
        if (LGDIClassName(view, @"_SBSystemApertureMagiciansCurtainView"))
            return LGDIHideCurtain();
        if (LGDIClassName(view, @"_SBGainMapView"))
            return LGDRemoveGainMap();
        if (LGDIClassName(view, @"_SBSystemApertureContainerViewContentView"))
            return LGDClearContentBg();
        return LGDIHideOutline();
    }
    return NO;
}

// =============================================================================
//  Hook: _SBSystemApertureMagiciansCurtainView（黑色形变主体）
// =============================================================================

%group LGDICurtainHook
%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGDILog(@"curtain didMoveToWindow bounds=%@", NSStringFromCGRect(self.bounds));
        LGDIHandleCurtainAttached(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGDIShouldForceHidden(self)) {
        if (!self.hidden) self.hidden = YES;
        LGDIScheduleSync(0.35);
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGDIShouldForceHidden(self) && !hidden) {
        LGDILog(@"curtain setHidden:NO blocked");
        hidden = YES;
    }
    %orig(hidden);
}

%end
%end

// =============================================================================
//  Hook: _SBGainMapView（HDR 压暗层）
// =============================================================================

%group LGDIGainMapHook
%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        if (LGDIShouldForceHidden(self)) {
            self.hidden = YES;
            LGDIScheduleSync(0.25);
        }
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGDIShouldForceHidden(self)) {
        if (!self.hidden) self.hidden = YES;
        LGDIScheduleSync(0.35);
    }
}

- (void)setHidden:(BOOL)hidden {
    if (LGDIShouldForceHidden(self) && !hidden) hidden = YES;
    %orig(hidden);
}

%end
%end

// =============================================================================
//  Hook: SBFTouchPassThroughView（灵动岛容器：压装饰 + 布局信号）
//  该类系统多处使用，必须用灵动岛窗口祖先过滤。
// =============================================================================

%group LGDITouchHook
%hook SBFTouchPassThroughView

- (void)layoutSubviews {
    %orig;
    if (LGDIFeatureEnabled() && LGDIInApertureWindow(self)) {
        LGDISuppressDecorations(self);
        LGDIScheduleSync(0.35);
    }
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureViewController
// =============================================================================

%group LGDIApertureVCHook
%hook SBSystemApertureViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    LGDILog(@"aperture viewWillAppear");
    if (LGDIFeatureEnabled()) LGDIScheduleSync(0.35);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (LGDIFeatureEnabled()) LGDIScheduleSync(0.35);
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureSceneElement（药丸 ↔ 展开形变时机）
// =============================================================================

%group LGDISceneElementHook
%hook SBSystemApertureSceneElement

- (void)setLayoutMode:(NSInteger)layoutMode reason:(NSInteger)reason {
    %orig(layoutMode, reason);
    LGDILog(@"setLayoutMode=%@(%ld) reason=%ld",
            LGDIModeName(layoutMode), (long)layoutMode, (long)reason);
    LGDIRecordElementMode(self, layoutMode);
    // 阶段2：布局模式交状态机消费（聚合多元素 + 按模式给驱动时长）
    [[DIPillStateMachine shared] updateLayoutMode:(DIPillLayoutMode)layoutMode
                                           reason:reason];
#if LIQUIDASS_DEBUG
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGDILog(@"stateMachine=%@", [[DIPillStateMachine shared] debugSummary]);
        LGDIRequestDump([NSString stringWithFormat:@"layoutMode=%ld", (long)layoutMode]);
    });
#endif
}

%end
%end

// =============================================================================
//  Hook: _SBSystemApertureContainerViewContentView（部分版本上的容器底色）
// =============================================================================

%group LGDIContentContainerHook
%hook _SBSystemApertureContainerViewContentView

- (void)setBackgroundColor:(UIColor *)color {
    if (LGDILiquidSuppressionActive() && LGDIInApertureWindow(self)
        && color && color != UIColor.clearColor
        && CGColorGetAlpha(color.CGColor) > 0.0) {
        // 记录原色，停用功能时由 LGDIRestoreAllSuppressed 统一还原
        if (!objc_getAssociatedObject(self, kLGDIRestoreInfoKey)) {
            LGDIRegisterSuppressed(self, @{ @"bg": color });
        }
        color = UIColor.clearColor;
    }
    %orig(color);
}

- (void)layoutSubviews {
    %orig;
    if (LGDILiquidSuppressionActive() && LGDIInApertureWindow(self)
        && self.backgroundColor
        && self.backgroundColor != UIColor.clearColor) {
        if (!objc_getAssociatedObject(self, kLGDIRestoreInfoKey)) {
            LGDIRegisterSuppressed(self, @{ @"bg": self.backgroundColor });
        }
        self.backgroundColor = UIColor.clearColor;
    }
}

%end
%end

// =============================================================================
//  Hook: _SAUIProvidedViewContainerView（SystemAperture 内容容器，对标 Mango）
// -----------------------------------------------------------------------------
//  Mango 专门 hook 了这个类（[Island] hooked _SAUIProvidedViewContainerView）。
//  它是承载实时活动「提供视图」的内层容器（compact 药丸/展开卡片内容的直接父
//  容器），自身常带一块近黑不透明背景，在 z-order 上盖在 atIndex:0 的玻璃之上。
//  外层的 _SBSystemApertureContainerViewContentView 并非这块黑底的实际承载者，
//  仅靠全树遍历可能在它晚于遍历加入/重设背景时漏掉，因此这里直接 hook，实时剥离。
//  只清背景色，绝不动 alpha/hidden，内容子视图（图标/文字/专辑图）原样保留。
// =============================================================================

%group LGDISAProvidedContainerHook
%hook _SAUIProvidedViewContainerView

- (void)setBackgroundColor:(UIColor *)color {
    if (LGDILiquidSuppressionActive() && LGDClearContentBg()
        && LGDIColorIsNearBlackOpaque(color)) {
        if (!objc_getAssociatedObject(self, kLGDIRestoreInfoKey)) {
            LGDIRegisterSuppressed(self, @{ @"bg": color });
            LGDILog(@"SAProvided container near-black bg intercepted on %@",
                    NSStringFromClass(self.class));
        }
        color = UIColor.clearColor;
    }
    %orig(color);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window && LGDILiquidSuppressionActive() && LGDClearContentBg()) {
        LGDIStripNearBlackBackground(self);
        LGDIScheduleSync(0.25);
    }
}

- (void)layoutSubviews {
    %orig;
    if (LGDILiquidSuppressionActive() && LGDClearContentBg()) {
        LGDIStripNearBlackBackground(self);
        LGDIScheduleSync(0.25);
    }
}

%end
%end

// =============================================================================
//  Hook: SBSystemApertureWindow（布局信号，绝不动窗口透明度）
// =============================================================================

%group LGDIApertureWindowHook
%hook SBSystemApertureWindow

- (void)layoutSubviews {
    %orig;
    if (LGDIFeatureEnabled()) LGDIScheduleSync(0.35);
}

%end
%end

// =============================================================================
//  Constructor
// =============================================================================

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGDIIsSpringBoardProcess()) return;
    if (@available(iOS 16.0, *)) {} else return;

    // 设置变更：开关关闭时恢复原黑色岛，开启时重新装配（滤镜参数刷新由
    // LGLiveBackdropView 全局监听 ParametersReloaded 自动完成，无需此处处理）
    lgObservePreferenceReload(^{
        LGDIReconcile();
    });

    if (objc_getClass("_SBSystemApertureMagiciansCurtainView")) {
        %init(LGDICurtainHook);
    }
    if (objc_getClass("_SBGainMapView")) {
        %init(LGDIGainMapHook);
    }
    if (objc_getClass("SBFTouchPassThroughView")) {
        %init(LGDITouchHook);
    }
    if (objc_getClass("SBSystemApertureViewController")) {
        %init(LGDIApertureVCHook);
    }
    if (objc_getClass("SBSystemApertureSceneElement")) {
        %init(LGDISceneElementHook);
    }
    if (objc_getClass("_SBSystemApertureContainerViewContentView")) {
        %init(LGDIContentContainerHook);
    }
    if (objc_getClass("_SAUIProvidedViewContainerView")) {
        %init(LGDISAProvidedContainerHook);
    }
    if (objc_getClass("SBSystemApertureWindow")) {
        %init(LGDIApertureWindowHook);
    }

    // 初始一律视为 inert：空闲小药丸不处理，等系统发出 compact/expanded
    // 的 setLayoutMode: 后再装配（此时 element 表才会有记录）
    sLGDIActive = NO;
    LGDILog(@"initialized enabled=%d (waits for compact/expanded layout)",
            lgHostEnabled(kLGDIFilterPrefix));

    // SpringBoard 启动时若已有实时活动（音乐/导航等），系统通常会补发
    // setLayoutMode:；这里的延迟 reconcile 仅作兜底
    for (NSNumber *delay in @[ @0.8, @2.5, @5.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGDIReconcile();
        });
    }
}
