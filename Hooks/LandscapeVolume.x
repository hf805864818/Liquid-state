#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

#pragma mark - Ringer Pill Probe (iOS 17)

// 遍历视图层级
static void vhPrintViewHierarchy(UIView *view, NSString *indent) {
    if (!view) return;
    NSString *className = NSStringFromClass([view class]);
    NSString *frameStr = NSStringFromCGRect(view.frame);
    NSString *bgColor = @"none";
    if (view.backgroundColor) {
        CGColorRef cgColor = view.backgroundColor.CGColor;
        size_t numComponents = CGColorGetNumberOfComponents(cgColor);
        if (numComponents >= 4) {
            const CGFloat *components = CGColorGetComponents(cgColor);
            bgColor = [NSString stringWithFormat:@"rgba(%.0f,%.0f,%.0f,%.2f)",
                       components[0]*255, components[1]*255, components[2]*255, components[3]];
        }
    }
    LGLog(@"[RingerProbe] %@%@  frame=%@  hidden=%d  alpha=%.2f  bg=%@",
          indent, className, frameStr, view.hidden, view.alpha, bgColor);
    
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *subview in view.subviews) {
        if (materialClass && [subview isKindOfClass:materialClass]) {
            LGLog(@"[RingerProbe] %@  -> contains MTMaterialView: %@",
                  indent, NSStringFromClass([subview class]));
        }
    }
    
    for (UIView *subview in view.subviews) {
        vhPrintViewHierarchy(subview, [indent stringByAppendingString:@"  "]);
    }
}

@interface SBRingerHUDViewController : UIViewController
@end

%hook SBRingerHUDViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    LGLog(@"[RingerProbe] SBRingerHUDViewController viewDidAppear");
    LGLog(@"[RingerProbe]   view class: %@", NSStringFromClass([self.view class]));
    LGLog(@"[RingerProbe]   view frame: %@", NSStringFromCGRect(self.view.frame));
    LGLog(@"[RingerProbe]   --- view hierarchy:");
    vhPrintViewHierarchy(self.view, @"     ");
}

%end

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
