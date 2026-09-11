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

// [闪烁根因修复] 滤镜更新挂起/恢复机制。
// 灵动岛弹簧动画期间，玻璃尺寸逐帧变化导致动态半径步进（.r0~.r16）反复跨过
// 边界，每次跨步都触发 layer.filters 数组替换 → render server 短暂无滤镜 =
// 灰/黑闪烁 2-3 次（对应弹簧弹跳）。
// 挂起期间 layoutSubviews 仍更新 specular（frame/radius），但跳过 applyFilters，
// 避免滤镜替换。恢复时用最终尺寸重新 evaluate 滤镜类型，一次性切换到位。
- (void)lgSuspendFilterUpdates;   // 挂起：动画开始时调用
- (void)lgResumeFilterUpdates;     // 恢复：动画结束时调用，作废节流缓存触发下次 layoutSubviews 重 evaluate
- (BOOL)lgFilterUpdateSuspended;   // 查询：延迟回调判断是否需要避让

// 为 native blur 层设置形状 mask（用于 Clock 文字形状裁剪）
- (void)lgSetNativeBlurMask:(CALayer *)maskLayer;

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
