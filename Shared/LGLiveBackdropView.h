#pragma once
#import <UIKit/UIKit.h>

void LGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#ifndef jbroot
#define jbroot(path) (path)
#endif
#endif

id LGGlassPreferenceValue(NSString *key);
void LGInvalidateGlassPreferenceCache(void);
NSString *LGFilterTypeForHostPrefix(NSString *prefix);

// Appearance mode support for separate light/dark parameters
void LGSetGlassAppearanceMode(UIUserInterfaceStyle mode);
UIUserInterfaceStyle LGGetGlassAppearanceMode(void);

@interface LGLiveBackdropView : UIView

@property (nonatomic, copy) NSString *lgFilterType;

@property (nonatomic, copy) NSNumber *lgSpecularEnabledOverride;

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName;

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName
                   filterType:(NSString *)filterType;
- (void)applyFilters;

// 强制 backdrop 重新建立 render-server 捕获并重挂滤镜。
// 用于：玻璃在内容/背景尚未就绪时就加入了特殊窗口（如灵动岛独立窗口），
// 首次 CABackdropLayer 捕获为空/黑；普通 applyFilters 在滤镜类型未变时会
// early-return，无法触发重采样。此方法重置捕获配置并强制重挂，无动画、可重复调用。
- (void)lgForceRefreshBackdrop;

// [闪烁根因修复] 滤镜类型锁定/解锁机制。
// 灵动岛弹簧动画期间，玻璃尺寸逐帧变化导致动态半径步进（.r0~.r16）反复跨过
// 边界，每次跨步都触发 layer.filters 数组替换 → render server 短暂无滤镜 =
// 灰/黑闪烁 2-3 次（对应弹簧弹跳）。
// 锁定期间 applyFilters 仍每帧调用（更新 scale 等参数），但跳过
// layer.filters 数组替换，避免滤镜替换闪烁。
// 解锁时作废节流缓存，下一帧 layoutSubviews 会用最终尺寸一次性切换到正确类型。
- (void)lgLockFilterType;    // 锁定：动画开始时调用
- (void)lgUnlockFilterType;  // 解锁：动画结束时调用
- (BOOL)lgFilterTypeLocked;   // 查询：延迟回调判断是否需要避让

// 为 native blur 层设置形状 mask（用于 Clock 文字形状裁剪）
- (void)lgSetNativeBlurMask:(CALayer *)maskLayer;

// [P0 修复] reparenting 标记：host 切换（removeFromSuperview + insertSubview）
// 时设置 YES，使 didMoveToWindow(nil) 跳过滤镜清空，避免 render server 销毁
// 捕获组导致 1-2 帧黑边。host 切换通常由 spring 动画中系统重排祖先链触发，
// 每次触发一次 host 重装 = 一次滤镜清空/重建 = 一次闪烁。spring 弹跳 2-3 次
// = 2-3 次闪烁。此标记让 host 切换走"保留滤镜"路径，黑边消除。
- (void)lgSetReparenting:(BOOL)reparenting;

// [P0 修复] 拆除玻璃时彻底清理 render server 捕获组。仅 removeFromSuperview +
// layer.filters=@[] 不够：_nativeBlurLayer 是挂在 self.layer 上的第二个
// CABackdropLayer 捕获组（独立 groupName），不显式移除会在渲染服务器侧残留
// 1-2 帧液态玻璃阴影。此方法原子清理 filters + nativeBlur + groupName。
- (void)lgTeardownCaptureGroup;

// [P0 修复] 跨 window/superview 移动后强制 nudge 捕获组重关联。
// 同 window 内换 superview 时 didMoveToWindow(nil) 不触发，reparenting 标记
// 用不上；insertSubview 触发的 didMoveToWindow(win) 里 applyFilters 因滤镜
// 类型未变 early return，setNeedsDisplay 不足以让 render server 重关联捕获组。
// 此方法在无动画事务内切换 sourceLayer off/on（对应 kageroumado
// "refreshConnection" 解法），强制捕获组重新关联，消除边缘黑框。
- (void)lgNudgeCaptureReattach;

@end

// Call to notify that SpringBoard is in foreground (icons visible) or background (app in front)
void LGSetSpringBoardInForeground(BOOL inForeground);

void LGInjectGlassIntoMaterialGroupType(UIView *materialView, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType);

void LGResyncGlassGeometry(UIView *materialView, const void *assocKey);
void LGRemoveGlassFromMaterial(UIView *materialView, const void *assocKey);

BOOL LGMaterialHasGlass(UIView *materialView, const void *assocKey);

// 充电/热状态降级接口 — 供各模块查询
BOOL LGLiquidIsCharging(void);               // 设备是否正在充电
BOOL LGLiquidIsPerformanceDegraded(void);     // 综合降级状态 (充电+热)
BOOL LGLiquidShouldSkipRenderFrame(void);    // backboardd 渲染器是否应跳过当前帧
