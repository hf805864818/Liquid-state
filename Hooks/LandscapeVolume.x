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

#pragma mark - iOS 17+ 音量 HUD 类名探测（按需触发，安全模式）

static NSMutableSet<NSString *> *sLGFoundVolumeClasses = nil;

static void LGPrintViewTree(UIView *view, NSString *prefix) {
    if (!view) return;
    NSString *clsName = NSStringFromClass([view class]);
    LGLog(@"[Volume-Probe] %@%@ frame=%@ hidden=%d alpha=%.2f",
          prefix, clsName, NSStringFromCGRect(view.frame), view.hidden, view.alpha);
    for (UIView *sv in view.subviews) {
        NSString *newPrefix = [prefix stringByAppendingString:@"  "];
        LGPrintViewTree(sv, newPrefix);
    }
}

static BOOL LGIsVolumeLikeClass(NSString *className) {
    if (!className || className.length == 0) return NO;
    NSString *lower = [className lowercaseString];
    NSArray *kws = @[@"volume", @"hud", @"pressband",
                     @"mediacontrols", @"mediaremote",
                     @"presentation", @"platter",
                     @"slider", @"progress"];
    for (NSString *kw in kws) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

static void LGProbeVolumeViews(void) {
    @autoreleasepool {
        if (!sLGFoundVolumeClasses) {
            sLGFoundVolumeClasses = [NSMutableSet set];
        }

        NSArray *windows = nil;
        if (@available(iOS 13.0, *)) {
            NSMutableArray *all = [NSMutableArray array];
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    [all addObjectsFromArray:scene.windows];
                }
            }
            windows = all;
        }
        if (!windows) {
            windows = [UIApplication sharedApplication].windows;
        }

        NSMutableArray *newFound = [NSMutableArray array];
        for (UIWindow *window in windows) {
            @try {
                // 广度优先搜索
                NSMutableArray *queue = [NSMutableArray arrayWithArray:window.subviews];
                while (queue.count > 0) {
                    UIView *v = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!v) continue;
                    NSString *cls = NSStringFromClass([v class]);
                    if (LGIsVolumeLikeClass(cls) && ![sLGFoundVolumeClasses containsObject:cls]) {
                        [sLGFoundVolumeClasses addObject:cls];
                        [newFound addObject:cls];
                        LGLog(@"[Volume-Probe] 发现新视图类: %@ (window=%@ frame=%@)",
                              cls, NSStringFromClass([window class]), NSStringFromCGRect(v.frame));
                        LGLog(@"[Volume-Probe] %@ 的完整视图树:", cls);
                        LGPrintViewTree(window, @"");
                    }
                    [queue addObjectsFromArray:v.subviews];
                }
            } @catch (NSException *e) {
                LGLog(@"[Volume-Probe] 扫描异常: %@", e.reason);
            }
        }

        if (newFound.count == 0) {
            LGLog(@"[Volume-Probe] 未发现新的音量相关视图类 (已发现 %lu 个)",
                  (unsigned long)sLGFoundVolumeClasses.count);
        }
    }
}

static void LGVolumeChangedHandler(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGLog(@"[Volume-Probe] 检测到音量变化，延迟 0.3 秒后扫描视图...");
        // 延迟一下，等 HUD 完全显示出来
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                LGProbeVolumeViews();
            } @catch (NSException *e) {
                LGLog(@"[Volume-Probe] 扫描崩溃: %@", e.reason);
            }
        });
    }
}

%ctor {
    if (!LGIsSpringBoardProcess()) {
        LGLog(@"[Volume] not SpringBoard process, skipping volume hooks");
        return;
    }
    LGLog(@"[Volume] LandscapeVolume tweak loaded in SpringBoard");

    // 注册音量变化通知监听器（用于探测 iOS 17 音量 HUD 类名）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        NULL,
        LGVolumeChangedHandler,
        CFSTR("AVSystemController_SystemVolumeDidChangeNotification"),
        NULL,
        CFNotificationSuspensionBehaviorDrop);
    LGLog(@"[Volume-Probe] 音量变化监听器已注册");

    lgObservePreferenceReload(^{
        LGLog(@"[Volume] preferences reloaded");
        // Glass views will update on next layout pass
    });
}
