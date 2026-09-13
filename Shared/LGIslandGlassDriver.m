// =============================================================================
//  LGIslandGlassDriver.m — 灵动岛玻璃驱动实现（原版 Liquid (Gl)ass 架构）
//
//  完全复刻原版方式：
//  - 找到系统灵动岛幕布视图 (_SBSystemApertureMagiciansCurtainView)
//  - 将幕布视图背景设为透明
//  - 在幕布视图的 superview 上插入玻璃层（幕布下方）
//  - 玻璃尺寸和位置跟随幕布视图自动同步
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
static const void *kLGIslandOriginalBGKey = &kLGIslandOriginalBGKey;

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

    LGIslandLog(@"attachToCurtainView: %@ frame=%@ bounds=%@",
                 NSStringFromClass(curtainView.class),
                 NSStringFromCGRect(curtainView.frame),
                 NSStringFromCGRect(curtainView.bounds));

    // 如果之前挂载过，先卸载
    if (self.curtainView && self.curtainView != curtainView) {
        [self detach];
    }

    self.curtainView = curtainView;

    // 保存原始背景色
    UIColor *originalBG = objc_getAssociatedObject(curtainView, kLGIslandOriginalBGKey);
    if (!originalBG) {
        originalBG = curtainView.backgroundColor ?: [UIColor blackColor];
        objc_setAssociatedObject(curtainView, kLGIslandOriginalBGKey, originalBG,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 将幕布视图背景设为透明，让玻璃能透出来
    curtainView.backgroundColor = [UIColor clearColor];
    LGIslandLog(@"curtainView background set to clearColor");

    // 创建玻璃视图（加在 superview 上，在 curtainView 下方）
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

    LGIslandLog(@"attach complete: glass=%@", self.glass ? @"OK" : @"FAIL");
}

- (void)detach {
    LGIslandLog(@"detach");

    // 恢复原始背景色
    if (self.curtainView) {
        UIColor *originalBG = objc_getAssociatedObject(self.curtainView, kLGIslandOriginalBGKey);
        if (originalBG) {
            self.curtainView.backgroundColor = originalBG;
            LGIslandLog(@"restored original background color");
        }
    }

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

    UIView *containerView = self.curtainView.superview;
    if (!containerView) {
        LGIslandLog(@"ERROR: curtainView has no superview");
        return;
    }

    LGIslandLog(@"createGlassView in container: %@", NSStringFromClass(containerView.class));

    // 使用 island 滤镜类型（原版方式）
    NSString *filterType = LGFilterTypeForHostPrefix(@"Island");
    if (!filterType) {
        filterType = @"dylv.liquidglass.island";
    }
    LGIslandLog(@"  filterType: %@", filterType);

    // 计算玻璃的 frame（和 curtainView 一样的位置和大小）
    CGRect glassFrame = [containerView convertRect:self.curtainView.frame
                                       fromView:self.curtainView.superview];

    self.glass = [[LGLiveBackdropView alloc] initWithFrame:glassFrame
                                                groupName:@"IslandGlass"
                                               filterType:filterType];
    self.glass.autoresizingMask = UIViewAutoresizingNone;
    self.glass.alpha = 1.0;
    self.glass.userInteractionEnabled = NO;

    // 插入到 curtainView 的下方
    NSInteger curtainIndex = [containerView.subviews indexOfObject:self.curtainView];
    if (curtainIndex == NSNotFound) {
        curtainIndex = 0;
    }
    [containerView insertSubview:self.glass atIndex:curtainIndex];

    LGIslandLog(@"  glass inserted at index %ld, frame=%@",
                 (long)curtainIndex, NSStringFromCGRect(self.glass.frame));

    // 关联对象
    objc_setAssociatedObject(self.curtainView, kLGIslandGlassKey,
                             self.glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

    UIView *containerView = self.glass.superview;
    if (!containerView) return;

    // 同步玻璃的 frame 到 curtainView 的位置
    CGRect curtainFrame = self.curtainView.frame;
    CGFloat cornerRadius = CGRectGetHeight(curtainFrame) / 2.0;

    LGIslandLog(@"updateLayout: curtainFrame=%@ cornerRadius=%.1f",
                 NSStringFromCGRect(curtainFrame), cornerRadius);

    // 转换坐标到玻璃所在的容器视图
    CGRect glassFrame = [containerView convertRect:curtainFrame
                                       fromView:self.curtainView.superview];
    self.glass.frame = glassFrame;

    // 更新圆角
    self.glass.layer.cornerRadius = cornerRadius;
    self.glass.layer.masksToBounds = YES;

    // 重新应用滤镜
    [self.glass applyFilters];

    // 强制刷新 backdrop（灵动岛窗口特殊，需要强制重采样）
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
