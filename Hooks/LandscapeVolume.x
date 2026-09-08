#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

// Vibrance view: sits on top of glass, boosts saturation/contrast for visual richness
@interface LGVolumeVibranceView : UIView
@end

@implementation LGVolumeVibranceView

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

static const void * const kLGLandscapeVolumeGlassKey = &kLGLandscapeVolumeGlassKey;
static const void * const kLGLandscapeVolumeVibranceKey = &kLGLandscapeVolumeVibranceKey;
static const void * const kLGVolumeHUDGlassKey = &kLGVolumeHUDGlassKey;
static const void * const kLGVolumeHUDVibranceKey = &kLGVolumeHUDVibranceKey;

#pragma mark - Preference helpers

static BOOL LGLandscapeVolumeGlassEnabled(void) {
    return LG_prefBool(@"LandscapeVolumeGlass.Enabled", NO);
}

static CGFloat LGLandscapeVolumeGlassCornerRadius(void) {
    return LG_prefFloat(@"LandscapeVolumeGlass.CornerRadius", 16.0);
}

static BOOL LGVolumeHUDGlassEnabled(void) {
    return LG_prefBool(@"VolumeHUDGlass.Enabled", NO);
}

static CGFloat LGVolumeHUDGlassCornerRadius(void) {
    return LG_prefFloat(@"VolumeHUDGlass.CornerRadius", 20.0);
}

#pragma mark - System material view helpers

// Find and hide/show system MTMaterialView subviews
static void LGHideSystemMaterialViews(UIView *view, BOOL hide) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    if (!materialClass) {
        LGLog(@"[Volume] MTMaterialView class not found!");
        return;
    }
    NSUInteger found = 0;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:materialClass]) {
            subview.hidden = hide;
            found++;
        }
    }
    if (found > 0) {
        LGLog(@"[Volume] found %lu MTMaterialView subviews, hidden=%d", (unsigned long)found, hide);
    }
}

#pragma mark - Landscape volume (SBVolumePressBand)

static void LGLandscapeVolumeApplyGlassToView(UIView *view) {
    if (!LGLandscapeVolumeGlassEnabled() || !view) {
        LGLog(@"[Volume-Landscape] apply skipped: enabled=%d view=%@", LGLandscapeVolumeGlassEnabled(), view);
        return;
    }

    LGLog(@"[Volume-Landscape] apply glass to view: %@ (frame=%@ subviews=%lu)",
          NSStringFromClass([view class]),
          NSStringFromCGRect(view.frame),
          (unsigned long)view.subviews.count);

    // Hide system material views so our glass is visible
    LGHideSystemMaterialViews(view, YES);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGLandscapeVolumeGlassKey);
    if (!glassView) {
        LGLog(@"[Volume-Landscape] creating new glass view (bounds=%@)", NSStringFromCGRect(view.bounds));
        glassView = LGCreateRegisteredGlass(view.bounds, nil, @"LandscapeVolume");
        if (!glassView) {
            LGLog(@"[Volume-Landscape] ERROR: LGCreateRegisteredGlass returned nil!");
            return;
        }
        objc_setAssociatedObject(view, kLGLandscapeVolumeGlassKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glassView, @"LandscapeVolume", view);
        // Insert on top so it's visible above remaining system subviews
        [view addSubview:glassView];
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        LGLog(@"[Volume-Landscape] glass view created and added as subview");
    } else {
        LGLog(@"[Volume-Landscape] reusing existing glass view");
    }

    CGFloat radius = LGLandscapeVolumeGlassCornerRadius();
    glassView.frame = view.bounds;
    glassView.layer.cornerRadius = radius;
    glassView.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glassView.hidden = NO;
    LGLog(@"[Volume-Landscape] calling applyFilters on glass view");
    [glassView applyFilters];

    // Add vibrance layer on top of glass
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGLandscapeVolumeVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeVibranceView alloc] initWithFrame:view.bounds];
        if (vibrance) {
            objc_setAssociatedObject(view, kLGLandscapeVolumeVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view addSubview:vibrance];
            vibrance.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            LGLog(@"[Volume-Landscape] vibrance view created and added");
        } else {
            LGLog(@"[Volume-Landscape] ERROR: vibrance view creation failed");
        }
    }
    if (vibrance) {
        vibrance.frame = view.bounds;
        vibrance.layer.cornerRadius = radius;
        vibrance.layer.masksToBounds = YES;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.hidden = NO;
    }

    // Apply corner radius to the host view itself
    view.layer.cornerRadius = radius;
    view.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
    LGLog(@"[Volume-Landscape] apply done: radius=%.1f glass=%@ vibrance=%@",
          radius, glassView, vibrance);
}

static void LGLandscapeVolumeRemoveGlassFromView(UIView *view) {
    if (!view) return;
    // Restore system material views
    LGHideSystemMaterialViews(view, NO);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGLandscapeVolumeGlassKey);
    if (glassView) {
        glassView.hidden = YES;
        [glassView removeFromSuperview];
        objc_setAssociatedObject(view, kLGLandscapeVolumeGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGLandscapeVolumeVibranceKey);
    if (vibrance) {
        vibrance.hidden = YES;
        [vibrance removeFromSuperview];
        objc_setAssociatedObject(view, kLGLandscapeVolumeVibranceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Portrait volume HUD (SBVolumeHUDView)

static void LGVolumeHUDApplyGlassToView(UIView *view) {
    if (!LGVolumeHUDGlassEnabled() || !view) {
        LGLog(@"[Volume-HUD] apply skipped: enabled=%d view=%@", LGVolumeHUDGlassEnabled(), view);
        return;
    }

    LGLog(@"[Volume-HUD] apply glass to view: %@ (frame=%@ subviews=%lu)",
          NSStringFromClass([view class]),
          NSStringFromCGRect(view.frame),
          (unsigned long)view.subviews.count);

    // Hide system material views so our glass is visible
    LGHideSystemMaterialViews(view, YES);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGVolumeHUDGlassKey);
    if (!glassView) {
        LGLog(@"[Volume-HUD] creating new glass view (bounds=%@)", NSStringFromCGRect(view.bounds));
        glassView = LGCreateRegisteredGlass(view.bounds, nil, @"VolumeHUD");
        if (!glassView) {
            LGLog(@"[Volume-HUD] ERROR: LGCreateRegisteredGlass returned nil!");
            return;
        }
        objc_setAssociatedObject(view, kLGVolumeHUDGlassKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glassView, @"VolumeHUD", view);
        // Insert on top so it's visible above remaining system subviews
        [view addSubview:glassView];
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        LGLog(@"[Volume-HUD] glass view created and added as subview");
    } else {
        LGLog(@"[Volume-HUD] reusing existing glass view");
    }

    CGFloat radius = LGVolumeHUDGlassCornerRadius();
    glassView.frame = view.bounds;
    glassView.layer.cornerRadius = radius;
    glassView.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glassView.hidden = NO;
    LGLog(@"[Volume-HUD] calling applyFilters on glass view");
    [glassView applyFilters];

    // Add vibrance layer on top of glass
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGVolumeHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeVibranceView alloc] initWithFrame:view.bounds];
        if (vibrance) {
            objc_setAssociatedObject(view, kLGVolumeHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view addSubview:vibrance];
            vibrance.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            LGLog(@"[Volume-HUD] vibrance view created and added");
        } else {
            LGLog(@"[Volume-HUD] ERROR: vibrance view creation failed");
        }
    }
    if (vibrance) {
        vibrance.frame = view.bounds;
        vibrance.layer.cornerRadius = radius;
        vibrance.layer.masksToBounds = YES;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.hidden = NO;
    }

    // Apply corner radius to the host view itself
    view.layer.cornerRadius = radius;
    view.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
    LGLog(@"[Volume-HUD] apply done: radius=%.1f glass=%@ vibrance=%@",
          radius, glassView, vibrance);
}

static void LGVolumeHUDRemoveGlassFromView(UIView *view) {
    if (!view) return;
    // Restore system material views
    LGHideSystemMaterialViews(view, NO);

    LGLiveBackdropView *glassView = objc_getAssociatedObject(view, kLGVolumeHUDGlassKey);
    if (glassView) {
        glassView.hidden = YES;
        [glassView removeFromSuperview];
        objc_setAssociatedObject(view, kLGVolumeHUDGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGVolumeVibranceView *vibrance = objc_getAssociatedObject(view, kLGVolumeHUDVibranceKey);
    if (vibrance) {
        vibrance.hidden = YES;
        [vibrance removeFromSuperview];
        objc_setAssociatedObject(view, kLGVolumeHUDVibranceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Hooks

// SpringBoard landscape volume press band
%hook SBVolumePressBand

- (void)layoutSubviews {
    %orig;
    LGLog(@"[Volume-Landscape] SBVolumePressBand layoutSubviews called (window=%@)", [(UIView *)self window]);
    if (LGLandscapeVolumeGlassEnabled()) {
        LGLandscapeVolumeApplyGlassToView((UIView *)self);
    } else {
        LGLandscapeVolumeRemoveGlassFromView((UIView *)self);
    }
}

- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    LGLog(@"[Volume-Landscape] SBVolumePressBand didMoveToWindow (window=%@)", selfView.window);
    if (selfView.window && LGLandscapeVolumeGlassEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGLandscapeVolumeApplyGlassToView(selfView);
        });
    } else if (!selfView.window) {
        LGLandscapeVolumeRemoveGlassFromView(selfView);
    }
}

%end

// Portrait volume HUD view
%hook SBVolumeHUDView

- (void)layoutSubviews {
    %orig;
    LGLog(@"[Volume-HUD] SBVolumeHUDView layoutSubviews called (window=%@)", [(UIView *)self window]);
    if (LGVolumeHUDGlassEnabled()) {
        LGVolumeHUDApplyGlassToView((UIView *)self);
    } else {
        LGVolumeHUDRemoveGlassFromView((UIView *)self);
    }
}

- (void)didMoveToWindow {
    %orig;
    UIView *selfView = (UIView *)self;
    LGLog(@"[Volume-HUD] SBVolumeHUDView didMoveToWindow (window=%@)", selfView.window);
    if (selfView.window && LGVolumeHUDGlassEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGVolumeHUDApplyGlassToView(selfView);
        });
    } else if (!selfView.window) {
        LGVolumeHUDRemoveGlassFromView(selfView);
    }
}

%end

#pragma mark - iOS 17+ 音量 HUD 类名探测扫描器

static NSMutableSet<NSString *> *sLGLoggedVolumeClasses = nil;
static dispatch_source_t sLGVolumeScanTimer = nil;

static NSString *LGViewTreeDescription(UIView *view, NSInteger depth) {
    if (!view) return @"";
    NSMutableString *result = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) {
        [result appendString:@"  "];
    }
    [result appendFormat:@"%@ frame=%@ hidden=%d alpha=%.2f\n",
        NSStringFromClass([view class]),
        NSStringFromCGRect(view.frame),
        view.hidden,
        view.alpha];
    for (UIView *subview in view.subviews) {
        [result appendString:LGViewTreeDescription(subview, depth + 1)];
    }
    return result;
}

static BOOL LGIsVolumeRelatedClass(NSString *className) {
    if (!className || className.length == 0) return NO;
    NSString *lower = [className lowercaseString];
    NSArray<NSString *> *keywords = @[
        @"volume", @"hud", @"pressband",
        @"mediacontrols", @"mediaremote",
        @"presentation", @"presented",
        @"slider", @"progress"
    ];
    for (NSString *kw in keywords) {
        if ([lower containsString:[kw lowercaseString]]) {
            return YES;
        }
    }
    return NO;
}

static void LGScanForVolumeViews(void) {
    @autoreleasepool {
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *window in scene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                }
            }
        }
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        if (!keyWindow) return;

        // 扫描所有 window，找出可能的音量 HUD
        NSArray *windows = [UIApplication sharedApplication].windows;
        NSMutableArray<NSString *> *volumeWindows = [NSMutableArray array];
        NSMutableArray<NSString *> *newClasses = [NSMutableArray array];

        for (UIWindow *window in windows) {
            if (!window || window.bounds.size.width == 0 || window.bounds.size.height == 0) continue;

            // 检查 window 本身的类名
            NSString *winClass = NSStringFromClass([window class]);
            if (LGIsVolumeRelatedClass(winClass)) {
                if (!sLGLoggedVolumeClasses || ![sLGLoggedVolumeClasses containsObject:winClass]) {
                    [newClasses addObject:winClass];
                    if (sLGLoggedVolumeClasses) {
                        [sLGLoggedVolumeClasses addObject:winClass];
                    }
                }
            }

            // 递归检查子视图
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:window.subviews];
            while (queue.count > 0) {
                UIView *view = queue.firstObject;
                [queue removeObjectAtIndex:0];
                NSString *clsName = NSStringFromClass([view class]);
                if (LGIsVolumeRelatedClass(clsName)) {
                    if (!sLGLoggedVolumeClasses || ![sLGLoggedVolumeClasses containsObject:clsName]) {
                        [newClasses addObject:clsName];
                        if (sLGLoggedVolumeClasses) {
                            [sLGLoggedVolumeClasses addObject:clsName];
                        }
                    }
                }
                [queue addObjectsFromArray:view.subviews];
            }
        }

        if (newClasses.count > 0) {
            LGLog(@"[Volume-Scan] 发现新的音量相关视图类 (%lu 个): %@",
                  (unsigned long)newClasses.count,
                  [newClasses componentsJoinedByString:@", "]);

            // 对每个新类，打印其完整视图树（从所在 window 开始）
            for (NSString *clsName in newClasses) {
                for (UIWindow *window in windows) {
                    __block BOOL found = NO;
                    void (^searchBlock)(UIView *) = nil;
                    searchBlock = ^(UIView *v) {
                        if (found) return;
                        if ([NSStringFromClass([v class]) isEqualToString:clsName]) {
                            found = YES;
                            LGLog(@"[Volume-Scan] 找到 %@ 的完整视图树:\n%@",
                                  clsName, LGViewTreeDescription(window, 0));
                            return;
                        }
                        for (UIView *sv in v.subviews) {
                            searchBlock(sv);
                            if (found) return;
                        }
                    };
                    searchBlock(window);
                    if (found) break;
                }
            }
        }
    }
}

%ctor {
    if (!LGIsSpringBoardProcess()) {
        LGLog(@"[Volume] not SpringBoard process, skipping volume hooks");
        return;
    }
    LGLog(@"[Volume] LandscapeVolume tweak loaded in SpringBoard");

    // 初始化类名扫描器：每 2 秒扫描一次，发现新的音量相关视图就打日志
    sLGLoggedVolumeClasses = [NSMutableSet set];
    sLGVolumeScanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sLGVolumeScanTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC,
                              0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sLGVolumeScanTimer, ^{
        LGScanForVolumeViews();
    });
    dispatch_resume(sLGVolumeScanTimer);
    LGLog(@"[Volume-Scan] 扫描器已启动，每 2 秒扫描一次视图层级");

    lgObservePreferenceReload(^{
        LGLog(@"[Volume] preferences reloaded");
        // Glass views will update on next layout pass
    });
}
