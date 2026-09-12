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
#import "../Shared/LGDIContentProvider.h"
#import "../Shared/LGDIWallpaperCapture.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGIOSurface.h"
#import <notify.h>
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
static __weak LGLiveBackdropView *sLGDIGlass;    // 当前玻璃（compact pill）
static BOOL                      sLGDIActive;    // 已激活液态化（开关开 && 当前 compact/expanded/detached）

// [阶段4] 展开态独立玻璃（对标 Mango expandedLiquidGlassView + blurBackgroundView）：
// 展开卡片不复用 pill 玻璃，而在展开内容所在窗口创建第二块玻璃，
// 配一块系统 UIVisualEffectView 原生模糊底板，解决展开态透明/纯黑问题。
static __weak UIView             *sLGDIExpHost;   // 展开玻璃挂载容器
static __weak LGLiveBackdropView *sLGDIExpGlass;  // 展开态独立玻璃
static __weak UIVisualEffectView *sLGDIExpBlur;   // 原生模糊底板
static BOOL                       sLGDIPillHiddenForExpanded; // pill 玻璃是否因展开态让位隐藏
static BOOL                      sLGDISyncQueued;
static CADisplayLink            *sLGDILink;
static CFTimeInterval            sLGDILinkDeadline;  // 驱动硬性兜底超时
static CFTimeInterval            sLGDIMinDriverEnd;  // 几何稳定停机的“最早”时刻（弹簧进行中不提前停）

// 退出活动时的延迟拆除：等系统收缩弹簧跑完再硬切还原，消灭回小药丸灰闪。
// sLGDITeardownPending 期间压制状态保持（玻璃随 curtain morph 回小药丸），
// generation 用于在活动复活时让已排队的拆除回调自动作废。
static BOOL                      sLGDITeardownPending;
static NSUInteger                sLGDITeardownGeneration;

// [闪烁修复] 拆除后冷却期：防止 hook 在拆除完成后立即用过期 sLGDIMode
// 重新点亮，导致玻璃反复装到默认小药丸上。冷却期内 !sLGDIActive 时不 Engage。
static CFTimeInterval            sLGDITeardownCooldownUntil;

// [锁屏检测 v5] 锁屏状态下不渲染液态玻璃，省电降温。
// 使用 Darwin 通知 com.apple.springboard.lockstate 监听锁屏/解锁事件，
// 通知回调中通过 SBLockScreenManager 查询实际状态（此时 SB 已完全启动，
// 调用 sharedInstance 安全）。不使用 NSNotification（需要 runloop 已启动），
// 不在 constructor 中调用 sharedInstance（会导致安全模式崩溃）。
static BOOL                      sLGDIOnLockScreen;

// [设计修复] 中心遮罩层：compact 药丸仅左右两端显示液态效果，
// 中心区域用深色层覆盖，保持系统原样的黑色中心条外观。
static CALayer                  *sLGDICenterCover;

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
    // [P4 修复] 同样验证 element mode：无效值不记录，防止
    // currentPreferredMode 返回越界值污染 LGDIHasActiveLayout 判定
    if (mode < 0 || mode > kLGDIModeDetached) {
        LGDILog(@"RecordElementMode: INVALID mode=%ld, ignoring", (long)mode);
        return;
    }
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
    // [P4 修复] 验证 mode 值：日志中观察到 mode=-1（mode-1）无效枚举值，
    // 系统在特定时序下可能传入越界值。无效值回退到 inert，防止状态机
    // 进入未定义状态导致点亮/拆除逻辑异常。
    if (mode < 0 || mode > DIPillLayoutModeDetached) {
        LGDILog(@"stateMachine: INVALID mode=%ld, clamping to inert", (long)mode);
        mode = DIPillLayoutModeInert;
    }
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
    // [设计调整] 默认小灵动岛（inert/minimal）保持系统原样，不做液态效果。
    // compact（长药丸，有活动内容）/ expanded / detached 才启用液态玻璃与黑幕压制。
    // inert/minimal 下闪烁的根因：此前 P4 修复路径以「curtain 在屏」为点亮信号，
    // 但默认小灵动岛 curtain 始终在屏 → 误装 pill 玻璃 → 弹簧动画中滤镜切换闪烁。
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
    // 延迟拆除窗口内（活动刚退出、玻璃正随收缩弹簧 morph 回小药丸）仍视为
    // 压制活跃：防止系统 setHidden:NO 穿透让黑色小药丸提前露出与玻璃重叠。
    // [闪烁根因修复 v2] 移除 || sLGDIActive 穿透：
    //   sLGDIActive 曾用于弹簧途中 element 表短暂空白时保持压制，但这导致
    //   拆除完成后 hook 仍能通过该标志间接维持压制 → 与过期 sLGDIMode 配合
    //   导致玻璃反复装到默认小药丸上。现在 sLGDITeardownPending 已覆盖
    //   拆除过渡窗口，compact↔expanded 弹跳期间 element 不会释放（同一
    //   element 切换模式），不需要额外 sLGDIActive 穿透。
    return LGDIFeatureEnabled()
        && (LGDIHasActiveLayout() || sLGDITeardownPending);
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

// [阶段4] 我方注入的所有玻璃/模糊底板：递归扫描、装饰压制、近黑剥离
// 一律整棵跳过（UIVisualEffectView 内部子视图也绝不能被动到）。
static inline BOOL LGDIIsOwnGlassView(UIView *v) {
    return v == sLGDIGlass || v == sLGDIExpGlass || v == sLGDIExpBlur;
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

// =============================================================================
//  阶段 3.1 纯诊断工具（LIQUIDASS_DEBUG 编译，零视觉改动）
//  目的：为「附件黑底 + 内容重承载」决策取证，只输出日志，不写任何
//  hidden / alpha / backgroundColor / frame。CI 以 LIQUIDASS_DEBUG=1 出包。
// =============================================================================
#if LIQUIDASS_DEBUG

// UIColor 安全描述（动态色/非 RGB 色空间不崩）
static NSString *LGDIDiagColorDesc(UIColor *bg) {
    if (!bg) return @"nil";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([bg getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"(%.2f,%.2f,%.2f,%.2f)", r, g, b, a];
    }
    return @"non-rgb";
}

// window 所属 scene 标识（persistentIdentifier + 激活状态）
static NSString *LGDIDiagSceneId(UIWindow *w) {
    if (!w) return @"<nil-win>";
    @try {
        UIWindowScene *ws = w.windowScene;
        if (!ws) return @"<no-scene>";
        NSString *pid = ws.session.persistentIdentifier;
        return [NSString stringWithFormat:@"%@/state=%ld/role=%@",
                pid ?: NSStringFromClass(ws.class),
                (long)ws.activationState, ws.session.role];
    } @catch (NSException *e) {
        return @"<scene-err>";
    }
}

// 向上打印祖先链（含每级 sibling index）：定位附件内容根与黑底承载者
static void LGDIDiagLogAncestorChain(UIView *v, NSUInteger maxUp, NSString *prefix) {
    UIView *a = v;
    for (NSUInteger i = 0; a && i <= maxUp; i++) {
        NSUInteger idx = NSNotFound, total = 0;
        if (a.superview) {
            idx = [a.superview.subviews indexOfObject:a];
            total = a.superview.subviews.count;
        }
        LGDILog(@"%@chain %lu: %@ sibIdx=%lu/%lu of %@ frame=%@ hidden=%d "
                @"alpha=%.2f clip=%d bg=%@ layer=%@",
                prefix, (unsigned long)i, NSStringFromClass(a.class),
                (unsigned long)idx, (unsigned long)total,
                a.superview ? NSStringFromClass(a.superview.class) : @"<nil>",
                NSStringFromCGRect(a.frame), (int)a.hidden, a.alpha,
                (int)a.clipsToBounds, LGDIDiagColorDesc(a.backgroundColor),
                NSStringFromClass(a.layer.class));
        a = a.superview;
    }
}

#endif

// DEBUG：一次性打印灵动岛窗口真实层级，定位黑色形体的实际承载视图
static void LGDIDumpTree(UIView *v, NSUInteger depth, NSUInteger maxDepth) {
#if LIQUIDASS_DEBUG
    if (!v || depth > maxDepth) return;
    NSString *cls = NSStringFromClass(v.class);
    NSUInteger sibIdx = NSNotFound, sibCount = 0;
    if (v.superview) {
        sibIdx = [v.superview.subviews indexOfObject:v];
        sibCount = v.superview.subviews.count;
    }
    LGDILog(@"tree %lu: %@ frame=%@ alpha=%.2f hidden=%d clip=%d bg=%@ layer=%@ sib=%lu/%lu",
            (unsigned long)depth, cls,
            NSStringFromCGRect(v.frame), v.alpha, (int)v.hidden,
            (int)v.clipsToBounds, LGDIDiagColorDesc(v.backgroundColor),
            NSStringFromClass(v.layer.class),
            (unsigned long)sibIdx, (unsigned long)sibCount);

    // 附件提供容器 / 材质层：黑底的直接承载者，额外打印 recipe / layer group
    if ([cls containsString:@"ProvidedView"] || [cls containsString:@"Material"]
        || [cls containsString:@"Backdrop"]) {
        NSString *recipe = @"-";
        @try {
            id rn = [v valueForKey:@"recipeName"] ?: [v valueForKey:@"_recipeName"];
            if (rn) recipe = [rn description];
        } @catch (NSException *e) { recipe = @"n/a"; }
        id group = nil, scale = nil;
        @try { group = [v.layer valueForKey:@"groupName"]; } @catch (...) {}
        @try { scale = [v.layer valueForKey:@"scale"]; } @catch (...) {}
        LGDILog(@"tree %lu:   MAT/PROVIDED/BACKDROP recipe=%@ layerGroup=%@ scale=%@",
                (unsigned long)depth, recipe, group, scale);
    }

    // _UIPortalView 把别处的 layer 树投影到灵动岛窗口，是黑色形体的头号嫌疑
    if ([cls containsString:@"PortalView"]) {
        @try {
            UIView *sv = [v valueForKey:@"sourceView"];
            if (sv) {
                UIWindow *srcWin = sv.window;
                CGRect inWin = srcWin ? [sv convertRect:sv.bounds toView:srcWin] : CGRectNull;
                LGDILog(@"tree %lu:   PORTAL sourceView=%@ inWindow=%@ level=%.1f "
                        @"scene=%@ hidden=%d alpha=%.2f clips=%d frameInSrcWin=%@ subviews=%lu",
                        (unsigned long)depth, NSStringFromClass(sv.class),
                        NSStringFromClass(srcWin.class), srcWin.windowLevel,
                        LGDIDiagSceneId(srcWin),
                        (int)sv.hidden, sv.alpha, (int)sv.clipsToBounds,
                        NSStringFromCGRect(inWin), (unsigned long)sv.subviews.count);
                // 源视图向上 5 层祖先链：黑底承载者通常是源视图的第 1~3 级父容器
                LGDIDiagLogAncestorChain(sv, 5,
                    [NSString stringWithFormat:@"tree %lu:   ", (unsigned long)depth]);
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

// ① 全窗口清单：确认附件源窗口与灵动岛窗口的层级先后 / scene 归属
static void LGDIDumpWindowInventory(UIWindow *apertureWin) {
    LGDILog(@"----- [diag1] window inventory begin -----");
    NSUInteger wi = 0;
    NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            LGDILog(@"win#%lu non-window-scene=%@ state=%ld",
                    (unsigned long)wi, NSStringFromClass(scene.class),
                    (long)scene.activationState);
            wi++;
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            LGDILog(@"win#%lu %@ level=%.1f hidden=%d key=%d frame=%@ scene=%@%@",
                    (unsigned long)wi, NSStringFromClass(w.class), w.windowLevel,
                    (int)w.hidden, (int)w.isKeyWindow,
                    NSStringFromCGRect(w.frame), LGDIDiagSceneId(w),
                    (w == apertureWin) ? @"  <== CURTAIN_WIN" : @"");
            wi++;
        }
    }
    LGDILog(@"----- [diag1] window inventory end (%lu windows) -----", (unsigned long)wi);
}

// ② host z 序：curtain→host 祖先链 + host 父级兄弟顺序 + host 内部子视图。
//    坐实/推翻「附件投影在玻璃合成顺序下方」这一关键推断。
static void LGDIDumpHostZOrder(UIView *curtain, UIView *host, UIWindow *win) {
    if (!curtain || !host) return;
    LGDILog(@"----- [diag2] z-order curtain -> host -----");
    NSMutableArray<UIView *> *chain = [NSMutableArray array];
    for (UIView *a = curtain; a && a != win; a = a.superview) [chain addObject:a];
    for (NSUInteger i = 0; i < chain.count; i++) {
        UIView *a = chain[i];
        NSUInteger idx = a.superview ? [a.superview.subviews indexOfObject:a] : NSNotFound;
        LGDILog(@"zchain %lu: %@ sibIdx=%lu/%lu of %@",
                (unsigned long)i, NSStringFromClass(a.class),
                (unsigned long)idx,
                (unsigned long)(a.superview ? a.superview.subviews.count : 0),
                a.superview ? NSStringFromClass(a.superview.class) : @"<nil>");
    }

    UIView *hp = host.superview;
    if (hp) {
        LGDILog(@"[diag2] host siblings inside %@ (%lu) — idx 小=合成顺序在下",
                NSStringFromClass(hp.class), (unsigned long)hp.subviews.count);
        NSUInteger si = 0;
        for (UIView *s in hp.subviews) {
            NSString *cn = NSStringFromClass(s.class);
            NSString *mark = (s == host) ? @"  <== HOST"
                : [cn containsString:@"PortalView"] ? @"  <== PORTAL"
                : [cn containsString:@"LGLiveBackdrop"] ? @"  <== GLASS?" : @"";
            LGDILog(@"hsib %lu: %@ frame=%@ hidden=%d alpha=%.2f%@",
                    (unsigned long)si, cn, NSStringFromCGRect(s.frame),
                    (int)s.hidden, s.alpha, mark);
            si++;
        }
    }
    LGDILog(@"[diag2] host.subviews (%lu) — 玻璃应在 idx 0",
            (unsigned long)host.subviews.count);
    NSUInteger hi = 0;
    for (UIView *s in host.subviews) {
        NSString *cn = NSStringFromClass(s.class);
        NSString *mark = [cn isEqualToString:@"LGLiveBackdropView"] ? @"  <== GLASS"
            : [cn containsString:@"PortalView"] ? @"  <== PORTAL" : @"";
        LGDILog(@"hsub %lu: %@ frame=%@ hidden=%d alpha=%.2f%@",
                (unsigned long)hi, cn, NSStringFromCGRect(s.frame),
                (int)s.hidden, s.alpha, mark);
        hi++;
        if (hi >= 30) { LGDILog(@"hsub ... truncated"); break; }
    }
}

// ③ 附件结构化快拍：全 Aperture/Alerting 窗口收集
//    PortalView / ProvidedView 容器 / MTMaterial，输出 portal 源视图与祖先链。
static void LGDIDiagCollectMarked(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                                  NSMutableArray<UIView *> *hits) {
    if (!v || depth > maxDepth) return;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"PortalView"] || [cn containsString:@"ProvidedView"]
        || [cn containsString:@"MTMaterial"]) {
        [hits addObject:v];
    }
    for (UIView *s in v.subviews) LGDIDiagCollectMarked(s, depth + 1, maxDepth, hits);
}

static void LGDIDumpAttachmentSnapshot(UIWindow *apertureWin) {
    LGDILog(@"----- [diag3] attachment snapshot begin -----");
    NSUInteger n = 0;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSString *wcn = NSStringFromClass(w.class);
            if (!([wcn containsString:@"Aperture"] || [wcn containsString:@"Alerting"]
                  || w == apertureWin)) continue;
            NSMutableArray<UIView *> *hits = [NSMutableArray array];
            LGDIDiagCollectMarked(w.rootViewController.view ?: (UIView *)w,
                                  0, 16, hits);
            if (hits.count == 0) continue;
            LGDILog(@"attWin %@ level=%.1f scene=%@ markedHits=%lu",
                    wcn, w.windowLevel, LGDIDiagSceneId(w),
                    (unsigned long)hits.count);
            for (UIView *v in hits) {
                NSString *cn = NSStringFromClass(v.class);
                CGRect inWin = [v convertRect:v.bounds toView:w];
                LGDILog(@"att#%lu %@ frameInWin=%@ hidden=%d alpha=%.2f bg=%@ subs=%lu",
                        (unsigned long)n, cn, NSStringFromCGRect(inWin),
                        (int)v.hidden, v.alpha,
                        LGDIDiagColorDesc(v.backgroundColor),
                        (unsigned long)v.subviews.count);
                if ([cn containsString:@"PortalView"]) {
                    @try {
                        UIView *sv = [v valueForKey:@"sourceView"];
                        if (sv) {
                            UIWindow *sw = sv.window;
                            CGRect sf = sw ? [sv convertRect:sv.bounds toView:sw]
                                           : CGRectNull;
                            LGDILog(@"att#%lu PORTAL-SRC %@ srcWin=%@ level=%.1f "
                                    @"scene=%@ frame=%@ hidden=%d alpha=%.2f "
                                    @"clip=%d bg=%@ subs=%lu",
                                    (unsigned long)n, NSStringFromClass(sv.class),
                                    NSStringFromClass(sw.class), sw.windowLevel,
                                    LGDIDiagSceneId(sw), NSStringFromCGRect(sf),
                                    (int)sv.hidden, sv.alpha,
                                    (int)sv.clipsToBounds,
                                    LGDIDiagColorDesc(sv.backgroundColor),
                                    (unsigned long)sv.subviews.count);
                            LGDIDiagLogAncestorChain(sv, 5,
                                [NSString stringWithFormat:@"att#%lu src-",
                                    (unsigned long)n]);
                        } else {
                            LGDILog(@"att#%lu PORTAL sourceView == nil", (unsigned long)n);
                        }
                    } @catch (NSException *e) {
                        LGDILog(@"att#%lu PORTAL introspect failed: %@",
                                (unsigned long)n, e.reason);
                    }
                }
                n++;
                if (n >= 80) {
                    LGDILog(@"att ... truncated at 80");
                    LGDILog(@"----- [diag3] attachment snapshot end (truncated) -----");
                    return;
                }
            }
        }
    }
    LGDILog(@"----- [diag3] attachment snapshot end (%lu marked views) -----",
            (unsigned long)n);
}

static NSUInteger sLGDIDumpCount;
static void LGDIRequestDump(NSString *reason) {
    // 阶段 3.1：三场景（音乐 compact/expanded、红果）反复切换都要能抓到，上限放宽
    if (sLGDIDumpCount >= 24) return;
    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    UIWindow *win = curtain.window ?: (sLGDIHost.window);
    if (!win) return;
    sLGDIDumpCount++;
    LGDILog(@"===== [DI-DUMP] #%lu reason=%@ mode=%@ =====",
            (unsigned long)sLGDIDumpCount, reason,
            LGDIModeName((NSInteger)[DIPillStateMachine shared].currentMode));

    // ① 全窗口清单（类名 / level / scene）
    LGDIDumpWindowInventory(win);

    // ② 灵动岛主窗口完整树（深度 8）
    LGDILog(@"----- [tree] aperture window %@ level=%.1f -----",
            NSStringFromClass(win.class), win.windowLevel);
    LGDIDumpTree(win, 0, 8);

    // ③ 其它 Aperture/Alerting 窗口（附件源窗口，深度 12）
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w == win) continue;
            NSString *cn = NSStringFromClass(w.class);
            if ([cn containsString:@"Aperture"] || [cn containsString:@"Alerting"]) {
                LGDILog(@"----- [tree] diag window %@ level=%.1f scene=%@ -----",
                        cn, w.windowLevel, LGDIDiagSceneId(w));
                LGDIDumpTree(w.rootViewController.view ?: (UIView *)w, 0, 12);
            }
        }
    }

    // ④ host z 序（玻璃 vs 附件投影的合成先后）
    UIView *diagHost = sLGDIHost ?: (curtain ? LGDIHostForCurtain(curtain) : nil);
    LGDIDumpHostZOrder(curtain, diagHost, win);

    // ⑤ 附件结构化快拍（portal 源视图 + 黑底祖先链）
    LGDIDumpAttachmentSnapshot(win);

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
                @"filters=%@ opaque=%d opacity=%.2f hidden=%d frame=%@",
                NSStringFromClass(glass.window.class), glass.window.windowLevel,
                [l valueForKey:@"groupName"], [l valueForKey:@"groupNamespace"],
                [l valueForKey:@"scale"], fdesc, (int)l.opaque, l.opacity,
                (int)l.hidden, NSStringFromCGRect(glass.frame));
    }
    LGDILog(@"===== [DI-DUMP] #%lu end =====", (unsigned long)sLGDIDumpCount);
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
    if (!v || LGDIIsOwnGlassView(v)) return NO;
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

// 所有对 alpha / backgroundColor / hidden 的压制与恢复写入都必须关闭
// CoreAnimation 隐式动作。我们的 hook 经常在系统弹簧动画事务内被调用
//（layoutSubviews / setHidden: 穿行于系统动画），裸赋值会被并入正在进行的
// 动画事务，活动退出时边框"灰闪"就是恢复写入的淡入与收缩弹簧叠加所致。
static void LGDIWithoutImplicitAnimations(dispatch_block_t block) {
    if (!block) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        block();
    }];
    [CATransaction commit];
}

// 记录并压制单个视图（幂等）
static void LGDISuppressOne(UIView *v) {
    if (!v || LGDIIsOwnGlassView(v)) return;
    if (!objc_getAssociatedObject(v, kLGDIRestoreInfoKey)) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"alpha"]  = @(v.alpha);
        info[@"hidden"] = @(v.hidden);
        if (v.backgroundColor) info[@"bg"] = v.backgroundColor;
        LGDIRegisterSuppressed(v, info);
        LGDILog(@"suppressed decor %@ frame=%@",
                NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
    }
    // 系统可能在布局中把状态改回来；等值时不重复写。
    // 必须瞬时生效：关闭隐式动画，避免在系统动画事务内淡出。
    LGDIWithoutImplicitAnimations(^{
        if (v.alpha != 0.0) v.alpha = 0.0;
        if (v.backgroundColor && v.backgroundColor != UIColor.clearColor) {
            v.backgroundColor = UIColor.clearColor;
        }
    });
}

// 递归全子树压制（深度受限）。iOS 17 的黑色形体是嵌套在容器深处的
// MTMaterialView，只扫宿主直接子视图必然漏掉；换宿主时也不能还原。
static void LGDISweepView(UIView *v, NSUInteger depth) {
    if (!v || depth == 0 || LGDIIsOwnGlassView(v)) return;
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
    // [P3 修复] 放宽阈值：原 0.25 漏掉灰色背景（r=g=b=0.3，系统常见），
    // 导致灰色盖在玻璃之上。提高到 0.35 捕获更多深灰背景。
    // alpha 从 0.4 降到 0.3：半透明深灰也需剥离。
    if (!(a > 0.3)) return NO;                  // 半透明底也需剥离
    return (r < 0.35 && g < 0.35 && b < 0.35); // 近黑/深灰
}

// 仅清背景色（bg-only）。记录到同一压制集合，停用/回空闲时由 restore 统一还原。
static void LGDIStripNearBlackBackground(UIView *v) {
    if (!v || LGDIIsOwnGlassView(v)) return;
    // curtain / gainMap 由各自的隐藏 hook 管理，这里不重复动
    if (LGDIClassName(v, @"_SBSystemApertureMagiciansCurtainView")) return;
    if (LGDIClassName(v, @"_SBGainMapView")) return;
    // [阶段3] 内容 Provider 策略：专辑封面等内容本体受保护，不剥离
    if (![[DIContentProviderRegistry shared] shouldStripNearBlackBackgroundForView:v])
        return;
    UIColor *bg = v.backgroundColor;
    if (!LGDIColorIsNearBlackOpaque(bg)) return;
    // 已被装饰压制（含 alpha 记录）的视图交给 LGDISuppressOne 路径，不重复登记
    if (!objc_getAssociatedObject(v, kLGDIRestoreInfoKey)) {
        LGDIRegisterSuppressed(v, @{ @"bg": bg });  // 只记 bg → 还原时只回写背景
        LGDILog(@"stripped near-black bg on %@ frame=%@",
                NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
    }
    // 直接写图层，绕过 setBackgroundColor: hook，避免被判定回路拦截。
    // 同样关闭隐式动画，防止剥离在系统动画事务内淡出。
    LGDIWithoutImplicitAnimations(^{
        v.layer.backgroundColor = UIColor.clearColor.CGColor;
    });
}

static void LGDIStripNearBlackSubtree(UIView *v, NSUInteger depth) {
    if (!v || depth == 0 || LGDIIsOwnGlassView(v)) return;
    LGDIStripNearBlackBackground(v);
    for (UIView *sub in v.subviews) LGDIStripNearBlackSubtree(sub, depth - 1);
}

static void LGDISuppressDecorations(UIView *host) {
    // [设计调整] 仅 compact/expanded/detached 才压制装饰；inert/minimal 保持系统原样。
    if (!host || !LGDILiquidSuppressionActive()) return;

    // 容器自身 + 整棵子树的「近黑不透明背景」剥离（由 ClearContentBg 控制）。
    // 只清背景色、不动 alpha/hidden，实时内容原样保留；这是露出底层液态玻璃的
    // 关键一路（内容/呈现容器的黑底原本盖在 atIndex:0 的玻璃之上）。
    if (LGDClearContentBg()) {
        // 从窗口根剥离：展开卡片的内容容器可能是 host 的兄弟分支，只扫 host 会漏
        UIView *stripRoot = host.window ?: host;
        LGDIStripNearBlackBackground(host);
        // [声波修复] compact 也用 22 层（声波/波形视图常嵌套在 18+ 层），
        // 不再区分 compact/expanded，统一深度
        BOOL isExpanded = (NSInteger)[DIPillStateMachine shared].currentMode
                          >= DIPillLayoutModeExpanded;
        LGDIStripNearBlackSubtree(stripRoot, 22);

        // 展开内容可能在独立窗口，也要扫到
        if (isExpanded && sLGDIGlass) {
            UIWindowScene *scene = sLGDIGlass.window.windowScene;
            for (UIWindow *w in scene.windows) {
                if (w == host.window) continue;
                if ([NSStringFromClass(w.class) containsString:@"Aperture"] ||
                    [NSStringFromClass(w.class) containsString:@"Alerting"]) {
                    UIView *root = w.rootViewController.view ?: (UIView *)w;
                    LGDIStripNearBlackSubtree(root, 14);
                }
            }
        }
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
            // 该路关闭：还原原始状态（无隐式动画，先清掉可能挂着的动画）
            [v.layer removeAllAnimations];
            LGDIWithoutImplicitAnimations(^{
                if (info[@"alpha"])  v.alpha = [info[@"alpha"] floatValue];
                if (info[@"hidden"]) v.hidden = [info[@"hidden"] boolValue];
                if (info[@"bg"])     v.layer.backgroundColor = [info[@"bg"] CGColor];
            });
            objc_setAssociatedObject(v, kLGDIRestoreInfoKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }

        // 该路开启：重新断言。bg-only 视图绝不能动 alpha/hidden（否则连内容一起消失），
        // 只保证背景保持透明；装饰/黑色材质视图才整视图 alpha=0。
        LGDIWithoutImplicitAnimations(^{
            if (!bgOnly) {
                if (v.alpha != 0.0) v.alpha = 0.0;
            }
            if (v.backgroundColor && v.backgroundColor != UIColor.clearColor) {
                v.layer.backgroundColor = UIColor.clearColor.CGColor;
            }
        });
    }
}

static void LGDIRestoreAllSuppressed(void) {
    for (UIView *v in [sLGDISuppressedViews allObjects]) {
        NSDictionary *info = objc_getAssociatedObject(v, kLGDIRestoreInfoKey);
        if (!info) continue;
        // 先移除残留动画，再在无隐式动画事务里瞬时还原，
        // 杜绝退出活动时装饰边框 0.25s 淡入造成的灰闪。
        [v.layer removeAllAnimations];
        LGDIWithoutImplicitAnimations(^{
            if (info[@"alpha"])  v.alpha = [info[@"alpha"] floatValue];
            if (info[@"hidden"]) v.hidden = [info[@"hidden"] boolValue];
            // 直接写图层，绕过 setBackgroundColor: hook（热切换宿主时开关仍为开启状态）
            if (info[@"bg"])     v.layer.backgroundColor = [info[@"bg"] CGColor];
        });
        objc_setAssociatedObject(v, kLGDIRestoreInfoKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"restored decor %@", NSStringFromClass(v.class));
    }
    [sLGDISuppressedViews removeAllObjects];
}

// =============================================================================
//  Geometry sync
// =============================================================================

// 展开模式下搜索灵动岛内容容器帧。compact curtain 不随展开改变尺寸，
// 展开内容在另一棵子树或另一个窗口。这里在整个窗口场景中搜索一个
// 「比 compact curtain 大、可见、非 portal/curtain/gainmap/glass、
//  尺寸合理」的视图作为展开内容帧。
// =============================================================================
//  [阶段 3/4] 展开目标定位（Provider 打分） + 展开独立玻璃生命周期
// -----------------------------------------------------------------------------
//  对标 Mango：
//    ensureExpandedBackgroundGlassCreated / destroyExpandedBackgroundGlass
//    refreshExpandedBackgroundGlassBackdrop / cleanupExpandedBackgroundGlassLiveCapture
//    mangoStartExpandedGlassLiveRefresh / mangoStopExpandedGlassLiveRefresh
//    mangoExpandedGlassDisplayLinkTick: / mangoExpandedGlassTargetFrame
//    _expandedLiquidGlassView / _blurBackgroundView / _expandedGlassHostView
//    _lastExpandedGlassFrame / _lastExpandedGlassCaptureTime / expandedGlassRetryCount
//
//  compact pill 玻璃（sLGDIGlass）追踪 curtain；一旦 Provider 辅助定位到
//  展开内容容器，就在其窗口创建独立的第二块玻璃 + 系统原生模糊底板，
//  pill 玻璃让位隐藏；回到 compact 时拆除展开玻璃、恢复 pill 玻璃。
// =============================================================================

static CGFloat LGDIFallbackCornerRadius(CGRect f);  // 前向声明
// [闪烁修复] 前向声明：在 LGDIEnsureExpandedGlass 中使用，但定义在 Glass lifecycle 段
static void LGDIDelayedRefreshBackdrop(LGLiveBackdropView *glass, NSTimeInterval delay);
// [独立 DisplayLink] 前向声明
static void LGDIStartExpandedDriver(NSTimeInterval duration);
static void LGDIStopExpandedDriver(void);
static void LGDIExpandedDriverTick(CADisplayLink *link);

static NSString * const kLGDIExpFilterType = @"dylv.liquidglass.dynamicisland.expanded";
static NSString * const kLGDIExpGroupTag   = @"dylv.liquidglass.island.expanded";

// [独立 DisplayLink] 展开态专用驱动，与 compact pill driver 完全隔离。
// 对齐 Mango 的 MangoExpandedGlassLinkProxy：compact 和 expanded 各自独立
// CADisplayLink，互不干扰。compact driver 只更新 pill 玻璃几何，
// expanded driver 只更新展开玻璃几何，避免共用 tick 中互相触发 applyFilters。
static CADisplayLink   *sLGDIExpLink;
static CFTimeInterval  sLGDIExpLinkDeadline;
static CFTimeInterval  sLGDIExpMinDriverEnd;
static NSUInteger       sLGDIExpSteadyFrameCount;
static CGRect           sLGDIExpLastPresentationFrame;
static BOOL             sLGDIExpDriverActive;

// CGRectNull 含 INFINITY，不是编译期常量，不能做静态初始化；用零值 + 标志位
static CGRect        sLGDIExpLastFrame;
static BOOL          sLGDIExpHasLastFrame;
static CFTimeInterval sLGDIExpLastCapture;
static NSInteger      sLGDIExpRetries;
static BOOL           sLGDIExpFramePending;  // 帧变化后等待稳定再重捕
static NSString      *sLGDIExpProviderID;

static const NSInteger      kLGDIExpMaxRetries      = 6;
static const NSTimeInterval kLGDIExpCaptureThrottle = 0.4;
// 原生模糊底板透明度：systemThinMaterial 本身较轻，0.5 保证通透明亮而不重新压暗
static const CGFloat        kLGDIExpBlurAlpha       = 0.5;

// best-effort 从存活 element 上取内容来源 bundle/client 标识。
// 全部 respondsToSelector 保护，类名/版本不匹配时返回 nil（回退纯视图签名匹配）。
static NSString *LGDICurrentContentBundleID(void) {
    for (id e in sLGDIElementModes) {
        if ([e respondsToSelector:@selector(clientIdentifier)]) {
            id s = ((id (*)(id, SEL))objc_msgSend)(e, @selector(clientIdentifier));
            if ([s isKindOfClass:NSString.class] && ((NSString *)s).length) return s;
        }
        if ([e respondsToSelector:@selector(bundleIdentifier)]) {
            id s = ((id (*)(id, SEL))objc_msgSend)(e, @selector(bundleIdentifier));
            if ([s isKindOfClass:NSString.class] && ((NSString *)s).length) return s;
        }
    }
    return nil;
}

// 在命中视图向上的祖先链中找展开玻璃宿主：
// 优先「卡片作用域内最高的不裁剪祖先」（玻璃正好覆盖整张展开卡片），
// 退化到 TouchPassThrough / 最高不裁剪祖先 / 窗口（与 pill 宿主同策略）。
static UIView *LGDIExpandedHostForView(UIView *view) {
    UIWindow *win = view.window;
    if (!win) return nil;
    UIView *card = nil, *touch = nil, *top = nil;
    for (UIView *a = view.superview; a && a != win; a = a.superview) {
        if (a.clipsToBounds) continue;
        CGRect af = [a convertRect:a.bounds toView:win];
        if (af.size.width <= 430.0 && af.size.height <= 280.0) card = a;  // 循环上移→保留最高者
        if ([NSStringFromClass(a.class) containsString:@"TouchPassThrough"]) touch = a;
        top = a;
    }
    return card ?: touch ?: top ?: win;
}

// 沿祖先链取第一个有效圆角（展开卡片圆角常设在外层容器上）
static CGFloat LGDIInheritedCornerRadius(UIView *view) {
    for (UIView *a = view; a; a = a.superview) {
        if (a.layer.cornerRadius > 1.0) return a.layer.cornerRadius;
    }
    return 0;
}

// Provider 辅助的展开目标搜索。返回 host 坐标系下的帧；
// outHost/outView/outRadius/outProvider 回传宿主、命中视图与圆角。
static CGRect LGDIFindExpandedTarget(UIView *curtain,
                                     UIView * __autoreleasing *outHost,
                                     UIView * __autoreleasing *outView,
                                     CGFloat *outRadius,
                                     id<DIContentProviding> __autoreleasing *outProvider) {
    if (!curtain || !curtain.window) return CGRectNull;
    CGRect compactFrame = [curtain convertRect:curtain.bounds toView:curtain.window];

    __block CGRect bestFrameWin = CGRectNull;
    __block UIView *bestView = nil;
    __block NSInteger bestScore = 0;
    __block CGFloat bestArea = 0;
    __block NSUInteger candidateCount = 0;
    NSString *bundleHint = LGDICurrentContentBundleID();

    void (^checkView)(UIView *) = ^(UIView *v) {
        if (!v || LGDIIsOwnGlassView(v) || v == curtain || v.hidden || v.alpha < 0.01)
            return;
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"PortalView"]) return;
        if ([cn containsString:@"GainMap"]) return;
        if ([cn containsString:@"BackdropLayer"]) return;
        if ([cn containsString:@"VisualEffect"]) return;  // 含我们注入的模糊底板及其 contentView
        if ([cn isEqualToString:@"LGLiveBackdropView"]) return;
        // 祖先链上若有我们注入的玻璃/模糊视图，同样排除（防止把底板子树当内容）
        for (UIView *a = v.superview; a; a = a.superview) {
            NSString *acn = NSStringFromClass(a.class);
            if ([acn isEqualToString:@"UIVisualEffectView"] ||
                [acn isEqualToString:@"LGLiveBackdropView"]) return;
        }

        UIWindow *win = v.window ?: curtain.window;
        CGRect f = [v convertRect:v.bounds toView:win];
        // 必须比 compact curtain 明显大（展开内容）
        if (f.size.width <= compactFrame.size.width + 10 ||
            f.size.height <= compactFrame.size.height + 5) return;
        // 排除全屏视图（容器背景板，不是展开内容）。放宽到 400x240
        // 以覆盖音量/音乐大卡片（旧 380x200 阈值实测漏检）。
        if (f.size.width > 400 || f.size.height > 240) return;
        // 必须在屏幕顶部灵动岛区域
        if (f.origin.y > 320) return;

        candidateCount++;
        id<DIContentProviding> p =
            [[DIContentProviderRegistry shared] providerForView:v hintBundleID:bundleHint];
        NSInteger score = [p scoreExpandedCandidate:v];
        CGFloat area = f.size.width * f.size.height;
        // 专用 Provider 命中优先；同分时取面积最大（等价旧启发式）
        if (score > bestScore || (score == bestScore && area > bestArea)) {
            bestScore = score;
            bestArea = area;
            bestView = v;
            bestFrameWin = f;
        }
    };

    // 搜索灵动岛窗口场景的所有窗口（展开内容可能在独立窗口）
    UIWindowScene *scene = curtain.window.windowScene;
    NSArray<UIWindow *> *windows = scene.windows;
    if (windows.count == 0) windows = UIApplication.sharedApplication.windows;

    for (UIWindow *w in windows) {
        if ([NSStringFromClass(w.class) containsString:@"Aperture"] ||
            [NSStringFromClass(w.class) containsString:@"Alerting"] ||
            w == curtain.window) {
            __block __weak void (^weakWalk)(UIView *, NSUInteger);
            void (^walk)(UIView *, NSUInteger) = ^(UIView *v, NSUInteger depth) {
                if (!v || depth > 12) return;
                checkView(v);
                for (UIView *sub in v.subviews) weakWalk(sub, depth + 1);
            };
            weakWalk = walk;
            UIView *root = w.rootViewController.view;
            if (!root) root = (UIView *)w;
            walk(root, 0);
        }
    }

#if LIQUIDASS_DEBUG
    {
        static NSUInteger sLGDIExpScanTick = 0;
        if ((sLGDIExpScanTick++ % 60) == 0) {
            if (bestView) {
                LGDILog(@"expanded scan: HIT view=%@ win=%@ score=%ld candidates=%lu "
                        @"(compact %.0fx%.0f)",
                        NSStringFromClass(bestView.class),
                        NSStringFromClass(bestView.window.class),
                        (long)bestScore, (unsigned long)candidateCount,
                        compactFrame.size.width, compactFrame.size.height);
            } else {
                LGDILog(@"expanded scan: MISS candidates=%lu (compact %.0fx%.0f)",
                        (unsigned long)candidateCount,
                        compactFrame.size.width, compactFrame.size.height);
            }
        }
    }
#endif

    if (!bestView) return CGRectNull;

    UIView *host = LGDIExpandedHostForView(bestView);
    if (!host) return CGRectNull;
    UIWindow *win = bestView.window;
    CGRect hostFrame = [win convertRect:bestFrameWin toView:host];
    if (!LGDIIsPlausibleSize(hostFrame.size)) return CGRectNull;

    CGFloat radius = LGDIInheritedCornerRadius(bestView);
    if (radius <= 0.5) radius = LGDIFallbackCornerRadius(hostFrame);

    if (outHost)     *outHost = host;
    if (outView)     *outView = bestView;
    if (outRadius)   *outRadius = radius;
    if (outProvider) {
        *outProvider = [[DIContentProviderRegistry shared]
            providerForView:bestView hintBundleID:bundleHint];
    }
    return hostFrame;
}

static CFTimeInterval sLGDIExpLastSweep;  // 展开窗口装饰压制节流
static CFTimeInterval sLGDIExpCompactSince; // 展开态进入 compact 的时刻（0=在展开态）

// 创建/挂载/同步展开玻璃（幂等）。frame/radius 均在 host 坐标系。
static void LGDIEnsureExpandedGlass(CGRect frame, UIView *host,
                                    CGFloat radius, id<DIContentProviding> provider) {
    if (!host) return;

    BOOL created = NO, hostChanged = NO;

    // 1) 原生模糊底板（系统 UIVisualEffectView，对标 Mango blurBackgroundView）
    UIVisualEffectView *blur = sLGDIExpBlur;
    if (!blur) {
        UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        blur = [[UIVisualEffectView alloc] initWithEffect:eff];
        blur.userInteractionEnabled = NO;
        blur.backgroundColor = UIColor.clearColor;
        blur.contentView.backgroundColor = UIColor.clearColor;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.layer.masksToBounds = YES;
        blur.alpha = kLGDIExpBlurAlpha;
        sLGDIExpBlur = blur;
        LGDILog(@"expanded: native blur base created");
    }
    if (blur.superview != host) {
        hostChanged = YES;
        [host insertSubview:blur atIndex:0];
    } else if (host.subviews.firstObject != blur) {
        // 系统布局可能重排子视图，持续把模糊底板压到最底（无动画）
        [host insertSubview:blur atIndex:0];
    }

    // 2) 独立液态玻璃（backboardd 按 filterType 前缀匹配，自动复用 DynamicIsland
    //    参数与壁纸 fallback 纹理；独立捕获组避免与 pill 玻璃几何/滤镜串扰）
    LGLiveBackdropView *glass = sLGDIExpGlass;
    if (!glass) {
        created = YES;
        glass = [[LGLiveBackdropView alloc] initWithFrame:frame
                                                 groupName:kLGDIExpGroupTag
                                                filterType:kLGDIExpFilterType];
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        sLGDIExpGlass = glass;
        sLGDIExpRetries = 0;
        LGDILog(@"expanded: independent glass created provider=%@ frame=%@",
                provider.identifier, NSStringFromCGRect(frame));
        // 首捕可能为空（内容/背景未就绪），多时间点触发软刷新
        // [黑边修复 v4] lgForceRefreshBackdrop 已改为软刷新，不销毁捕获组
        for (NSNumber *delay in @[ @0.2, @0.8 ]) {
            LGDIDelayedRefreshBackdrop(glass, delay.doubleValue);
        }
    }
    if (glass.superview != host) {
        hostChanged = YES;
        [host insertSubview:glass aboveSubview:blur];
    } else {
        NSUInteger bi = [host.subviews indexOfObject:blur];
        NSUInteger gi = [host.subviews indexOfObject:glass];
        if (bi != NSNotFound && (gi == NSNotFound || gi != bi + 1)) {
            [host insertSubview:glass aboveSubview:blur];
        }
    }
    sLGDIExpHost = host;
    sLGDIExpProviderID = provider.identifier;

    // 3) 逐帧几何（无隐式动画，避免与系统弹簧事务叠加闪框）
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!CGRectEqualToRect(blur.frame, frame)) blur.frame = frame;
    if (!CGRectEqualToRect(glass.frame, frame)) glass.frame = frame;
    if (fabs(blur.layer.cornerRadius - radius) > 0.25) blur.layer.cornerRadius = radius;
    if (fabs(glass.layer.cornerRadius - radius) > 0.25) glass.layer.cornerRadius = radius;
    if (blur.hidden) blur.hidden = NO;
    if (glass.hidden) glass.hidden = NO;
    // [黑边修复 v2] pill 玻璃让位必须与展开玻璃显示在同一 CATransaction 中：
    // 旧逻辑在 commit 后才隐藏 pill 玻璃 → 中间有 1 帧两者都可见或都不可见
    // → 黑边/重叠闪烁。原子切换 = 同一 render server 提交。
    if (!sLGDIPillHiddenForExpanded && sLGDIGlass) {
        sLGDIGlass.hidden = YES;
        sLGDIPillHiddenForExpanded = YES;
    }
    [CATransaction commit];

    // 5) 展开窗口内同样要扫掉黑材质/剥黑底，否则盖在展开玻璃之上。
    //    全窗口递归代价高，绝不能逐帧执行：仅创建/换宿主时立即扫一次，
    //    稳态下按 0.3s 节流补扫（捕获系统 layoutSubviews 重建的装饰）。
    //    [外框修复] strip 深度从 16 提到 22（与 LGDISuppressDecorations 一致），
    //    覆盖展开内容深层容器（视频/音乐内容黑底常在 18+ 层）。
    CFTimeInterval now = CACurrentMediaTime();
    if (created || hostChanged || now - sLGDIExpLastSweep > 0.3) {
        sLGDIExpLastSweep = now;
        UIView *sweepRoot = host.window ?: host;
        LGDISweepView(sweepRoot, 16);
        if (LGDClearContentBg()) LGDIStripNearBlackSubtree(sweepRoot, 22);
        if (created || hostChanged) {
            // [外框修复] 内容常在展开后 0.3~1.5s 才加载完，多次延迟再扫
            __weak UIView *weakHost = host;
            for (NSNumber *delay in @[ @0.2, @0.5, @1.0, @1.5 ]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (sLGDIActive && weakHost) {
                        UIView *r = weakHost.window ?: weakHost;
                        LGDISweepView(r, 16);
                        if (LGDClearContentBg()) LGDIStripNearBlackSubtree(r, 22);
                    }
                });
            }
        }
    }
}

// 每帧同步展开玻璃。返回 YES 表示展开玻璃在管（调用方跳过 pill 几何）；
// 返回 NO 表示展开内容尚未就绪且还没有展开玻璃（调用方临时回退 pill 追踪）。
static BOOL LGDISyncExpandedGeometry(void) {
    UIView *curtain = sLGDICurtain;
    if (!curtain) return sLGDIExpGlass != nil;

    UIView *host = nil;
    CGFloat radius = 0;
    id<DIContentProviding> provider = nil;
    CGRect f = LGDIFindExpandedTarget(curtain, &host, NULL, &radius, &provider);

    if (CGRectIsNull(f) || !host) {
        // 展开玻璃可见时保持旧帧等待目标恢复；隐藏时（compact 过渡期）回退 pill 同步
        return (sLGDIExpGlass && !sLGDIExpGlass.hidden) ? YES : NO;
    }

    LGDIEnsureExpandedGlass(f, host, radius,
                            provider ?: [[DIContentProviderRegistry shared] fallbackProvider]);

    // 帧稳定后节流强刷 backdrop（对标 Mango lastExpandedGlassCaptureTime +
    // expandedGlassRetryCount：只在形变收敛后重采，避免弹簧途中频繁重建捕获组）
    CFTimeInterval now = CACurrentMediaTime();
    BOOL sameFrame = sLGDIExpHasLastFrame
        && fabs(f.origin.x - sLGDIExpLastFrame.origin.x) < 0.5
        && fabs(f.origin.y - sLGDIExpLastFrame.origin.y) < 0.5
        && fabs(f.size.width  - sLGDIExpLastFrame.size.width)  < 0.5
        && fabs(f.size.height - sLGDIExpLastFrame.size.height) < 0.5;
    if (!sameFrame) {
        sLGDIExpFramePending = YES;
    } else if (sLGDIExpFramePending
               && sLGDIExpRetries < kLGDIExpMaxRetries
               && now - sLGDIExpLastCapture > kLGDIExpCaptureThrottle
               && ![sLGDIExpGlass lgFilterTypeLocked]) {
        // [黑边修复 v4] lgForceRefreshBackdrop 已改为软刷新（setNeedsDisplay），
        // 不会销毁捕获组。帧稳定后触发软刷新让 render server 重新采样。
        sLGDIExpFramePending = NO;
        sLGDIExpRetries++;
        sLGDIExpLastCapture = now;
        LGDIDelayedRefreshBackdrop(sLGDIExpGlass, 0.15);
    }
    sLGDIExpLastFrame = f;
    sLGDIExpHasLastFrame = YES;
    return YES;
}

// 拆除展开玻璃（回 compact / 功能关闭 / teardown）。无动画硬切，不产生淡变。
static void LGDIDestroyExpandedGlass(NSString *reason) {
    // [独立 DisplayLink] 先停止展开 driver，防止拆除后 tick 访问已释放的 glass
    LGDIStopExpandedDriver();
    LGLiveBackdropView *glass = sLGDIExpGlass;
    UIVisualEffectView *blur = sLGDIExpBlur;
    if (!glass && !blur) {
        sLGDIPillHiddenForExpanded = NO;
        return;
    }
    LGDIWithoutImplicitAnimations(^{
        // [F2 修复] 同 teardown：removeFromSuperview 前清理 render server 捕获组
        if (glass) {
            [glass removeFromSuperview];
            @try {
                glass.layer.filters = @[];
                [glass.layer setValue:nil forKey:@"groupName"];
            } @catch (NSException *e) {
                LGDILog(@"destroyExpanded KVC cleanup exception: %@", e.reason);
            }
        }
        [blur removeFromSuperview];
    });
    sLGDIExpGlass = nil;
    sLGDIExpBlur = nil;
    sLGDIExpHost = nil;
    sLGDIExpLastFrame = CGRectZero;
    sLGDIExpHasLastFrame = NO;
    sLGDIExpRetries = 0;
    sLGDIExpFramePending = NO;
    sLGDIExpLastSweep = 0;
    sLGDIExpProviderID = nil;
    if (sLGDIPillHiddenForExpanded && sLGDIGlass) {
        sLGDIGlass.hidden = NO;
        sLGDIPillHiddenForExpanded = NO;
    }
    // [设计修复] 回到 compact 时恢复中心遮罩可见性：展开态将其隐藏，
    // 下一帧几何同步才会重新设为 NO，但中间可能有 1 帧完整液态效果透出。
    if (sLGDICenterCover && sLGDICenterCover.hidden) {
        sLGDICenterCover.hidden = NO;
    }
    LGDILog(@"expanded glass destroyed: %@", reason);
}

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

    // [阶段4] 展开模式下 compact curtain 保持 compact 尺寸，展开内容在另一棵
    // 子树/窗口：交给独立展开玻璃（Provider 辅助定位 + 原生模糊底板）。
    //   - 展开玻璃在管 → 本帧不再动 pill 玻璃；
    //   - 展开内容尚未就绪且展开玻璃还没建 → 临时回退 pill 追踪 curtain morph；
    //   - 回到 compact → 拆除展开玻璃、恢复 pill 玻璃。
    BOOL isExpanded = (NSInteger)[DIPillStateMachine shared].currentMode >= DIPillLayoutModeExpanded;

    if (isExpanded) {
        sLGDIExpCompactSince = 0;  // 在展开态 → 重置 compact 计时
        // [设计修复] 展开态不需要中心遮罩（展开玻璃独立管理）
        if (sLGDICenterCover && !sLGDICenterCover.hidden) {
            sLGDICenterCover.hidden = YES;
        }
        // [独立 DisplayLink] 展开态：如果展开玻璃已创建，由独立 driver 接管。
        // compact driver 只负责首次展开（玻璃尚未创建时）的 pill 追踪。
        // 一旦展开玻璃存在，启动独立 driver 并立即 return——
        // compact pill 不再被逐帧更新，避免 applyFilters 触发 → 闪烁。
        if (sLGDIExpGlass) {
            // 首次进入展开态（独立 driver 未激活）：启动独立 driver
            if (!sLGDIExpDriverActive) {
                LGDIStartExpandedDriver(1.2);
            }
            // 同步一次展开玻璃几何（由独立 driver 后续逐帧接管）
            LGDISyncExpandedGeometry();
            return;
        }
        // 展开玻璃尚未创建：LGDISyncExpandedGeometry 内部会创建它
        if (LGDISyncExpandedGeometry()) {
            // 创建成功：启动独立 driver 接管后续帧
            if (!sLGDIExpDriverActive) {
                LGDIStartExpandedDriver(1.2);
            }
            return;
        }
        // 展开目标未找到且玻璃未创建：回退 pill 追踪
    } else if (sLGDIExpGlass || sLGDIExpBlur) {
        // [闪烁根因修复] 弹簧弹跳会快速 expanded→compact→expanded→compact 循环。
        // 旧逻辑每次 compact 都立即 hide 展开玻璃 + show pill 玻璃，每次 expanded
        // 又反过来——每帧 toggle = 黑边闪烁 2-3 次（对应弹簧振荡）。
        // 新逻辑：compact 时先尝试同步展开玻璃（弹跳可能已回到 expanded）；
        // 如果确实没有展开目标，开始 0.3s 防抖计时，期间保持展开玻璃可见不动，
        // pill 玻璃也保持隐藏——不 toggle = 不闪烁。
        // 0.3s 后仍为 compact 才执行可见性切换。
        if ([DIPillStateMachine shared].currentMode == DIPillLayoutModeInert) {
            LGDIDestroyExpandedGlass(@"inert (idle)");
        } else {
            // 先尝试同步展开玻璃——弹跳可能已回到 expanded
            if (LGDISyncExpandedGeometry()) {
                sLGDIExpCompactSince = 0;
                return;  // 回到 expanded，展开玻璃在管
            }
            // 确实没有展开目标
            if (sLGDIExpCompactSince == 0) {
                sLGDIExpCompactSince = CACurrentMediaTime();
            }
            if (CACurrentMediaTime() - sLGDIExpCompactSince < 0.3) {
                // 防抖窗口内：保持展开玻璃可见（冻在旧帧），pill 玻璃保持隐藏
                // 不 toggle = 不闪烁。仍同步 pill 几何以备切换后立即对齐。
                // 跳过本帧的 pill 可见性切换，但不跳过几何同步。
            } else {
                // 防抖到期：确认是真 compact，执行切换
                // [黑边修复 v2] 原子切换：隐藏展开玻璃 + 显示 pill 玻璃在
                // 同一 CATransaction，避免 1 帧空隙闪烁。
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if (sLGDIExpGlass && !sLGDIExpGlass.hidden) sLGDIExpGlass.hidden = YES;
                if (sLGDIExpBlur && !sLGDIExpBlur.hidden) sLGDIExpBlur.hidden = YES;
                if (sLGDIPillHiddenForExpanded && sLGDIGlass) {
                    sLGDIGlass.hidden = NO;
                    sLGDIPillHiddenForExpanded = NO;
                }
                [CATransaction commit];
            }
        }
    }

    CGRect targetFrame;
    CGFloat targetRadius;

    {
        CALayer *pl = usePresentation ? curtain.layer.presentationLayer : nil;
        if (pl) {
            // presentationLayer.frame 位于 curtain.superview 的坐标系。
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
    // [设计修复] 同步中心遮罩层 frame：覆盖药丸中心区域，
    // 仅左右两端（各占 height/2 宽度）显示液态效果。
    // 中心遮罩 frame = (endWidth, 0, centerWidth, height)
    if (sLGDICenterCover) {
        CGFloat pillH = targetFrame.size.height;
        CGFloat endW = pillH / 2.0;
        CGFloat centerW = targetFrame.size.width - 2.0 * endW;
        if (centerW > 1.0) {
            CGRect coverFrame = CGRectMake(endW, 0, centerW, pillH);
            if (!CGRectEqualToRect(sLGDICenterCover.frame, coverFrame)) {
                sLGDICenterCover.frame = coverFrame;
            }
            sLGDICenterCover.hidden = NO;
            // 中心区域是直边矩形，不需要圆角——药丸圆角在左右两端，
            // 中心遮罩从 endW=pillH/2 开始，已在圆弧之后。
        } else {
            // 药丸太窄（接近正方形）时无需中心遮罩
            sLGDICenterCover.hidden = YES;
        }
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
// [闪烁修复] 几何稳定后的缓冲帧数：继续跟帧同步几何但不再断言装饰，
// 等待系统残余动画彻底到位后再停 driver，避免稳定判定后动画尾部导致反复启停。
static const NSUInteger kLGDISteadySettleFrames = 15;  // ~250ms 缓冲
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
        // 先逐帧同步几何（内部按状态决定 pill 玻璃还是展开玻璃在管）
        LGDISyncGeometryFromPresentation(YES);

        // 几何稳定判定。[独立 DisplayLink] 展开态时展开玻璃由独立 driver 管理，
        // compact driver 只用 curtain 的 presentationLayer 判稳。展开 driver
        // 有自己的判稳逻辑（sLGDIExpSteadyFrameCount + sLGDIExpLastPresentationFrame）。
        CALayer *present;
        CGRect f;
        if (sLGDIExpGlass && sLGDIExpDriverActive) {
            // 展开独立 driver 在管：compact driver 用 curtain 判稳
            present = curtain.layer.presentationLayer;
            f = present ? present.frame : curtain.frame;
        } else if (sLGDIExpGlass) {
            // 展开玻璃存在但独立 driver 未激活（过渡期）：用展开玻璃判稳
            present = sLGDIExpGlass.layer.presentationLayer;
            f = present ? present.frame : sLGDIExpGlass.frame;
        } else {
            present = curtain.layer.presentationLayer;
            f = present ? present.frame : curtain.frame;
        }
        BOOL stable = CGRectEqualToRect(f, CGRectNull) ? NO :
            (fabs(f.origin.x - sLGDILastPresentationFrame.origin.x) < kLGDISteadyDelta
             && fabs(f.origin.y - sLGDILastPresentationFrame.origin.y) < kLGDISteadyDelta
             && fabs(f.size.width  - sLGDILastPresentationFrame.size.width)  < kLGDISteadyDelta
             && fabs(f.size.height - sLGDILastPresentationFrame.size.height) < kLGDISteadyDelta);
        sLGDILastPresentationFrame = f;
        sLGDISteadyFrameCount = stable ? sLGDISteadyFrameCount + 1 : 0;

        // [闪烁修复] 形变期间系统可能反复把幕布/装饰放回来，每帧重新断言。
        // 几何稳定后（sLGDISteadyFrameCount > 0 表示已进入稳定态）停止逐帧断言，
        // 避免与系统隐式动画/事务冲突造成边框闪烁。
        if (sLGDISteadyFrameCount == 0) {
            if (LGDIHideCurtain() && !curtain.hidden) curtain.hidden = YES;
            UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
            if (LGDRemoveGainMap() && gain && !gain.hidden) gain.hidden = YES;
            LGDIReassertSuppressed();
        }

        // [声波修复] 稳态后仍定期全扫一次，捕获 layoutSubviews 后晚加载
        // 的内容视图（声波/波形/频谱等），0.5s 一次，O(被压制数量) 级
        static CFTimeInterval sLGDILastPeriodicSweep = 0;
        CFTimeInterval sweepNow = CACurrentMediaTime();
        if (sweepNow - sLGDILastPeriodicSweep > 0.5) {
            sLGDILastPeriodicSweep = sweepNow;
            UIView *sweepHost = sLGDIHost;
            if (sweepHost && LGDILiquidSuppressionActive()) {
                LGDISuppressDecorations(sweepHost);
            }
        }

        CFTimeInterval now = CACurrentMediaTime();
        if (sLGDISteadyFrameCount >= kLGDISteadyFrameThreshold + kLGDISteadySettleFrames
            && now >= sLGDIMinDriverEnd) {
            LGDISyncGeometryFromPresentation(NO);
            [[DIPillStateMachine shared] setInteractiveExpanding:NO];
            LGDIStopDriver();
            // 弹簧动画到位、实时活动布局完全稳定后，触发一次软刷新：
            // 此时窗外实时画面已就绪，setNeedsDisplay 让 render server 重新采样。
            // [黑边修复 v4] lgForceRefreshBackdrop 已改为软刷新，不销毁捕获组。
            // 延迟 0.15s：如果弹跳触发新动画 → StartDriver → 滤镜锁定
            // → 延迟回调自动重试（lgFilterTypeLocked → 推迟）。
            static CFTimeInterval sLGDILastForceRefresh = 0;
            if (sLGDIGlass && now - sLGDILastForceRefresh > 0.4) {
                sLGDILastForceRefresh = now;
                LGDIDelayedRefreshBackdrop(sLGDIGlass, 0.15);
            }
            if (sLGDIExpGlass) LGDIDelayedRefreshBackdrop(sLGDIExpGlass, 0.15);
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
    // [闪烁根因修复] 弹簧动画期间锁定滤镜类型：动态半径步进（.r0~.r16）
    // 随尺寸变化反复跨步 → layer.filters 数组替换 → render server 短暂无滤镜 =
    // 灰/黑闪烁 2-3 次。锁定后 applyFilters 仍每帧调用（更新 scale 等），
    // 但跳过 layer.filters 数组替换，避免闪烁。
    // [独立 DisplayLink] compact driver 只锁定 pill 玻璃。
    // 展开玻璃由独立 driver (LGDIStartExpandedDriver) 自行锁定/解锁。
    if (sLGDIGlass) [sLGDIGlass lgLockFilterType];
}

static void LGDIStopDriver(void) {
    sLGDILink.paused = YES;
    // [黑边修复 v4] 延迟 0.15s 解锁滤镜类型：弹簧弹跳会在 driver 停机后
    // 1-2 帧内触发新动画（振荡），立即解锁 → applyFilters → 滤镜数组替换
    // → 黑边闪。延迟 0.15s 解锁，期间新动画到达会重新 StartDriver 并再次
    // 锁定，解锁回调到达时如果仍在动画中则跳过。
    // lgUnlockFilterType 内部设置 0.5s 稳定期，解锁后系统残余布局更新
    // 不会触发滤镜类型替换（步进跨步导致黑边闪烁的根因已消除）。
    // [独立 DisplayLink] compact driver 只解锁 pill 玻璃。
    // 展开玻璃由独立 driver (LGDIStopExpandedDriver) 自行解锁。
    LGLiveBackdropView *glass = sLGDIGlass;
    NSUInteger gen = sLGDITeardownGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 如果在此期间 driver 被重新启动（新动画），跳过解锁
        if (!sLGDILink.paused) return;
        // 如果期间发生了 teardown，glass 已被释放
        if (gen != sLGDITeardownGeneration) return;
        if (glass) [glass lgUnlockFilterType];
    });
}

// =============================================================================
//  [独立 DisplayLink] 展开态专用 driver
//  对齐 Mango 的 MangoExpandedGlassLinkProxy：展开玻璃有独立的 CADisplayLink，
//  与 compact pill driver 完全隔离。compact driver 只更新 pill 玻璃几何，
//  expanded driver 只更新展开玻璃几何。两者不再共用同一个 tick 函数，
//  避免展开态下 compact pill 的 applyFilters 被不必要地触发 → 闪烁。
// =============================================================================

@interface LGDIExpDisplayLinkTarget : NSObject
@end
@implementation LGDIExpDisplayLinkTarget
- (void)tick:(CADisplayLink *)link { LGDIExpandedDriverTick(link); }
@end

static LGDIExpDisplayLinkTarget *sLGDIExpLinkTarget;

static void LGDIStartExpandedDriver(NSTimeInterval duration) {
    if (!sLGDIExpLinkTarget) sLGDIExpLinkTarget = [LGDIExpDisplayLinkTarget new];
    if (!sLGDIExpLink) {
        sLGDIExpLink = [CADisplayLink displayLinkWithTarget:sLGDIExpLinkTarget
                                                   selector:@selector(tick:)];
        [sLGDIExpLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    sLGDIExpLink.paused = NO;
    CFTimeInterval now = CACurrentMediaTime();
    sLGDIExpLinkDeadline = now + duration;
    sLGDIExpMinDriverEnd = now + duration * 0.6;
    sLGDIExpSteadyFrameCount = 0;
    sLGDIExpLastPresentationFrame = CGRectNull;
    sLGDIExpDriverActive = YES;
    // 展开玻璃滤镜锁定：防止展开动画期间步进跨步替换 filter 数组
    if (sLGDIExpGlass) [sLGDIExpGlass lgLockFilterType];
}

static void LGDIStopExpandedDriver(void) {
    sLGDIExpLink.paused = YES;
    sLGDIExpDriverActive = NO;
    // 延迟解锁（同 compact driver 策略）
    LGLiveBackdropView *expGlass = sLGDIExpGlass;
    NSUInteger gen = sLGDITeardownGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sLGDIExpDriverActive) return;  // 期间被重新启动
        if (gen != sLGDITeardownGeneration) return;  // 期间 teardown
        if (expGlass) [expGlass lgUnlockFilterType];
    });
}

static void LGDIExpandedDriverTick(CADisplayLink *link) {
    (void)link;
    @autoreleasepool {
        if (!sLGDIActive || !sLGDIExpGlass) {
            LGDIStopExpandedDriver();
            return;
        }

        // 只同步展开玻璃几何，完全不碰 compact pill
        LGDISyncExpandedGeometry();

        // 几何稳定判定（使用展开玻璃 presentationLayer）
        CALayer *present = sLGDIExpGlass.layer.presentationLayer;
        CGRect f = present ? present.frame : sLGDIExpGlass.frame;
        BOOL stable = CGRectEqualToRect(f, CGRectNull) ? NO :
            (fabs(f.origin.x - sLGDIExpLastPresentationFrame.origin.x) < kLGDISteadyDelta
             && fabs(f.origin.y - sLGDIExpLastPresentationFrame.origin.y) < kLGDISteadyDelta
             && fabs(f.size.width  - sLGDIExpLastPresentationFrame.size.width)  < kLGDISteadyDelta
             && fabs(f.size.height - sLGDIExpLastPresentationFrame.size.height) < kLGDISteadyDelta);
        sLGDIExpLastPresentationFrame = f;
        sLGDIExpSteadyFrameCount = stable ? sLGDIExpSteadyFrameCount + 1 : 0;

        CFTimeInterval now = CACurrentMediaTime();
        if (sLGDIExpSteadyFrameCount >= kLGDISteadyFrameThreshold + kLGDISteadySettleFrames
            && now >= sLGDIExpMinDriverEnd) {
            LGDIStopExpandedDriver();
            // 稳定后软刷新
            if (sLGDIExpGlass) LGDIDelayedRefreshBackdrop(sLGDIExpGlass, 0.15);
            return;
        }

        // 硬性兜底
        if (now >= sLGDIExpLinkDeadline) {
            LGDIStopExpandedDriver();
            return;
        }
    }
}

#pragma mark - Forward declarations

static void LGDIScheduleSync(NSTimeInterval driverDuration);
static void LGDIReconcile(void);
static BOOL LGDICurtainReady(UIView *curtain);

// =============================================================================
//  [路线B] 壁纸跨进程捕获 — SpringBoard 端
//
//  CABackdropLayer 在 SBSystemApertureWindow 中无法跨窗口采样壁纸。
//  这里在 SpringBoard 中创建一个 IOSurface，定期捕获灵动岛区域
//  下方壁纸内容，写入 IOSurface。backboardd 通过 IOSurfaceID 创建
//  MTLTexture，在 shader 中作为 fallback 折射源。
//
//  捕获策略：通过 renderInContext: 渲染壁纸窗口的 layer 到 IOSurface
//  的像素内存。灵动岛区域很小（~160x64pt），CPU 渲染开销可接受。
// =============================================================================

static IOSurfaceRef sLGDIWallpaperSurface = NULL;
static uint32_t     sLGDIWallpaperSurfaceID = 0;
static NSUInteger   sLGDIWallpaperW = 0;
static NSUInteger   sLGDIWallpaperH = 0;
static dispatch_source_t sLGDIWallpaperTimer = nil;

// 壁纸 surface 元数据文件路径（跨进程通信：文件 I/O + Darwin 通知）
static NSString *LGDIWallpaperPrefsPath(void) {
    NSString *standard = @LG_DI_WALLPAPER_PREFS_PATH;
    if ([[NSFileManager defaultManager] fileExistsAtPath:standard]) return standard;
    NSString *jb = jbroot(@LG_DI_WALLPAPER_PREFS_PATH);
    return jb ?: standard;
}

// 将 surface ID / 宽 / 高写入 plist 文件并广播 Darwin 通知
static void LGDIWriteWallpaperSurfaceInfo(uint32_t surfaceID, NSUInteger w, NSUInteger h) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (surfaceID) {
        info[LG_DI_WALLPAPER_SURFACE_ID_KEY]    = @(surfaceID);
        info[LG_DI_WALLPAPER_SURFACE_WIDTH_KEY]  = @(w);
        info[LG_DI_WALLPAPER_SURFACE_HEIGHT_KEY] = @(h);
    }
    [info writeToFile:LGDIWallpaperPrefsPath() atomically:YES];
    notify_post(LG_DI_WALLPAPER_CAPTURE_READY_NOTIFY);
}

// 获取壁纸窗口（优先 SBWallpaperWindow，其次 SBHomeScreenWindow）
static UIWindow *LGDIFindWallpaperWindow(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSString *cls = NSStringFromClass(w.class);
        if ([cls containsString:@"Wallpaper"] || [cls containsString:@"HomeScreen"]) {
            return w;
        }
    }
    return nil;
}

void LGDIEnsureWallpaperSurface(CGSize size) {
    NSUInteger w = (NSUInteger)ceil(size.width);
    NSUInteger h = (NSUInteger)ceil(size.height);
    if (w < 2 || h < 2) return;

    if (sLGDIWallpaperSurface && w == sLGDIWallpaperW && h == sLGDIWallpaperH) return;

    // [R1 修复] 重建前先写入 surfaceID=0 暂停标记，通知 backboardd
    // 停止采样旧 surface。避免重建期间 backboardd 仍读取旧 surface →
    // 尺寸不匹配或读取已释放内存。
    if (sLGDIWallpaperSurface) {
        LGDIWriteWallpaperSurfaceInfo(0, 0, 0);
        CFRelease(sLGDIWallpaperSurface);
        sLGDIWallpaperSurface = NULL;
        sLGDIWallpaperSurfaceID = 0;
    }

    NSDictionary *options = @{
        (__bridge id)kIOSurfaceWidth: @(w),
        (__bridge id)kIOSurfaceHeight: @(h),
        (__bridge id)kIOSurfacePixelFormat: @(LG_IOSURFACE_PF_BGRA8),
        (__bridge id)kIOSurfaceBytesPerElement: @(4),
        // 不用已废弃的 kIOSurfaceIsGlobal 常量（-Werror 会命中），直接用原始键名
        (__bridge id)CFSTR("IOSurfaceIsGlobal"): @YES,
    };
    sLGDIWallpaperSurface = IOSurfaceCreate((CFDictionaryRef)options);
    if (!sLGDIWallpaperSurface) {
        LGDILog(@"[路线B] IOSurfaceCreate failed");
        return;
    }
    sLGDIWallpaperSurfaceID = IOSurfaceGetID(sLGDIWallpaperSurface);
    sLGDIWallpaperW = w;
    sLGDIWallpaperH = h;

    // 写入 plist 文件供 backboardd 读取（文件 I/O + Darwin 通知）
    LGDIWriteWallpaperSurfaceInfo(sLGDIWallpaperSurfaceID, w, h);

    LGDILog(@"[路线B] wallpaper surface created ID=%u dims=%lux%lu",
            sLGDIWallpaperSurfaceID, (unsigned long)w, (unsigned long)h);
}

void LGDICaptureWallpaperIntoSurface(CGRect screenRect) {
    if (!sLGDIWallpaperSurface || !sLGDIWallpaperSurfaceID) return;
    screenRect = CGRectIntegral(screenRect);
    if (screenRect.size.width < 2 || screenRect.size.height < 2) return;

    // 确保尺寸匹配（含 scale）
    CGFloat scale = UIScreen.mainScreen.scale;
    NSUInteger needW = (NSUInteger)ceil(screenRect.size.width * scale);
    NSUInteger needH = (NSUInteger)ceil(screenRect.size.height * scale);
    if (needW != sLGDIWallpaperW || needH != sLGDIWallpaperH) {
        LGDIEnsureWallpaperSurface(CGSizeMake(needW, needH));
        if (!sLGDIWallpaperSurface) return;
    }

    UIWindow *wallpaperWin = LGDIFindWallpaperWindow();
    if (!wallpaperWin) {
        // 没有独立壁纸窗口时，尝试用主屏幕根视图
        wallpaperWin = UIApplication.sharedApplication.windows.firstObject;
        if (!wallpaperWin) return;
    }

    // 将壁纸窗口在灵动岛屏幕区域的内容渲染到 IOSurface
    IOSurfaceLock(sLGDIWallpaperSurface, 0, NULL);
    void *base = IOSurfaceGetBaseAddress(sLGDIWallpaperSurface);
    size_t stride = IOSurfaceGetBytesPerRow(sLGDIWallpaperSurface);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base,
        sLGDIWallpaperW, sLGDIWallpaperH, 8, stride, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        IOSurfaceUnlock(sLGDIWallpaperSurface, 0, NULL);
        return;
    }

    // 偏移到灵动岛在屏幕上的位置
    CGContextTranslateCTM(ctx,
        -screenRect.origin.x * scale,
        -screenRect.origin.y * scale);
    CGContextScaleCTM(ctx, scale, scale);

    // 渲染壁纸层到 IOSurface
    [wallpaperWin.layer renderInContext:ctx];

    CGContextRelease(ctx);
    IOSurfaceUnlock(sLGDIWallpaperSurface, 0, NULL);

    // 通知 backboardd 有新数据
    notify_post(LG_DI_WALLPAPER_CAPTURE_READY_NOTIFY);
}

void LGDITeardownWallpaperSurface(void) {
    if (sLGDIWallpaperTimer) {
        dispatch_source_cancel(sLGDIWallpaperTimer);
        sLGDIWallpaperTimer = nil;
    }
    // [L2 修复] 先写入 surfaceID=0 到 plist 并广播通知，让 backboardd
    // 停止读取当前 IOSurface，然后再销毁。避免 backboardd 在 surface
    // 已释放后仍尝试访问 → 读取垃圾数据或 render server 异常。
    LGDIWriteWallpaperSurfaceInfo(0, 0, 0);

    if (sLGDIWallpaperSurface) {
        // 延迟 50ms 销毁 IOSurface，给 backboardd 一个运行周期处理无效标记
        IOSurfaceRef surfaceToRelease = sLGDIWallpaperSurface;
        sLGDIWallpaperSurface = NULL;
        uint32_t oldID = sLGDIWallpaperSurfaceID;
        sLGDIWallpaperSurfaceID = 0;
        sLGDIWallpaperW = 0;
        sLGDIWallpaperH = 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CFRelease(surfaceToRelease);
            LGDILog(@"[路线B] wallpaper surface torn down + backboardd notified (old ID=%u)", oldID);
        });
    } else {
        sLGDIWallpaperSurfaceID = 0;
        sLGDIWallpaperW = 0;
        sLGDIWallpaperH = 0;
    }
}

// [阶段4] 壁纸 fallback 捕获区域：pill 帧与展开玻璃帧取并集，
// 保证展开卡片折射时 fallback 纹理覆盖整张卡片而不只是 compact 药丸。
static CGRect LGDICaptureScreenRect(UIView *curtain) {
    CGRect rect = [curtain convertRect:curtain.bounds toView:nil];
    LGLiveBackdropView *expGlass = sLGDIExpGlass;
    if (expGlass && !expGlass.hidden && expGlass.window) {
        rect = CGRectUnion(rect, [expGlass convertRect:expGlass.bounds toView:nil]);
    }
    return CGRectIntegral(rect);
}

// 启动定时壁纸捕获（热状态自适应间隔）
static void LGDIStartWallpaperCapture(void) {
    if (sLGDIWallpaperTimer) return;

    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (!curtain) return;

    // 立即捕获一次（[阶段4] 区域含展开玻璃帧并集）
    CGRect screenRect = LGDICaptureScreenRect(curtain);
    CGFloat scale = UIScreen.mainScreen.scale;
    LGDIEnsureWallpaperSurface(CGSizeMake(
        screenRect.size.width * scale, screenRect.size.height * scale));
    LGDICaptureWallpaperIntoSurface(screenRect);

    // 定时刷新：热状态越高间隔越长，降低 CPU 占用
    // Nominal/Fair → 2s, Serious → 5s, Critical → 10s, 充电+热 → 额外 ×1.5
    sLGDIWallpaperTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                  dispatch_get_main_queue());
    // 初始 2s，每次回调动态计算下一次间隔
    dispatch_source_set_timer(sLGDIWallpaperTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC),
                              2.0 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    __weak UIView *weakCurtain = curtain;
    dispatch_source_set_event_handler(sLGDIWallpaperTimer, ^{
        UIView *c = weakCurtain ?: sLGDICurtain;
        if (!c || !sLGDIActive) {
            return;
        }

        // 热状态自适应：动态调整定时器间隔
        NSUInteger thermal = [NSProcessInfo processInfo].thermalState;
        NSTimeInterval interval;
        switch (thermal) {
            case 3:  interval = 5.0;  break;  // Serious
            case 4:  interval = 10.0; break;  // Critical
            default: interval = 2.0;  break;  // Nominal/Fair
        }
        // 充电 + 热状态 ≥ Fair 时进一步放慢
        if (LGLiquidIsCharging() && thermal >= 2) {
            interval *= 1.5;
        }
        static NSTimeInterval sLastAppliedInterval = 0;
        if (sLastAppliedInterval != interval) {
            sLastAppliedInterval = interval;
            dispatch_source_set_timer(sLGDIWallpaperTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                (uint64_t)(interval * NSEC_PER_SEC), 0.5 * NSEC_PER_SEC);
        }

        // Critical 热状态时跳过本帧捕获，减少 CPU 负载
        if (thermal >= 4 && LGLiquidShouldSkipRenderFrame()) {
            return;
        }

        CGRect sr = LGDICaptureScreenRect(c);
        LGDICaptureWallpaperIntoSurface(sr);
    });
    dispatch_resume(sLGDIWallpaperTimer);
}

// =============================================================================
//  阶段 3.2/3.3/3.4 探针 v2（仅 LIQUIDASS_DEBUG）
//  开关 DynamicIsland.EmptyCaptureDebug 运行时启用，关闭即完全还原。
// -----------------------------------------------------------------------------
//  6 相自动轮换（每相 3 秒），岛下方有蓝底白字相号角标 P0..P5，
//  对相号拍照即可，无需数秒：
//    P0 baseline      全部原样（含我们 curtain 窗口里的主玻璃）
//    P1 our-glass-off 临时隐藏我们的主玻璃 → 判定灰闪/黑丸/细边框是否我方造成
//    P2 hide-bgcard   隐藏内容窗口系统胶囊底栈(luma 卡片) → 两侧黑方块归属
//    P3 hide-curtain  隐藏内容窗口 curtain + gainMap
//    P4 win31-glass   内容窗口插测试玻璃(亮绿描边标出真实 frame) → 液态 or 黑
//    P5 glass+hidebg  测试玻璃 + 隐藏底栈（最终方案预览）
//    M0..Mn           挂载窗口探测：同一块玻璃每 3 秒换一个全屏窗口
//                     （含 3 个自建窗口 normal/statusBar/alert+1200），
//                     角标 M序号/总数 + 窗口类名/层级；框内呈液态即代表
//                     该合成域可作为正式挂载点，黑/透明则为隔离域。
//
//  另有一次性结构 dump：compact 态 wrapper 三层子树（找附件黑底归属层）、
//  全部 AccessoryPortalView 及其 ivar（沿父类链）。
// =============================================================================
#if LIQUIDASS_DEBUG

static NSTimer    *sLGDIProbeTimer;
static LGLiveBackdropView *sLGDIProbeGlass;
static UILabel    *sLGDIProbeBadge;
static NSInteger   sLGDIProbePhase = -1;
static CFTimeInterval sLGDIProbePhaseAt = 0;
static NSInteger   sLGDIProbeTickCount = 0;
static NSString   *sLGDIProbeIvarIdentity;
static NSString   *sLGDIProbeTreeIdentity;
static NSMutableDictionary<NSValue *, NSNumber *> *sLGDIProbeHiddenOrig;
// M 相（挂载窗口探测）状态，前置声明供 LGDIProbeFullReset 使用
static NSMutableArray<UIWindow *> *sLGDIProbeOwnWindows;
static NSArray<UIWindow *> *sLGDIProbeMountCandidates;
static NSString   *sLGDIProbeMountSig;
static NSValue    *sLGDIProbeMountHostKey;

static const NSTimeInterval kLGDIProbePhaseSecs = 3.0;

static BOOL LGDIProbeEnabled(void) {
    return LGDIReadBool(@"DynamicIsland.EmptyCaptureDebug", NO);
}

// 深度受限的类名查找（精确 / 包含）
static UIView *LGDIProbeFindView(UIView *root, BOOL (^match)(NSString *),
                                 NSUInteger maxDepth) {
    if (!root || maxDepth > 18) maxDepth = 18;
    __block UIView *hit = nil;
    __block __weak void (^weakWalk)(UIView *, NSUInteger);
    void (^walk)(UIView *, NSUInteger) = ^(UIView *v, NSUInteger d) {
        if (hit || !v || d > maxDepth) return;
        if (match(NSStringFromClass(v.class))) { hit = v; return; }
        for (UIView *s in v.subviews) weakWalk(s, d + 1);
    };
    weakWalk = walk;
    walk(root, 0);
    return hit;
}

// 深度受限的类名收集（全部匹配）
static NSArray<UIView *> *LGDIProbeFindViews(UIView *root,
                                             BOOL (^match)(NSString *),
                                             NSUInteger maxDepth) {
    if (!root || maxDepth > 18) maxDepth = 18;
    NSMutableArray *hits = [NSMutableArray array];
    __block __weak void (^weakWalk)(UIView *, NSUInteger);
    void (^walk)(UIView *, NSUInteger) = ^(UIView *v, NSUInteger d) {
        if (!v || d > maxDepth) return;
        if (match(NSStringFromClass(v.class))) [hits addObject:v];
        for (UIView *s in v.subviews) weakWalk(s, d + 1);
    };
    weakWalk = walk;
    walk(root, 0);
    return hits;
}

// 找到承载内容的 SBSystemApertureWindow（SystemAperture scene，
// 不是 curtain 窗口），及其内部的内容容器。
static UIWindow *LGDIProbeFindContentWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (![NSStringFromClass(w.class)
                    isEqualToString:@"SBSystemApertureWindow"]) continue;
            if (w == sLGDIHost.window) continue;  // curtain 窗口
            UIView *c = LGDIProbeFindView(w, ^BOOL(NSString *cn) {
                return [cn isEqualToString:@"SBSystemApertureContainerView"];
            }, 14);
            if (c) return w;
        }
    }
    return nil;
}

// container(tree3) -> PT(tree2) -> depth1 wrapper(tree1)
static UIView *LGDIProbeDepth1Wrapper(UIView *container) {
    UIView *p2 = container.superview;
    UIView *p1 = p2.superview;
    if (!p1) return nil;
    if (![NSStringFromClass(p1.class) isEqualToString:@"SBFTouchPassThroughView"]) {
        p1 = p1.superview;
    }
    return p1;
}

// ---- 一次性结构 dump：compact 态 wrapper 三层子树 --------------------------
static void LGDIProbeDumpTreeOnce(UIView *wrapper, UIView *container) {
    BOOL compact = container.bounds.size.width < 250.0;
    NSString *ident = [NSString stringWithFormat:@"%p/%@/w%@/%d",
                       wrapper, NSStringFromClass(wrapper.class),
                       NSStringFromCGSize(wrapper.bounds.size), compact];
    if ([ident isEqualToString:sLGDIProbeTreeIdentity]) return;
    sLGDIProbeTreeIdentity = ident;

    LGDILog(@"----- [probe-tree] identity=%@ compact=%d -----", ident, compact);
    __block __weak void (^weakWalk)(UIView *, NSUInteger, UIView *);
    void (^walk)(UIView *, NSUInteger, UIView *) =
        ^(UIView *v, NSUInteger d, UIView *win) {
        if (!v || d > 3) return;
        CGRect fw = [v convertRect:v.bounds toView:win];
        UIColor *bg = v.backgroundColor;
        CGFloat br = 0, bg2 = 0, bb = 0, ba = 0;
        [bg getRed:&br green:&bg2 blue:&bb alpha:&ba];
        NSMutableString *pad = [NSMutableString string];
        for (NSUInteger i = 0; i < d; i++) [pad appendString:@"  "];
        LGDILog(@"[probe-tree]%@%@ frameInWin=%@ hidden=%d alpha=%.2f "
                @"clip=%d corner=%.1f bg=(%.2f,%.2f,%.2f,%.2f) subs=%lu",
                pad, NSStringFromClass(v.class),
                NSStringFromCGRect(fw), (int)v.hidden, v.alpha,
                (int)v.clipsToBounds, v.layer.cornerRadius,
                br, bg2, bb, ba, (unsigned long)v.subviews.count);
        for (UIView *s in v.subviews) weakWalk(s, d + 1, win);
    };
    weakWalk = walk;
    walk(wrapper, 0, wrapper.window);
    LGDILog(@"----- [probe-tree] end -----");
}

// ---- 一次性 ivar dump：全部 PortalView，view/layer 均沿父类链 --------------
static void LGDIProbeDumpIvarsOnce(UIView *win5, UIView *container,
                                   UIView *bgCard) {
    (void)win5;
    NSString *ident = [NSString stringWithFormat:@"%p/%@/%@",
                       container, NSStringFromClass(container.class),
                       NSStringFromCGSize(container.bounds.size)];
    if ([ident isEqualToString:sLGDIProbeIvarIdentity]) return;
    sLGDIProbeIvarIdentity = ident;

    LGDILog(@"----- [probe-ivar] identity=%@ -----", ident);
    LGDILog(@"[probe-ivar] container=%@ bgCard=%@ r=%.2f containerR=%.2f",
            NSStringFromCGRect(container.frame),
            NSStringFromClass(bgCard.class), bgCard.layer.cornerRadius,
            container.layer.cornerRadius);

    NSArray<UIView *> *portals = LGDIProbeFindViews(container, ^BOOL(NSString *cn) {
        return [cn containsString:@"PortalView"];
    }, 12);
    LGDILog(@"[probe-ivar] portal count=%lu", (unsigned long)portals.count);

    [portals enumerateObjectsUsingBlock:^(UIView *portal, NSUInteger pi, BOOL *stop) {
        LGDILog(@"[probe-ivar] portal#%lu class=%@ frame=%@ clips=%d",
                (unsigned long)pi, NSStringFromClass(portal.class),
                NSStringFromCGRect(portal.frame), (int)portal.clipsToBounds);

        // view 侧 ivar：沿父类链走到 UIView
        Class vc = portal.class;
        while (vc && vc != NSObject.class) {
            unsigned int n = 0;
            Ivar *ivars = class_copyIvarList(vc, &n);
            if (n > 0)
                LGDILog(@"[probe-ivar]   viewClass=%@ ivarCount=%u",
                        NSStringFromClass(vc), n);
            for (unsigned int i = 0; i < n; i++) {
                const char *iname = ivar_getName(ivars[i]);
                const char *itype = ivar_getTypeEncoding(ivars[i]);
                LGDILog(@"[probe-ivar]     %s type=%s", iname, itype ?: "?");
                if (itype && itype[0] == '@') {
                    id val = object_getIvar(portal, ivars[i]);
                    if (val) {
                        NSString *desc = [[val description] substringToIndex:
                            MIN((NSUInteger)120, [val description].length)];
                        if ([val isKindOfClass:UIView.class]) {
                            UIView *vv = (UIView *)val;
                            LGDILog(@"[probe-ivar]       view=%@ frame=%@ win=%@",
                                    desc, NSStringFromCGRect(vv.frame),
                                    NSStringFromClass(vv.window.class));
                        } else if ([val isKindOfClass:CALayer.class]) {
                            CALayer *ll = (CALayer *)val;
                            LGDILog(@"[probe-ivar]       layer=%@ frame=%@ hidden=%d",
                                    desc, NSStringFromCGRect(ll.frame),
                                    (int)ll.hidden);
                        } else {
                            LGDILog(@"[probe-ivar]       value=%@", desc);
                        }
                    }
                }
            }
            free(ivars);
            if (vc == UIView.class) break;
            vc = class_getSuperclass(vc);
        }

        // layer 侧 ivar：沿父类链走到 CALayer
        CALayer *layer = portal.layer;
        Class lc = layer.class;
        while (lc && lc != NSObject.class) {
            unsigned int ln = 0;
            Ivar *livars = class_copyIvarList(lc, &ln);
            if (ln > 0)
                LGDILog(@"[probe-ivar]   layerClass=%@ ivarCount=%u",
                        NSStringFromClass(lc), ln);
            for (unsigned int i = 0; i < ln; i++) {
                const char *iname = ivar_getName(livars[i]);
                const char *itype = ivar_getTypeEncoding(livars[i]);
                LGDILog(@"[probe-ivar]     %s type=%s", iname, itype ?: "?");
                if (itype && itype[0] == '@') {
                    id val = object_getIvar(layer, livars[i]);
                    if (val) {
                        LGDILog(@"[probe-ivar]       value=%@",
                                [[val description] substringToIndex:
                                    MIN((NSUInteger)120, [val description].length)]);
                    }
                }
            }
            free(livars);
            if (lc == CALayer.class) break;
            lc = class_getSuperclass(lc);
        }
    }];
    LGDILog(@"----- [probe-ivar] end -----");
}

// ---- hidden 记账（恢复用）--------------------------------------------------
static void LGDIProbeSetHidden(UIView *v, BOOL hidden) {
    if (!v) return;
    NSValue *key = [NSValue valueWithNonretainedObject:v];
    if (!sLGDIProbeHiddenOrig) sLGDIProbeHiddenOrig = [NSMutableDictionary dictionary];
    if (!sLGDIProbeHiddenOrig[key]) sLGDIProbeHiddenOrig[key] = @(v.hidden);
    if (v.hidden != hidden) v.hidden = hidden;
}

static void LGDIProbeRestoreHides(void) {
    [sLGDIProbeHiddenOrig enumerateKeysAndObjectsUsingBlock:^(NSValue *key,
            NSNumber *orig, BOOL *stop) {
        UIView *v = key.nonretainedObjectValue;
        if (v && v.hidden != orig.boolValue) v.hidden = orig.boolValue;
    }];
    [sLGDIProbeHiddenOrig removeAllObjects];
    // 主玻璃恢复可见（P1 只是临时隐藏）
    if (sLGDIGlass) sLGDIGlass.hidden = NO;
}

// ---- 相号角标（普通 UIView，不经过 shader，保证可见）-----------------------
static UILabel *LGDIProbeEnsureBadge(UIView *wrapper) {
    if (!sLGDIProbeBadge) {
        UILabel *b = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 118, 24)];
        b.backgroundColor = [UIColor colorWithRed:0.05 green:0.35 blue:0.95 alpha:0.85];
        b.textColor = UIColor.whiteColor;
        b.font = [UIFont boldSystemFontOfSize:13];
        b.textAlignment = NSTextAlignmentCenter;
        b.layer.cornerRadius = 12;
        b.layer.masksToBounds = YES;
        b.userInteractionEnabled = NO;
        sLGDIProbeBadge = b;
    }
    // M 相需要在不同窗口间重挂
    if (sLGDIProbeBadge.superview != wrapper) {
        [sLGDIProbeBadge removeFromSuperview];
        [wrapper addSubview:sLGDIProbeBadge];
    }
    return sLGDIProbeBadge;
}

static void LGDIProbeUpdateBadge(UIView *wrapper, UIView *container,
                                 NSInteger phase) {
    UILabel *b = LGDIProbeEnsureBadge(wrapper);
    static const char *names[] = {
        "P0 BASE", "P1 GLASS-OFF", "P2 HIDE-BG",
        "P3 HIDE-CURTAIN", "P4 TEST-GLASS", "P5 GLASS+NOBG"
    };
    b.text = [NSString stringWithUTF8String:names[phase % 6]];
    CGRect cf = [container convertRect:container.bounds toView:wrapper];
    CGFloat w = 132;
    b.frame = CGRectMake(CGRectGetMidX(cf) - w / 2.0,
                         CGRectGetMaxY(cf) + 8.0, w, 24);
    b.hidden = NO;
}

// ---- 相位应用（每 tick 重放，抵消正式代码/系统对状态的回写）----------------
static void LGDIProbeApplyPhase(NSInteger phase, UIView *wrapper,
                                UIView *bgCard) {
    LGDIProbeRestoreHides();
    LGDIWithoutImplicitAnimations(^{
        // P1：临时隐藏我们 curtain 窗口的主玻璃
        if (phase == 1 && sLGDIGlass) sLGDIGlass.hidden = YES;
        // P2 / P5：隐藏系统胶囊底栈
        if (phase == 2 || phase == 5) LGDIProbeSetHidden(bgCard, YES);
        // P3：隐藏内容窗口 curtain + gainMap
        if (phase == 3) {
            UIView *c2 = LGDIProbeFindView(wrapper, ^BOOL(NSString *cn) {
                return [cn isEqualToString:@"_SBSystemApertureMagiciansCurtainView"];
            }, 4);
            LGDIProbeSetHidden(c2, YES);
            UIView *gm = c2 ? LGDIFindSubviewOfClass(c2, @"_SBGainMapView") : nil;
            LGDIProbeSetHidden(gm, YES);
        }
    });
    LGDILog(@"[probe] PHASE=%ld active", (long)phase);
}

// ---- P4/P5：内容窗口测试玻璃（亮绿描边标出真实 frame）----------------------
static void LGDIProbeSyncGlass(UIView *container, UIView *contentSib,
                               UIView *bgCard, BOOL wanted) {
    UIView *wrapper = contentSib.superview;
    if (!wanted) {
        if (sLGDIProbeGlass) {
            [sLGDIProbeGlass removeFromSuperview];
            sLGDIProbeGlass = nil;
            LGDILog(@"[probe-glass] removed (this phase has no test glass)");
        }
        return;
    }
    CGRect f = [container convertRect:container.bounds toView:wrapper];
    if (!LGDIIsPlausibleSize(f.size)) return;

    if (!sLGDIProbeGlass) {
        sLGDIProbeGlass = LGCreateRegisteredGlass(f, kLGDIBackdropGroup,
                                                  kLGDIFilterPrefix);
        if (!sLGDIProbeGlass) {
            LGDILog(@"[probe-glass] create failed");
            return;
        }
        sLGDIProbeGlass.layer.cornerCurve   = kCACornerCurveContinuous;
        sLGDIProbeGlass.layer.masksToBounds = YES;
        // 亮绿描边：普通 CALayer 属性，不经过 backdrop shader，
        // 无论捕获结果如何都能看到玻璃的实际覆盖范围
        sLGDIProbeGlass.layer.borderWidth  = 1.5;
        sLGDIProbeGlass.layer.borderColor  =
            [UIColor colorWithRed:0.1 green:0.95 blue:0.2 alpha:0.95].CGColor;
        [wrapper insertSubview:sLGDIProbeGlass belowSubview:contentSib];
        LGDILog(@"[probe-glass] INSERTED frame=%@ —— 观察框内："
                @"液态实时模糊(成功) / 黑 / 透明空",
                NSStringFromCGRect(f));
        __weak LGLiveBackdropView *wg = sLGDIProbeGlass;
        for (NSNumber *d in @[ @0.2, @0.6, @1.2, @2.4 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [wg lgForceRefreshBackdrop];
            });
        }
    } else if (sLGDIProbeGlass.superview != wrapper) {
        [wrapper insertSubview:sLGDIProbeGlass belowSubview:contentSib];
    }
    if (!CGRectEqualToRect(sLGDIProbeGlass.frame, f)) sLGDIProbeGlass.frame = f;

    CGFloat r = bgCard.layer.cornerRadius;
    if (r <= 0.5) r = f.size.height / 2.0;
    if (fabs(sLGDIProbeGlass.layer.cornerRadius - r) > 0.25) {
        sLGDIProbeGlass.layer.cornerRadius = r;
    }
}

static void LGDIProbeFullReset(NSString *reason) {
    LGDIProbeRestoreHides();
    if (sLGDIProbeGlass) {
        [sLGDIProbeGlass removeFromSuperview];
        sLGDIProbeGlass = nil;
    }
    if (sLGDIProbeBadge) {
        [sLGDIProbeBadge removeFromSuperview];
        sLGDIProbeBadge = nil;
    }
    for (UIWindow *w in sLGDIProbeOwnWindows) w.hidden = YES;
    sLGDIProbeOwnWindows = nil;
    sLGDIProbeMountCandidates = nil;
    sLGDIProbeMountSig = nil;
    sLGDIProbeMountHostKey = nil;
    sLGDIProbePhase = -1;
    sLGDIProbeIvarIdentity = nil;
    sLGDIProbeTreeIdentity = nil;
    if (reason) LGDILog(@"[probe] reset — %@", reason);
}

// =============================================================================
//  挂载窗口探测（M 相，P0..P5 之后自动接 M0..Mn）
// -----------------------------------------------------------------------------
//  回答闸门问题：哪个合成域窗口里的 CABackdropLayer 能在灵动岛区域抓到
//  壁纸实时画面（液态），哪些和两个 SBSystemApertureWindow 一样只能抓到
//  空/同窗灰。同一块亮绿描边测试玻璃每 3 秒换一个候选窗口，角标显示
//  M序号/总数 + 窗口类名/层级，对号拍照即可。
//  M 相期间统一去污染：隐藏我方主玻璃、系统 luma 底卡、内容窗口
//  curtain/gainMap，保证亮绿框内只剩"该窗口玻璃自己的捕获结果"。
//  候选 = 所有全屏非灵动岛窗口（按 windowLevel 排序）+ 3 个自建窗口
//  （normal / statusBar / alert+1200，验证自建高层级窗口是否可行）。
// =============================================================================
static UIWindowScene *LGDIProbeMainScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

static UIWindow *LGDIProbeMakeOwnWindow(CGFloat level) {
    UIWindowScene *scene = LGDIProbeMainScene();
    if (!scene) return nil;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = UIScreen.mainScreen.bounds;
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [[UIViewController alloc] init];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    w.userInteractionEnabled = NO;
    w.hidden = NO;
    return w;
}

static NSString *LGDIProbeShortClassName(NSString *cn) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"SBSystemApertureWindow": @"ApertureWin",
            @"SBFTouchPassThroughWindow": @"TouchPassWin",
        };
    });
    NSString *m = map[cn];
    return m ?: cn;
}

// 候选窗口清单（窗口清单变化时重建；自建窗口持久复用）
static NSArray<UIWindow *> *LGDIProbeMountCandidatesList(void) {
    NSMutableString *sig = [NSMutableString string];
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    CGSize ss = UIScreen.mainScreen.bounds.size;
    // 先确保自建窗口存在：它们随后会被场景枚举自然收录（类名 UIWindow），
    // 无需手动追加，否则会重复成两个候选。
    if (!sLGDIProbeOwnWindows) {
        sLGDIProbeOwnWindows = [NSMutableArray array];
        for (NSNumber *lv in @[ @(UIWindowLevelNormal),
                               @(UIWindowLevelStatusBar),
                               @(UIWindowLevelAlert + 1200) ]) {
            UIWindow *w = LGDIProbeMakeOwnWindow(lv.doubleValue);
            if (w) [sLGDIProbeOwnWindows addObject:w];
        }
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSString *cn = NSStringFromClass(w.class);
            // 两个灵动岛窗口 P4/P5 已验证抓不到壁纸，排除出候选
            if ([cn isEqualToString:@"SBSystemApertureWindow"]) continue;
            if (w.hidden || w.alpha < 0.15) continue;
            if (w.bounds.size.width < ss.width * 0.9 ||
                w.bounds.size.height < ss.height * 0.9) continue;
            NSValue *k = [NSValue valueWithNonretainedObject:w];
            if ([seen containsObject:k]) continue;
            [seen addObject:k];
            [out addObject:w];
            [sig appendFormat:@"%p:%@:%.0f;", w, cn, w.windowLevel];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    if ([sig isEqualToString:sLGDIProbeMountSig] && sLGDIProbeMountCandidates)
        return sLGDIProbeMountCandidates;
    sLGDIProbeMountSig = sig;
    sLGDIProbeMountCandidates = out;
    LGDILog(@"[probe-mount] candidate inventory (%lu):", (unsigned long)out.count);
    [out enumerateObjectsUsingBlock:^(UIWindow *w, NSUInteger i, BOOL *stop) {
        (void)stop;
        LGDILog(@"[probe-mount]   M%lu host=%@ level=%.1f frame=%@ alpha=%.2f",
                (unsigned long)i, NSStringFromClass(w.class), w.windowLevel,
                NSStringFromCGRect(w.frame), w.alpha);
    }];
    return out;
}

static void LGDIProbeMountSync(UIWindow *host, CGRect screenFrame,
                               NSInteger idx, NSInteger total) {
    if (!host) return;
    CGRect f = [host convertRect:screenFrame fromWindow:nil];
    if (!LGDIIsPlausibleSize(f.size)) return;

    if (!sLGDIProbeGlass) {
        sLGDIProbeGlass = LGCreateRegisteredGlass(f, kLGDIBackdropGroup,
                                                  kLGDIFilterPrefix);
        if (!sLGDIProbeGlass) { LGDILog(@"[probe-mount] glass create failed"); return; }
        sLGDIProbeGlass.layer.cornerCurve   = kCACornerCurveContinuous;
        sLGDIProbeGlass.layer.masksToBounds = YES;
        sLGDIProbeGlass.layer.borderWidth  = 2.0;
        sLGDIProbeGlass.layer.borderColor  =
            [UIColor colorWithRed:0.1 green:0.95 blue:0.2 alpha:0.95].CGColor;
    }
    NSValue *hk = [NSValue valueWithNonretainedObject:host];
    if (sLGDIProbeGlass.superview != host) {
        [host addSubview:sLGDIProbeGlass];
        sLGDIProbeMountHostKey = hk;
        LGDILog(@"[probe-mount] M%ld/%ld host=%@ level=%.1f frame=%@ —— "
                @"框内液态(该窗口可用) / 黑 / 透明(隔离域)",
                (long)idx, (long)total, NSStringFromClass(host.class),
                host.windowLevel, NSStringFromCGRect(f));
        __weak LGLiveBackdropView *wg = sLGDIProbeGlass;
        [wg lgForceRefreshBackdrop];
        for (NSNumber *d in @[ @0.2, @0.6, @1.2, @2.2 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [wg lgForceRefreshBackdrop];
            });
        }
    } else if (![sLGDIProbeMountHostKey isEqual:hk]) {
        sLGDIProbeMountHostKey = hk;
    }
    if (!CGRectEqualToRect(sLGDIProbeGlass.frame, f)) sLGDIProbeGlass.frame = f;
    if (fabs(sLGDIProbeGlass.layer.cornerRadius - 43.7) > 0.25)
        sLGDIProbeGlass.layer.cornerRadius = 43.7;

    UILabel *b = LGDIProbeEnsureBadge(host);
    NSString *name = [sLGDIProbeOwnWindows containsObject:host]
        ? [NSString stringWithFormat:@"OWN L%.0f", host.windowLevel]
        : [NSString stringWithFormat:@"%@ L%.0f",
           LGDIProbeShortClassName(NSStringFromClass(host.class)), host.windowLevel];
    b.text = [NSString stringWithFormat:@"M%ld/%ld %@",
              (long)idx, (long)total, name];
    CGFloat w = MIN(260, name.length * 7.0 + 70);
    b.frame = CGRectMake(CGRectGetMidX(f) - w / 2.0,
                         CGRectGetMaxY(f) + 8.0, w, 24);
    b.hidden = NO;
}

// ---- prefs 链路诊断：不依赖开关，DEBUG 包常驻（DI 活动期限速打印）---------
// 目的：定位"设置里开了开关，但某进程读到的 plist 里没有该键"——
// 直接 stat 多个候选路径并绕缓存直读，比对 inode/大小/mtime/键数/原始值。
static NSString *sLGDIProbePrefsSig;

static void LGDIProbeLogFileAt(NSString *p) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    BOOL exists = [fm fileExistsAtPath:p isDirectory:&dir];
    if (!exists || dir) {
        LGDILog(@"[probe-prefs] %@ -> %@", p, exists ? @"DIR" : @"missing");
        return;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    id raw = d[@"DynamicIsland.EmptyCaptureDebug"];
    LGDILog(@"[probe-prefs] %@", p);
    LGDILog(@"[probe-prefs]   inode=%llu size=%lld mtime=%@ keys=%lu "
            @"EmptyCaptureDebug=%@(%@)",
            (unsigned long long)[attrs fileSystemFileNumber],
            (long long)[attrs fileSize],
            attrs.fileModificationDate,
            (unsigned long)d.count,
            raw ? NSStringFromClass([raw class]) : @"nil",
            raw ? [raw description] : @"-");
}

static void LGDIProbePrefsDiag(void) {
    NSMutableArray<NSString *> *cands = [NSMutableArray arrayWithObject:
        @"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist"];
    // roothide 容器实体路径（本进程被重定向时，直开字面路径会被改写，
    // 故再枚举 .jbroot-* 容器里的同名文件，用于和 backboardd 日志对照 inode）
    NSArray<NSString *> *jbRoots =
        [[NSFileManager.defaultManager contentsOfDirectoryAtPath:
            @"/var/containers/Bundle/Application" error:nil]
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSString *name, NSDictionary *bindings) {
            (void)bindings;
            return [name hasPrefix:@".jbroot"];
        }]];
    for (NSString *jr in jbRoots) {
        [cands addObject:[NSString stringWithFormat:
            @"/var/containers/Bundle/Application/%@/var/mobile/Library/"
            @"Preferences/dylv.liquidassprefs.plist", jr]];
    }
    // 签名变化（任一文件 inode/size/mtime/键值变化）才打印，避免刷屏
    NSMutableString *sig = [NSMutableString string];
    for (NSString *p in cands) {
        NSDictionary *a = [NSFileManager.defaultManager
            attributesOfItemAtPath:p error:nil];
        [sig appendFormat:@"%@|%llu|%lld|%@;", p,
            (unsigned long long)[a fileSystemFileNumber],
            (long long)[a fileSize], a.fileModificationDate];
    }
    id cached = LGGlassPreferenceValue(@"DynamicIsland.EmptyCaptureDebug");
    [sig appendFormat:@"cached=%@(%@)", cached ? NSStringFromClass([cached class]) : @"nil",
     cached ? [cached description] : @"-"];
    if ([sig isEqualToString:sLGDIProbePrefsSig]) return;
    sLGDIProbePrefsSig = sig;

    LGDILog(@"----- [probe-prefs] SpringBoard file view -----");
    for (NSString *p in cands) LGDIProbeLogFileAt(p);
    // Preferences 目录下所有 dylv.liquidass* 文件，排查域写错文件
    NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObject:
        @"/var/mobile/Library/Preferences"];
    for (NSString *jr in jbRoots) {
        [dirs addObject:[NSString stringWithFormat:
            @"/var/containers/Bundle/Application/%@/var/mobile/Library/Preferences", jr]];
    }
    for (NSString *d in dirs) {
        NSArray *items = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:d
                                                                             error:nil]
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSString *name, NSDictionary *bindings) {
            (void)bindings;
            return [name hasPrefix:@"dylv.liquidass"];
        }]];
        LGDILog(@"[probe-prefs] dir %@ -> %@", d,
                items.count ? [items componentsJoinedByString:@", "] : @"(none)");
    }
    LGDILog(@"[probe-prefs] cached LGGlassPreferenceValue=%@(%@)",
            cached ? NSStringFromClass([cached class]) : @"nil",
            cached ? [cached description] : @"-");
    LGDILog(@"----- [probe-prefs] end -----");
}

static void LGDIProbeTick(NSTimer *timer) {
    (void)timer;
    // prefs 链路诊断不依赖开关：DI 活动期限速运行
    if (sLGDIActive && LGDIFeatureEnabled() && (sLGDIProbeTickCount % 10) == 0) {
        LGDIProbePrefsDiag();
    }
    if (!sLGDIActive || !LGDIFeatureEnabled() || !LGDIProbeEnabled()) {
        if (sLGDIProbeGlass || sLGDIProbeBadge || sLGDIProbePhase >= 0) {
            LGDIProbeFullReset(@"switch OFF / DI inactive — all restored");
        }
        sLGDIProbeTickCount++;
        return;
    }

    UIWindow *win5 = LGDIProbeFindContentWindow();
    UIView *container = win5 ? LGDIProbeFindView(win5, ^BOOL(NSString *cn) {
        return [cn isEqualToString:@"SBSystemApertureContainerView"];
    }, 14) : nil;
    if (!win5 || !container) return;  // 过渡中，保持现状
    UIView *contentSib = container.superview;
    UIView *wrapper    = LGDIProbeDepth1Wrapper(container);
    if (!contentSib || !wrapper) return;

    UIView *luma = LGDIProbeFindView(wrapper, ^BOOL(NSString *cn) {
        return [cn isEqualToString:@"_UILumaTrackingBackdropView"];
    }, 5);
    UIView *bgCard = luma.superview ?: luma;

    LGDIProbeDumpTreeOnce(wrapper, container);
    LGDIProbeDumpIvarsOnce(win5, container, bgCard);

    // 相轮换（每相 3 秒）：P0..P5 内容窗口实验，随后 M0..Mn 挂载窗口探测
    NSArray<UIWindow *> *mounts = LGDIProbeMountCandidatesList();
    NSInteger mountCount = (NSInteger)mounts.count;
    NSInteger phaseCount = 6 + mountCount;
    CFTimeInterval now = CACurrentMediaTime();
    if (sLGDIProbePhase < 0) {
        sLGDIProbePhase = 0;
        sLGDIProbePhaseAt = now;
    } else if (now - sLGDIProbePhaseAt >= kLGDIProbePhaseSecs) {
        sLGDIProbePhase = (sLGDIProbePhase + 1) % phaseCount;
        sLGDIProbePhaseAt = now;
    }
    if (sLGDIProbePhase >= phaseCount) sLGDIProbePhase = 0;

    if (sLGDIProbePhase < 6) {
        LGDIProbeApplyPhase(sLGDIProbePhase, wrapper, bgCard);
        LGDIProbeSyncGlass(container, contentSib, bgCard,
                           sLGDIProbePhase == 4 || sLGDIProbePhase == 5);
        LGDIProbeUpdateBadge(wrapper, container, sLGDIProbePhase);
    } else {
        // M 相：先恢复 P 相状态再统一去污染，随后把测试玻璃迁到候选窗口
        LGDIProbeRestoreHides();
        LGDIWithoutImplicitAnimations(^{
            if (sLGDIGlass) LGDIProbeSetHidden(sLGDIGlass, YES);
            LGDIProbeSetHidden(bgCard, YES);
            UIView *c2 = LGDIProbeFindView(wrapper, ^BOOL(NSString *cn) {
                return [cn isEqualToString:@"_SBSystemApertureMagiciansCurtainView"];
            }, 4);
            LGDIProbeSetHidden(c2, YES);
            LGDIProbeSetHidden(LGDIFindSubviewOfClass(c2, @"_SBGainMapView"), YES);
        });
        CGRect sf = [bgCard convertRect:bgCard.bounds toView:nil];
        if (!LGDIIsPlausibleSize(sf.size))
            sf = [container convertRect:container.bounds toView:nil];
        NSInteger mi = sLGDIProbePhase - 6;
        if (mi >= 0 && mi < mountCount)
            LGDIProbeMountSync(mounts[mi], sf, mi, mountCount);
    }

    if ((sLGDIProbeTickCount++ % 12) == 0) {
        LGDILog(@"[probe] tick phase=%ld/%ld glassHost=%@ mainGlassHidden=%d",
                (long)sLGDIProbePhase, (long)phaseCount,
                sLGDIProbeGlass.superview
                    ? NSStringFromClass(sLGDIProbeGlass.superview.class) : @"-",
                sLGDIGlass ? (int)sLGDIGlass.hidden : -1);
    }
}

static void LGDIProbeEnsureTimer(void) {
    if (!sLGDIProbeTimer) {
        sLGDIProbeTimer = [NSTimer timerWithTimeInterval:0.2 repeats:YES
                                                    block:^(NSTimer *t) {
            LGDIProbeTick(t);
        }];
        [[NSRunLoop mainRunLoop] addTimer:sLGDIProbeTimer
                                  forMode:NSRunLoopCommonModes];
        LGDILog(@"[probe] timer armed — switch DynamicIsland.EmptyCaptureDebug "
                @"ON to activate, DI must be active");
    }
}

static void LGDIProbeStopTimer(void) {
    [sLGDIProbeTimer invalidate];
    sLGDIProbeTimer = nil;
    LGDIProbeFullReset(nil);
}

#endif // LIQUIDASS_DEBUG

// [黑边修复 v4] 延迟刷新 backdrop 的安全版本。
// v4 改变策略：lgForceRefreshBackdrop 已改为软刷新（不改 groupName、
// 不重置 _filterAttached），不会销毁 render server 捕获组 → 不产生黑边。
// 此函数仍检查 lgFilterTypeLocked，锁定时推迟执行（解锁后 0.5s 稳定期
// 内 lgForceRefreshBackdrop 的 applyFilters 会 early return，不替换滤镜）。
// 0.5s 防抖仍保留：避免多次 setNeedsDisplay 造成不必要的 render server 负载。
static CFTimeInterval sLGDILastDelayedRefresh = 0;
static const NSTimeInterval kLGDIDelayedRefreshDebounce = 0.5;
static void LGDIDelayedRefreshBackdrop(LGLiveBackdropView *glass, NSTimeInterval delay) {
    __weak LGLiveBackdropView *weakGlass = glass;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGLiveBackdropView *g = weakGlass;
        if (!g || !g.window) return;
        if ([g lgFilterTypeLocked]) {
            // 动画进行中，0.2s 后重试
            LGDIDelayedRefreshBackdrop(g, 0.2);
        } else {
            // [黑边修复 v4] 防抖：虽然 lgForceRefreshBackdrop 已是软刷新，
            // 多次 setNeedsDisplay 仍会增加 render server 负载，保留防抖。
            CFTimeInterval now = CACurrentMediaTime();
            if (now - sLGDILastDelayedRefresh < kLGDIDelayedRefreshDebounce) {
                LGDILog(@"delayed refresh debounced at %.2fs", now);
                return;
            }
            sLGDILastDelayedRefresh = now;
            [g lgForceRefreshBackdrop];
        }
    });
}

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

    // [P2 修复] 先压制装饰再装玻璃：消除「玻璃已装但装饰未压」的 1-2 帧空窗。
    // 旧顺序：insertSubview → SweepView → StripNearBlackSubtree，中间有闪烁。
    // 新顺序：SweepView → StripNearBlackSubtree → insertSubview，装饰先隐再装玻璃。
    if (sLGDIActive) {
        UIView *sweepRoot = host.window ?: host;
        LGDISweepView(sweepRoot, 14);
        if (LGDClearContentBg()) LGDIStripNearBlackSubtree(sweepRoot, 16);
    }

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
        // [设计修复] 添加中心遮罩层：compact 药丸仅左右两端显示液态效果。
        // 中心区域用深色层覆盖，保持系统原样的黑色中心条外观。
        // 遮罩层位于玻璃上方、内容下方（insertSubview:aboveSubview:glass）。
        if (!sLGDICenterCover) {
            sLGDICenterCover = [CALayer layer];
            sLGDICenterCover.backgroundColor = [UIColor.blackColor CGColor];
            sLGDICenterCover.name = @"lgdi.centerCover";
            LGDILog(@"center cover layer created for left/right-only liquid effect");
        }
        if (!sLGDICenterCover.superlayer) {
            [glass.layer addSublayer:sLGDICenterCover];
        }
        // [阶段4] 换宿主重装时若展开玻璃仍在管，pill 继续让位，避免双玻璃同显
        if (sLGDIPillHiddenForExpanded) glass.hidden = YES;
        LGDILog(@"glass installed in host=%@ frame=%@",
                NSStringFromClass(host.class),
                NSStringFromCGRect(glass.frame));

        // [P2 修复] 装玻璃后再异步扫一次：系统在 insertSubview 后可能
        // 重建装饰视图（layoutSubviews 重建子树），需要捕获新装饰。
        __weak UIView *weakHost = host;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sLGDIActive && weakHost) {
                UIView *sr = weakHost.window ?: weakHost;
                LGDISweepView(sr, 14);
                if (LGDClearContentBg()) LGDIStripNearBlackSubtree(sr, 16);
            }
        });

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
        // 未变时会 early-return。这里在布局就绪的多个时间点触发软刷新
        // （setNeedsDisplay），让 render server 重新采样窗外实时画面。
        // [黑边修复 v4] lgForceRefreshBackdrop 已改为软刷新：不改 groupName、
        // 不重置 _filterAttached → 不销毁捕获组 → 不产生黑边。
        // 延迟回调仅触发 setNeedsDisplay + scale 重评估，安全无闪烁。
        for (NSNumber *delay in @[ @0.3, @1.0 ]) {
            LGDIDelayedRefreshBackdrop(glass, delay.doubleValue);
        }
    }

    sLGDICurtain = curtain;
    sLGDIHost = host;

    // [阶段4] 展开态宿主切换导致 pill 玻璃重装时，继续保持让位隐藏
    if (sLGDIPillHiddenForExpanded) glass.hidden = YES;

    LGDISyncGeometryFromPresentation(NO);
    LGDIScheduleSync(0.35);

    // [路线B] 启动壁纸捕获：创建 IOSurface 并定期将灵动岛区域
    // 下方的壁纸内容渲染进去，供 backboardd 端作为折射 fallback 纹理
    LGDIStartWallpaperCapture();

#if LIQUIDASS_DEBUG
    LGDIProbeEnsureTimer();
#endif
}

static void LGDITeardown(BOOL featureDisabled) {
    LGLiveBackdropView *glass = sLGDIGlass;

    LGDIStopDriver();
    LGDIStopExpandedDriver();  // [独立 DisplayLink] 确保 teardown 时展开 driver 也停止
    // [阶段4] 先拆展开玻璃（恢复 pill hidden 状态由它内部处理，
    // 随后 pill 玻璃也会被整体移除，顺序无视觉影响）
    LGDIDestroyExpandedGlass(@"teardown");
#if LIQUIDASS_DEBUG
    // 活动退出：探针玻璃与轮换隐藏一并还原（timer 停止）
    LGDIProbeStopTimer();
#endif

    // 整个拆除过程（拆玻璃 / 恢复装饰 / 放回黑色形体）在无隐式动画事务内
    // 硬切完成。延迟拆除回调到达时系统收缩弹簧已结束，这里不会产生任何淡变。
    LGDIWithoutImplicitAnimations(^{
        if (glass) {
            // [F2 修复] 在 removeFromSuperview 之前显式清理 layer.filters 和
            // groupName，让 render server 在同一渲染事务内销毁捕获组，
            // 避免残留捕获组在下次创建玻璃时干扰首帧采样 → 闪烁/发黑。
            // 先移除视图确保即使 KVC 抛异常也不会残留。
            [glass removeFromSuperview];
            @try {
                glass.layer.filters = @[];
                [glass.layer setValue:nil forKey:@"groupName"];
            } @catch (NSException *e) {
                LGDILog(@"teardown KVC cleanup exception: %@", e.reason);
            }
            sLGDIGlass = nil;
        }
        // [设计修复] 清理中心遮罩层：从 glass.layer 移除并置空
        if (sLGDICenterCover) {
            [sLGDICenterCover removeFromSuperlayer];
            sLGDICenterCover = nil;
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
    });

    // [路线B] 停止壁纸捕获并清理 IOSurface，防止 backboardd 端
    // 继续引用已失效的 surface ID
    LGDITeardownWallpaperSurface();

    sLGDICurtain = nil;
    sLGDIHost = nil;
}

// =============================================================================
//  延迟拆除（修复回小药丸灰闪）
// -----------------------------------------------------------------------------
//  活动退出时事件路径检测到 !LGDIHasActiveLayout()。旧逻辑立刻 teardown：
//  恢复装饰的淡变 × 系统收缩弹簧 = 灰色边框跟着闪一下。
//  现在：保持玻璃与压制状态，driver 逐帧跟随 curtain 从长药丸 morph 回
//  小药丸；延迟 kLGDIDeferredTeardownDelay 待弹簧到位后，在关闭隐式动画的
//  事务里一次性硬切回系统黑色小药丸。延迟窗口内活动复活则取消拆除。
// =============================================================================
// [闪烁根因修复] 延迟拆除窗口：0.25s 太短，element 表在活动切换时
// 会短暂空白（旧 element 释放、新 element 尚未注册），0.25s 内新 element
// 可能还没到，导致拆除 → 恢复装饰 → 立即重新点亮 → 再拆 → 无限循环 = 闪烁。
// 增大到 0.8s：给新 element 足够注册时间，同时也覆盖 curtain 收缩弹簧。
static const NSTimeInterval kLGDIDeferredTeardownDelay = 0.8;

static void LGDICancelDeferredTeardown(NSString *reason) {
    if (!sLGDITeardownPending) return;
    sLGDITeardownPending = NO;
    sLGDITeardownGeneration++;
    // [闪烁修复] 防御性清除冷却期：正常流程中冷却期只在拆除回调中设置，
    // 取消时尚未设置。但防御性清除以应对可能的边缘竞态。
    sLGDITeardownCooldownUntil = 0;
    LGDILog(@"deferred teardown cancelled: %@", reason);
}

static void LGDIScheduleDeferredTeardown(void) {
    if (sLGDITeardownPending) return;
    sLGDITeardownPending = YES;
    NSUInteger gen = sLGDITeardownGeneration;

    // 收缩期间继续逐帧跟随弹簧（玻璃随 curtain 收缩回小药丸尺寸）。
    // sLGDIActive 保持 YES，driver tick 才不会自行停机。
    LGDIStartDriverReal(kLGDIDeferredTeardownDelay + 0.15);
    LGDILog(@"idle layout — defer teardown %.2fs for shrink spring",
            kLGDIDeferredTeardownDelay);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kLGDIDeferredTeardownDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 窗口内活动复活（generation 已自增）：本次拆除自动作废
        if (gen != sLGDITeardownGeneration) return;
        sLGDITeardownPending = NO;
        // 兜底：事件先于取消逻辑到达时，若布局已重新活跃则不拆
        if (LGDIFeatureEnabled() && LGDIHasActiveLayout()) {
            LGDILog(@"deferred teardown skipped — layout active again");
            // [闪烁修复 v2] 重新排队延迟拆除：element 仍存活但可能即将释放。
            // 旧逻辑用 sLGDIMode 判断是否重新排队，但该值会过期。
            // 新逻辑用 element 表判断：表非空 = 仍活跃 = 不拆但继续轮询。
            // element 释放后 hook 事件会触发 LGDIScheduleSync → 新一轮拆除；
            // 但若系统恰好不触发 hook（边缘场景），这里提供安全网。
            LGDIScheduleDeferredTeardown();
            return;
        }
        sLGDIActive = NO;
        // [闪烁修复] 设置 1.0s 冷却期：拆除后 hook 可能因 curtain
        // layoutSubviews 立即触发 LGDIScheduleSync → LGDIEngage。
        // 冷却期内 LGDIEngage 不点亮，防止用过期 sLGDIMode 重装玻璃。
        sLGDITeardownCooldownUntil = CACurrentMediaTime() + 1.0;
        LGDITeardown(YES);
        LGDILog(@"deferred teardown executed — stock pill restored (cooldown 1.0s)");
    });
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
    // [锁屏检测 v5] 锁屏时不渲染液态玻璃，省电降温
    if (sLGDIOnLockScreen) return NO;
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
            LGDICancelDeferredTeardown(@"feature turned off");
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"disengage: feature turned off, stock island restored");
        }
        return;
    }
    // [闪烁根因修复 v2] 不再用 sLGDIMode 作为回退点亮信号。
    // 旧逻辑：LGDIHasActiveLayout()=NO 时，若 sLGDIMode 仍为 compact/expanded
    // 则认为 element 表延迟填充 → 点亮。但活动结束时系统不回调
    // setLayoutMode:inert，sLGDIMode 过期停留在 compact → 误点亮 → 玻璃
    // 反复装到默认小药丸上 → 滤镜类型切换闪烁。
    // 新逻辑：LGDIHasActiveLayout() 基于 element 弱引用表实时聚合，element
    // 释放后自动回到 inert。setLayoutMode: hook 在 %orig 之前注册 element，
    // 所以新活动启动时 element 表已填充，不存在「延迟填充」场景。
    // 若 LGDIHasActiveLayout()=NO，一律不点亮；有残留玻璃则延迟拆除。
    if (!curtain) curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    BOOL curtainReady = LGDICurtainReady(curtain);

    if (!LGDIHasActiveLayout()) {
        // [闪烁修复] 检查拆除冷却期：刚拆除完成时 hook 可能立即触发，
        // 此时 sLGDIMode 可能仍过期为 compact。冷却期内直接返回，
        // 不点亮也不延迟拆除（拆除已完成，无需再拆）。
        BOOL inCooldown = (sLGDITeardownCooldownUntil > 0
                           && CACurrentMediaTime() < sLGDITeardownCooldownUntil);
        if (inCooldown) {
            LGDILog(@"engage: in teardown cooldown, skipping (stale mode protection)");
            return;
        }
        if (sLGDIActive || sLGDIGlass) {
            LGDIScheduleDeferredTeardown();
            LGDILog(@"disengage: no active layout — deferring liquid removal");
        }
        return;
    }
    if (!curtainReady) return;   // 布局未完成/已下屏：等下一个事件重试

    // 活动在延迟拆除窗口内复活：取消拆除，无缝继续液态态
    LGDICancelDeferredTeardown(@"layout active again");
    // [闪烁修复] 新活动启动，清除冷却期
    sLGDITeardownCooldownUntil = 0;

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
            LGDICancelDeferredTeardown(@"feature disabled (sync)");
            sLGDIActive = NO;
            LGDITeardown(YES);
        }
        return;
    }

    // [闪烁修复 v2] 同 LGDIEngage：不再用过期 sLGDIMode 回退点亮。
    // element 表实时聚合是最可靠的信号。
    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    BOOL curtainReady = LGDICurtainReady(curtain);

    if (!LGDIHasActiveLayout()) {
        // [闪烁修复] 拆除冷却期检查：防止拆除后 hook 立即重装玻璃
        BOOL inCooldown = (sLGDITeardownCooldownUntil > 0
                           && CACurrentMediaTime() < sLGDITeardownCooldownUntil);
        if (inCooldown && !sLGDIActive) {
            LGDILog(@"scheduled sync: in teardown cooldown, skipping engage");
            return;
        }
        // [闪烁修复 v2] 不再调用 LGDIEngage 回退路径（它会重复检查已知条件）。
        // 直接处理：有残留玻璃或激活态 → 延迟拆除；否则无事可做。
        if (sLGDIActive || sLGDIGlass) {
            LGDIScheduleDeferredTeardown();
            LGDILog(@"scheduled sync: idle layout — defer liquid removal");
        }
        return;
    }

    // 延迟拆除窗口内活动复活：取消拆除，继续液态态
    LGDICancelDeferredTeardown(@"active layout (sync)");

    if (!curtainReady) return;  // curtain 未就绪：等下一个事件重试

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
    // [黑边修复 v2] 同步再扫一次（非异步）：layoutSubviews 可能在
    // SuppressDecorations 之后同步重建装饰视图，旧逻辑用 dispatch_async
    // 异步二次扫描，中间有 1-2 帧新装饰已渲染但未被压制 = 黑边闪。
    // 改为同步立即再扫，捕获同一 runloop 中重建的装饰。
    if (sLGDIActive && host) {
        LGDISweepView(host, 14);
        if (LGDClearContentBg()) LGDIStripNearBlackSubtree(host, 22);
    }
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
    // 点亮/拆除统一由 LGDIEngage 裁决——
    //   总开关关          -> 拆除还原
    //   inert/minimal      -> 拆除还原（默认小岛保持系统原样）
    //   compact/expanded   -> 找到在屏幕布即装玻璃
    // LGDIEngage 内部先判布局再找 curtain，inert/minimal 态即使 curtain 在屏也不点亮。
    if (!LGDIFeatureEnabled()) {
        if (sLGDIActive || sLGDIGlass) {
            LGDICancelDeferredTeardown(@"feature disabled (reconcile)");
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
    // [P4 修复] 递增重试：不依赖后续系统事件，主动在多个时间点重试。
    // curtain bounds=0x0 第二次 didMoveToWindow 在日志中已观察到，
    // 递增重试确保即使首次 async 时 bounds 未就绪，后续仍能点亮。
    for (NSNumber *delay in @[ @0.1, @0.2, @0.4, @0.8 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!sLGDIActive && LGDIFeatureEnabled() && LGDICurtainReady(curtain)) {
                LGDILog(@"engage: escalating retry at %.1fs", delay.doubleValue);
                LGDIEngage(curtain);
            }
        });
    }
}

static BOOL LGDIShouldForceHidden(UIView *view) {
    // [设计调整] 仅 compact/expanded/detached 才强制隐藏黑色形体；
    // inert/minimal 小岛放行，保持系统原样。
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
    // 必须在 %orig 之前更新 element 模式表：%orig 会触发系统布局，
    // 容器 layoutSubviews 在此刻就会查 LGDILiquidSuppressionActive()。
    // 若 element 表还是旧模式（compact/expanded），剥离会在 minimal/inert
    // 转换过程中误触发，造成空闲小岛灰色闪烁。
    LGDIRecordElementMode(self, layoutMode);
    LGDILog(@"setLayoutMode=%@(%ld) reason=%ld",
            LGDIModeName(layoutMode), (long)layoutMode, (long)reason);
    %orig(layoutMode, reason);
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
//  Lock screen detection (v5)
// -----------------------------------------------------------------------------
//  锁屏时不渲染液态玻璃，省电降温。使用 Darwin 通知监听锁屏/解锁事件，
//  不在 constructor 中调用 SBLockScreenManager（会导致安全模式崩溃）。
//  通知回调中通过 SBLockScreenManager 查询实际状态——此时 SB 已完全启动，
//  调用 sharedInstance 安全。使用现有 LGDITeardown/LGDIReconcile 函数，
//  不直接操作 glass 引用，避免折叠后玻璃残留。
// =============================================================================
static void LGDIOnLockStateChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    @autoreleasepool {
        Class lockMgrCls = objc_getClass("SBLockScreenManager");
        if (!lockMgrCls) return;
        id lockMgr = ((id (*)(Class, SEL))objc_msgSend)(lockMgrCls, @selector(sharedInstance));
        if (!lockMgr) return;
        BOOL locked = ((BOOL (*)(id, SEL))objc_msgSend)(lockMgr, @selector(isUILocked));

        if (locked != sLGDIOnLockScreen) {
            sLGDIOnLockScreen = locked;
            LGDILog(@"lock state changed: %d", locked);
            if (locked) {
                // 锁屏：拆除液态玻璃，省电降温
                // 使用现有 teardown 函数，确保 glass 从 superview 正确移除，
                // 不会残留。不取消 deferred teardown（让正常流程处理）。
                if (sLGDIActive || sLGDIGlass) {
                    LGDICancelDeferredTeardown(@"lock screen");
                    sLGDIActive = NO;
                    LGDITeardown(NO);
                }
            } else {
                // 解锁：延迟 reconcile，等系统布局稳定后再重新点亮
                // 延迟 0.3s：解锁后系统需要时间恢复灵动岛布局，
                // 立即 reconcile 可能找不到 curtain 或尺寸未就绪
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    LGDIReconcile();
                });
            }
        }
    }
}

// =============================================================================
//  Constructor
// =============================================================================

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGDIIsSpringBoardProcess()) return;
    if (@available(iOS 16.0, *)) {} else return;

    // [锁屏检测 v5] 注册 Darwin 通知监听锁屏/解锁事件。
    // CFNotificationCenterGetDarwinNotifyCenter 在 constructor 中安全调用：
    // 它不依赖 SpringBoard 的运行时状态，只注册一个内核级通知回调。
    // SBLockScreenManager 的调用推迟到通知回调中（此时 SB 已启动）。
    CFNotificationCenterRef darwinCenter =
        CFNotificationCenterGetDarwinNotifyCenter();
    if (darwinCenter) {
        CFNotificationCenterAddObserver(darwinCenter,
                                       NULL,
                                       LGDIOnLockStateChanged,
                                       CFSTR("com.apple.springboard.lockstate"),
                                       NULL,
                                       CFNotificationSuspensionBehaviorDeliverImmediately);
        LGDILog(@"lock screen notification registered");
    }

    // 设置变更：开关关闭时恢复原黑色岛，开启时重新装配（滤镜参数刷新由
    // LGLiveBackdropView 全局监听 ParametersReloaded 自动完成，无需此处处理）
    lgObservePreferenceReload(^{
        LGDIReconcile();
#if LIQUIDASS_DEBUG
        // 诊断开关随时可开：timer 自身按 开关+活动 双条件门控
        LGDIProbeEnsureTimer();
#endif
    });
#if LIQUIDASS_DEBUG
    LGDIProbeEnsureTimer();
#endif

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
    // [P4 修复] 缩短兜底延迟：0.8/2.5/5.0s 对短时通知太慢，
    // 改为 0.3/0.8/1.5/3.0s，更快捕获启动时已有活动
    for (NSNumber *delay in @[ @0.3, @0.8, @1.5, @3.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGDIReconcile();
        });
    }
}
