// =============================================================================
//  LGDI2View.h — 灵动岛2 自定义视图
//
//  纯自定义 UIView，不 Hook 任何系统灵动岛私有类。
//  复用 LGLiveBackdropView 液态玻璃渲染引擎和 DynamicIsland2 宿主参数。
//  按 Banana deb 方式：不做锁屏检测，跟随系统自然行为。
// =============================================================================

#import <UIKit/UIKit.h>
#import "LGLiveBackdropView.h"

typedef NS_ENUM(NSInteger, LGDI2LayoutMode) {
    LGDI2LayoutModeCompact = 0,   // 长药丸
    LGDI2LayoutModeExpanded = 1,  // 展开卡片
};

@interface LGDI2View : UIView

@property (nonatomic, assign) LGDI2LayoutMode layoutMode;
@property (nonatomic, strong, readonly) LGLiveBackdropView *glassView;

// 创建并安装到指定父视图
+ (instancetype)installInSuperview:(UIView *)superview
                       filterPrefix:(NSString *)prefix;

// 从父视图移除并清理
- (void)uninstall;

// 刷新参数（偏好变更后调用）
- (void)refreshConfiguration;

// 更新布局（屏幕旋转/设备方向变化时调用）
- (void)updateLayout;

// 切换布局模式（compact ↔ expanded）
- (void)switchToMode:(LGDI2LayoutMode)mode animated:(BOOL)animated;

// 启动定时布局同步（用于 hideWhenInactive 状态检测）
- (void)startLayoutSyncTimer;

@end
