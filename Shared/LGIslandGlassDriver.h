// =============================================================================
//  LGIslandGlassDriver.h — 灵动岛玻璃驱动（原版 Liquid (Gl)ass 架构）
//
//  完全复刻 Banana deb 的实现方式：
//  - 直接 Hook 系统 _SBSystemApertureMagiciansCurtainView
//  - 在系统灵动岛视图上注入玻璃层，不创建独立视图
//  - 使用 dylv.liquidglass.island 滤镜类型
//  - 极简配置：Enabled + HideWhenInactive
// =============================================================================

#pragma once
#import <UIKit/UIKit.h>
#import "LGLiveBackdropView.h"

@interface LGIslandGlassDriver : NSObject

@property (nonatomic, weak) UIView *curtainView;          // 系统灵动岛幕布视图
@property (nonatomic, strong) LGLiveBackdropView *glass;  // 玻璃背景视图
@property (nonatomic, strong) CALayer *gainMapLayer;      // 增益图层（液态高光）
@property (nonatomic, strong) NSArray *rimLayers;         // 边缘高光层
@property (nonatomic, assign) BOOL layoutEnabled;         // 布局是否启用

// 单例
+ (instancetype)sharedDriver;

// 挂载到系统灵动岛幕布视图
- (void)attachToCurtainView:(UIView *)curtainView;

// 从系统视图卸载
- (void)detach;

// 刷新布局（系统视图尺寸变化时调用）
- (void)updateLayout;

// 刷新配置（偏好变更时调用）
- (void)refreshConfiguration;

// 设置无活动时隐藏（HideWhenInactive）
- (void)setHideWhenInactive:(BOOL)hidden;

// 检查系统灵动岛是否处于活动状态
- (BOOL)isSystemIslandActive;

@end
