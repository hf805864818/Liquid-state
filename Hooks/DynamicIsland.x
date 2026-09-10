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
@interface SBSystemApertureWindow : UIWindow
@end

#pragma mark - Constants / association keys

static NSString * const kLGDIFilterPrefix    = @"DynamicIsland";
static NSString * const kLGDIBackdropGroup   = @"dylv.liquidglass.island";

static void *kLGDIRestoreInfoKey  = &kLGDIRestoreInfoKey; // 被压制装饰视图 -> 原始状态

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

static __weak UIView            *sLGDICurtain;   // 当前幕布（唯一）
static __weak UIView            *sLGDIHost;      // 玻璃挂载容器
static __weak LGLiveBackdropView *sLGDIGlass;    // 当前玻璃
static BOOL                      sLGDIActive;    // 已激活液态化（开关开 && 当前 compact/expanded）
static BOOL                      sLGDISyncQueued;
static CADisplayLink            *sLGDILink;
static CFTimeInterval            sLGDILinkDeadline;

// element(weak) -> 当前 layoutMode。仅 compact/expanded 视为“有活跃内容”
static NSMapTable<id, NSNumber *> *sLGDIElementModes;

static BOOL LGDIModeIsLiquid(NSInteger mode) {
    return mode == kLGDIModeCompact || mode == kLGDIModeExpanded;
}

static BOOL LGDIHasActiveLayout(void) {
    for (id element in sLGDIElementModes) {
        NSNumber *n = [sLGDIElementModes objectForKey:element];
        if (LGDIModeIsLiquid(n.integerValue)) return YES;
        // 关联表可能滞后于系统内部直接改值，KVC 校正一次（失败则信任记录值）
        @try {
            NSInteger cur = [[element valueForKey:@"layoutMode"] integerValue];
            if (LGDIModeIsLiquid(cur)) return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

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
        default:                return [NSString stringWithFormat:@"mode%ld", (long)mode];
    }
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
    // 黑色材质按类名直判（其内部可能有超过 2 个子视图）
    if (LGDIIsBlackBodyMaterial(v) && !LGDIIsContentSubview(v)) return YES;
    if (v.subviews.count > 2) return NO;            // 内容容器一定有子视图
    if (LGDIIsContentSubview(v)) return NO;
    return LGDIIsDecorSubview(v);
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
        if (!v.hidden) v.hidden = YES;
    } else if (LGDIShouldSuppressDecor(v)) {
        LGDISuppressOne(v);
    }
    for (UIView *sub in v.subviews) LGDISweepView(sub, depth - 1);
}

static void LGDISuppressDecorations(UIView *host) {
    if (!host || !sLGDIActive) return;

    // 容器自身底色清空（容器类不命中装饰谓词，单独处理）
    if (host.backgroundColor && host.backgroundColor != UIColor.clearColor) {
        LGDISuppressOne(host);
    } else if (objc_getAssociatedObject(host, kLGDIRestoreInfoKey)
               && host.backgroundColor != UIColor.clearColor) {
        host.layer.backgroundColor = UIColor.clearColor.CGColor;
    }

    LGDISweepView(host, 12);
}

// 逐帧廉价再断言：只遍历已追踪视图，O(被压制数量)，不做递归和类名匹配
static void LGDIReassertSuppressed(void) {
    if (!sLGDIActive) return;
    for (UIView *v in [sLGDISuppressedViews allObjects]) {
        if (v.alpha != 0.0) v.alpha = 0.0;
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
// =============================================================================

static void LGDIStopDriver(void);

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
        if (!curtain.hidden) curtain.hidden = YES;
        UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
        if (gain && !gain.hidden) gain.hidden = YES;
        LGDIReassertSuppressed();
        LGDISyncGeometryFromPresentation(YES);

        if (CACurrentMediaTime() >= sLGDILinkDeadline) {
            LGDISyncGeometryFromPresentation(NO);
            LGDIStopDriver();
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
    sLGDILinkDeadline = CACurrentMediaTime() + duration;
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
    curtain.hidden = YES;
    UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
    gain.hidden = YES;

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

        // backboardd 滤镜 atom 注册有重试，补发几次 applyFilters
        __weak LGLiveBackdropView *weakGlass = glass;
        for (NSNumber *delay in @[ @0.5, @1.5, @3.0, @6.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }
    }

    sLGDICurtain = curtain;
    sLGDIHost = host;

    // 安装/迁移时从窗口根全树压制，防止黑色材质是宿主的兄弟分支；
    // 布局期的增量压制仍只扫容器自身
    if (sLGDIActive) LGDISweepView(host.window ?: host, 14);
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
//  Sync scheduling
// =============================================================================

static void LGDIDoScheduledSync(void) {
    sLGDISyncQueued = NO;
    if (!sLGDIActive) return;

    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (!curtain || !curtain.window) return;

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

    if (!curtain.hidden) curtain.hidden = YES;
    UIView *gain = LGDIFindSubviewOfClass(curtain, @"_SBGainMapView");
    if (gain && !gain.hidden) gain.hidden = YES;
    LGDISuppressDecorations(host);
    LGDISyncGeometryFromPresentation(NO);
}

static void LGDIScheduleSync(NSTimeInterval driverDuration) {
    if (!sLGDIActive) return;

    if (driverDuration > 0) {
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
    BOOL enabled = lgHostEnabled(kLGDIFilterPrefix);
    // 只在 compact 长药丸 / expanded 展开卡片上液态化；
    // inert 空闲小药丸与 minimal 极小形态保持系统原样
    BOOL want = enabled && LGDIHasActiveLayout();

    if (!want) {
        if (sLGDIActive || sLGDIGlass) {
            sLGDIActive = NO;
            LGDITeardown(YES);
            LGDILog(@"inert/minimal or disabled: stock island restored");
        }
        return;
    }

    sLGDIActive = YES;
    UIView *curtain = sLGDICurtain ?: LGDIFindCurtainInWindows();
    if (curtain && curtain.window) {
        LGDIInstallGlass(curtain);
    } else {
        LGDILog(@"reconcile: active layout but no on-screen curtain yet");
    }
}

static void LGDIHandleCurtainAttached(UIView *curtain) {
    if (!sLGDIActive) return;
    sLGDICurtain = curtain;
    // didMoveToWindow 时层级往往还没布局完，延后一拍再装
    dispatch_async(dispatch_get_main_queue(), ^{
        if (curtain.window && LGDIIsPlausibleSize(curtain.bounds.size)) {
            LGDIInstallGlass(curtain);
        } else {
            LGDIScheduleSync(0.25);
        }
    });
}

static BOOL LGDIShouldForceHidden(UIView *view) {
    return sLGDIActive && view.window != nil && LGDIInApertureWindow(view);
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
    if (sLGDIActive && LGDIInApertureWindow(self)) {
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
    if (sLGDIActive) LGDIScheduleSync(0.35);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (sLGDIActive) LGDIScheduleSync(0.35);
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
    // compact/expanded 装配玻璃；回到 inert/minimal 还原系统黑色形体
    LGDIReconcile();
    if (sLGDIActive) {
        // 弹簧形变约 0.5~0.7s，驱动逐帧跟随
        LGDIScheduleSync(0.85);
#if LIQUIDASS_DEBUG
        // 形变完成后 dump 展开形态的真实层级
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGDIRequestDump([NSString stringWithFormat:@"layoutMode=%ld", (long)layoutMode]);
        });
#endif
    }
}

%end
%end

// =============================================================================
//  Hook: _SBSystemApertureContainerViewContentView（部分版本上的容器底色）
// =============================================================================

%group LGDIContentContainerHook
%hook _SBSystemApertureContainerViewContentView

- (void)setBackgroundColor:(UIColor *)color {
    if (sLGDIActive && color && color != UIColor.clearColor
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
    if (sLGDIActive && self.backgroundColor
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
//  Hook: SBSystemApertureWindow（布局信号，绝不动窗口透明度）
// =============================================================================

%group LGDIApertureWindowHook
%hook SBSystemApertureWindow

- (void)layoutSubviews {
    %orig;
    if (sLGDIActive) LGDIScheduleSync(0.35);
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
