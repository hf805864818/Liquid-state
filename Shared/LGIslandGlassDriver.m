// =============================================================================
//  LGIslandGlassDriver.m — 灵动岛玻璃驱动实现（原版 Liquid (Gl)ass 架构）
//
//  复刻原版实现方式：
//  - 玻璃是 _SBSystemApertureMagiciansCurtainView 的子视图
//  - 隐藏系统的 material（黑色背景），让玻璃透出来
//  - 玻璃视图跟随 curtainView 的 bounds 自动适配
// =============================================================================

#import "LGIslandGlassDriver.h"
#import "LGSharedSupport.h"
#import "LGGlassKit.h"
#import "LGHostRegistry.h"
#import <objc/runtime.h>

// 强制开启调试
#define LIQUIDASS_DEBUG 1

static void LGIslandLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGIslandLog(NSString *fmt, ...) {
#if LIQUIDASS_DEBUG
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[IslandGlass] %@", s);
#else
    (void)fmt;
#endif
}

static const void *kLGIslandGlassKey = &kLGIslandGlassKey;
static const void *kLGIslandDriverKey = &kLGIslandDriverKey;
static const void *kLGIslandMaterialHiddenKey = &kLGIslandMaterialHiddenKey;
static const void *kLGIslandOriginalSubviewsKey = &kLGIslandOriginalSubviewsKey;

@implementation LGIslandGlassDriver

+ (instancetype)sharedDriver {
    static LGIslandGlassDriver *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LGIslandGlassDriver alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _layoutEnabled = YES;
        _rimLayers = @[];
    }
    return self;
}

#pragma mark - 挂载/卸载

- (void)attachToCurtainView:(UIView *)curtainView {
    if (!curtainView) return;
    if (self.curtainView == curtainView && self.glass) return;

    LGIslandLog(@"attachToCurtainView: %@", NSStringFromClass(curtainView.class));
    LGIslandLog(@"  frame=%@ bounds=%@",
                 NSStringFromCGRect(curtainView.frame),
                 NSStringFromCGRect(curtainView.bounds));
    LGIslandLog(@"  subviews count=%lu", (unsigned long)curtainView.subviews.count);
    for (UIView *sv in curtainView.subviews) {
        LGIslandLog(@"    subview: %@ frame=%@",
                     NSStringFromClass(sv.class), NSStringFromCGRect(sv.frame));
    }

    // 如果之前挂载过，先卸载
    if (self.curtainView && self.curtainView != curtainView) {
        [self detach];
    }

    self.curtainView = curtainView;

    // 隐藏系统黑色背景（material），这是原版的关键
    [self hideSystemMaterial];

    // 创建玻璃视图（直接加在 curtainView 内部，最底层）
    [self createGlassView];

    // 创建增益图层
    [self createGainMapLayer];

    // 创建边缘高光层
    [self createRimLayers];

    // 初始布局
    [self updateLayout];

    // 关联对象（防止重复创建）
    objc_setAssociatedObject(curtainView, kLGIslandDriverKey, self,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LGIslandLog(@"attach complete");
}

- (void)detach {
    LGIslandLog(@"detach");

    // 恢复系统 material
    [self restoreSystemMaterial];

    if (self.glass) {
        [self.glass removeFromSuperview];
        self.glass = nil;
    }
    if (self.gainMapLayer) {
        [self.gainMapLayer removeFromSuperlayer];
        self.gainMapLayer = nil;
    }
    for (CALayer *layer in self.rimLayers) {
        [layer removeFromSuperlayer];
    }
    self.rimLayers = @[];
    self.curtainView = nil;
}

#pragma mark - 隐藏/恢复系统 material

- (void)hideSystemMaterial {
    if (!self.curtainView) return;

    NSNumber *alreadyHidden = objc_getAssociatedObject(self.curtainView,
                                                        kLGIslandMaterialHiddenKey);
    if (alreadyHidden.boolValue) {
        LGIslandLog(@"material already hidden, skipping");
        return;
    }

    LGIslandLog(@"hideSystemMaterial: finding material views");

    // 递归查找并隐藏 MTMaterialView 或类似的材质视图
    [self hideMaterialInView:self.curtainView];

    // 也试试把 curtainView 本身的背景设为透明
    if (self.curtainView.backgroundColor) {
        LGIslandLog(@"  curtainView had backgroundColor, setting to clear");
        self.curtainView.backgroundColor = [UIColor clearColor];
    }

    objc_setAssociatedObject(self.curtainView, kLGIslandMaterialHiddenKey,
                             @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LGIslandLog(@"hideSystemMaterial complete");
}

- (void)hideMaterialInView:(UIView *)view {
    if (!view) return;

    NSString *className = NSStringFromClass(view.class);

    // 材质视图类名特征
    BOOL isMaterial = ([className containsString:@"Material"] ||
                       [className containsString:@"Backdrop"] ||
                       [className containsString:@"Vibrancy"]);

    if (isMaterial && view != self.glass) {
        LGIslandLog(@"  hiding material view: %@ (hidden was %d)",
                     className, view.hidden);
        view.hidden = YES;
    }

    for (UIView *subview in view.subviews) {
        [self hideMaterialInView:subview];
    }
}

- (void)restoreSystemMaterial {
    if (!self.curtainView) return;

    NSNumber *alreadyHidden = objc_getAssociatedObject(self.curtainView,
                                                        kLGIslandMaterialHiddenKey);
    if (!alreadyHidden.boolValue) return;

    LGIslandLog(@"restoreSystemMaterial");

    [self restoreMaterialInView:self.curtainView];

    objc_setAssociatedObject(self.curtainView, kLGIslandMaterialHiddenKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)restoreMaterialInView:(UIView *)view {
    if (!view) return;

    NSString *className = NSStringFromClass(view.class);
    BOOL isMaterial = ([className containsString:@"Material"] ||
                       [className containsString:@"Backdrop"] ||
                       [className containsString:@"Vibrancy"]);

    if (isMaterial && view != self.glass) {
        view.hidden = NO;
    }

    for (UIView *subview in view.subviews) {
        [self restoreMaterialInView:subview];
    }
}

#pragma mark - 玻璃视图创建

- (void)createGlassView {
    if (!self.curtainView) return;
    if (self.glass) return;

    LGIslandLog(@"createGlassView inside curtainView");

    // 使用 island 滤镜类型（原版方式）
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    if (!filterType) {
        filterType = @"dylv.liquidglass.island";
    }
    LGIslandLog(@"  filterType: %@", filterType);

    self.glass = [[LGLiveBackdropView alloc] initWithFrame:self.curtainView.bounds
                                                groupName:@"IslandGlass"
                                               filterType:filterType];
    self.glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    self.glass.alpha = 1.0;
    self.glass.userInteractionEnabled = NO;

    // 插入到 curtainView 的最底层
    [self.curtainView insertSubview:self.glass atIndex:0];

    // 关联对象
    objc_setAssociatedObject(self.curtainView, kLGIslandGlassKey,
                             self.glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LGIslandLog(@"  glass inserted at index 0");
}

#pragma mark - 增益图层创建（液态高光效果）

- (void)createGainMapLayer {
    if (!self.curtainView) return;
    if (self.gainMapLayer) return;

    LGIslandLog(@"createGainMapLayer");

    self.gainMapLayer = [CALayer layer];
    self.gainMapLayer.name = @"LGIslandGainMapLayer";
    self.gainMapLayer.opacity = 0.25;
    self.gainMapLayer.zPosition = 0.1;

    // 创建渐变层模拟增益图效果
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.5].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.15].CGColor,
        (__bridge id)[UIColor clearColor].CGColor
    ];
    gradient.locations = @[@0.0, @0.4, @1.0];
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);
    [self.gainMapLayer addSublayer:gradient];

    if (self.glass) {
        [self.glass.layer addSublayer:self.gainMapLayer];
    }
}

#pragma mark - 边缘高光层

- (void)createRimLayers {
    if (!self.curtainView) return;
    if (self.rimLayers.count > 0) return;

    LGIslandLog(@"createRimLayers");

    NSMutableArray *layers = [NSMutableArray array];

    // 顶部边缘高光
    CALayer *topRim = [CALayer layer];
    topRim.name = @"LGIslandRimTop";
    topRim.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    topRim.zPosition = 0.2;
    if (self.glass) {
        [self.glass.layer addSublayer:topRim];
    }
    [layers addObject:topRim];

    self.rimLayers = [layers copy];
}

#pragma mark - 布局更新

- (void)updateLayout {
    if (!self.curtainView || !self.layoutEnabled) return;
    if (!self.glass) return;

    CGRect bounds = self.curtainView.bounds;
    CGFloat cornerRadius = CGRectGetHeight(bounds) / 2.0;

    LGIslandLog(@"updateLayout: bounds=%@ cornerRadius=%.1f",
                 NSStringFromCGRect(bounds), cornerRadius);

    // 玻璃充满整个 curtainView
    self.glass.frame = bounds;
    self.glass.layer.cornerRadius = cornerRadius;
    self.glass.layer.masksToBounds = YES;

    // 应用滤镜
    [self.glass applyFilters];

    // 强制刷新 backdrop
    [self.glass lgForceRefreshBackdrop];

    // 更新增益图层
    if (self.gainMapLayer) {
        self.gainMapLayer.frame = self.glass.bounds;
        self.gainMapLayer.cornerRadius = cornerRadius;
        self.gainMapLayer.masksToBounds = YES;

        for (CALayer *sublayer in self.gainMapLayer.sublayers) {
            sublayer.frame = self.gainMapLayer.bounds;
        }
    }

    // 更新边缘高光层
    if (self.rimLayers.count > 0) {
        CALayer *topRim = self.rimLayers.firstObject;
        topRim.frame = CGRectMake(0, 0, CGRectGetWidth(self.glass.bounds), 1.0);
        topRim.cornerRadius = cornerRadius;
        topRim.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    }

    // HideWhenInactive 处理
    BOOL hideWhenInactive = LG_prefBool(@"DynamicIsland2.HideWhenInactive", NO);
    if (hideWhenInactive) {
        BOOL active = [self isSystemIslandActive];
        [self setHideWhenInactive:!active];
    } else {
        [self setHideWhenInactive:NO];
    }
}

#pragma mark - 显示/隐藏

- (void)setHideWhenInactive:(BOOL)hidden {
    if (self.glass) {
        self.glass.hidden = hidden;
    }
    if (self.gainMapLayer) {
        self.gainMapLayer.hidden = hidden;
    }
    for (CALayer *layer in self.rimLayers) {
        layer.hidden = hidden;
    }
}

#pragma mark - 系统灵动岛活动状态检测

- (BOOL)isSystemIslandActive {
    if (!self.curtainView) return NO;

    CGFloat w = CGRectGetWidth(self.curtainView.bounds);
    CGFloat h = CGRectGetHeight(self.curtainView.bounds);

    // inert/minimal 时尺寸极小（约 36x37），compact 时宽度 > 120
    BOOL active = (w > 100.0 || h > 50.0);

    LGIslandLog(@"isSystemIslandActive: size=%.1fx%.1f active=%d", w, h, active);
    return active;
}

#pragma mark - 配置刷新

- (void)refreshConfiguration {
    LGIslandLog(@"refreshConfiguration");

    if (self.glass) {
        [self.glass applyFilters];
        [self.glass lgForceRefreshBackdrop];
    }

    [self updateLayout];
}

@end
