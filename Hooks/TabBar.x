#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGLiquidMotion.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGSharedSupport.h"

static const void *kLGTabBarPendingDumpKey = &kLGTabBarPendingDumpKey;
static const void *kLGTabBarLastSignatureKey = &kLGTabBarLastSignatureKey;
static const void *kLGTabBarGlassKey = &kLGTabBarGlassKey;
static const void *kLGTabBarStylingKey = &kLGTabBarStylingKey;
static const void *kLGTabBarSelectedHighlightKey = &kLGTabBarSelectedHighlightKey;
static const void *kLGTabBarSelectionGlassKey = &kLGTabBarSelectionGlassKey;
static const void *kLGTabBarSelectionAnimatorKey = &kLGTabBarSelectionAnimatorKey;
static const void *kLGTabBarMotionStateKey = &kLGTabBarMotionStateKey;
static const void *kLGTabBarBlueOverlayKey = &kLGTabBarBlueOverlayKey;
static const void *kLGTabBarBlueContentKey = &kLGTabBarBlueContentKey;
static const void *kLGTabBarAccentColorKey = &kLGTabBarAccentColorKey;
static const void *kLGTabBarOriginalTintKey = &kLGTabBarOriginalTintKey;
static const void *kLGTabBarOriginalBackgroundHiddenKey =
    &kLGTabBarOriginalBackgroundHiddenKey;
static const void *kLGTabBarOriginalClipsKey = &kLGTabBarOriginalClipsKey;
static const void *kLGTabBarOriginalMasksKey = &kLGTabBarOriginalMasksKey;
static const CGFloat kLGTabBarHighlightHeight = 54.0;
static const CGFloat kLGTabBarLensWidth = 94.0;
static const CGFloat kLGTabBarLensHeight = 72.0;

@interface UITabBarButton : UIControl
@end

@interface LGTabBarMotionState : NSObject
@property (nonatomic, weak) UITabBar *bar;
@property (nonatomic, weak) LGLiveBackdropView *lens;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) CGFloat targetCenterX;
@property (nonatomic, assign) CGFloat targetWidth;
@property (nonatomic, assign) CGFloat targetHeight;
@property (nonatomic, assign) CGFloat renderedCenterX;
@property (nonatomic, assign) CGFloat renderedWidth;
@property (nonatomic, assign) CGFloat renderedHeight;
@property (nonatomic, assign) CGFloat widthVelocity;
@property (nonatomic, assign) CGFloat heightVelocity;
@property (nonatomic, assign) CGFloat velocityX;
@property (nonatomic, assign) CGFloat gestureStartX;
@property (nonatomic, assign) BOOL dragged;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign) BOOL awaitingTapDestination;
@property (nonatomic, assign) BOOL awaitingRestingShape;
@property (nonatomic, assign) CGFloat restingTargetWidth;
@property (nonatomic, assign) CGFloat collapseStartDistance;
@property (nonatomic, assign) CFTimeInterval destinationStartTime;
@property (nonatomic, assign) CGFloat lastTouchX;
@property (nonatomic, assign) CFTimeInterval lastTouchTime;
@property (nonatomic, assign) CFTimeInterval lastDisplayTime;
- (void)start;
- (void)stop;
@end

static CGRect LGTabBarPillFrame(UITabBar *bar);
static LGLiveBackdropView *LGTabBarSelectionLens(UITabBar *bar);
static LGTabBarMotionState *LGTabBarMotionStateForBar(UITabBar *bar,
                                                       BOOL create);
static void LGPersistTabBarDump(NSString *dump, NSString *reason);
static void LGPositionTabBarBlueOverlay(UITabBar *bar,
                                        LGLiveBackdropView *lens);
static UIView *LGTabBarBlueOverlay(UITabBar *bar, BOOL create);
static void LGFinalizeTabBarSelection(UITabBar *bar,
                                      LGLiveBackdropView *lens,
                                      LGTabBarMotionState *state);

@implementation LGTabBarMotionState

static inline CGFloat LGTabBarSpringStep(CGFloat current,
                                         CGFloat target,
                                         CGFloat *velocity,
                                         CGFloat response,
                                         CGFloat dampingRatio,
                                         CGFloat dt) {
    CGFloat remaining = fmin(fmax(dt, 0.0), 1.0 / 30.0);
    while (remaining > 0.0) {
        CGFloat step = fmin(remaining, 1.0 / 120.0);
        CGFloat omega = 2.0 * M_PI / response;
        CGFloat acceleration =
            (target - current) * omega * omega -
            2.0 * dampingRatio * omega * (*velocity);
        *velocity += acceleration * step;
        current += *velocity * step;
        remaining -= step;
    }
    return current;
}

- (void)start {
    if (self.displayLink) return;
    self.lastDisplayTime = 0.0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(tick:)];
    self.displayLink.preferredFramesPerSecond = 60; // 60fps is smooth enough for lens animation
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.lastDisplayTime = 0.0;
}

- (void)tick:(CADisplayLink *)link {
    LGLiveBackdropView *lens = self.lens;
    UITabBar *bar = self.bar;
    if (!lens || !bar || lens.hidden) {
        [self stop];
        return;
    }
    CFTimeInterval dt = self.lastDisplayTime > 0.0
        ? link.timestamp - self.lastDisplayTime : 1.0 / 60.0;
    self.lastDisplayTime = link.timestamp;
    LGLiquidRenderedState current =
        LGLiquidRenderedStateMake(self.renderedCenterX,
                                  CGSizeMake(self.renderedWidth,
                                             self.renderedHeight));
    LGLiquidRenderedState target =
        LGLiquidRenderedStateMake(self.targetCenterX,
                                  CGSizeMake(self.targetWidth,
                                             self.targetHeight));
    LGLiquidRenderedState next =
        LGLiquidRenderedStateStep(current, target, self.active, dt);
    CGFloat response = self.active ? 0.155 : 0.135;
    next.width = LGTabBarSpringStep(current.width, target.width,
                                    &_widthVelocity, response, 1.0, dt);
    next.height = LGTabBarSpringStep(current.height, target.height,
                                     &_heightVelocity, response, 1.0, dt);
    self.renderedCenterX = next.centerX;
    self.renderedWidth = next.width;
    self.renderedHeight = next.height;
    lens.bounds = CGRectMake(0.0, 0.0, next.width, next.height);
    lens.center = CGPointMake(next.centerX,
                              CGRectGetMidY(LGTabBarPillFrame(bar)));
    lens.layer.cornerRadius = next.height * 0.5;
    LGPositionTabBarBlueOverlay(bar, lens);

    if (self.awaitingTapDestination) {
        BOOL arrived =
            fabs(next.centerX - self.targetCenterX) < 1.0 &&
            fabs(next.width - kLGTabBarLensWidth) < 1.0 &&
            fabs(next.height - kLGTabBarLensHeight) < 1.0;
        BOOL timedOut =
            CACurrentMediaTime() - self.destinationStartTime > 0.75;
        if (arrived || timedOut) {
            self.awaitingTapDestination = NO;
            self.active = NO;
            self.targetWidth = self.restingTargetWidth;
            self.targetHeight = kLGTabBarHighlightHeight;
            self.awaitingRestingShape = YES;
            self.collapseStartDistance =
                hypot(next.width - self.targetWidth,
                      next.height - self.targetHeight);
            self.destinationStartTime = CACurrentMediaTime();
        }
    }
    UIView *highlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    if (highlight) {
        highlight.bounds = CGRectMake(0.0, 0.0, next.width, next.height);
        highlight.center = lens.center;
        highlight.layer.cornerRadius = next.height * 0.5;
        highlight.hidden = NO;
    }
    if (self.awaitingRestingShape) {
        CGFloat remaining =
            hypot(next.width - self.targetWidth,
                  next.height - self.targetHeight);
        CGFloat progress = self.collapseStartDistance > 0.001
            ? 1.0 - remaining / self.collapseStartDistance : 1.0;
        progress = fmin(fmax(progress, 0.0), 1.0);
        CGFloat handoff = progress * progress * (3.0 - 2.0 * progress);
        highlight.alpha = handoff;
        lens.alpha = 1.0 - handoff;
        UIView *blueOverlay = LGTabBarBlueOverlay(bar, NO);
        blueOverlay.alpha = 1.0 - handoff;
        BOOL settled =
            fabs(next.centerX - self.targetCenterX) < 0.75 &&
            fabs(next.width - self.targetWidth) < 0.75 &&
            fabs(next.height - self.targetHeight) < 0.75;
        BOOL timedOut =
            CACurrentMediaTime() - self.destinationStartTime > 0.50;
        if (settled || timedOut) {
            self.awaitingRestingShape = NO;
            LGFinalizeTabBarSelection(bar, lens, self);
        }
    }
}

@end

static CGRect LGTabBarPillFrame(UITabBar *bar) {
    const CGFloat height = 64.0;
    const CGFloat minimumScreenInset = 16.0;
    const CGFloat bottomInset = 10.0;
    const CGFloat itemSlotWidth = 67.0;
    const CGFloat pillEdgePadding = 4.0;
    CGFloat availableWidth =
        MAX(0.0, CGRectGetWidth(bar.bounds) - minimumScreenInset * 2.0);
    NSUInteger itemCount = bar.items.count;
    CGFloat intrinsicWidth = itemCount
        ? itemSlotWidth * itemCount + pillEdgePadding * 2.0
        : availableWidth;
    CGFloat width = MIN(availableWidth, intrinsicWidth);
    CGFloat originX = (CGRectGetWidth(bar.bounds) - width) * 0.5;
    return CGRectMake(originX,
                      CGRectGetHeight(bar.bounds) - bottomInset - height,
                      width,
                      height);
}

static BOOL LGIsStockTabBar(UITabBar *bar) {
    return bar && object_getClass(bar) == objc_getClass("UITabBar");
}

static NSArray<UIView *> *LGStockTabBarButtons(UITabBar *bar) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    Class buttonClass = objc_getClass("UITabBarButton");
    if (!buttonClass) return buttons;
    for (UIView *view in bar.subviews) {
        if ([view isKindOfClass:buttonClass]) [buttons addObject:view];
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat leftX = CGRectGetMinX(left.frame);
        CGFloat rightX = CGRectGetMinX(right.frame);
        if (leftX < rightX) return NSOrderedAscending;
        if (leftX > rightX) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return buttons;
}

static BOOL LGTabBarButtonGeometryIsConstraintManaged(UIView *button) {
    if (!button) return YES;

    return !button.translatesAutoresizingMaskIntoConstraints ||
           button.constraints.count > 0 ||
           button.superview.constraints.count > 0;
}

static BOOL LGTabBarUsesCustomLayout(UITabBar *bar) {
    if (!bar) return YES;
    // custom layouts own their button geometry so leave them alone
    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    if (!buttons.count) return NO;
    for (UIView *button in buttons) {
        if (LGTabBarButtonGeometryIsConstraintManaged(button)) return YES;
    }
    return NO;
}

// Forward declarations for shadow view helpers (defined below)
static BOOL LGIsInjectedTabBarView(UIView *view, UITabBar *bar);
static void LGHideTabBarShadowViews(UITabBar *bar);
static void LGUnhideTabBarShadowViews(UITabBar *bar);

static void LGRemoveTabBarInjection(UITabBar *bar) {
    if (!bar) return;
    BOOL injected =
        [objc_getAssociatedObject(bar, kLGTabBarStylingKey) boolValue] ||
        objc_getAssociatedObject(bar, kLGTabBarGlassKey) ||
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey) ||
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey) ||
        objc_getAssociatedObject(bar, kLGTabBarBlueOverlayKey);
    if (!injected) return;

    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, NO);
    [state stop];
    state.active = NO;
    state.awaitingTapDestination = NO;
    state.awaitingRestingShape = NO;

    NSArray<NSValue *> *keys = @[
        [NSValue valueWithPointer:kLGTabBarGlassKey],
        [NSValue valueWithPointer:kLGTabBarSelectedHighlightKey],
        [NSValue valueWithPointer:kLGTabBarSelectionGlassKey],
        [NSValue valueWithPointer:kLGTabBarBlueOverlayKey]
    ];
    for (NSValue *keyValue in keys) {
        const void *key = keyValue.pointerValue;
        UIView *view = objc_getAssociatedObject(bar, key);
        [view removeFromSuperview];
        objc_setAssociatedObject(bar, key, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    LGUnhideTabBarShadowViews(bar);
    NSNumber *originalClips =
        objc_getAssociatedObject(bar, kLGTabBarOriginalClipsKey);
    NSNumber *originalMasks =
        objc_getAssociatedObject(bar, kLGTabBarOriginalMasksKey);
    if (originalClips) bar.clipsToBounds = originalClips.boolValue;
    if (originalMasks) bar.layer.masksToBounds = originalMasks.boolValue;
    objc_setAssociatedObject(bar, kLGTabBarOriginalBackgroundHiddenKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarOriginalClipsKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarOriginalMasksKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarStylingKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGCollectTabBarContentViews(UIView *root,
                                        NSMutableArray<UIView *> *content,
                                        NSUInteger depth) {
    if (!root || depth > 5) return;
    for (UIView *view in root.subviews) {
        NSString *className = NSStringFromClass(view.class);
        if ([className isEqualToString:@"UITabBarSwappableImageView"] ||
            [className isEqualToString:@"UITabBarButtonLabel"]) {
            [content addObject:view];
        }
        LGCollectTabBarContentViews(view, content, depth + 1);
    }
}

static void LGCenterStockTabBarButtonContent(UIView *button) {
    if (LGTabBarButtonGeometryIsConstraintManaged(button)) return;
    NSMutableArray<UIView *> *content = [NSMutableArray array];
    LGCollectTabBarContentViews(button, content, 0);
    if (!content.count) return;

    CGRect contentBounds = CGRectNull;
    for (UIView *view in content) {
        CGRect rect = [view.superview convertRect:view.frame toView:button];
        contentBounds = CGRectIsNull(contentBounds)
            ? rect : CGRectUnion(contentBounds, rect);
    }
    if (CGRectIsNull(contentBounds)) return;

    CGFloat offset = CGRectGetMidY(button.bounds) - CGRectGetMidY(contentBounds);
    if (fabs(offset) < 0.01) return;
    for (UIView *view in content) {
        CGPoint center = view.center;
        center.y += offset;
        view.center = center;
    }
}

static UIImage *LGTabBarContentMaskImage(UITabBar *bar, CGRect pillFrame) {
    if (CGRectIsEmpty(pillFrame)) return nil;
    UIGraphicsBeginImageContextWithOptions(pillFrame.size, NO,
                                           UIScreen.mainScreen.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    for (UIView *button in LGStockTabBarButtons(bar)) {
        NSMutableArray<UIView *> *content = [NSMutableArray array];
        LGCollectTabBarContentViews(button, content, 0);
        for (UIView *view in content) {
            if (view.hidden || view.alpha < 0.01) continue;
            CGRect rect = [view convertRect:view.bounds toView:bar];
            CGContextSaveGState(context);
            CGContextTranslateCTM(context,
                                  CGRectGetMinX(rect) - CGRectGetMinX(pillFrame),
                                  CGRectGetMinY(rect) - CGRectGetMinY(pillFrame));
            [view.layer renderInContext:context];
            CGContextRestoreGState(context);
        }
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIColor *LGTabBarAccentColor(UITabBar *bar) {
    UIColor *stored = objc_getAssociatedObject(bar, kLGTabBarAccentColorKey);
    if (stored) return stored;

    UIColor *accent = bar.tintColor;
    if (!accent) {
        if (@available(iOS 13.0, *)) {
            UITabBarItemStateAppearance *selected =
                bar.standardAppearance.stackedLayoutAppearance.selected;
            accent = selected.iconColor;
            if (!accent) {
                id titleColor = selected.titleTextAttributes[NSForegroundColorAttributeName];
                if ([titleColor isKindOfClass:[UIColor class]]) accent = titleColor;
            }
        }
    }
    return accent ?: UIColor.systemBlueColor;
}

static UIView *LGTabBarBlueOverlay(UITabBar *bar, BOOL create) {
    UIView *overlay = objc_getAssociatedObject(bar, kLGTabBarBlueOverlayKey);
    if (overlay || !create) return overlay;

    overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.userInteractionEnabled = NO;
    overlay.clipsToBounds = YES;
    overlay.hidden = YES;
    overlay.alpha = 0.0;
    if (@available(iOS 13.0, *)) {
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
    }

    UIView *blueContent = [[UIView alloc] initWithFrame:CGRectZero];
    blueContent.userInteractionEnabled = NO;
    blueContent.backgroundColor = LGTabBarAccentColor(bar);
    [overlay addSubview:blueContent];
    objc_setAssociatedObject(overlay, kLGTabBarBlueContentKey, blueContent,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bar addSubview:overlay];
    objc_setAssociatedObject(bar, kLGTabBarBlueOverlayKey, overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return overlay;
}

static void LGRebuildTabBarBlueMask(UITabBar *bar) {
    // this mask colors only glyph pixels covered by the moving lens
    UIView *overlay = LGTabBarBlueOverlay(bar, YES);
    UIView *blueContent =
        objc_getAssociatedObject(overlay, kLGTabBarBlueContentKey);
    blueContent.backgroundColor = LGTabBarAccentColor(bar);
    CGRect pillFrame = LGTabBarPillFrame(bar);
    UIImage *maskImage = LGTabBarContentMaskImage(bar, pillFrame);
    CALayer *mask = [CALayer layer];
    mask.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(pillFrame),
                            CGRectGetHeight(pillFrame));
    mask.contents = (__bridge id)maskImage.CGImage;
    mask.contentsScale = maskImage.scale;
    blueContent.layer.mask = mask;
}

static void LGPositionTabBarBlueOverlay(UITabBar *bar,
                                        LGLiveBackdropView *lens) {
    UIView *overlay = LGTabBarBlueOverlay(bar, NO);
    if (!overlay || !lens) return;
    CGRect pillFrame = LGTabBarPillFrame(bar);
    overlay.bounds = lens.bounds;
    overlay.center = lens.center;
    overlay.layer.cornerRadius = CGRectGetHeight(lens.bounds) * 0.5;
    UIView *blueContent =
        objc_getAssociatedObject(overlay, kLGTabBarBlueContentKey);
    blueContent.frame = CGRectMake(CGRectGetMinX(pillFrame) -
                                       CGRectGetMinX(overlay.frame),
                                   CGRectGetMinY(pillFrame) -
                                       CGRectGetMinY(overlay.frame),
                                   CGRectGetWidth(pillFrame),
                                   CGRectGetHeight(pillFrame));
}

static BOOL LGIsInjectedTabBarView(UIView *view, UITabBar *bar) {
    if (!view || !bar) return NO;
    if ([view isKindOfClass:[LGLiveBackdropView class]]) return YES;
    if (view == objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey)) return YES;
    if (view == objc_getAssociatedObject(bar, kLGTabBarBlueOverlayKey)) return YES;
    return NO;
}

// 后序遍历: 先处理子视图, 再根据子树是否包含内容来决定是否清除背景色
// 返回 YES 表示该视图或其后代包含内容视图 (UITabBarSwappableImageView / UITabBarButtonLabel)
// — 阴影属性: 对所有视图清除 (安全, 不影响渲染)
// — 背景色: 只清除「不包含内容后代」的视图 (如选中背景、阴影视图)
//   保留「包含内容后代」的视图背景 (如内容容器), 避免破坏 iOS 渲染管线
static BOOL LGClearTabBarButtonShadowsRecursive(UIView *view) {
    if (!view) return NO;

    NSString *cn = NSStringFromClass(view.class);
    BOOL isContent =
        [cn isEqualToString:@"UITabBarSwappableImageView"] ||
        [cn isEqualToString:@"UITabBarButtonLabel"];

    // 先处理子视图 (后序遍历)
    BOOL subtreeHasContent = isContent;
    for (UIView *child in view.subviews) {
        if (LGClearTabBarButtonShadowsRecursive(child)) {
            subtreeHasContent = YES;
        }
    }

    // 阴影属性: 对所有视图清除
    view.layer.shadowOpacity = 0.0;
    view.layer.shadowColor = UIColor.clearColor.CGColor;
    view.layer.shadowRadius = 0.0;
    view.layer.shadowOffset = CGSizeZero;
    view.layer.shadowPath = nil;

    // 背景色: 只清除不含内容后代的视图
    // 选中背景/阴影视图是内容的同级 (不含内容后代) → 清除
    // 内容容器是内容的父级 (含内容后代) → 保留
    if (!isContent && !subtreeHasContent) {
        if (view.backgroundColor) {
            view.backgroundColor = UIColor.clearColor;
        }
        // iOS 可能直接设置 layer.backgroundColor 而不经过 view.backgroundColor
        if (view.layer.backgroundColor) {
            view.layer.backgroundColor = UIColor.clearColor.CGColor;
        }
    }

    return subtreeHasContent;
}

// 清除单个 UITabBarButton 的阴影和背景 (不隐藏视图)
// 按钮自身是 UIControl, 清除其背景不影响子视图渲染
static void LGClearSingleTabBarButton(UIView *button) {
    if (!button) return;
    // 清除按钮自身的 shadow 和背景
    button.layer.shadowOpacity = 0.0;
    button.layer.shadowColor = UIColor.clearColor.CGColor;
    button.layer.shadowRadius = 0.0;
    button.layer.shadowOffset = CGSizeZero;
    button.layer.shadowPath = nil;
    // 按钮自身的背景色: 直接清除 (UIControl 背景不影响子视图)
    // 递归函数不会清除它 (按钮含内容后代), 但按钮背景正是选中方块阴影的来源
    button.backgroundColor = UIColor.clearColor;
    button.layer.backgroundColor = UIColor.clearColor.CGColor;
    // 递归清除子视图: 阴影全部清除, 背景只清除不含内容的视图
    LGClearTabBarButtonShadowsRecursive(button);
}

// 清除 UITabBarButton 内部的阴影和选中背景 (不隐藏视图)
static void LGHideTabBarButtonInternals(UITabBar *bar) {
    Class buttonClass = objc_getClass("UITabBarButton");
    for (UIView *button in bar.subviews) {
        if (!buttonClass || ![button isKindOfClass:buttonClass]) continue;
        LGClearSingleTabBarButton(button);
    }
}

static void LGHideTabBarShadowViews(UITabBar *bar) {
    Class buttonClass = objc_getClass("UITabBarButton");
    for (UIView *view in bar.subviews) {
        if (buttonClass && [view isKindOfClass:buttonClass]) continue;
        if (LGIsInjectedTabBarView(view, bar)) continue;
        view.hidden = YES;
    }
    bar.layer.shadowOpacity = 0.0;
    bar.layer.shadowColor = UIColor.clearColor.CGColor;
    bar.layer.shadowRadius = 0.0;
    bar.layer.shadowOffset = CGSizeZero;
    bar.layer.shadowPath = nil;
    // 清除按钮内部的阴影和选中背景 (保留内容容器背景)
    LGHideTabBarButtonInternals(bar);
}

static void LGUnhideTabBarShadowViews(UITabBar *bar) {
    Class buttonClass = objc_getClass("UITabBarButton");
    for (UIView *view in bar.subviews) {
        if (buttonClass && [view isKindOfClass:buttonClass]) continue;
        if (LGIsInjectedTabBarView(view, bar)) continue;
        view.hidden = NO;
    }
}

// 每次布局都需重新执行的清理: 隐藏系统背景、清除阴影
// iOS 在 layoutSubviews 中可能重新恢复 shadow 属性和 _UIBarBackground 可见性
static void LGReassertTabBarBackgroundHidden(UITabBar *bar) {
    UIView *stockBackground = nil;
    Class backgroundClass = objc_getClass("_UIBarBackground");
    for (UIView *view in bar.subviews) {
        if (backgroundClass && [view isKindOfClass:backgroundClass]) {
            stockBackground = view;
            break;
        }
    }
    if (stockBackground && !stockBackground.hidden) stockBackground.hidden = YES;
    LGHideTabBarShadowViews(bar);
}

static void LGStyleStockTabBar(UITabBar *bar) {
    if (!lgHostEnabled(@"TabBar")) {
        LGRemoveTabBarInjection(bar);
        return;
    }
    if (!LGIsStockTabBar(bar) || !bar.window) return;

    if (LGTabBarUsesCustomLayout(bar)) {
        LGRemoveTabBarInjection(bar);
        return;
    }

    // 已设置过: 只执行每次布局需重复的清理
    if ([objc_getAssociatedObject(bar, kLGTabBarStylingKey) boolValue]) {
        LGReassertTabBarBackgroundHidden(bar);
        return;
    }

    objc_setAssociatedObject(bar, kLGTabBarStylingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(bar, kLGTabBarOriginalClipsKey,
                             @(bar.clipsToBounds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bar, kLGTabBarOriginalMasksKey,
                             @(bar.layer.masksToBounds),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (bar.clipsToBounds) bar.clipsToBounds = NO;
    if (bar.layer.masksToBounds) bar.layer.masksToBounds = NO;

    // 通过 UITabBarAppearance API 清除系统选中背景 (iOS 13+)
    // 这是方块阴影的真正来源 — iOS 通过外观 API 渲染选中背景,
    // 不是通过视图的 backgroundColor, 所以清除视图属性无效
    // 注意: configureWithTransparentBackground 是 UIBarAppearance 的方法,
    // 只能在 UITabBarAppearance 上调用, 不能在 UITabBarItemAppearance 上调用
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *appearance = [bar.standardAppearance copy];
        if (!appearance) appearance = [[UITabBarAppearance alloc] init];
        // 清除标签栏背景色、背景图、阴影色、阴影图 (UIBarAppearance 方法)
        [appearance configureWithTransparentBackground];
        // 清除选中指示器 (新版 API)
        appearance.selectionIndicatorImage = nil;
        appearance.selectionIndicatorTintColor = UIColor.clearColor;
        bar.standardAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            bar.scrollEdgeAppearance = appearance;
        }
        // 清除旧版 API: 选中指示器图、阴影图
        bar.selectionIndicatorImage = nil;
        bar.shadowImage = nil;
        // 确保标签栏半透明
        bar.translucent = YES;
    }

    UIView *stockBackground = nil;
    Class backgroundClass = objc_getClass("_UIBarBackground");
    for (UIView *view in bar.subviews) {
        if (backgroundClass && [view isKindOfClass:backgroundClass]) {
            stockBackground = view;
            break;
        }
    }
    if (stockBackground) {
        objc_setAssociatedObject(bar, kLGTabBarOriginalBackgroundHiddenKey,
                                 @(stockBackground.hidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        stockBackground.hidden = YES;
    }
    LGHideTabBarShadowViews(bar);

    const CGFloat height = 64.0;
    CGRect pillFrame = LGTabBarPillFrame(bar);

    LGLiveBackdropView *glass = objc_getAssociatedObject(bar, kLGTabBarGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(pillFrame, nil, @"TabBar");
        if (glass) {
            glass.userInteractionEnabled = NO;
            [bar insertSubview:glass atIndex:0];
            objc_setAssociatedObject(bar, kLGTabBarGlassKey, glass,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (glass && !CGRectEqualToRect(glass.frame, pillFrame)) glass.frame = pillFrame;
    if (glass && fabs(glass.layer.cornerRadius - height * 0.5) > 0.01)
        glass.layer.cornerRadius = height * 0.5;
    if (@available(iOS 13.0, *)) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;

    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    if (buttons.count) {
        const CGFloat horizontalContentInset = 4.0;
        CGRect contentFrame = CGRectInset(pillFrame, horizontalContentInset, 0.0);
        CGFloat buttonWidth = CGRectGetWidth(contentFrame) / buttons.count;
        [buttons enumerateObjectsUsingBlock:^(UIView *button, NSUInteger index,
                                              __unused BOOL *stop) {
            if (LGTabBarButtonGeometryIsConstraintManaged(button)) return;
            CGRect targetFrame = CGRectMake(CGRectGetMinX(contentFrame) +
                                                buttonWidth * index,
                                            CGRectGetMinY(contentFrame),
                                            buttonWidth,
                                            CGRectGetHeight(contentFrame));
            if (!CGRectEqualToRect(button.frame, targetFrame)) button.frame = targetFrame;
        }];

        UIView *highlight =
            objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
        if (!highlight) {
            highlight = [[UIView alloc] initWithFrame:CGRectZero];
            highlight.userInteractionEnabled = NO;
            highlight.layer.masksToBounds = YES;
            if (@available(iOS 13.0, *)) {
                highlight.layer.cornerCurve = kCACornerCurveContinuous;
            }
            if (glass) [bar insertSubview:highlight aboveSubview:glass];
            else [bar insertSubview:highlight atIndex:0];
            objc_setAssociatedObject(bar, kLGTabBarSelectedHighlightKey,
                                     highlight,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        LGTabBarMotionState *motion = LGTabBarMotionStateForBar(bar, NO);
        BOOL transitioning = motion &&
            (motion.active || motion.awaitingTapDestination ||
             motion.awaitingRestingShape);
        NSUInteger selectedIndex = [bar.items indexOfObjectIdenticalTo:bar.selectedItem];
        if (selectedIndex != NSNotFound && selectedIndex < buttons.count) {
            BOOL dark = bar.traitCollection.userInterfaceStyle ==
                        UIUserInterfaceStyleDark;
            if (!transitioning) {
                UIView *selectedButton = buttons[selectedIndex];
                CGRect buttonFrame = [selectedButton.superview
                    convertRect:selectedButton.frame toView:bar];
                CGRect highlightBounds = CGRectMake(0.0, 0.0,
                                                    CGRectGetWidth(buttonFrame),
                                                    kLGTabBarHighlightHeight);
                CGPoint highlightCenter = CGPointMake(CGRectGetMidX(buttonFrame),
                                                      CGRectGetMidY(pillFrame));
                if (!CGRectEqualToRect(highlight.bounds, highlightBounds))
                    highlight.bounds = highlightBounds;
                if (!CGPointEqualToPoint(highlight.center, highlightCenter))
                    highlight.center = highlightCenter;
                if (fabs(highlight.layer.cornerRadius -
                         kLGTabBarHighlightHeight * 0.5) > 0.01)
                    highlight.layer.cornerRadius = kLGTabBarHighlightHeight * 0.5;
                highlight.backgroundColor =
                    [UIColor colorWithWhite:dark ? 1.0 : 0.0
                                      alpha:dark ? 0.10 : 0.06];
                highlight.alpha = 1.0;
                highlight.hidden = NO;
            } else {
                highlight.hidden = NO;
                if (!motion.awaitingRestingShape) highlight.alpha = 0.0;
            }
        } else {
            highlight.hidden = YES;
        }
    }

    objc_setAssociatedObject(bar, kLGTabBarStylingKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static UITabBar *LGTabBarForButton(UIView *button) {
    for (UIView *view = button.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UITabBar class]]) return (UITabBar *)view;
    }
    return nil;
}

static void LGStopTabBarSelectionAnimation(LGLiveBackdropView *lens) {
    UIViewPropertyAnimator *animator =
        objc_getAssociatedObject(lens, kLGTabBarSelectionAnimatorKey);
    [animator stopAnimation:YES];
    objc_setAssociatedObject(lens, kLGTabBarSelectionAnimatorKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static LGLiveBackdropView *LGTabBarSelectionLens(UITabBar *bar) {
    if (!lgHostEnabled(@"TabBar") || !LGIsStockTabBar(bar)) return nil;
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    if (lens) return lens;

    lens = LGCreateRegisteredGlass(CGRectZero, nil, @"TabBarSelection");
    if (!lens) return nil;
    lens.userInteractionEnabled = NO;
    lens.hidden = YES;
    lens.alpha = 0.0;
    lens.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) lens.layer.cornerCurve = kCACornerCurveContinuous;

    LGLiveBackdropView *base = objc_getAssociatedObject(bar, kLGTabBarGlassKey);
    if (base) [bar insertSubview:lens aboveSubview:base];
    else [bar insertSubview:lens atIndex:0];
    objc_setAssociatedObject(bar, kLGTabBarSelectionGlassKey, lens,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return lens;
}

static CGRect LGTabBarLensFrameForButton(UITabBar *bar, UIView *button) {
    CGRect buttonFrame = [button.superview convertRect:button.frame toView:bar];
    CGRect pillFrame = LGTabBarPillFrame(bar);
    const CGFloat height = kLGTabBarLensHeight;
    const CGFloat width = kLGTabBarLensWidth;
    CGFloat centerX = CGRectGetMidX(buttonFrame);
    centerX = MIN(CGRectGetMaxX(pillFrame) - width * 0.5,
                  MAX(CGRectGetMinX(pillFrame) + width * 0.5, centerX));
    return CGRectMake(centerX - width * 0.5,
                      CGRectGetMidY(pillFrame) - height * 0.5,
                      width, height);
}

static LGTabBarMotionState *LGTabBarMotionStateForBar(UITabBar *bar,
                                                       BOOL create) {
    LGTabBarMotionState *state =
        objc_getAssociatedObject(bar, kLGTabBarMotionStateKey);
    if (!state && create) {
        state = [LGTabBarMotionState new];
        state.bar = bar;
        objc_setAssociatedObject(bar, kLGTabBarMotionStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL LGTabBarMotionRange(UITabBar *bar, CGFloat *minimum,
                                CGFloat *maximum) {
    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    if (!buttons.count) return NO;
    UIView *first = buttons.firstObject;
    UIView *last = buttons.lastObject;
    CGRect firstFrame = [first.superview convertRect:first.frame toView:bar];
    CGRect lastFrame = [last.superview convertRect:last.frame toView:bar];
    if (minimum) *minimum = CGRectGetMidX(firstFrame);
    if (maximum) *maximum = CGRectGetMidX(lastFrame);
    return YES;
}

static void LGBeginTabBarLiquidMotion(UITabBar *bar,
                                      LGLiveBackdropView *lens,
                                      UITabBarButton *button,
                                      UITouch *touch) {
    // one display link owns drag spring and release travel
    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, YES);
    [state stop];
    CGRect frame = LGTabBarLensFrameForButton(bar, button);
    CGRect buttonFrame =
        [button.superview convertRect:button.frame toView:bar];
    CGFloat centerX = CGRectGetMidX(frame);
    UIView *highlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    CGFloat restingCenterX = highlight
        ? highlight.center.x : CGRectGetMidX(buttonFrame);
    CGFloat restingWidth = highlight && CGRectGetWidth(highlight.bounds) > 0.0
        ? CGRectGetWidth(highlight.bounds) : CGRectGetWidth(buttonFrame);
    state.bar = bar;
    state.lens = lens;
    state.generation += 1;
    state.awaitingTapDestination = NO;
    state.awaitingRestingShape = NO;
    state.active = YES;
    state.targetCenterX = centerX;
    state.targetWidth = kLGTabBarLensWidth;
    state.targetHeight = kLGTabBarLensHeight;
    state.renderedCenterX = restingCenterX;
    state.renderedWidth = restingWidth;
    state.renderedHeight = kLGTabBarHighlightHeight;
    state.widthVelocity = 0.0;
    state.heightVelocity = 0.0;
    state.velocityX = 0.0;
    state.gestureStartX = touch ? [touch locationInView:bar].x : centerX;
    state.lastTouchX = state.gestureStartX;
    state.dragged = NO;
    state.lastTouchTime = CACurrentMediaTime();
    lens.bounds = CGRectMake(0.0, 0.0, restingWidth,
                             kLGTabBarHighlightHeight);
    lens.center = CGPointMake(restingCenterX,
                              CGRectGetMidY(LGTabBarPillFrame(bar)));
    lens.layer.cornerRadius = kLGTabBarHighlightHeight * 0.5;
    [state start];
}

static void LGShowTabBarSelectionLens(UITabBarButton *button, UITouch *touch) {
    if (!lgHostEnabled(@"TabBar")) return;
    UITabBar *bar = LGTabBarForButton(button);
    if (!LGIsStockTabBar(bar)) return;
    LGStyleStockTabBar(bar);

    LGLiveBackdropView *lens = LGTabBarSelectionLens(bar);
    if (!lens) return;
    LGStopTabBarSelectionAnimation(lens);

    [bar bringSubviewToFront:lens];
    lens.frame = LGTabBarLensFrameForButton(bar, button);
    lens.layer.cornerRadius = CGRectGetHeight(lens.bounds) * 0.5;
    lens.hidden = NO;
    lens.alpha = 1.0;
    lens.transform = CGAffineTransformIdentity;
    lens.backgroundColor = UIColor.clearColor;
    UIView *selectedHighlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    selectedHighlight.hidden = NO;
    selectedHighlight.alpha = 0.0;
    if (!objc_getAssociatedObject(bar, kLGTabBarOriginalTintKey)) {
        objc_setAssociatedObject(bar, kLGTabBarOriginalTintKey,
                                 bar.tintColor ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(bar, kLGTabBarAccentColorKey,
                             bar.tintColor ?: UIColor.systemBlueColor,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *neutralTint = bar.unselectedItemTintColor;
    if (!neutralTint) {
        neutralTint = [UIColor colorWithWhite:
            bar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
                ? 0.65 : 0.35 alpha:1.0];
    }
    bar.tintColor = neutralTint;
    LGBeginTabBarLiquidMotion(bar, lens, button, touch);
    LGRebuildTabBarBlueMask(bar);
    UIView *blueOverlay = LGTabBarBlueOverlay(bar, YES);
    LGPositionTabBarBlueOverlay(bar, lens);
    [bar bringSubviewToFront:blueOverlay];

    [bar bringSubviewToFront:lens];
    blueOverlay.hidden = NO;
    blueOverlay.alpha = 0.0;
    blueOverlay.transform = CGAffineTransformIdentity;

    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:0.12
                                                  curve:UIViewAnimationCurveEaseOut
                                             animations:nil];
    [animator addAnimations:^{
        blueOverlay.alpha = 1.0;
    }];
    objc_setAssociatedObject(lens, kLGTabBarSelectionAnimatorKey, animator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [animator startAnimation];
}

static void LGMoveTabBarSelectionLens(UITabBarButton *button, UITouch *touch) {
    UITabBar *bar = LGTabBarForButton(button);
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    if (!lens || lens.hidden) return;

    CGPoint point = [touch locationInView:bar];
    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, YES);
    if (fabs(point.x - state.gestureStartX) > 4.0) state.dragged = YES;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = MAX(now - state.lastTouchTime, 0.001);
    CGFloat rawVelocity = (point.x - state.lastTouchX) / dt;
    state.velocityX = LGLiquidFilteredVelocity(state.velocityX, rawVelocity);
    state.lastTouchX = point.x;
    state.lastTouchTime = now;

    CGFloat minimum = 0.0, maximum = 0.0;
    if (!LGTabBarMotionRange(bar, &minimum, &maximum)) return;
    LGLiquidDragState drag = LGLiquidDragStateMake(
        point.x, minimum, maximum,
        CGSizeMake(kLGTabBarLensWidth, kLGTabBarLensHeight),
        state.velocityX, 58.0);
    state.active = YES;
    state.targetCenterX = drag.centerX;
    state.targetWidth = drag.width;
    state.targetHeight = drag.height;
    [state start];
}

static UITabBarButton *LGNearestTabBarButton(UITabBar *bar, CGFloat centerX) {
    UITabBarButton *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (UIView *view in LGStockTabBarButtons(bar)) {
        CGRect frame = [view.superview convertRect:view.frame toView:bar];
        CGFloat distance = fabs(CGRectGetMidX(frame) - centerX);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearest = (UITabBarButton *)view;
        }
    }
    return nearest;
}

static void LGCommitTabBarSelectionAtLens(UITabBarButton *trackingButton,
                                          UITouch *touch) {
    UITabBar *bar = LGTabBarForButton(trackingButton);
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    CGPoint touchInBar = touch ? [touch locationInView:bar] : CGPointZero;
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"[TABBAR INTERACTION] bar=%p tracking=%p touch=%@ lens=%p "
         "lensHidden=%d lensFrame=%@ selectedBefore=%p\n",
        bar, trackingButton, NSStringFromCGPoint(touchInBar), lens,
        lens.hidden, NSStringFromCGRect(lens.frame), bar.selectedItem];
    if (!lens || lens.hidden) {
        [log appendString:@"result=aborted-no-visible-lens\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }

    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, NO);
    UITabBarButton *target = state && !state.dragged
        ? trackingButton : LGNearestTabBarButton(bar, lens.center.x);
    if (!target) {
        [log appendString:@"result=aborted-no-nearest-button\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }

    BOOL originalWillCommit =
        target == trackingButton &&
        CGRectContainsPoint(trackingButton.bounds,
                            [touch locationInView:trackingButton]);

    NSArray<UIView *> *buttons = LGStockTabBarButtons(bar);
    NSUInteger index = [buttons indexOfObjectIdenticalTo:target];
    [buttons enumerateObjectsUsingBlock:^(UIView *button, NSUInteger buttonIndex,
                                          __unused BOOL *stop) {
        CGRect frame = [button.superview convertRect:button.frame toView:bar];
        [log appendFormat:@"button[%lu]=%p frame=%@ centerX=%.2f%@\n",
            (unsigned long)buttonIndex, button, NSStringFromCGRect(frame),
            CGRectGetMidX(frame), button == target ? @" TARGET" : @""];
    }];
    [log appendFormat:
        @"target=%p targetIndex=%@ itemCount=%lu delegate=%p/%@ "
         "originalWillCommit=%d\n",
        target, index == NSNotFound ? @"NSNotFound" :
            [NSString stringWithFormat:@"%lu", (unsigned long)index],
        (unsigned long)bar.items.count, bar.delegate,
        NSStringFromClass([bar.delegate class]), originalWillCommit];
    if (originalWillCommit) {
        [log appendString:@"result=native-original-button\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }
    if (index == NSNotFound || index >= bar.items.count) {
        [log appendString:@"result=aborted-index-item-mismatch\n"];
        LGPersistTabBarDump(log, @"interaction-release");
        return;
    }
    UITabBarItem *item = bar.items[index];

    id delegate = bar.delegate;
    if ([delegate isKindOfClass:[UITabBarController class]]) {
        UITabBarController *controller = (UITabBarController *)delegate;
        NSString *initialLog = [log copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            controller.selectedIndex = index;
            NSString *result = [initialLog stringByAppendingFormat:
                @"result=deferred-controller-index selectedAfter=%p "
                 "controllerIndexAfter=%lu\n",
                bar.selectedItem, (unsigned long)controller.selectedIndex];
            LGPersistTabBarDump(result, @"interaction-release");
        });
        return;
    }

    NSString *initialLog = [log copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        bar.selectedItem = item;
        SEL didSelect = @selector(tabBar:didSelectItem:);
        BOOL calledDelegate = [delegate respondsToSelector:didSelect];
        if (calledDelegate) {
            ((void (*)(id, SEL, UITabBar *, UITabBarItem *))objc_msgSend)(
                delegate, didSelect, bar, item);
        }
        NSString *result = [initialLog stringByAppendingFormat:
            @"result=deferred-standalone delegateCallback=%d selectedAfter=%p\n",
            calledDelegate, bar.selectedItem];
        LGPersistTabBarDump(result, @"interaction-release");
    });
}

static void LGFinalizeTabBarSelection(UITabBar *bar,
                                      LGLiveBackdropView *lens,
                                      LGTabBarMotionState *state) {
    if (!bar || !lens || lens.hidden) return;
    UIView *blueOverlay = LGTabBarBlueOverlay(bar, NO);
    UIView *highlight =
        objc_getAssociatedObject(bar, kLGTabBarSelectedHighlightKey);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    lens.alpha = 0.0;
    lens.hidden = YES;
    lens.backgroundColor = UIColor.clearColor;
    highlight.alpha = 1.0;
    highlight.hidden = NO;
    if (blueOverlay) {
        blueOverlay.hidden = YES;
        blueOverlay.alpha = 0.0;
        blueOverlay.transform = CGAffineTransformIdentity;
    }
    [CATransaction commit];
    id originalTint =
        objc_getAssociatedObject(bar, kLGTabBarOriginalTintKey);
    bar.tintColor = originalTint == NSNull.null ? nil : originalTint;
    objc_setAssociatedObject(bar, kLGTabBarOriginalTintKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(bar, kLGTabBarAccentColorKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    [state stop];
    LGStyleStockTabBar(bar);
}

static void LGHideTabBarSelectionLens(UITabBarButton *button) {
    UITabBar *bar = LGTabBarForButton(button);
    LGLiveBackdropView *lens =
        objc_getAssociatedObject(bar, kLGTabBarSelectionGlassKey);
    if (!lens || lens.hidden) return;
    LGStopTabBarSelectionAnimation(lens);
    LGTabBarMotionState *state = LGTabBarMotionStateForBar(bar, NO);
    BOOL isTap = state && !state.dragged;
    UITabBarButton *nearest = isTap
        ? button : LGNearestTabBarButton(bar, lens.center.x);
    CGRect frame = nearest
        ? [nearest.superview convertRect:nearest.frame toView:bar]
        : CGRectZero;
    if (state) {

        state.active = isTap;
        state.targetCenterX = nearest ? CGRectGetMidX(frame) : lens.center.x;
        state.targetWidth = isTap ? kLGTabBarLensWidth
                                  : (nearest ? CGRectGetWidth(frame)
                                             : state.renderedWidth);
        state.targetHeight = isTap ? kLGTabBarLensHeight
                                   : kLGTabBarHighlightHeight;
        state.velocityX = 0.0;
        state.awaitingTapDestination = isTap;
        state.awaitingRestingShape = !isTap;
        state.restingTargetWidth = nearest ? CGRectGetWidth(frame)
                                           : state.renderedWidth;
        if (!isTap) {
            state.collapseStartDistance =
                hypot(state.renderedWidth - state.targetWidth,
                      state.renderedHeight - state.targetHeight);
        }
        state.destinationStartTime = CACurrentMediaTime();
        [state start];
    }

}

static void LGPersistTabBarDump(NSString *dump, NSString *reason) {
    if (!dump.length) return;
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"liquidass-tabbar.plist"];
    NSArray *existing = [NSArray arrayWithContentsOfFile:path];
    NSMutableArray *entries = [existing isKindOfClass:[NSArray class]]
        ? [existing mutableCopy] : [NSMutableArray array];
    [entries addObject:@{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"pid": @(getpid()),
        @"reason": reason ?: @"unknown",
        @"dump": dump,
    }];
    while (entries.count > 12) [entries removeObjectAtIndex:0];
    [entries writeToFile:path atomically:YES];
}

static NSString *LGTabBarColorDescription(UIColor *color) {
    if (!color) return @"nil";
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)", r, g, b, a];
    }
    CGFloat white = 0.0;
    if ([color getWhite:&white alpha:&a]) {
        return [NSString stringWithFormat:@"white(%.3f,%.3f)", white, a];
    }
    return color.description ?: @"unknown";
}

static void LGAppendTabBarViewTree(NSMutableString *output, UIView *view,
                                   NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 8 || *visited >= 200) return;
    (*visited)++;

    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger index = 0; index < depth; index++) [indent appendString:@"  "];

    CGRect windowFrame = CGRectNull;
    if (view.window) {
        @try {
            windowFrame = [view convertRect:view.bounds toView:view.window];
        } @catch (__unused NSException *exception) {}
    }

    CALayer *layer = view.layer;
    NSString *maskClass = layer.mask ? NSStringFromClass(layer.mask.class) : @"nil";
    NSString *layerBgDesc = @"nil";
    if (layer.backgroundColor) {
        UIColor *lc = [UIColor colorWithCGColor:layer.backgroundColor];
        layerBgDesc = LGTabBarColorDescription(lc);
    }
    BOOL hasContents = layer.contents != nil;
    NSUInteger sublayerCount = layer.sublayers ? layer.sublayers.count : 0;
    [output appendFormat:
        @"%@[%lu] %@ %p frame=%@ bounds=%@ window=%@ alpha=%.3f hidden=%d "
         "opaque=%d user=%d bg=%@ layerBg=%@ layerCls=%@ contents=%d "
         "radius=%.2f curve=%@ masks=%d mask=%@ sublayers=%lu "
         "borderW=%.1f subviews=%lu constraints=%lu autoresize=0x%lx\n",
        indent, (unsigned long)depth, NSStringFromClass(view.class), view,
        NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
        NSStringFromCGRect(windowFrame), view.alpha, view.hidden, view.opaque,
        view.userInteractionEnabled, LGTabBarColorDescription(view.backgroundColor),
        layerBgDesc, NSStringFromClass(layer.class), hasContents,
        layer.cornerRadius,
        layer.cornerCurve ?: @"nil", layer.masksToBounds, maskClass,
        (unsigned long)sublayerCount,
        layer.borderWidth,
        (unsigned long)view.subviews.count, (unsigned long)view.constraints.count,
        (unsigned long)view.autoresizingMask];

    // Dump sublayers (not subviews — raw CALayer sublayers)
    if (sublayerCount > 0) {
        [output appendFormat:@"%@  sublayers:\n", indent];
        for (CALayer *sl in layer.sublayers) {
            NSString *slBgDesc = @"nil";
            if (sl.backgroundColor) {
                UIColor *slc = [UIColor colorWithCGColor:sl.backgroundColor];
                slBgDesc = LGTabBarColorDescription(slc);
            }
            [output appendFormat:
                @"%@    SL %@ %p frame=%@ hidden=%d bg=%@ contents=%d "
                 "radius=%.2f masks=%d sublayers=%lu\n",
                indent, NSStringFromClass(sl.class), sl,
                NSStringFromCGRect(sl.frame), sl.hidden,
                slBgDesc, sl.contents != nil,
                sl.cornerRadius, sl.masksToBounds,
                sl.sublayers ? (unsigned long)sl.sublayers.count : 0UL];
        }
    }

    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        [output appendFormat:@"%@  control state=0x%lx enabled=%d selected=%d "
                              "highlighted=%d label=%@\n",
            indent, (unsigned long)control.state, control.enabled, control.selected,
            control.highlighted, control.accessibilityLabel ?: @"nil"];
        // Check backgroundImage for normal and selected states
        @try {
            UIImage *normalBg = [control backgroundImageForState:UIControlStateNormal];
            UIImage *selectedBg = [control backgroundImageForState:UIControlStateSelected];
            UIImage *highlightedBg = [control backgroundImageForState:UIControlStateHighlighted];
            UIImage *disabledBg = [control backgroundImageForState:UIControlStateDisabled];
            [output appendFormat:
                @"%@  bgImages: normal=%@ selected=%@ highlighted=%@ disabled=%@\n",
                indent,
                normalBg ? normalBg.description ?: @"yes" : @"nil",
                selectedBg ? selectedBg.description ?: @"yes" : @"nil",
                highlightedBg ? highlightedBg.description ?: @"yes" : @"nil",
                disabledBg ? disabledBg.description ?: @"yes" : @"nil"];
        } @catch (__unused NSException *e) {}
    }

    for (UIView *subview in view.subviews) {
        LGAppendTabBarViewTree(output, subview, depth + 1, visited);
        if (*visited >= 200) break;
    }
}

static NSString *LGTabBarSignature(UITabBar *bar) {
    NSMutableString *signature = [NSMutableString stringWithFormat:
        @"%@|%@|%@|%.3f|%lu|",
        NSStringFromCGRect(bar.frame), NSStringFromCGRect(bar.bounds),
        NSStringFromUIEdgeInsets(bar.safeAreaInsets), bar.alpha,
        (unsigned long)bar.items.count];
    for (UITabBarItem *item in bar.items) {
        [signature appendFormat:@"%p:%ld:%d:%@|", item, (long)item.tag,
         item.enabled, item == bar.selectedItem ? @"selected" : @"normal"];
    }
    for (UIView *subview in bar.subviews) {
        [signature appendFormat:@"%@:%@:%d:%.2f|", NSStringFromClass(subview.class),
         NSStringFromCGRect(subview.frame), subview.hidden, subview.alpha];
    }
    return signature;
}

static void LGDumpTabBar(UITabBar *bar, NSString *reason) {
    if (!bar.window) return;

    NSString *signature = LGTabBarSignature(bar);
    NSString *previous = objc_getAssociatedObject(bar, kLGTabBarLastSignatureKey);
    if ([previous isEqualToString:signature]) return;
    objc_setAssociatedObject(bar, kLGTabBarLastSignatureKey, signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIWindow *window = bar.window;
    id scrollEdgeAppearance = nil;
    if ([bar respondsToSelector:NSSelectorFromString(@"scrollEdgeAppearance")]) {
        @try { scrollEdgeAppearance = [bar valueForKey:@"scrollEdgeAppearance"]; }
        @catch (__unused NSException *exception) {}
    }
    NSMutableString *dump = [NSMutableString stringWithFormat:
        @"[TABBAR] reason=%@ process=%@ os=%@ bar=%p class=%@ window=%p/%@ "
         "windowBounds=%@ screenScale=%.2f frame=%@ bounds=%@ safe=%@ "
         "layoutMargins=%@ intrinsic=%@ standardAppearance=%p scrollEdgeAppearance=%p "
         "items=%lu selected=%p\n"
         "  bar.bg=%@ bar.layerBg=%@ bar.translucent=%d bar.bgImage=%@ "
         "bar.selectionIndicatorImage=%@ bar.shadowImage=%@\n",
        reason ?: @"unknown", NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        UIDevice.currentDevice.systemVersion, bar, NSStringFromClass(bar.class),
        window, NSStringFromClass(window.class), NSStringFromCGRect(window.bounds),
        window.screen.scale, NSStringFromCGRect(bar.frame), NSStringFromCGRect(bar.bounds),
        NSStringFromUIEdgeInsets(bar.safeAreaInsets),
        NSStringFromUIEdgeInsets(bar.layoutMargins),
        NSStringFromCGSize(bar.intrinsicContentSize), bar.standardAppearance,
        scrollEdgeAppearance, (unsigned long)bar.items.count, bar.selectedItem,
        LGTabBarColorDescription(bar.backgroundColor),
        bar.layer.backgroundColor ? LGTabBarColorDescription(
            [UIColor colorWithCGColor:bar.layer.backgroundColor]) : @"nil",
        bar.translucent,
        bar.backgroundImage ? bar.backgroundImage.description ?: @"yes" : @"nil",
        bar.selectionIndicatorImage ? @"yes" : @"nil",
        bar.shadowImage ? @"yes" : @"nil"];

    // Dump appearance details
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *sa = bar.standardAppearance;
        UITabBarAppearance *sea = nil;
        if ([bar respondsToSelector:NSSelectorFromString(@"scrollEdgeAppearance")]) {
            @try { sea = [bar valueForKey:@"scrollEdgeAppearance"]; }
            @catch (__unused NSException *e) {}
        }
        [dump appendFormat:
            @"  appearance: standard=%p scrollEdge=%p\n"
            @"    std.bgColor=%@ std.bgImage=%@ std.shadowColor=%@ std.shadowImage=%@ "
            @"std.selectionIndicatorImage=%@ std.selectionIndicatorTintColor=%@\n"
            @"    sea.bgColor=%@ sea.selectionIndicatorImage=%@\n",
            sa, sea,
            LGTabBarColorDescription(sa.backgroundColor),
            sa.backgroundImage ? @"yes" : @"nil",
            sa.shadowColor ? LGTabBarColorDescription(sa.shadowColor) : @"nil",
            sa.shadowImage ? @"yes" : @"nil",
            sa.selectionIndicatorImage ? @"yes" : @"nil",
            LGTabBarColorDescription(sa.selectionIndicatorTintColor),
            sea ? LGTabBarColorDescription(sea.backgroundColor) : @"no-scrollEdge",
            (sea && sea.selectionIndicatorImage) ? @"yes" : (sea ? @"nil" : @"no-scrollEdge")];
    }

    [bar.items enumerateObjectsUsingBlock:^(UITabBarItem *item, NSUInteger index,
                                            __unused BOOL *stop) {
        [dump appendFormat:
            @"  item[%lu]=%p title=%@ tag=%ld enabled=%d selected=%d badge=%@ "
             "image=%@ selectedImage=%@ accessibility=%@\n",
            (unsigned long)index, item, item.title ?: @"nil", (long)item.tag,
            item.enabled, item == bar.selectedItem, item.badgeValue ?: @"nil",
            item.image.description ?: @"nil", item.selectedImage.description ?: @"nil",
            item.accessibilityLabel ?: @"nil"];
    }];

    NSUInteger visited = 0;
    LGAppendTabBarViewTree(dump, bar, 0, &visited);
    if (visited >= 200) [dump appendString:@"  ... hierarchy truncated at 200 views\n"];
    LGLog(@"%@", dump);
    NSLog(@"%@", dump);
    LGPersistTabBarDump(dump, reason);
}

static void LGScheduleTabBarDump(UITabBar *bar, NSString *reason) {
    if (!bar.window || [objc_getAssociatedObject(bar, kLGTabBarPendingDumpKey) boolValue])
        return;
    objc_setAssociatedObject(bar, kLGTabBarPendingDumpKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITabBar *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITabBar *strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, kLGTabBarPendingDumpKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        LGDumpTabBar(strongBar, reason);
    });
}

%hook UITabBar

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (lgHostEnabled(@"TabBar") && LGIsStockTabBar(self) && self.window &&
        CGRectContainsPoint(LGTabBarPillFrame(self), point)) return YES;
    return %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        LGStyleStockTabBar(self);
        LGScheduleTabBarDump(self, @"didMoveToWindow");
    }
}

- (void)layoutSubviews {
    %orig;
    LGStyleStockTabBar(self);
    LGScheduleTabBarDump(self, @"layoutSubviews");
}

- (void)setItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)animated {
    %orig(items, animated);
    LGStyleStockTabBar(self);
    LGScheduleTabBarDump(self, @"setItems");
}

- (void)setSelectedItem:(UITabBarItem *)item {
    %orig(item);
    LGStyleStockTabBar(self);
    LGScheduleTabBarDump(self, @"setSelectedItem");
}

%end

static void LGRefreshTabBarsInView(UIView *view) {
    if ([view isKindOfClass:UITabBar.class]) {
        LGStyleStockTabBar((UITabBar *)view);
    }
    for (UIView *subview in view.subviews) LGRefreshTabBarsInView(subview);
}

%ctor {
    lgObservePreferenceReload(^{
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                LGRefreshTabBarsInView(window);
            }
        });
    });
}

%hook UITabBarButton

- (void)layoutSubviews {
    %orig;
    UITabBar *bar = LGTabBarForButton(self);
    if (lgHostEnabled(@"TabBar") && LGIsStockTabBar(bar)) {
        LGCenterStockTabBarButtonContent(self);
        // iOS 在按钮布局时设置选中背景 — 此时清除才能去掉方块阴影
        LGClearSingleTabBarButton(self);
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (tracking && lgHostEnabled(@"TabBar"))
        LGShowTabBarSelectionLens(self, touch);
    return tracking;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (!lgHostEnabled(@"TabBar")) return tracking;
    LGTabBarMotionState *state =
        LGTabBarMotionStateForBar(LGTabBarForButton(self), NO);
    if (tracking || state.active) LGMoveTabBarSelectionLens(self, touch);
    return tracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    if (!lgHostEnabled(@"TabBar")) return;
    LGCommitTabBarSelectionAtLens(self, touch);
    LGHideTabBarSelectionLens(self);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    if (lgHostEnabled(@"TabBar")) LGHideTabBarSelectionLens(self);
}

%end
