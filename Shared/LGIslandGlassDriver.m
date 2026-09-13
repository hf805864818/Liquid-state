// =============================================================================
//  LGIslandGlassDriver.m — 灵动岛玻璃驱动实现（原版 Liquid (Gl)ass 架构）
//
//  完全复刻原版方式：直接在系统灵动岛幕布视图上注入玻璃层
// =============================================================================

#import "LGIslandGlassDriver.h"
#import "LGSharedSupport.h"
#import "LGGlassKit.h"
#import "LGHostRegistry.h"
#import <objc/runtime.h>

#ifndef LIQUIDASS_DEBUG
#define LIQUIDASS_DEBUG 0
#endif

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

    // 如果之前挂载过，先卸载
    if (self.curtainView && self.curtainView != curtainView) {
        [self detach];
    }

    self.curtainView = curtainView;

    // 创建玻璃视图
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
}

- (void)detach {
    LGIslandLog(@"detach");

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

#pragma mark - 玻璃视图创建

- (void)createGlassView {
    if (!self.curtainView) return;
    if (self.glass) return;

    LGIslandLog(@"createGlassView");

    // 使用 island 滤镜类型（原版方式）
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    if (!filterType) {
        filterType = @"dylv.liquidglass.island";
    }

    self.glass = [[LGLiveBackdropView alloc] initWithFrame:self.curtainView.bounds
                                                groupName:@"IslandGlass"
                                               filterType:filterType];
    self.glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    self.glass.alpha = 1.0;

    // 插入到幕布视图的最底层（在系统内容下方）
    [self.curtainView insertSubview:self.glass atIndex:0];

    // 关联对象
    objc_setAssociatedObject(self.curtainView, kLGIslandGlassKey,
                             self.glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LGIslandLog(@"glass view created: %@", NSStringFromCGRect(self.glass.frame));
}

#pragma mark - 增益图层创建（液态高光效果）

- (void)createGainMapLayer {
    if (!self.curtainView) return;
    if (self.gainMapLayer) return;

    LGIslandLog(@"createGainMapLayer");

    self.gainMapLayer = [CALayer layer];
    self.gainMapLayer.name = @"LGIslandGainMapLayer";
    self.gainMapLayer.opacity = 0.3;

    // 创建渐变层模拟增益图效果
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.6].CGColor,
        (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.2].CGColor,
        (__bridge id)[UIColor clearColor].CGColor
    ];
    gradient.locations = @[@0.0, @0.5, @1.0];
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);
    [self.gainMapLayer addSublayer:gradient];

    [self.curtainView.layer addSublayer:self.gainMapLayer];
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
    topRim.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    [self.curtainView.layer addSublayer:topRim];
    [layers addObject:topRim];

    self.rimLayers = [layers copy];
}

#pragma mark - 布局更新

- (void)updateLayout {
    if (!self.curtainView || !self.layoutEnabled) return;

    CGRect bounds = self.curtainView.bounds;
    CGFloat cornerRadius = CGRectGetHeight(bounds) / 2.0;

    LGIslandLog(@"updateLayout: bounds=%@ cornerRadius=%.1f",
                NSStringFromCGRect(bounds), cornerRadius);

    // 更新玻璃视图
    if (self.glass) {
        self.glass.frame = bounds;
        self.glass.layer.cornerRadius = cornerRadius;
        self.glass.layer.masksToBounds = YES;
        [self.glass applyFilters];
    }

    // 更新增益图层
    if (self.gainMapLayer) {
        self.gainMapLayer.frame = bounds;
        self.gainMapLayer.cornerRadius = cornerRadius;
        self.gainMapLayer.masksToBounds = YES;

        for (CALayer *sublayer in self.gainMapLayer.sublayers) {
            sublayer.frame = self.gainMapLayer.bounds;
        }
    }

    // 更新边缘高光层
    if (self.rimLayers.count > 0) {
        CALayer *topRim = self.rimLayers.firstObject;
        topRim.frame = CGRectMake(0, 0, CGRectGetWidth(bounds), 1.5);
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
    }

    [self updateLayout];
}

@end
