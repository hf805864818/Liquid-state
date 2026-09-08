#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

@interface MTShadowView : UIImageView
@end

@interface CCUIContinuousSliderView : UIControl
@end

@interface SBElasticSliderView : CCUIContinuousSliderView
@end

@interface SBElasticVolumeSliderView : SBElasticSliderView
@end

@interface SBElasticSliderMaterialWrapperView : UIView {
    MTMaterialView *_captureOnlyMaterialView;
    MTMaterialView *_baseMaterialView;
    UIView *_shadowView;
    UIView *_sliderWrapperView;
    UIView *_maskView;
    SBElasticVolumeSliderView *_sliderView;
}
- (void)_setContinuousCornerRadius:(double)radius;
@end

@interface SBRingerPillView : UIView
@end

@interface PLPillContentView : UIView
@end

@interface PLPillView : UIView
@end

#pragma mark - Vibrance Views

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
        self.autoresizingMask = UIViewAutoresizingNone;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

@interface LGPillHUDVibranceView : UIView
@end

@implementation LGPillHUDVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingNone;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

#pragma mark - Probe Utils (forward declaration)
static void LGPrintViewHierarchy(UIView *view, NSString *indent);

#pragma mark - Volume HUD (Elastic Slider)

static const void * const kLGVolumeHUDGlassKey = &kLGVolumeHUDGlassKey;
static const void * const kLGVolumeHUDVibranceKey = &kLGVolumeHUDVibranceKey;

static BOOL LGVolumeHUDEnabled(void) {
    return LG_prefBool(@"VolumeHUDGlass.Enabled", NO);
}

static CGFloat LGVolumeHUDCornerRadius(CGRect bounds) {
    CGFloat prefRadius = LG_prefFloat(@"VolumeHUDGlass.CornerRadius", 20.0);
    // 如果用户设置了大于0的圆角，用用户的；否则保持药丸形（完全圆角）
    if (prefRadius > 0) {
        return prefRadius;
    }
    return MIN(bounds.size.width, bounds.size.height) * 0.5f;
}

static UIView *LGVolumeHUDSliderBackground(UIView *slider) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *subview in slider.subviews)
        if ([subview isKindOfClass:materialClass]) return subview;
    return nil;
}

static void LGUpdateVolumeHUDGlass(SBElasticSliderMaterialWrapperView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTMaterialView *cap = nil;
    UIView *shadow = nil;
    UIView *sliderWrapper = nil;
    UIView *sliderView = nil;
    @try {
        base = [self valueForKey:@"_baseMaterialView"];
        cap = [self valueForKey:@"_captureOnlyMaterialView"];
        shadow = [self valueForKey:@"_shadowView"];
        sliderWrapper = [self valueForKey:@"_sliderWrapperView"];
        sliderView = [self valueForKey:@"_sliderView"];
    } @catch (...) {}

    if (!LGVolumeHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGVolumeHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        if (cap) cap.hidden = NO;
        if (shadow) shadow.hidden = NO;
        if (sliderView) LGVolumeHUDSliderBackground(sliderView).hidden = NO;
        return;
    }

    if (base) base.hidden = YES;
    if (cap) cap.hidden = YES;
    if (shadow) shadow.hidden = YES;

    LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGVolumeHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (sliderWrapper) {
                [self insertSubview:vibrance belowSubview:sliderWrapper];
            } else {
                [self addSubview:vibrance];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"VolumeHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGVolumeHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"VolumeHUD", self);

        if (vibrance) {
            [self insertSubview:glass belowSubview:vibrance];
        } else if (sliderWrapper) {
            [self insertSubview:glass belowSubview:sliderWrapper];
        } else {
            [self addSubview:glass];
        }
    }

    CGFloat radius = LGVolumeHUDCornerRadius(self.bounds);

    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    if (vibrance) {
        vibrance.hidden = NO;
        vibrance.frame = self.bounds;
        vibrance.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.layer.masksToBounds = YES;
    }

    self.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (sliderWrapper) {
        sliderWrapper.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderWrapper.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderWrapper.layer.masksToBounds = YES;
    }

    if (sliderView) {
        UIView *sliderBg = LGVolumeHUDSliderBackground(sliderView);
        if (sliderBg) sliderBg.hidden = YES;
        sliderView.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderView.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderView.layer.masksToBounds = YES;
    }
}

%hook SBElasticSliderMaterialWrapperView

- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        LGLog(@"[VolumeHUD] initWithFrame: %@", NSStringFromCGRect(frame));
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (instancetype)initWithSliderView:(id)sliderView {
    self = %orig;
    if (self) {
        LGLog(@"[VolumeHUD] initWithSliderView: class=%@", NSStringFromClass([sliderView class]));
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (void)layoutSubviews {
    %orig;
    LGLog(@"[VolumeHUD] layoutSubviews bounds=%@ enabled=%d",
          NSStringFromCGRect(self.bounds), LGVolumeHUDEnabled());
    LGUpdateVolumeHUDGlass(self);
}

- (void)_setContinuousCornerRadius:(double)radius {
    if (LGVolumeHUDEnabled()) {
        CGFloat pillRadius = LGVolumeHUDCornerRadius(self.bounds);
        %orig((double)pillRadius);
        LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (glass) {
            glass.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                glass.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
        LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (vibrance) {
            vibrance.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                vibrance.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
    } else {
        %orig;
    }
}

%end

#pragma mark - Pill HUD (Ringer / Mute)

static const void * const kLGPillHUDGlassKey = &kLGPillHUDGlassKey;
static const void * const kLGPillHUDVibranceKey = &kLGPillHUDVibranceKey;

static BOOL LGPillHUDEnabled(void) {
    // 铃声药丸HUD复用VolumeHUD的开关设置
    return LG_prefBool(@"VolumeHUDGlass.Enabled", NO);
}

static CGFloat LGPillHUDCornerRadius(CGRect bounds) {
    CGFloat prefRadius = LG_prefFloat(@"VolumeHUDGlass.CornerRadius", 20.0);
    if (prefRadius > 0) {
        return prefRadius;
    }
    return MIN(bounds.size.width, bounds.size.height) * 0.5f;
}

static void LGUpdateRingerPillGlass(SBRingerPillView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTShadowView *shadow = nil;
    @try {
        base = [self valueForKey:@"_materialView"];
        shadow = [self valueForKey:@"_shadowView"];
    } @catch (...) {}

    if (!LGPillHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGPillHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        return;
    }

    if (base) base.hidden = YES;

    LGPillHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGPillHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGPillHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (shadow) {
                [self insertSubview:vibrance aboveSubview:shadow];
            } else {
                [self insertSubview:vibrance atIndex:0];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"VolumeHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGPillHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"VolumeHUD", self);

        if (vibrance) {
            [self insertSubview:glass belowSubview:vibrance];
        } else if (shadow) {
            [self insertSubview:glass aboveSubview:shadow];
        } else {
            [self insertSubview:glass atIndex:0];
        }
    }

    CGFloat radius = LGPillHUDCornerRadius(self.bounds);

    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    if (vibrance) {
        vibrance.hidden = NO;
        vibrance.frame = self.bounds;
        vibrance.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.layer.masksToBounds = YES;
    }

    self.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static void LGUpdatePLPillGlass(PLPillView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTShadowView *shadow = nil;
    UIView *contentView = nil;
    @try {
        base = [self valueForKey:@"_materialView"];
        shadow = [self valueForKey:@"_shadowView"];
        contentView = [self valueForKey:@"_contentView"];
    } @catch (...) {}

    if (!LGPillHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGPillHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        return;
    }

    if (base) base.hidden = YES;

    LGPillHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGPillHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGPillHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGPillHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (contentView) {
                [self insertSubview:vibrance belowSubview:contentView];
            } else if (shadow) {
                [self insertSubview:vibrance aboveSubview:shadow];
            } else {
                [self insertSubview:vibrance atIndex:0];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"VolumeHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGPillHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"VolumeHUD", self);

        if (vibrance) {
            [self insertSubview:glass belowSubview:vibrance];
        } else if (contentView) {
            [self insertSubview:glass belowSubview:contentView];
        } else if (shadow) {
            [self insertSubview:glass aboveSubview:shadow];
        } else {
            [self insertSubview:glass atIndex:0];
        }
    }

    CGFloat radius = LGPillHUDCornerRadius(self.bounds);

    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    if (vibrance) {
        vibrance.hidden = NO;
        vibrance.frame = self.bounds;
        vibrance.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.layer.masksToBounds = YES;
    }

    self.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

%hook SBRingerPillView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGLog(@"[PillProbe] SBRingerPillView didMoveToWindow  frame=%@  enabled=%d",
              NSStringFromCGRect(self.frame), LGPillHUDEnabled());
        // 打印所有 ivar
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([self class], &count);
        NSMutableArray *ivarNames = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            NSString *nsName = [NSString stringWithUTF8String:name];
            [ivarNames addObject:nsName];
        }
        free(ivars);
        LGLog(@"[PillProbe] SBRingerPillView ivars: %@", ivarNames);
        
        // 打印子视图层级
        LGPrintViewHierarchy(self, @"  ");
    }
}

- (void)layoutSubviews {
    %orig;
    LGUpdateRingerPillGlass(self);
}

%end

%hook PLPillView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGLog(@"[PillProbe] PLPillView didMoveToWindow  frame=%@  enabled=%d",
              NSStringFromCGRect(self.frame), LGPillHUDEnabled());
        // 打印所有 ivar
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([self class], &count);
        NSMutableArray *ivarNames = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            NSString *nsName = [NSString stringWithUTF8String:name];
            [ivarNames addObject:nsName];
        }
        free(ivars);
        LGLog(@"[PillProbe] PLPillView ivars: %@", ivarNames);
        
        // 打印子视图层级
        LGPrintViewHierarchy(self, @"  ");
    }
}

- (void)layoutSubviews {
    %orig;
    LGUpdatePLPillGlass(self);
}

%end

#pragma mark - iOS 17 Volume Slider Probe

// 遍历视图层级，打印包含 MTMaterialView 的父视图链
static void LGPrintViewHierarchy(UIView *view, NSString *indent) {
    if (!view) return;
    NSString *className = NSStringFromClass([view class]);
    NSString *frameStr = NSStringFromCGRect(view.frame);
    LGLog(@"[VolumeProbe] %@%@  frame=%@  hidden=%d  alpha=%.2f",
          indent, className, frameStr, view.hidden, view.alpha);
    
    // 检查是否有 MTMaterialView 子视图
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *subview in view.subviews) {
        if (materialClass && [subview isKindOfClass:materialClass]) {
            LGLog(@"[VolumeProbe] %@  -> contains MTMaterialView: %@",
                  indent, NSStringFromClass([subview class]));
        }
    }
    
    for (UIView *subview in view.subviews) {
        LGPrintViewHierarchy(subview, [indent stringByAppendingString:@"  "]);
    }
}

%hook SBElasticSliderView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGLog(@"[VolumeProbe] SBElasticSliderView didMoveToWindow");
        LGLog(@"[VolumeProbe]   self class: %@", NSStringFromClass([self class]));
        LGLog(@"[VolumeProbe]   self frame: %@", NSStringFromCGRect(self.frame));
        LGLog(@"[VolumeProbe]   superview class: %@", NSStringFromClass([self.superview class]));
        
        // 向上遍历父视图，找到包含 MTMaterialView 的容器
        UIView *current = self.superview;
        NSInteger level = 0;
        Class materialClass = NSClassFromString(@"MTMaterialView");
        while (current && level < 10) {
            BOOL hasMaterial = NO;
            for (UIView *subview in current.subviews) {
                if (materialClass && [subview isKindOfClass:materialClass]) {
                    hasMaterial = YES;
                    break;
                }
            }
            LGLog(@"[VolumeProbe]   level %ld: %@  frame=%@  hasMaterial=%d",
                  (long)level, NSStringFromClass([current class]),
                  NSStringFromCGRect(current.frame), hasMaterial);
            if (hasMaterial) {
                LGLog(@"[VolumeProbe]   *** Found material container at level %ld: %@",
                      (long)level, NSStringFromClass([current class]));
                LGPrintViewHierarchy(current, @"      ");
            }
            current = current.superview;
            level++;
        }
    }
}

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGLog(@"[VolumeHUD] VolumeHUD tweak loaded");
    LGLog(@"[VolumeHUD] SBElasticSliderMaterialWrapperView exists: %d",
          NSClassFromString(@"SBElasticSliderMaterialWrapperView") != nil);
    LGLog(@"[VolumeHUD] SBRingerPillView exists: %d",
          NSClassFromString(@"SBRingerPillView") != nil);
    LGLog(@"[VolumeHUD] PLPillView exists: %d",
          NSClassFromString(@"PLPillView") != nil);
    LGLog(@"[VolumeHUD] SBVolumeControl exists: %d",
          NSClassFromString(@"SBVolumeControl") != nil);
    LGLog(@"[VolumeHUD] SBHUDController exists: %d",
          NSClassFromString(@"SBHUDController") != nil);
    LGLog(@"[VolumeHUD] SBElasticSliderView exists: %d",
          NSClassFromString(@"SBElasticSliderView") != nil);
    LGLog(@"[VolumeHUD] SBElasticHUDViewController exists: %d",
          NSClassFromString(@"SBElasticHUDViewController") != nil);
    LGLog(@"[VolumeHUD] MRUVolumeView exists: %d",
          NSClassFromString(@"MRUVolumeView") != nil);
    LGLog(@"[VolumeHUD] MediaControlsVolumeContainerView exists: %d",
          NSClassFromString(@"MediaControlsVolumeContainerView") != nil);

    lgObservePreferenceReload(^{
        LGLog(@"VolumeHUD: Preferences reloaded");
    });
}
