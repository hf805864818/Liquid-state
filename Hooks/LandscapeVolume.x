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

#pragma mark - Volume HUD Vibrance View

// 饱和度+对比度增强层，叠加在液态玻璃上面增强通透感
@interface LGVolumeHUDVibranceView : UIView
@end

@implementation LGVolumeHUDVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)updateSaturation:(CGFloat)saturation contrast:(CGFloat)contrast {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(saturation) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(contrast) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

static const void * const kVHVibranceKey = &kVHVibranceKey;

static void vhUpdateVibranceForMaterial(UIView *material) {
    if (!material) return;
    if (!LG_prefBool(@"VolumeHUD.Enabled", YES)) return;
    
    LGLiveBackdropView *glass = objc_getAssociatedObject(material, kGlassKey);
    if (!glass) return;
    
    CGFloat saturation = LG_prefFloat(@"VolumeHUD.Saturation", 1.85);
    CGFloat contrast = LG_prefFloat(@"VolumeHUD.Contrast", 1.06);
    
    // 如果饱和度和对比度都是 1.0（无增强），移除 vibrance 视图
    if (saturation <= 1.0 && contrast <= 1.0) {
        LGVolumeHUDVibranceView *existing = objc_getAssociatedObject(material, kVHVibranceKey);
        if (existing) {
            [existing removeFromSuperview];
            objc_setAssociatedObject(material, kVHVibranceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    
    LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(material, kVHVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeHUDVibranceView alloc] initWithFrame:glass.bounds];
        if (!vibrance) return;
        objc_setAssociatedObject(material, kVHVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [glass.superview insertSubview:vibrance belowSubview:glass];
    }
    
    vibrance.frame = glass.frame;
    vibrance.layer.cornerRadius = glass.layer.cornerRadius;
    if (@available(iOS 13.0, *)) {
        vibrance.layer.cornerCurve = kCACornerCurveContinuous;
    }
    vibrance.layer.masksToBounds = YES;
    [vibrance updateSaturation:saturation contrast:contrast];
}

static void vhVolumeHUDPostInstall(UIView *material, LGLiveBackdropView *glass) {
    // 安装后立即添加 vibrance 层
    vhUpdateVibranceForMaterial(material);
}

// 前向声明
static BOOL vhIsVolumeHUDMaterial(UIView *material);

// 每次 layoutSubviews 时更新 vibrance 层（保证偏好变化时也能生效）
%hook MTMaterialView
- (void)layoutSubviews {
    %orig;
    UIView *selfView = (UIView *)self;
    if (vhIsVolumeHUDMaterial(selfView)) {
        vhUpdateVibranceForMaterial(selfView);
    }
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
    CGFloat prefRadius = LG_prefFloat(@"VolumeHUD.CornerRadius", 0.0);
    
    // 如果用户设置了大于0的圆角，用用户的；否则保持药丸形（完全圆角）
    if (prefRadius > 0) return prefRadius;
    return MIN(bounds.size.width, bounds.size.height) * 0.5f;
}

#pragma mark - Preference Migration

// 从旧的 VolumeHUDGlass.* 前缀迁移到 VolumeHUD.*
static void vhMigrateLegacyPreferences(void) {
    // 检查是否已经迁移过
    id migrated = (__bridge_transfer id)CFPreferencesCopyValue(
        (__bridge CFStringRef)@"VolumeHUD.MigratedFromGlassPrefix",
        (__bridge CFStringRef)LGPrefsDomain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (migrated && [migrated isKindOfClass:[NSNumber class]] && [migrated boolValue]) return;
    
    __block BOOL hasLegacy = NO;
    
    // 辅助函数：迁移单个 key
    void (^migrateKey)(NSString *, NSString *) = ^(NSString *oldKey, NSString *newKey) {
        id oldValue = (__bridge_transfer id)CFPreferencesCopyValue(
            (__bridge CFStringRef)oldKey,
            (__bridge CFStringRef)LGPrefsDomain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (oldValue) {
            CFPreferencesSetValue((__bridge CFStringRef)newKey,
                                  (__bridge CFPropertyListRef)oldValue,
                                  (__bridge CFStringRef)LGPrefsDomain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            hasLegacy = YES;
        }
    };
    
    // 音量 HUD
    migrateKey(@"VolumeHUDGlass.Enabled", @"VolumeHUD.Enabled");
    migrateKey(@"VolumeHUDGlass.CornerRadius", @"VolumeHUD.CornerRadius");
    migrateKey(@"VolumeHUDGlass.Blur", @"VolumeHUD.Blur");
    
    // 横屏音量
    migrateKey(@"LandscapeVolumeGlass.Enabled", @"LandscapeVolume.Enabled");
    migrateKey(@"LandscapeVolumeGlass.CornerRadius", @"LandscapeVolume.CornerRadius");
    migrateKey(@"LandscapeVolumeGlass.Blur", @"LandscapeVolume.Blur");
    
    // 标记已迁移
    CFPreferencesSetValue((__bridge CFStringRef)@"VolumeHUD.MigratedFromGlassPrefix",
                          kCFBooleanTrue,
                          (__bridge CFStringRef)LGPrefsDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    
    LGLog(@"VolumeHUD: Legacy preference migration completed (hadLegacy=%d)", hasLegacy);
}

#pragma mark - Constructor

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    
    // 迁移旧版本偏好
    vhMigrateLegacyPreferences();
    
    // 注册 Volume HUD 材质宿主
    // 覆盖：音量条 + 铃声/静音药丸
    // priority 设为 120，比 ControlCenter(110) 高，确保优先匹配
    LGRegisterMaterialHost(@"VolumeHUD", 120, ^BOOL(UIView *material) {
        return vhIsVolumeHUDMaterial(material);
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {
        return vhVolumeHUDCornerRadius(material);
    }, nil, ^void(UIView *material, LGLiveBackdropView *glass) {
        vhVolumeHUDPostInstall(material, glass);
    });
    
    lgObservePreferenceReload(^{
        LGLog(@"VolumeHUD: Preferences reloaded");
    });
}
