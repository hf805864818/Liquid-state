#import "LGLiveBackdropView.h"
#import "LGHostRegistry.h"
#import "LGCoverSheetState.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <time.h>
#import <math.h>
#import <unistd.h>

static const void *kLGOutsetKey = &kLGOutsetKey;
static const void *kLGRadiusKey = &kLGRadiusKey;
static const void *kLGSpecularEnabledOverrideKey = &kLGSpecularEnabledOverrideKey;

static NSDictionary<NSString *, id> *sLGGlassPreferences;

static NSString *LGGlassPreferencesPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist");
    });
    return path;
}

static UIUserInterfaceStyle sLGGlassAppearanceMode = UIUserInterfaceStyleUnspecified;

void LGSetGlassAppearanceMode(UIUserInterfaceStyle mode) {
    sLGGlassAppearanceMode = mode;
}

UIUserInterfaceStyle LGGetGlassAppearanceMode(void) {
    return sLGGlassAppearanceMode;
}

static NSString *LGAppearanceModeSuffix(void) {
    if (sLGGlassAppearanceMode == UIUserInterfaceStyleDark) return @".Dark";
    if (sLGGlassAppearanceMode == UIUserInterfaceStyleLight) return @".Light";
    return nil;
}

static BOOL LGKeySupportsAppearanceMode(NSString *key) {
    if (!key.length) return NO;
    // Skip tint colors - they are already mode-specific by nature
    if ([key hasSuffix:@"LightTintColor"] || [key hasSuffix:@"DarkTintColor"]) return NO;
    // Skip the separate modes toggle itself
    if ([key hasPrefix:@"Appearance."]) return NO;
    // Skip global/system settings that shouldn't be mode-specific
    if ([key hasPrefix:@"Global."]) return NO;
    if ([key hasPrefix:@"Specular.Motion."]) return NO;
    if ([key hasPrefix:@"MemorySaving."]) return NO;
    if ([key hasPrefix:@"DynamicQuality."]) return NO;
    if ([key hasPrefix:@"AdaptiveBlur."]) return NO;
    if ([key hasPrefix:@"WallpaperTint."]) return NO;
    if ([key hasPrefix:@"LowPower."]) return NO;
    if ([key hasPrefix:@"FocusMode."]) return NO;
    if ([key hasPrefix:@"Banner."]) return NO;
    if ([key hasPrefix:@"LandscapeVolumeGlass."]) return NO;
    if ([key hasPrefix:@"VolumeHUDGlass."]) return NO;
    if ([key hasPrefix:@"Renderer."]) return NO;
    if ([key hasPrefix:@"QuickToggle."]) return NO;
    if ([key hasPrefix:@"SurfaceSort."]) return NO;
    if ([key hasPrefix:@"SettingsControls."]) return NO;
    // All per-surface parameters support appearance mode
    return YES;
}

id LGGlassPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    @synchronized([LGLiveBackdropView class]) {
        if (!sLGGlassPreferences) {
            sLGGlassPreferences =
                [NSDictionary dictionaryWithContentsOfFile:LGGlassPreferencesPath()] ?: @{};
        }
        // Check separate mode first (only for per-surface parameters)
        id separateFlag = sLGGlassPreferences[@"Appearance.SeparateModes"];
        if ([separateFlag isKindOfClass:[NSNumber class]] && [separateFlag boolValue]) {
            NSString *suffix = LGAppearanceModeSuffix();
            if (suffix.length && LGKeySupportsAppearanceMode(key)) {
                NSString *modeKey = [key stringByAppendingString:suffix];
                id modeValue = sLGGlassPreferences[modeKey];
                if (modeValue != nil) {
                    return modeValue;
                }
            }
        }
        return sLGGlassPreferences[key];
    }
}

void LGInvalidateGlassPreferenceCache(void) {
    @synchronized([LGLiveBackdropView class]) {
        sLGGlassPreferences = nil;
    }
}

NSString *LGFilterTypeForHostPrefix(NSString *prefix) {
    if (!prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    return host ? [NSString stringWithUTF8String:host->filterType] : nil;
}

static void sblog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sblog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *format = [NSString stringWithUTF8String:fmt ?: ""];
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    LGLog(@"[LGSB] %@", message);
}

static const NSInteger kLGDynamicRadiusSteps = 32;

static CFStringRef const kLGParametersReloadedNotification =
    CFSTR("dylv.liquidglass/ParametersReloaded");
static NSHashTable<LGLiveBackdropView *> *sLGAllGlasses;
static BOOL sLGFilterRefreshSetup;
static BOOL LGSpecularEnabledForFilterType(NSString *type) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(type.UTF8String);
    if (host == &kLGHostRegistry[LGHostIdentifierCoverSheet]) return NO;
    if (host && host->specularOpacity <= 0.001f) return NO;
    NSString *prefix = host ? [NSString stringWithUTF8String:host->preferencePrefix] : nil;
    if (!prefix.length) return YES;
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".SpecularEnabled"]);
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

static NSHashTable<LGLiveBackdropView *> *sLGMotionGlasses;
static CMMotionManager *sLGMotionManager;
static BOOL sLGMotionSetup;
static BOOL sLGMotionRunning;
static BOOL sLGSpringBoardInForeground; // set lazily on first setup
static CGFloat sLGSpecularAngle = -M_PI_4;
static BOOL sLGMotionEnabled;
static CGFloat sLGMotionSensitivity = 2.0;
static CGFloat sLGMotionLoggedSensitivity = -1.0;

// 热状态感知: 充电发热时自动降级渲染
static NSUInteger sLGThermalState;        // NSProcessInfoThermalState
static BOOL sLGThermalThrottling;
static CFTimeInterval sLGLastMemoryReportTime;

static CGFloat LGThermalScaleFactor(void) {
    switch (sLGThermalState) {
        case 2:  // NSProcessInfoThermalStateFair
            return 0.75;
        case 3:  // NSProcessInfoThermalStateSerious
            return 0.50;
        case 4:  // NSProcessInfoThermalStateCritical
            return 0.30;
        default: // NSProcessInfoThermalStateNominal
            return 1.0;
    }
}

static BOOL LGThermalShouldDisableMotion(void) {
    return sLGThermalState >= 3; // Serious or Critical
}

static void LGThermalStateChanged(void) {
    NSUInteger newState = [NSProcessInfo processInfo].thermalState;
    if (newState == sLGThermalState) return;
    sLGThermalState = newState;
    BOOL shouldThrottle = (newState >= 2);
    if (shouldThrottle == sLGThermalThrottling) return;
    sLGThermalThrottling = shouldThrottle;

    LGLog(@"thermal state changed: %lu throttling=%d", (unsigned long)newState, shouldThrottle);

    // 热状态变化时重新评估运动传感器
    if (sLGMotionSetup) LGRefreshMotionHighlights();

    // 重新应用所有滤镜 (降采样率变化)
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (LGLiveBackdropView *glass in sLGAllGlasses.allObjects) {
            [glass reapplyFilterForParameterReload];
        }
        [CATransaction commit];
    });
}
static CFStringRef const kLGMotionPrefsReloadNotification = CFSTR("dylv.liquidassprefs/Reload");

static void LGApplyMotionHighlightAngle(void);
static void LGRefreshMotionHighlights(void);
static void LGEnsureFilterRefreshObserver(void);

static BOOL LGIsSpringBoardBundle(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void LGReloadMotionHighlightPreferences(void) {
    id enabled = LGGlassPreferenceValue(@"Specular.Motion.Enabled");
    id sensitivity = LGGlassPreferenceValue(@"Specular.Motion.Sensitivity");
    BOOL previousEnabled = sLGMotionEnabled;
    CGFloat previousSensitivity = sLGMotionSensitivity;
    sLGMotionEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
    CGFloat value = [sensitivity respondsToSelector:@selector(doubleValue)] ? [sensitivity doubleValue] : 2.0;
    sLGMotionSensitivity = MAX(0.0, MIN(8.0, value));
    if (sLGMotionLoggedSensitivity < 0.0 || previousEnabled != sLGMotionEnabled ||
        fabs(previousSensitivity - sLGMotionSensitivity) > 0.01) {
        sLGMotionLoggedSensitivity = sLGMotionSensitivity;
        LGLog(@"motion highlights prefs enabled=%d sensitivity=%.2f", sLGMotionEnabled, sLGMotionSensitivity);
    }
}

static void LGMotionPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGInvalidateGlassPreferenceCache();
        LGReloadMotionHighlightPreferences();
        LGRefreshMotionHighlights();
    });
}

static BOOL LGUsesDynamicRadiusType(NSString *filterType) {

    return filterType.length &&
           LGHostIdentifierForFilterType(filterType.UTF8String) != LGHostIdentifierClock;
}

static BOOL LGUsesPrefsControlCaptureScale(NSString *filterType) {
    switch (LGHostIdentifierForFilterType(filterType.UTF8String)) {
        case LGHostIdentifierPrefsSlider:
        case LGHostIdentifierPrefsSwitch:
        case LGHostIdentifierPrefsButton:
        case LGHostIdentifierPrefsSegment:
            return YES;
        default:
            return NO;
    }
}

static CGFloat LGNativeBlurRadiusForFilterType(NSString *filterType) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(filterType.UTF8String);
    if (!host) return 0.0;
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    NSString *key = [prefix stringByAppendingString:@".Blur"];
    id value = LGGlassPreferenceValue(key);
    return [value respondsToSelector:@selector(doubleValue)]
        ? MAX(0.0, [value doubleValue]) : host->blur;
}

static id LGCreateNativeGaussianFilter(Class filterCls, CGFloat radius) {
    if (!filterCls || radius <= 0.0) return nil;
    id blurFilter = nil;
    SEL typeSelector = NSSelectorFromString(@"filterWithType:");
    if ([filterCls respondsToSelector:typeSelector]) {
        blurFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, typeSelector, @"gaussianBlur");
    }
    if (!blurFilter) {
        SEL nameSelector = NSSelectorFromString(@"filterWithName:");
        if ([filterCls respondsToSelector:nameSelector]) {
            blurFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
                filterCls, nameSelector, @"gaussianBlur");
        }
    }
    if (!blurFilter) return nil;
    @try {
        [blurFilter setValue:@(radius) forKey:@"inputRadius"];
        [blurFilter setValue:@YES forKey:@"inputNormalizeEdges"];
    } @catch (__unused NSException *e) {
        return nil;
    }
    return blurFilter;
}

static const CGFloat kLGScaleMax    = 0.75;
static const CGFloat kLGScaleMin    = 0.25;

static const CGFloat kLGClockCaptureScale = 0.50;

static const CGFloat kLGCoverSheetCaptureScale = 1.00;

static const CGFloat kLGPrefsControlScale = 1.50;
static const CGFloat kLGDefaultScaleBudget = 8000.0;
static CGFloat LGQualityValue(void) {
    id value = LGGlassPreferenceValue(@"Global.Quality");
    CGFloat quality = [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : 1.0;
    if (!isfinite(quality)) quality = 1.0;
    return fmin(1.0, fmax(0.1, quality));
}

static CGFloat LGMemorySavingScaleFactor(void) {
    id enabled = LGGlassPreferenceValue(@"MemorySaving.Enabled");
    if (![enabled isKindOfClass:[NSNumber class]] || ![(NSNumber *)enabled boolValue]) {
        return 1.0;
    }

    CGFloat level = 0.5f;
    id levelVal = LGGlassPreferenceValue(@"MemorySaving.Level");
    if ([levelVal isKindOfClass:[NSNumber class]]) {
        level = [(NSNumber *)levelVal floatValue];
    }

    // Check for active memory pressure boost
    id pressureVal = LGGlassPreferenceValue(@"MemorySaving.ActivePressure");
    if ([pressureVal isKindOfClass:[NSNumber class]] && [(NSNumber *)pressureVal floatValue] > 0.01) {
        level = MAX(level, [(NSNumber *)pressureVal floatValue]);
    }

    level = fmin(1.0, fmax(0.0, level));
    // Reduce scale budget by up to 50% at max memory saving
    return 1.0 - level * 0.5;
}

static CGFloat LGDynamicQualityScaleFactor(void) {
    id enabled = LGGlassPreferenceValue(@"DynamicQuality.Enabled");
    if (![enabled isKindOfClass:[NSNumber class]] || ![(NSNumber *)enabled boolValue]) {
        return 1.0;
    }

    id highLoad = LGGlassPreferenceValue(@"DynamicQuality.HighLoadActive");
    if (![highLoad isKindOfClass:[NSNumber class]] || ![(NSNumber *)highLoad boolValue]) {
        return 1.0;
    }

    CGFloat aggressiveness = 0.4f;
    id aggVal = LGGlassPreferenceValue(@"DynamicQuality.Aggressiveness");
    if ([aggVal isKindOfClass:[NSNumber class]]) {
        aggressiveness = [(NSNumber *)aggVal floatValue];
    }
    aggressiveness = fmin(1.0, fmax(0.0, aggressiveness));

    // Reduce scale budget during high load
    return 1.0 - aggressiveness * 0.35;
}

static CGFloat LGScaleBudget(void) {
    return kLGDefaultScaleBudget * LGQualityValue() * LGMemorySavingScaleFactor() * LGDynamicQualityScaleFactor() * LGThermalScaleFactor();
}

static CGFloat LGScaleForSize(CGSize s) {
    // area budget keeps total capture cost predictable
    CGFloat area = s.width * s.height;
    if (area <= 1.0) return kLGScaleMax;
    CGFloat scale = sqrt(LGScaleBudget() / area);
    return fmin(kLGScaleMax, fmax(kLGScaleMin, scale));
}

@interface LGLiveBackdropView ()
- (void)updateSpecular;
- (void)applySpecularAngle:(CGFloat)angle;
- (void)reapplyFilterForParameterReload;
@end

static void LGParametersReloaded(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{

        // clear cached prefs before rebuilding every live filter
        LGInvalidateGlassPreferenceCache();
        NSArray<LGLiveBackdropView *> *glasses = sLGAllGlasses.allObjects;
        LGLog(@"render parameters ready; refreshing %lu live filters",
              (unsigned long)glasses.count);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (LGLiveBackdropView *glass in glasses) {
            [glass reapplyFilterForParameterReload];
        }
        [CATransaction commit];
    });
}

static void LGEnsureFilterRefreshObserver(void) {
    if (!sLGAllGlasses) sLGAllGlasses = [NSHashTable weakObjectsHashTable];
    if (sLGFilterRefreshSetup) return;
    sLGFilterRefreshSetup = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LGParametersReloaded,
                                    kLGParametersReloadedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static BOOL LGHasVisibleMotionGlass(void) {
    for (LGLiveBackdropView *glass in sLGMotionGlasses.allObjects) {
        if (glass.window && !glass.hidden && glass.alpha > 0.001) {
            return YES;
        }
    }
    return NO;
}

static void LGApplyMotionHighlightAngle(void) {
    for (LGLiveBackdropView *glass in sLGMotionGlasses.allObjects) {
        if (!glass.window || glass.hidden || glass.alpha <= 0.001) continue;
        [glass applySpecularAngle:sLGSpecularAngle];
    }
}

static void LGRefreshMotionHighlights(void) {
    if (!sLGMotionSetup || !LGIsSpringBoardBundle()) return;

    // Motion disabled in settings → always stop
    if (!sLGMotionEnabled) {
        if (sLGMotionRunning) {
            [sLGMotionManager stopDeviceMotionUpdates];
            sLGMotionRunning = NO;
        }
        sLGSpecularAngle = -M_PI_4;
        LGApplyMotionHighlightAngle();
        return;
    }

    // 热状态严重时禁用运动传感器 (充电发热保护)
    if (LGThermalShouldDisableMotion()) {
        if (sLGMotionRunning) {
            [sLGMotionManager stopDeviceMotionUpdates];
            sLGMotionRunning = NO;
            LGLog(@"motion highlights stopped — thermal throttling (state=%lu)", (unsigned long)sLGThermalState);
        }
        return;
    }

    // SpringBoard in background (app in front) → no glass is actually visible, stop sensor
    if (!sLGSpringBoardInForeground) {
        if (sLGMotionRunning) {
            [sLGMotionManager stopDeviceMotionUpdates];
            sLGMotionRunning = NO;
            LGLog(@"motion highlights stopped — SpringBoard in background");
        }
        return;
    }

    BOOL hasVisibleGlass = LGHasVisibleMotionGlass();

    // No visible glass → stop sensor completely to save power
    if (!hasVisibleGlass) {
        if (sLGMotionRunning) {
            [sLGMotionManager stopDeviceMotionUpdates];
            sLGMotionRunning = NO;
            LGLog(@"motion highlights stopped — no visible glasses");
        }
        return;
    }

    // Has visible glass and not running → start sensor
    if (sLGMotionRunning) return;

    CMAttitudeReferenceFrame frames = [CMMotionManager availableAttitudeReferenceFrames];
    CMAttitudeReferenceFrame frame = (frames & CMAttitudeReferenceFrameXMagneticNorthZVertical)
        ? CMAttitudeReferenceFrameXMagneticNorthZVertical
        : CMAttitudeReferenceFrameXArbitraryCorrectedZVertical;

    sLGMotionManager.deviceMotionUpdateInterval = 1.0 / 5.0; // 5Hz, reduces sensor power draw
    sLGMotionRunning = YES;
    [sLGMotionManager startDeviceMotionUpdatesUsingReferenceFrame:frame
                                                            toQueue:NSOperationQueue.mainQueue
                                                        withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion || error || !sLGMotionEnabled) return;
        // Double-check visibility inside handler (defensive, should not be needed but harmless)
        if (!LGHasVisibleMotionGlass()) return;

        CMAttitude *attitude = motion.attitude;

        CGFloat baseMotion = attitude.yaw + attitude.roll * 0.65 + attitude.pitch * 0.35;
        CGFloat target = baseMotion * (sLGMotionSensitivity / 1.5);

        CGFloat delta = atan2(sin(target - sLGSpecularAngle), cos(target - sLGSpecularAngle));
        CGFloat nextAngle = sLGSpecularAngle + delta * 0.40;
        static CGFloat lastAppliedAngle = CGFLOAT_MAX;
        if (lastAppliedAngle == CGFLOAT_MAX ||
            fabs(atan2(sin(nextAngle - lastAppliedAngle), cos(nextAngle - lastAppliedAngle))) >= 0.025) {
            sLGSpecularAngle = nextAngle;
            lastAppliedAngle = nextAngle;
            LGApplyMotionHighlightAngle();
        }
    }];
    LGLog(@"motion highlights started reference=%s", frame == CMAttitudeReferenceFrameXMagneticNorthZVertical ? "magnetic-north" : "corrected-arbitrary");
}

static void LGSpringBoardResignedActive(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        sLGSpringBoardInForeground = NO;
        LGLog(@"SpringBoard resigned active — pausing motion sensor");
        LGRefreshMotionHighlights();
    });
}

static void LGSpringBoardBecameActive(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        sLGSpringBoardInForeground = YES;
        LGLog(@"SpringBoard became active — resuming motion sensor");
        LGRefreshMotionHighlights();
    });
}

static void LGEnsureMotionHighlights(void) {
    if (!LGIsSpringBoardBundle()) return;
    if (!sLGMotionGlasses) sLGMotionGlasses = [NSHashTable weakObjectsHashTable];
    if (!sLGMotionManager) sLGMotionManager = [CMMotionManager new];
    if (!sLGMotionSetup) {
        sLGMotionSetup = YES;
        // Determine initial foreground state from UIApplication
        sLGSpringBoardInForeground = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        LGMotionPreferencesDidChange,
                                        kLGMotionPrefsReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // Observe SpringBoard active state — stop sensor when an app is in front
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                        LGSpringBoardResignedActive,
                                        (CFStringRef)UIApplicationWillResignActiveNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                        LGSpringBoardBecameActive,
                                        (CFStringRef)UIApplicationDidBecomeActiveNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // 热状态监控: 充电发热时自动降级
        sLGThermalState = [NSProcessInfo processInfo].thermalState;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull n) {
            (void)n;
            LGThermalStateChanged();
        }];
    }
    LGReloadMotionHighlightPreferences();
    LGRefreshMotionHighlights();
}

static const CGFloat kLGSpecularMinimumOpacity = 0.30;
static const CGFloat kLGSpecularBrightBoostOpacity = 0.70;

// MARK: - Memory usage tracking
static NSHashTable<LGLiveBackdropView *> *sLGLiveViews;
static unsigned long long sLGLastReportedCacheBytes = 0;

static NSHashTable *LGLiveViews(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGLiveViews = [NSHashTable weakObjectsHashTable];
    });
    return sLGLiveViews;
}

static void LGRegisterLiveView(LGLiveBackdropView *view) {
    if (!view) return;
    [LGLiveViews() addObject:view];
}

static void LGUnregisterLiveView(LGLiveBackdropView *view) {
    if (!view) return;
    [LGLiveViews() removeObject:view];
}

static unsigned long long LGEstimateViewMemoryUsage(LGLiveBackdropView *view) {
    if (!view) return 0;
    CGSize size = view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return 0;
    CGFloat scale = [UIScreen mainScreen].scale;
    // 估算: 背景层 + 高光层 + 模糊缓存, 按 RGBA 32bpp 计算
    // 大约是 2.5 倍的单帧像素内存
    unsigned long long pixels = (unsigned long long)(size.width * scale) * (unsigned long long)(size.height * scale);
    return pixels * 4 * 2.5; // 4 bytes per pixel, ~2.5 layers
}

static unsigned long long LGTotalLiveViewMemoryUsage(void) {
    unsigned long long total = 0;
    for (LGLiveBackdropView *view in LGLiveViews()) {
        total += LGEstimateViewMemoryUsage(view);
    }
    return total;
}

static void LGReportMemoryUsageIfNeeded(void) {
    CFTimeInterval now = CACurrentMediaTime();
    // 最多每 5 秒报告一次, 避免频繁遍历
    if (now - sLGLastMemoryReportTime < 5.0) return;
    sLGLastMemoryReportTime = now;

    unsigned long long current = LGTotalLiveViewMemoryUsage();
    // 变化超过 10% 才更新, 避免频繁写入
    unsigned long long diff = current > sLGLastReportedCacheBytes
        ? current - sLGLastReportedCacheBytes
        : sLGLastReportedCacheBytes - current;
    if (sLGLastReportedCacheBytes == 0 || diff > sLGLastReportedCacheBytes * 0.1) {
        sLGLastReportedCacheBytes = current;
        CFPreferencesSetAppValue(CFSTR("__runtime_cache_usage_bytes"),
                                 (__bridge CFNumberRef)@(current),
                                 CFSTR("dylv.liquidass"));
        CFPreferencesAppSynchronize(CFSTR("dylv.liquidass"));
    }
}

@implementation LGLiveBackdropView {
    NSString        *_lgGroupName;
    CAGradientLayer *_specular;
    CAGradientLayer *_specularBoost;
    CALayer         *_specularMask;
    CALayer         *_specularBoostMask;
    CALayer         *_nativeBlurLayer;
    CGFloat          _nativeBlurRadius;
    BOOL             _backdropConfigured;
    BOOL             _filterAttached;
    uint32_t         _lgId;
    CGFloat          _appliedScale;
    BOOL             _parameterRefreshVariant;
    CGSize           _lastLayoutSize;       // layoutSubviews throttling
    CGFloat          _lastLayoutCornerRadius; // layoutSubviews throttling
}

- (NSString *)lgEffectiveFilterType {
    if (!_lgFilterType.length)
        return [NSString stringWithUTF8String:kLGHostRegistry[LGHostIdentifierDefault].filterType];
    NSString *base = _lgFilterType;

    if (LGUsesDynamicRadiusType(base) && !CGRectIsEmpty(self.bounds)) {
        CGFloat shortest = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
        CGFloat ratio = shortest > 0.0 ? self.layer.cornerRadius / shortest : 0.0;
        NSInteger step = (NSInteger)llround(MAX(0.0, MIN(0.5, ratio)) * kLGDynamicRadiusSteps);
        base = [base stringByAppendingFormat:@".r%ld", (long)step];
    }
    NSString *type = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [base stringByAppendingString:@".dark"] : base;
    if (_parameterRefreshVariant) type = [type stringByAppendingString:@".refresh"];
    return type;
}

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame groupName:nil filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName {
    return [self initWithFrame:frame groupName:groupName filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName filterType:(NSString *)filterType {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _lgFilterType = [filterType copy];
    static uint32_t idCounter = 0;
    _lgId = ++idCounter;
    if (groupName.length) {

        _lgGroupName = [groupName copy];
    } else {

        _lgGroupName = [NSString stringWithFormat:@"dylv.liquidglass.g%u", _lgId];
    }
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    self.opaque                 = NO;

    self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    LGEnsureFilterRefreshObserver();
    [sLGAllGlasses addObject:self];
    LGEnsureMotionHighlights();
    [sLGMotionGlasses addObject:self];
    LGRegisterLiveView(self);
    [self applyFilters];
    return self;
}

- (void)dealloc {
    [sLGAllGlasses removeObject:self];
    [sLGMotionGlasses removeObject:self];
    LGUnregisterLiveView(self);
    LGReportMemoryUsageIfNeeded();
    // Re-evaluate motion state after removing this glass
    if (sLGMotionSetup) LGRefreshMotionHighlights();
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyFilters];
    // Window changed → re-evaluate whether motion sensor needs to be running
    if (sLGMotionSetup) LGRefreshMotionHighlights();
}

- (void)setHidden:(BOOL)hidden {
    BOOL wasHidden = self.hidden;
    [super setHidden:hidden];
    if (wasHidden != hidden && sLGMotionSetup) {
        LGRefreshMotionHighlights();
    }
}

- (void)setAlpha:(CGFloat)alpha {
    BOOL wasVisible = self.alpha > 0.001;
    [super setAlpha:alpha];
    BOOL isVisible = alpha > 0.001;
    if (wasVisible != isVisible && sLGMotionSetup) {
        LGRefreshMotionHighlights();
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        _filterAttached = NO;
        [self applyFilters];
    }
}

- (NSNumber *)lgSpecularEnabledOverride {
    return objc_getAssociatedObject(self, kLGSpecularEnabledOverrideKey);
}

- (void)setLgSpecularEnabledOverride:(NSNumber *)override {
    NSNumber *previous = self.lgSpecularEnabledOverride;
    if ((previous == override) || [previous isEqualToNumber:override]) return;
    objc_setAssociatedObject(self, kLGSpecularEnabledOverrideKey, [override copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSpecular];
}

- (void)layoutSubviews  {
    [super layoutSubviews];
    CGSize currentSize = self.bounds.size;
    CGFloat currentRadius = self.layer.cornerRadius;
    // Throttle: skip filter/specular reapply if size & corner radius haven't changed
    if (CGSizeEqualToSize(currentSize, _lastLayoutSize) &&
        fabs(currentRadius - _lastLayoutCornerRadius) < 0.5) {
        return;
    }
    _lastLayoutSize = currentSize;
    _lastLayoutCornerRadius = currentRadius;
    [self applyFilters];
    [self updateSpecular];
}

- (void)updateNativeBlurOverlayWithRadius:(CGFloat)radius filterClass:(Class)filterCls {
    if (radius <= 0.0 || !filterCls) {
        [_nativeBlurLayer removeFromSuperlayer];
        _nativeBlurLayer = nil;
        _nativeBlurRadius = 0.0;
        return;
    }

    BOOL needsFilter = !_nativeBlurLayer || fabs(_nativeBlurRadius - radius) > 0.001;
    id gaussian = needsFilter ? LGCreateNativeGaussianFilter(filterCls, radius) : nil;
    if (needsFilter && !gaussian) return;
    if (!_nativeBlurLayer) {
        Class backdropCls = NSClassFromString(@"CABackdropLayer");
        if (!backdropCls) return;
        _nativeBlurLayer = [backdropCls layer];
        @try {
            [_nativeBlurLayer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
            [_nativeBlurLayer setValue:@YES forKey:@"windowServerAware"];
            [_nativeBlurLayer setValue:[_lgGroupName stringByAppendingString:@".nativeblur"]
                                forKey:@"groupName"];
            [_nativeBlurLayer setValue:@"dylv.liquidglass.nativeblur" forKey:@"groupNamespace"];
            [_nativeBlurLayer setValue:@YES forKey:@"ignoresScreenClip"];

            [_nativeBlurLayer setValue:@1.0 forKey:@"scale"];
        } @catch (NSException *e) {
            LGLog(@"glass#%u native blur overlay configure failed: %@", _lgId, e.reason);
        }
        [self.layer insertSublayer:_nativeBlurLayer atIndex:0];
        if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) == LGHostIdentifierClock) {
            LGLog(@"clock native blur layer created radius=%.2f group=%@",
                  radius, _lgGroupName);
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _nativeBlurLayer.frame = self.bounds;
    _nativeBlurLayer.cornerRadius = self.layer.cornerRadius;
    _nativeBlurLayer.masksToBounds = YES;
    @try { [_nativeBlurLayer setValue:[self.layer valueForKey:@"cornerCurve"] forKey:@"cornerCurve"]; }
    @catch (__unused NSException *e) {}
    if (gaussian) {
        _nativeBlurLayer.filters = @[gaussian];
        _nativeBlurRadius = radius;
        if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) == LGHostIdentifierClock) {
            LGLog(@"clock native blur filter applied radius=%.2f bounds=%@",
                  radius, NSStringFromCGRect(self.bounds));
        }
    }
    [CATransaction commit];
}

- (void)updateSpecular {
    if (CGRectIsEmpty(self.bounds)) return;

    NSNumber *override = self.lgSpecularEnabledOverride;
    BOOL enabled = override ? override.boolValue
                            : LGSpecularEnabledForFilterType(_lgFilterType);
    if (!enabled && !_specular) return;

    if (!_specular) {
        id clear = (id)UIColor.clearColor.CGColor;
        _specular = [CAGradientLayer layer];
        _specular.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularMinimumOpacity].CGColor,
                             clear,
                             (id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularMinimumOpacity].CGColor];
        _specular.locations = @[@0.0, @0.5, @1.0];
        _specularMask = [CALayer layer];
        _specularMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularMask.borderColor = UIColor.blackColor.CGColor;
        _specular.mask = _specularMask;
        [self.layer addSublayer:_specular];

        _specularBoost = [CAGradientLayer layer];
        _specularBoost.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularBrightBoostOpacity].CGColor,
                                  clear,
                                  (id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularBrightBoostOpacity].CGColor];
        _specularBoost.locations = @[@0.0, @0.5, @1.0];
        _specularBoost.compositingFilter = @"overlayBlendMode";
        _specularBoostMask = [CALayer layer];
        _specularBoostMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularBoostMask.borderColor = UIColor.blackColor.CGColor;
        _specularBoost.mask = _specularBoostMask;
        [self.layer addSublayer:_specularBoost];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specular.hidden = !enabled;
    _specularBoost.hidden = !enabled;
    for (CALayer *gradient in @[_specular, _specularBoost]) gradient.frame = self.bounds;
    for (CALayer *mask in @[_specularMask, _specularBoostMask]) {
        mask.frame = self.bounds;
        mask.cornerRadius = self.layer.cornerRadius;
        mask.cornerCurve = self.layer.cornerCurve;
        mask.borderWidth = 0.75;
    }
    [CATransaction commit];
    [self applySpecularAngle:sLGSpecularAngle];
}

- (void)applySpecularAngle:(CGFloat)angle {
    if (!_specular) return;
    CGFloat dx = cos(angle) * 0.5;
    CGFloat dy = sin(angle) * 0.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specular.startPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    _specular.endPoint = CGPointMake(0.5 - dx, 0.5 - dy);
    _specularBoost.startPoint = _specular.startPoint;
    _specularBoost.endPoint = _specular.endPoint;
    [CATransaction commit];
}

- (void)applyFilters {
    CALayer *layer = self.layer;
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;

    @try {

        if (!_backdropConfigured) {
            // these private flags keep capture in render server space
            [layer setValue:@NO  forKey:@"layerUsesCoreImageFilters"];
            [layer setValue:@YES forKey:@"windowServerAware"];
            [layer setValue:_lgGroupName forKey:@"groupName"];
            [layer setValue:@"dylv.liquidglass" forKey:@"groupNamespace"];

            [layer setValue:@YES forKey:@"ignoresScreenClip"];
            _backdropConfigured = YES;
        }

        CGFloat wantScale;
        switch (LGHostIdentifierForFilterType(_lgFilterType.UTF8String)) {
            case LGHostIdentifierClock:
                wantScale = kLGClockCaptureScale;
                break;
            case LGHostIdentifierCoverSheet:
                wantScale = kLGCoverSheetCaptureScale;
                break;
            default:
                wantScale = LGUsesPrefsControlCaptureScale(_lgFilterType)
                    ? kLGPrefsControlScale : LGScaleForSize(self.bounds.size);
                break;
        }
        if (fabs(wantScale - _appliedScale) > 0.02) {
            [layer setValue:@(wantScale) forKey:@"scale"];
            _appliedScale = wantScale;
            LGLog(@"glass#%u scale type=%@ bounds=%.1fx%.1f quality=%.2f budget=%.0f scale=%.3f",
                       _lgId,
                       _lgFilterType ?: @"default",
                       CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds),
                       LGQualityValue(), LGScaleBudget(), wantScale);
        }

        NSString *wantType = [self lgEffectiveFilterType];
        NSArray *existing = layer.filters;
        CGFloat nativeBlur = LGNativeBlurRadiusForFilterType(_lgFilterType ?: wantType);
        Class filterCls = NSClassFromString(@"CAFilter");
        [self updateNativeBlurOverlayWithRadius:nativeBlur filterClass:filterCls];

        if (_filterAttached && existing.count == 1) {
            NSString *type = nil;
            @try { type = [existing.firstObject valueForKey:@"type"]; } @catch (...) {}
            if ([type isEqualToString:wantType]) {
                return;
            }
        }
        if (!filterCls) { sblog("CAFilter class not found"); return; }

        id glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), wantType);

        if (!glassFilter) {
            LGLog(@"glass#%u filterWithType nil (not registered yet?)", _lgId);
            return;
        }

        layer.filters = @[glassFilter];
        _filterAttached = YES;
    } @catch (NSException *e) {
        sblog("applyFilters exception: %s", e.reason.UTF8String);
    }
}

- (void)reapplyFilterForParameterReload {

    _parameterRefreshVariant = !_parameterRefreshVariant;

    _appliedScale = -1.0;
    _filterAttached = NO;
    [self applyFilters];
    [self.layer setNeedsDisplay];
}

@end

#pragma mark - generic host injection

void LGSetSpringBoardInForeground(BOOL inForeground) {
    if (!LGIsSpringBoardBundle()) return;
    if (sLGSpringBoardInForeground == inForeground) return;
    sLGSpringBoardInForeground = inForeground;
    LGLog(@"SpringBoard foreground state changed: %d", inForeground);
    if (sLGMotionSetup) {
        LGRefreshMotionHighlights();
    }
}

static CGRect LGOutsetFrame(CGRect mf, UIEdgeInsets outset) {
    return CGRectMake(mf.origin.x - outset.left,
                      mf.origin.y - outset.top,
                      mf.size.width  + outset.left + outset.right,
                      mf.size.height + outset.top  + outset.bottom);
}

void LGInjectGlassIntoMaterialGroupType(UIView *mat, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType) {
    UIView *parent = mat.superview;
    if (!parent) return;

    CGRect gf = LGOutsetFrame(mat.frame, outset);

    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) {
        glass = [[LGLiveBackdropView alloc] initWithFrame:gf groupName:groupName filterType:filterType];
        __weak LGLiveBackdropView *weakGlass = glass;
        for (NSNumber *delay in @[ @1.5, @3.0, @5.0, @8.0, @12.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakGlass applyFilters];
            });
        }
        [parent insertSubview:glass aboveSubview:mat];
        objc_setAssociatedObject(mat, assocKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != parent) [parent insertSubview:glass aboveSubview:mat];
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;
    if (!CGRectEqualToRect(glass.frame, gf))          glass.frame              = gf;
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;

    objc_setAssociatedObject(glass, kLGOutsetKey, [NSValue valueWithUIEdgeInsets:outset],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glass, kLGRadiusKey, @(cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!mat.hidden) mat.hidden = YES;
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius);

void LGResyncGlassGeometry(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    NSValue *ov  = objc_getAssociatedObject(glass, kLGOutsetKey);
    NSNumber *rv = objc_getAssociatedObject(glass, kLGRadiusKey);
    LGSyncGlassGeometry(mat, assocKey, ov ? ov.UIEdgeInsetsValue : UIEdgeInsetsZero,
                        rv ? rv.doubleValue : -1.0);
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    CGRect gf = LGOutsetFrame(mat.frame, outset);
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;

    if (!CGRectEqualToRect(glass.frame, gf)) {
        glass.frame = gf;
    }
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    if (!mat.hidden) mat.hidden = YES;
}

void LGRemoveGlassFromMaterial(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    objc_setAssociatedObject(mat, assocKey, nil, OBJC_ASSOCIATION_ASSIGN);
    mat.hidden = NO;

    [glass removeFromSuperview];
}

BOOL LGMaterialHasGlass(UIView *mat, const void *assocKey) {
    return objc_getAssociatedObject(mat, assocKey) != nil;
}
