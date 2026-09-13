// =============================================================================
//  LGIslandGlassDriver.m — 灵动岛玻璃驱动
//
//  先做最简验证：找到 curtain view 后把它染成红色，确认我们找对了视图
// =============================================================================

#import "LGIslandGlassDriver.h"
#import "LGSharedSupport.h"
#import "LGGlassKit.h"
#import "LGHostRegistry.h"
#import <objc/runtime.h>

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
    LGIslandLog(@"  frame=%@ bounds=%@ alpha=%.2f hidden=%d",
                 NSStringFromCGRect(curtainView.frame),
                 NSStringFromCGRect(curtainView.bounds),
                 curtainView.alpha, curtainView.hidden);
    LGIslandLog(@"  backgroundColor=%@", curtainView.backgroundColor);
    LGIslandLog(@"  subviews count=%lu", (unsigned long)curtainView.subviews.count);
    for (UIView *sv in curtainView.subviews) {
        LGIslandLog(@"    [%ld] %@ frame=%@ hidden=%d alpha=%.2f",
                     (long)[curtainView.subviews indexOfObject:sv],
                     NSStringFromClass(sv.class),
                     NSStringFromCGRect(sv.frame),
                     sv.hidden, sv.alpha);
    }

    // 如果之前挂载过，先卸载
    if (self.curtainView && self.curtainView != curtainView) {
        [self detach];
    }

    self.curtainView = curtainView;

    // ====== 第一步验证：把 curtainView 染成红色，确认找对了 ======
    curtainView.backgroundColor = [UIColor redColor];
    LGIslandLog(@"  TEST: set curtainView background to RED");

    // 同时也试试把子视图都设半透明，看看里面有什么
    for (UIView *sv in curtainView.subviews) {
        sv.alpha = 0.3;
    }

    // 创建玻璃视图
    [self createGlassView];

    // 初始布局
    [self updateLayout];

    // 关联对象
    objc_setAssociatedObject(curtainView, kLGIslandDriverKey, self,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LGIslandLog(@"attach complete: glass=%@", self.glass ? @"OK" : @"FAIL");
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

#pragma mark - 玻璃视图创建（最简版）

- (void)createGlassView {
    if (!self.curtainView) return;
    if (self.glass) return;

    LGIslandLog(@"createGlassView");

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

    // 放在最底层
    [self.curtainView insertSubview:self.glass atIndex:0];

    // 也给玻璃加个边框，确认它确实存在
    self.glass.layer.borderWidth = 2.0;
    self.glass.layer.borderColor = [UIColor greenColor].CGColor;

    LGIslandLog(@"  glass created at index 0, frame=%@", NSStringFromCGRect(self.glass.frame));
}

#pragma mark - 布局更新

- (void)updateLayout {
    if (!self.curtainView || !self.layoutEnabled) return;
    if (!self.glass) return;

    CGRect bounds = self.curtainView.bounds;
    CGFloat cornerRadius = CGRectGetHeight(bounds) / 2.0;

    LGIslandLog(@"updateLayout: bounds=%@ cornerRadius=%.1f",
                 NSStringFromCGRect(bounds), cornerRadius);

    self.glass.frame = bounds;
    self.glass.layer.cornerRadius = cornerRadius;
    self.glass.layer.masksToBounds = YES;

    [self.glass applyFilters];
    [self.glass lgForceRefreshBackdrop];
}

- (void)setHideWhenInactive:(BOOL)hidden {
    if (self.glass) {
        self.glass.hidden = hidden;
    }
}

- (BOOL)isSystemIslandActive {
    if (!self.curtainView) return NO;
    CGFloat w = CGRectGetWidth(self.curtainView.bounds);
    CGFloat h = CGRectGetHeight(self.curtainView.bounds);
    return (w > 100.0 || h > 50.0);
}

- (void)refreshConfiguration {
    LGIslandLog(@"refreshConfiguration");
    if (self.glass) {
        [self.glass applyFilters];
        [self.glass lgForceRefreshBackdrop];
    }
    [self updateLayout];
}

@end
