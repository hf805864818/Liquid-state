// =============================================================================
//  LGDI2Mutex.h — 灵动岛互斥开关
//
//  DI1（原灵动岛）和 DI2（灵动岛2）互斥：开一个自动关另一个。
//  DI2 稳定后将移除 DI1，此文件简化为 DI2 直接总开关。
// =============================================================================

#pragma once

#import <Foundation/Foundation.h>
#import "LGSharedSupport.h"

typedef NS_ENUM(NSInteger, LGDIMode) {
    LGDIModeNone = 0,        // 都关闭
    LGDIModeOriginal = 1,     // DI1 开启，DI2 关闭
    LGDIModeCustom = 2,        // DI2 开启，DI1 关闭
};

// 查询当前生效的灵动岛模式
static inline LGDIMode LGDIActiveMode(void) {
    BOOL di1 = LG_prefBool(@"DynamicIsland.Enabled", NO);
    BOOL di2 = LG_prefBool(@"DynamicIsland2.Enabled", NO);

    if (di1 && di2) {
        // 互斥：两者同时开时，优先 DI2（用户主动开启表示意图切换）
        return LGDIModeCustom;
    }
    if (di2) return LGDIModeCustom;
    if (di1) return LGDIModeOriginal;
    return LGDIModeNone;
}

// 检查 DI2 是否应该启用（供 DI1 的 LGDIFeatureEnabled 调用）
static inline BOOL LGDI2IsActive(void) {
    return LG_prefBool(@"DynamicIsland2.Enabled", NO);
}

// 设置端调用：开 DI2 时自动关 DI1，反之亦然
// 调用后会触发偏好变更通知 + Respring
extern void LGDISetMode(LGDIMode mode);
