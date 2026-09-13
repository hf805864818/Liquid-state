// =============================================================================
//  LGDI2View.m — 灵动岛2 自定义视图实现
//
//  复用 LGLiveBackdropView 液态玻璃渲染引擎
//  使用 DynamicIsland2 宿主参数（与 DI1 参数完全一致）
//  按 Banana deb 方式：不做锁屏检测，HideWhenInactive 单一开关
// =============================================================================

#import "LGDI2View.h"
#import "LGGlassKit.h"
#import "LGHostRegistry.h"
#import "LGSharedSupport.h"
#import "LGDI2Mutex.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#ifndef LIQUIDASS_DEBUG
#define LIQUIDASS_DEBUG 0
#endif

static void LGDI2Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDI2Log(NSString *fmt, ...) {
#if LIQUIDASS_DEBUG
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI2] %@", s);
#else
    (void)fmt;
#endif
}

@interface LGDI2View ()
@property (nonatomic, strong) LGLiveBackdropView *glassView;
@property (nonatomic, strong) LGLiveBackdropView *expandedGlassView;
@property (nonatomic, strong) UIVisualEffectView *expandedBlurView;
@property (nonatomic, strong) CALayer *centerCover;
@property (nonatomic, assign) CGFloat currentHeight;
@property (nonatomic, assign) CGFloat currentWidth;
@property (nonatomic, strong) NSTimer *layoutSyncTimer;
@end

@implementation LGDI2View

+ (instancetype)installInSuperview:(UIView *)superview
                       filterPrefix:(NSString *)prefix {
    LGDI2Log(@"installInSuperview: prefix=%@", prefix);

    LGDI2View *view = [[LGDI2View alloc] initWithFrame:CGRectZero];
    view.layoutMode = LGDI2LayoutModeCompact;

    // 创建 compact pill 玻璃
    view.glassView = LGCreateRegisteredGlass(
        CGRectZero,
        @"dylv.liquidglass.island2",  // 独立 backdrop group
        prefix);
    if (view.glassView) {
        [view addSubview:view.glassView];
        LGDI2Log(@"glassView created successfully");
    } else {
        LGDI2Log(@"ERROR: glassView creation failed!");
    }

    // 中心遮罩（compact 模式下保持系统黑色中心条外观）
    view.centerCover = [CALayer layer];
    view.centerCover.backgroundColor = [UIColor blackColor].CGColor;
    view.centerCover.cornerRadius = 0;
    [view.glassView.layer addSublayer:view.centerCover];

    [superview addSubview:view];
    [view updateLayout];

    return view;
}

- (void)updateLayout {
    if (!self.superview) return;

    CGFloat screenWidth = CGRectGetWidth(self.superview.bounds);
    CGFloat di1BottomY = [self lgCalculateDI1BottomY];

    // 读取偏好参数
    CGFloat offsetY = LG_prefFloat(@"DynamicIsland2.OffsetY", 16.0);
    CGFloat widthRatio = LG_prefFloat(@"DynamicIsland2.WidthRatio", 0.78);
    CGFloat height = LG_prefFloat(@"DynamicIsland2.Height", 37.0);
    CGFloat cornerRadius = LG_prefFloat(@"DynamicIsland2.CornerRadius", 18.5);

    BOOL hideWhenInactive = LG_prefBool(@"DynamicIsland2.HideWhenInactive", YES);

    if (self.layoutMode == LGDI2LayoutModeExpanded) {
        height = LG_prefFloat(@"DynamicIsland2.ExpandedHeight", 160.0);
        cornerRadius = LG_prefFloat(@"DynamicIsland2.ExpandedCornerRadius", 24.0);
    }

    // [Banana deb] hideWhenInactive: 系统灵动岛处于 inert/minimal 时隐藏 DI2
    if (hideWhenInactive) {
        BOOL systemDIActive = [self lgIsSystemDIActive];
        self.hidden = !systemDIActive;
    } else {
        self.hidden = NO;
    }

    // 如果隐藏了，不需要更新布局
    if (self.hidden) {
        LGDI2Log(@"updateLayout: hidden (hideWhenInactive=%d)", hideWhenInactive);
        return;
    }

    self.currentWidth = screenWidth * widthRatio;
    self.currentHeight = height;

    CGFloat x = (screenWidth - self.currentWidth) / 2.0;
    CGFloat y = di1BottomY + offsetY;

    self.frame = CGRectMake(x, y, self.currentWidth, self.currentHeight);

    // 同步玻璃 frame（安全检查 glassView 非空）
    if (self.glassView) {
        self.glassView.frame = self.bounds;
    }

    if (self.expandedGlassView) {
        self.expandedGlassView.frame = self.bounds;
    }

    // 中心遮罩（仅 compact 模式）
    if (self.layoutMode == LGDI2LayoutModeCompact) {
        CGFloat endW = self.currentHeight / 2.0;
        CGFloat centerW = self.currentWidth - 2.0 * endW;
        self.centerCover.frame = CGRectMake(endW, 0, centerW, self.currentHeight);
        self.centerCover.hidden = NO;

        BOOL showCenterBar = LG_prefBool(@"DynamicIsland2.ShowCenterBar", YES);
        self.centerCover.hidden = !showCenterBar;
    } else {
        self.centerCover.hidden = YES;
    }

    // 圆角
    self.layer.cornerRadius = cornerRadius;
    self.layer.masksToBounds = YES;
    if (self.glassView) {
        self.glassView.layer.cornerRadius = cornerRadius;
        self.glassView.layer.masksToBounds = YES;
    }

    if (self.expandedGlassView) {
        self.expandedGlassView.layer.cornerRadius = cornerRadius;
        self.expandedGlassView.layer.masksToBounds = YES;
    }

    // 强制 backdrop 刷新（安全检查）
    if (self.glassView) {
        [self.glassView lgForceRefreshBackdrop];
        [self.glassView applyFilters];
    }

    LGDI2Log(@"updateLayout: frame=%@ mode=%ld hideInactive=%d",
              NSStringFromCGRect(self.frame), (long)self.layoutMode, hideWhenInactive);
}

// [Banana deb] 检测系统灵动岛是否处于活动状态
// compact (长药丸) / expanded (展开卡片) = 活动
// inert (默认小药丸) / minimal (极小) = 不活动
- (BOOL)lgIsSystemDIActive {
    UIWindow *apertureWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([NSStringFromClass(w.class) containsString:@"Aperture"]) {
            apertureWindow = w;
            break;
        }
    }
    if (!apertureWindow) return NO;

    CGFloat w = CGRectGetWidth(apertureWindow.bounds);
    CGFloat h = CGRectGetHeight(apertureWindow.bounds);
    // inert/minimal 时窗口极小（约 36x37），compact 时宽度 > 120
    BOOL active = (w > 100.0 || h > 50.0);
    LGDI2Log(@"lgIsSystemDIActive: aperture=%.1fx%.1f active=%d", w, h, active);
    return active;
}

// 计算 DI1 底边 Y 坐标
- (CGFloat)lgCalculateDI1BottomY {
    // 方案1：读系统灵动岛窗口的实际 frame
    UIWindow *apertureWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([NSStringFromClass(w.class) containsString:@"Aperture"]) {
            apertureWindow = w;
            break;
        }
    }
    if (apertureWindow) {
        CGFloat bottom = CGRectGetMaxY(apertureWindow.frame);
        LGDI2Log(@"DI1 bottom Y from aperture window: %.1f", bottom);
        return bottom;
    }

    // 方案2：回退到状态栏高度 + 默认药丸高度
    CGFloat statusBarH = CGRectGetHeight(
        [UIApplication sharedApplication].statusBarFrame);
    if (statusBarH < 1) statusBarH = 54.0; // fallback
    CGFloat di1Height = 37.0; // 默认药丸高度
    CGFloat bottom = statusBarH + di1Height;
    LGDI2Log(@"DI1 bottom Y fallback: %.1f (statusBar=%.1f + pill=%.1f)",
              bottom, statusBarH, di1Height);
    return bottom;
}

- (void)refreshConfiguration {
    LGDI2Log(@"refreshConfiguration");
    [self updateLayout];
    if (self.glassView) {
        [self.glassView lgForceRefreshBackdrop];
        [self.glassView applyFilters];
    }
}

- (void)switchToMode:(LGDI2LayoutMode)mode animated:(BOOL)animated {
    if (mode == self.layoutMode) return;

    LGDI2Log(@"switchToMode: %ld -> %ld animated=%d",
              (long)self.layoutMode, (long)mode, animated);

    // [防闪烁] 原子切换：禁用隐式动画
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];

    self.layoutMode = mode;

    if (mode == LGDI2LayoutModeExpanded) {
        // compact → expanded
        if (self.glassView) self.glassView.hidden = YES;

        if (!self.expandedGlassView) {
            self.expandedGlassView = LGCreateRegisteredGlass(
                self.bounds,
                @"dylv.liquidglass.island2.expanded",
                @"DynamicIsland2");
            if (self.expandedGlassView) {
                [self addSubview:self.expandedGlassView];

                // 原生模糊底板
                UIBlurEffect *blur = [UIBlurEffect effectWithStyle:
                    UIBlurEffectStyleSystemMaterial];
                self.expandedBlurView = [[UIVisualEffectView alloc]
                    initWithEffect:blur];
                self.expandedBlurView.frame = self.bounds;
                self.expandedBlurView.alpha = 0.0;
                [self insertSubview:self.expandedBlurView
                         belowSubview:self.expandedGlassView];
            }
        }

        if (self.expandedGlassView) {
            self.expandedGlassView.hidden = NO;
            self.expandedBlurView.alpha = 1.0;
        }
    } else {
        // expanded → compact
        if (self.expandedGlassView) self.expandedGlassView.hidden = YES;
        if (self.expandedBlurView) self.expandedBlurView.alpha = 0.0;
        if (self.glassView) self.glassView.hidden = NO;
    }

    [CATransaction commit];

    [self updateLayout];

    // 强制 backdrop 刷新
    if (self.glassView) {
        [self.glassView lgForceRefreshBackdrop];
        [self.glassView applyFilters];
    }
    if (self.expandedGlassView && !self.expandedGlassView.hidden) {
        [self.expandedGlassView lgForceRefreshBackdrop];
        [self.expandedGlassView applyFilters];
    }
}

- (void)startLayoutSyncTimer {
    [self.layoutSyncTimer invalidate];
    self.layoutSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          target:self
                                                        selector:@selector(updateLayout)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)uninstall {
    LGDI2Log(@"uninstall");
    [self.layoutSyncTimer invalidate];
    self.layoutSyncTimer = nil;

    [self.glassView removeFromSuperview];
    self.glassView = nil;

    [self.expandedGlassView removeFromSuperview];
    self.expandedGlassView = nil;

    [self.expandedBlurView removeFromSuperview];
    self.expandedBlurView = nil;

    self.centerCover = nil;

    [self removeFromSuperview];
}

@end
