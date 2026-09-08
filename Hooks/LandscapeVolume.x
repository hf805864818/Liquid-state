#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

#pragma mark - Volume HUD Material Host

// 判断一个 MTMaterialView 是不是在音量 HUD 里（音量条 + 铃声药丸）
static BOOL vhIsVolumeHUDMaterial(UIView *material) {
    if (!isExactClass(material, @"MTMaterialView")) return NO;
    
    // --- 音量条 ---
    // iOS 17+: 在 SBElasticSliderView 内部
    if (hasAncestorOfClassName(material, @"SBElasticSliderView")) return YES;
    // iOS 14-16: 在 SBElasticSliderMaterialWrapperView 内部
    if (hasAncestorOfClassName(material, @"SBElasticSliderMaterialWrapperView")) return YES;
    
    // --- 铃声/静音药丸 ---
    // iOS 14-16: SBRingerPillView 或 PLPillView
    if (hasAncestorOfClassName(material, @"SBRingerPillView")) return YES;
    if (hasAncestorOfClassName(material, @"PLPillView")) return YES;
    
    // iOS 17+: 可能在 SBRingerHUDViewController 的 view 里
    // 通过遍历响应者链查找
    UIResponder *responder = material;
    while (responder) {
        responder = [responder nextResponder];
        if ([responder isKindOfClass:NSClassFromString(@"SBRingerHUDViewController")]) {
            return YES;
        }
        if (responder && [responder isKindOfClass:[UIViewController class]]) {
            NSString *clsName = NSStringFromClass([responder class]);
            if ([clsName containsString:@"RingerHUD"] ||
                [clsName containsString:@"MuteHUD"] ||
                [clsName containsString:@"SilentHUD"]) {
                return YES;
            }
        }
    }
    
    return NO;
}

static CGFloat vhVolumeHUDCornerRadius(UIView *material) {
    if (!vhIsVolumeHUDMaterial(material)) return -1.0;
    
    // 找到容器视图来计算圆角
    UIView *container = material.superview;
    while (container) {
        NSString *cls = NSStringFromClass([container class]);
        if ([cls isEqualToString:@"SBElasticSliderView"] ||
            [cls isEqualToString:@"SBElasticSliderMaterialWrapperView"] ||
            [cls isEqualToString:@"SBRingerPillView"] ||
            [cls isEqualToString:@"PLPillView"]) {
            break;
        }
        container = container.superview;
    }
    
    CGRect bounds = container ? container.bounds : material.bounds;
    CGFloat prefRadius = LG_prefFloat(@"VolumeHUDGlass.CornerRadius", 0.0);
    
    // 如果用户设置了大于0的圆角，用用户的；否则保持药丸形（完全圆角）
    if (prefRadius > 0) return prefRadius;
    return MIN(bounds.size.width, bounds.size.height) * 0.5f;
}

#pragma mark - Constructor

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    
    // 注册 Volume HUD 材质宿主
    // 覆盖：音量条 + 铃声/静音药丸
    // priority 设为 120，比 ControlCenter(110) 高，确保优先匹配
    LGRegisterMaterialHost(@"VolumeHUD", 120, ^BOOL(UIView *material) {
        return vhIsVolumeHUDMaterial(material);
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {
        return vhVolumeHUDCornerRadius(material);
    }, nil, nil);
    
    lgObservePreferenceReload(^{
        LGLog(@"VolumeHUD: Preferences reloaded");
    });
}
