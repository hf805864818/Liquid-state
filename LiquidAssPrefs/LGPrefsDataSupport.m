#import "LGPrefsDataSupport.h"
#import "LGPRootListController.h"
#import "LGPrefsLiquidSlider.h"
#import "LGPrefsLiquidSwitch.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGHostRegistry.h"
#import <notify.h>

// Forward declaration - defined later in this file
static NSArray<NSDictionary *> *LGModuleResetItem(NSString *actionName, NSString *title, NSString *subtitle);

NSString * const kLGPrefsUIRefreshNotification = @"LGPrefsUIRefreshNotification";
NSString * const kLGPrefsRespringChangedNotification = @"LGPrefsRespringChangedNotification";
NSString * const kLGLastSurfaceKey = @"LGPrefsLastSurface";
NSString * const kLGPrefsLanguageChangedNotification = @"LGPrefsLanguageChangedNotification";
NSString * const kLGPrefsLanguageKey = @"LGPrefsLanguage";
static NSString * const kLGNeedsRespringKey = @"LGPrefsNeedsRespring";
static NSString * const kLGRespringBarDismissedKey = @"LGPrefsRespringBarDismissed";
static dispatch_queue_t sLGPrefsWriteQueue;
static NSString * const kLGDynamicDefaultPrefix = @"__dynamic_default.";
static NSMutableDictionary<NSString *, id> *sLGPendingPreferences;
static NSMutableSet<NSString *> *sLGPendingPreferenceRemovals;

static void LGEnsurePendingPreferencesInitialized(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGPendingPreferences = [NSMutableDictionary dictionary];
        sLGPendingPreferenceRemovals = [NSMutableSet set];
    });
}

static void LGEnsurePreferencesWriteQueueInitialized(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGPrefsWriteQueue = dispatch_queue_create("dylv.liquidass.prefswrite", DISPATCH_QUEUE_SERIAL);
    });
}

static NSArray<NSString *> *LGExportablePreferenceKeys(void) {
    NSMutableOrderedSet<NSString *> *orderedKeys = [NSMutableOrderedSet orderedSet];
    NSArray<NSArray<NSDictionary *> *> *sources = @[
        LGAllSurfaceItems(),
        LGMoreOptionsItems(),
        LGPrefsSettingsItems()
    ];
    for (NSArray<NSDictionary *> *items in sources) {
        for (NSDictionary *item in items) {
            NSString *key = item[@"key"];
            if (key.length) [orderedKeys addObject:key];
        }
    }
    return orderedKeys.array;
}

// 获取所有可导出参数的 key→默认值 映射
// 用于导出备份时包含所有参数（包括用户未修改过的默认值）
static NSDictionary<NSString *, id> *LGExportablePreferenceDefaults(void) {
    NSMutableDictionary<NSString *, id> *defaults = [NSMutableDictionary dictionary];
    NSArray<NSArray<NSDictionary *> *> *sources = @[
        LGAllSurfaceItems(),
        LGMoreOptionsItems(),
        LGPrefsSettingsItems()
    ];
    for (NSArray<NSDictionary *> *items in sources) {
        for (NSDictionary *item in items) {
            NSString *key = item[@"key"];
            id defaultValue = item[@"default"];
            if (key.length && defaultValue && defaults[key] == nil) {
                defaults[key] = defaultValue;
            }
        }
    }
    return [defaults copy];
}

static NSBundle *LGActiveLocalizationBundle(void) {
    NSString *languageCode = [LGPrefsUIStateDefaults() stringForKey:kLGPrefsLanguageKey];
    NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
    if (!languageCode.length) {
        languageCode = @"zh-Hans";
    }
    if ([languageCode isEqualToString:@"en"]) {
        return baseBundle;
    }

    NSString *bundlePath = [baseBundle pathForResource:languageCode ofType:@"lproj"];
    if (!bundlePath.length) {
        return baseBundle;
    }

    NSBundle *localizedBundle = [NSBundle bundleWithPath:bundlePath];
    return localizedBundle ?: baseBundle;
}

static NSString *LGDisplayNameForLanguageCode(NSString *languageCode) {
    if (!languageCode.length) return @"";
    if ([languageCode isEqualToString:@"en"]) return @"English";

    NSLocale *displayLocale = [NSLocale currentLocale];
    NSString *localeIdentifier = [NSLocale canonicalLocaleIdentifierFromString:languageCode];
    NSString *name = [displayLocale displayNameForKey:NSLocaleIdentifier value:localeIdentifier];
    if (!name.length) {
        NSDictionary *components = [NSLocale componentsFromLocaleIdentifier:localeIdentifier];
        NSString *baseLanguageCode = components[NSLocaleLanguageCode];
        if (baseLanguageCode.length) {
            name = [displayLocale localizedStringForLanguageCode:baseLanguageCode];
        }
    }
    return name.length ? name : languageCode;
}

static NSArray<NSDictionary *> *LGAvailableLanguageChoices(void) {
    static NSArray<NSDictionary *> *choices;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
        NSMutableOrderedSet<NSString *> *codes = [NSMutableOrderedSet orderedSetWithObjects:@"zh-Hans", @"en", nil];
        for (NSString *path in [baseBundle pathsForResourcesOfType:@"lproj" inDirectory:nil]) {
            NSString *languageCode = [[path lastPathComponent] stringByDeletingPathExtension];
            if (languageCode.length && ![languageCode isEqualToString:@"Base"]) {
                [codes addObject:languageCode];
            }
        }

        NSMutableArray<NSDictionary *> *dynamicChoices = [NSMutableArray arrayWithCapacity:codes.count];
        for (NSString *languageCode in codes) {
            [dynamicChoices addObject:@{
                @"value": languageCode,
                @"title": LGDisplayNameForLanguageCode(languageCode)
            }];
        }

        [dynamicChoices sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
            NSString *leftValue = lhs[@"value"];
            NSString *rightValue = rhs[@"value"];
            if ([leftValue isEqualToString:@"zh-Hans"]) return NSOrderedAscending;
            if ([rightValue isEqualToString:@"zh-Hans"]) return NSOrderedDescending;
            if ([leftValue isEqualToString:@"en"]) return NSOrderedAscending;
            if ([rightValue isEqualToString:@"en"]) return NSOrderedDescending;
            return [lhs[@"title"] localizedCaseInsensitiveCompare:rhs[@"title"]];
        }];
        choices = [dynamicChoices copy];
    });
    return choices;
}

Class LGPrefsSwitchClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSwitch") ?: [UISwitch class];
}

Class LGPrefsSliderClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSlider") ?: [UISlider class];
}

NSUserDefaults *LGPrefsUIStateDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

void LGSynchronizeSurfaceStateDefaults(void) {
    [LGPrefsUIStateDefaults() synchronize];
}

NSString *LGLastSurfaceIdentifier(void) {
    return [LGPrefsUIStateDefaults() stringForKey:kLGLastSurfaceKey];
}

void LGSetLastSurfaceIdentifier(NSString *identifier) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    if (identifier.length) {
        [defaults setObject:identifier forKey:kLGLastSurfaceKey];
    } else {
        [defaults removeObjectForKey:kLGLastSurfaceKey];
    }
    LGSynchronizeSurfaceStateDefaults();
}

void LGClearLastSurfaceIdentifierIfMatching(NSString *identifier) {
    if (!identifier.length) return;
    NSString *current = LGLastSurfaceIdentifier();
    if ([current isEqualToString:identifier]) {
        LGSetLastSurfaceIdentifier(nil);
    }
}

void LGObservePrefsNotifications(id target) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:target
               selector:@selector(handlePrefsUIRefresh:)
                   name:kLGPrefsUIRefreshNotification
                 object:nil];
    [center addObserver:target
               selector:@selector(handleRespringStateChanged:)
                   name:kLGPrefsRespringChangedNotification
                 object:nil];
}

NSString *LGLocalized(NSString *key) {
    NSBundle *bundle = LGActiveLocalizationBundle();
    NSString *localized = [bundle localizedStringForKey:key value:key table:nil];
    if (localized.length && ![localized isEqualToString:key]) return localized;
    NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
    return [baseBundle localizedStringForKey:key value:key table:nil];
}

NSString *LGPrefsAppName(void) {
    return LGLocalized(@"prefs.app_name");
}

NSString *LGCurrentPrefsLanguageCode(void) {
    NSString *languageCode = [LGPrefsUIStateDefaults() stringForKey:kLGPrefsLanguageKey];
    return languageCode.length ? languageCode : @"zh-Hans";
}

void LGSetCurrentPrefsLanguageCode(NSString *languageCode) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    if (!languageCode.length || [languageCode isEqualToString:@"zh-Hans"]) {
        [defaults removeObjectForKey:kLGPrefsLanguageKey];
    } else {
        [defaults setObject:languageCode forKey:kLGPrefsLanguageKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
}

BOOL LGNeedsRespring(void) {
    return [LGPrefsUIStateDefaults() boolForKey:kLGNeedsRespringKey];
}

BOOL LGRespringBarDismissed(void) {
    return [LGPrefsUIStateDefaults() boolForKey:kLGRespringBarDismissedKey];
}

void LGSetRespringBarDismissed(BOOL dismissed) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    [defaults setBool:dismissed forKey:kLGRespringBarDismissedKey];
    LGSynchronizeSurfaceStateDefaults();
}

void LGSetNeedsRespring(BOOL needsRespring) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    [defaults setBool:needsRespring forKey:kLGNeedsRespringKey];
    if (!needsRespring) {
        [defaults setBool:NO forKey:kLGRespringBarDismissedKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsRespringChangedNotification object:nil];
}

void LGForceSynchronizePreferences(void) {
    // controls stage values until apply commits one coherent snapshot
    LGEnsurePendingPreferencesInitialized();

    NSDictionary<NSString *, id> *pendingValues = [sLGPendingPreferences copy];
    NSSet<NSString *> *pendingRemovals = [sLGPendingPreferenceRemovals copy];
    LGEnsurePreferencesWriteQueueInitialized();
    dispatch_sync(sLGPrefsWriteQueue, ^{
        [pendingValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            (void)stop;
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     (__bridge CFPropertyListRef)value,
                                     (__bridge CFStringRef)LGPrefsDomain);
        }];
        for (NSString *key in pendingRemovals) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     NULL,
                                     (__bridge CFStringRef)LGPrefsDomain);
        }
        BOOL wrote = CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        LGLog(@"[prefs-apply] committed=%lu removed=%lu wrote=%d; posting Reload",
              (unsigned long)pendingValues.count,
              (unsigned long)pendingRemovals.count,
              wrote);
        notify_post(LGPrefsChangedNotificationCString);
    });

    [sLGPendingPreferences removeAllObjects];
    [sLGPendingPreferenceRemovals removeAllObjects];

    LGSetRespringBarDismissed(NO);
    LGSetNeedsRespring(YES);
}

NSNumber *LGReadPreference(NSString *key, NSNumber *fallback) {
    id obj = LGReadPreferenceObject(key, fallback);
    return [obj isKindOfClass:[NSNumber class]] ? obj : fallback;
}

id LGReadPreferenceObject(NSString *key, id fallback) {
    LGEnsurePendingPreferencesInitialized();
    if ([sLGPendingPreferences objectForKey:key]) {
        return sLGPendingPreferences[key];
    }
    if ([sLGPendingPreferenceRemovals containsObject:key]) {
        return fallback;
    }
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)LGPrefsDomain);
    id obj = CFBridgingRelease(value);
    
    // Appearance mode fallback: if mode-specific key doesn't exist, try base key
    if (!obj && LGIsSeparateAppearanceModeEnabled()) {
        if ([key hasSuffix:@".Light"]) {
            NSString *baseKey = [key substringToIndex:key.length - @".Light".length];
            if ([sLGPendingPreferences objectForKey:baseKey]) {
                return sLGPendingPreferences[baseKey];
            }
            if (![sLGPendingPreferenceRemovals containsObject:baseKey]) {
                CFPropertyListRef baseValue = CFPreferencesCopyAppValue((__bridge CFStringRef)baseKey,
                                                                        (__bridge CFStringRef)LGPrefsDomain);
                id baseObj = CFBridgingRelease(baseValue);
                if (baseObj) return baseObj;
            }
        } else if ([key hasSuffix:@".Dark"]) {
            NSString *baseKey = [key substringToIndex:key.length - @".Dark".length];
            if ([sLGPendingPreferences objectForKey:baseKey]) {
                return sLGPendingPreferences[baseKey];
            }
            if (![sLGPendingPreferenceRemovals containsObject:baseKey]) {
                CFPropertyListRef baseValue = CFPreferencesCopyAppValue((__bridge CFStringRef)baseKey,
                                                                        (__bridge CFStringRef)LGPrefsDomain);
                id baseObj = CFBridgingRelease(baseValue);
                if (baseObj) return baseObj;
            }
        }
    }
    
    return obj ?: fallback;
}

void LGWritePreference(NSString *key, NSNumber *value) {
    LGWritePreferenceObject(key, value);
}

void LGWritePreferenceObject(NSString *key, id value) {
    if (!key.length || !value) return;
    LGEnsurePendingPreferencesInitialized();

    // If user modifies any setting that isn't part of the theme system itself,
    // clear the current preset theme marker (since they've customized away from the preset)
    static NSString * const kPresetThemeKey = @"PresetTheme.Current";
    if (![key isEqualToString:kPresetThemeKey] &&
        ![key hasPrefix:@"SurfaceSort."] &&
        ![key hasPrefix:@"SettingsControls."] &&
        ![key isEqualToString:@"Global.Enabled"] &&
        ![key hasPrefix:@"LowPower.Active"] &&
        ![key hasPrefix:@"FocusMode.Active"] &&
        ![key hasPrefix:@"DynamicQuality.HighLoadActive"] &&
        ![key hasPrefix:@"MemorySaving.ActivePressure"] &&
        ![key hasPrefix:@"WallpaperTint.LightColor"] &&
        ![key hasPrefix:@"WallpaperTint.DarkColor"] &&
        ![key hasPrefix:@"AdaptiveBlur.CurrentBrightness"]) {
        NSString *currentTheme = sLGPendingPreferences[kPresetThemeKey];
        if (!currentTheme) {
            CFTypeRef existing = CFPreferencesCopyAppValue((__bridge CFStringRef)kPresetThemeKey,
                                                           (__bridge CFStringRef)LGPrefsDomain);
            if (existing) {
                currentTheme = (__bridge_transfer NSString *)existing;
            }
        }
        if ([currentTheme isKindOfClass:[NSString class]] && currentTheme.length > 0) {
            sLGPendingPreferences[kPresetThemeKey] = @"";
            LGLog(@"[prefs-pending] cleared preset theme marker due to user modification of %@", key);
        }
    }

    sLGPendingPreferences[key] = value;
    [sLGPendingPreferenceRemovals removeObject:key];
    LGLog(@"[prefs-pending] staged %@=%@", key, value);
}

void LGWritePreferenceAndMaybeRequireRespring(NSString *key, NSNumber *value) {
    LGWritePreference(key, value);
}

void LGRemovePreference(NSString *key) {
    if (!key.length) return;
    LGEnsurePendingPreferencesInitialized();
    [sLGPendingPreferences removeObjectForKey:key];
    [sLGPendingPreferenceRemovals addObject:key];
    LGLog(@"[prefs-pending] staged removal %@", key);
}

NSDictionary *LGSwitchSetting(NSString *key, NSString *title, NSString *subtitle, BOOL fallback) {
    return @{
        @"type": @"switch",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback)
    };
}

NSDictionary *LGSectionSetting(NSString *title, NSString *subtitle) {
    return @{
        @"type": @"section",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @""
    };
}

static NSDictionary *LGSpacerSetting(CGFloat height, CGFloat afterSpacing) {
    return @{
        @"type": @"section",
        @"title": @"",
        @"subtitle": @"",
        @"height": @(height),
        @"after_spacing": @(afterSpacing)
    };
}

static NSDictionary *LGAboutContentSetting(void) {
    return @{
        @"type": @"about_content"
    };
}

NSDictionary *LGNavSetting(NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @""
    };
}

static NSDictionary *LGKeyedNavSetting(NSString *key, NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @"",
        @"default": @""
    };
}

NSDictionary *LGMenuSetting(NSString *key, NSString *title, NSString *subtitle, NSString *fallback, NSArray<NSDictionary *> *choices) {
    return @{
        @"type": @"menu",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"default": fallback ?: @"",
        @"choices": choices ?: @[]
    };
}

NSDictionary *LGSliderSetting(NSString *key, NSString *title, NSString *subtitle,
                              CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return @{
        @"type": @"slider",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback),
        @"min": @(min),
        @"max": @(max),
        @"decimals": @(decimals)
    };
}

static NSDictionary *LGSettingControlledByKey(NSDictionary *item, NSString *enabledKey, id enabledDefault) {
    NSMutableDictionary *copy = [item mutableCopy];
    if (enabledKey.length) copy[@"enabled_key"] = enabledKey;
    if (enabledDefault) copy[@"enabled_default"] = enabledDefault;
    return [copy copy];
}

static NSArray<NSDictionary *> *LGSettingsControlledByKey(
    NSArray<NSDictionary *> *items, NSString *enabledKey, id enabledDefault) {
    NSMutableArray<NSDictionary *> *controlled =
        [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        [controlled addObject:LGSettingControlledByKey(
            item, enabledKey, enabledDefault)];
    }
    return [controlled copy];
}

NSDictionary *LGGlassEnabledSetting(NSString *key, BOOL fallback) {
    NSMutableDictionary *item = [LGSwitchSetting(key,
                                                 LGLocalized(@"prefs.control.enabled"),
                                                 LGLocalized(@"prefs.subtitle.enabled"),
                                                 fallback) mutableCopy];
    item[@"controls_following_panel"] = @YES;
    return [item copy];
}

static const CGFloat kLGUniversalBlurMax = 50.0f;
static const CGFloat kLGUniversalThicknessMax = 200.0f;
static const CGFloat kLGUniversalRefractiveIndexMax = 5.0f;
static const CGFloat kLGUniversalRefractionMax = 5.0f;
static const CGFloat kLGUniversalDispersionMax = 20.0f;

static NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static const CGFloat kLGUniversalQualityMax = 1.0f;

NSArray<NSDictionary *> *LGRendererItemsForHostPrefix(NSString *prefix) {
    const LGHostDefinition *host = LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    if (!host) return @[];
    NSString *(^key)(NSString *) = ^NSString *(NSString *field) {
        return [prefix stringByAppendingFormat:@".%@", field];
    };
    NSString *lightTint = [NSString stringWithUTF8String:host->lightTintHex];
    NSString *darkTint = [NSString stringWithUTF8String:host->darkTintHex];
    BOOL enabledByDefault = ![prefix isEqualToString:@"AppIcons"];
    return @[
        LGGlassEnabledSetting(key(@"Enabled"), enabledByDefault),
        LGSliderSetting(key(@"BezelRatio"), LGLocalized(@"prefs.control.bezel_ratio"),
                        LGLocalized(@"prefs.subtitle.bezel_ratio"),
                        host->bezelRatio, 0.0, 1.0, 3),
        LGGlassThicknessSetting(key(@"GlassThickness"), host->glassThickness, 0.0, 220.0, 1),
        LGGlassRefractionSetting(key(@"RefractionScale"), host->refractionScale, 0.0, 5.0, 2),
        LGGlassRefractiveIndexSetting(key(@"RefractiveIndex"), host->refractiveIndex, 1.0, 3.0, 2),
        LGSwitchSetting(key(@"DispersionEnabled"),
                        LGLocalized(@"prefs.control.chromatic_dispersion"),
                        LGLocalized(@"prefs.subtitle.chromatic_dispersion"),
                        host->dispersionStrength > 0.001f),
        LGSliderSetting(key(@"DispersionStrength"),
                        LGLocalized(@"prefs.control.dispersion_strength"),
                        LGLocalized(@"prefs.subtitle.dispersion_strength"),
                        host->dispersionStrength, 0.0, kLGUniversalDispersionMax, 1),
        LGGlassSpecularSetting(key(@"SpecularOpacity"), host->specularOpacity, 0.0, 1.0, 2),
        LGGlassBlurSetting(key(@"Blur"), host->blur, 0.0, 50.0, 1),
        @{
            @"type": @"color", @"key": key(@"LightTintColor"),
            @"title": LGLocalized(@"prefs.control.light_tint_color"),
            @"subtitle": LGLocalized(@"prefs.subtitle.light_tint_color"), @"default": lightTint
        }, @{
            @"type": @"color", @"key": key(@"DarkTintColor"),
            @"title": LGLocalized(@"prefs.control.dark_tint_color"),
            @"subtitle": LGLocalized(@"prefs.subtitle.dark_tint_color"), @"default": darkTint
        },
    ];
}

BOOL LGPrefsItemIsVisible(NSDictionary *item) {
    NSString *visibleKey = item[@"visible_key"];
    NSArray *visibleValues = item[@"visible_values"];
    if (!visibleKey.length || visibleValues.count == 0) return YES;

    id fallback = item[@"visible_default"];
    id storedValue = LGReadPreferenceObject(visibleKey, fallback);
    NSString *currentValue = nil;
    if ([storedValue isKindOfClass:NSString.class]) {
        currentValue = storedValue;
    } else if ([storedValue respondsToSelector:@selector(stringValue)]) {
        currentValue = [storedValue stringValue];
    } else if ([storedValue respondsToSelector:@selector(description)]) {
        currentValue = [storedValue description];
    }
    if (!currentValue.length && [fallback isKindOfClass:NSString.class]) {
        currentValue = fallback;
    }
    return currentValue.length && [visibleValues containsObject:currentValue];
}

static NSArray<NSDictionary *> *LGJoinItemGroups(NSArray<NSArray<NSDictionary *> *> *groups) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSArray<NSDictionary *> *group in groups) [items addObjectsFromArray:group];
    return items;
}

static NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.blur"), LGLocalized(@"prefs.subtitle.blur"), fallback, min, kLGUniversalBlurMax, decimals);
}

static NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.glass_thickness"), LGLocalized(@"prefs.subtitle.glass_thickness"), fallback, min, kLGUniversalThicknessMax, decimals);
}

static NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refractive_index"), LGLocalized(@"prefs.subtitle.refractive_index"), fallback, min, kLGUniversalRefractiveIndexMax, decimals);
}

static NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refraction"), LGLocalized(@"prefs.subtitle.refraction"), fallback, min, kLGUniversalRefractionMax, decimals);
}

static NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    (void)fallback; (void)min; (void)max; (void)decimals;

    NSString *enabledKey = [key hasSuffix:@".SpecularOpacity"]
        ? [[key substringToIndex:key.length - @".SpecularOpacity".length]
           stringByAppendingString:@".SpecularEnabled"]
        : key;
    return LGSwitchSetting(enabledKey,
                           LGLocalized(@"prefs.control.specular"),
                           LGLocalized(@"prefs.subtitle.specular"), YES);
}

NSDictionary *LGGlassQualitySetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key,
                           LGLocalized(@"prefs.control.quality"),
                           LGLocalized(@"prefs.subtitle.quality"),
                           fallback,
                           min,
                           MIN(max, kLGUniversalQualityMax),
                           decimals);
}

NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals) {
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%ldf", (long)decimals], value];
}

static NSString *LGSurfaceGroupSortTitle(NSArray<NSDictionary *> *items) {
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"section"]) {
            NSString *title = item[@"title"];
            if (title.length) return title;
        }
    }
    NSString *title = items.firstObject[@"title"];
    return title ?: @"";
}

static NSString *LGSurfaceGroupIdentifier(NSArray<NSDictionary *> *items) {
    // Try to find a unique identifier for this group based on the first enabled key
    for (NSDictionary *item in items) {
        NSString *key = item[@"key"];
        if (key.length && [key hasSuffix:@".Enabled"]) {
            return [key substringToIndex:key.length - 8]; // strip .Enabled
        }
    }
    // For nav-type items, use the surface_identifier
    for (NSDictionary *item in items) {
        NSString *surfaceId = item[@"surface_identifier"];
        if (surfaceId.length) return surfaceId;
    }
    return LGSurfaceGroupSortTitle(items);
}

static NSInteger LGSurfaceDefaultOrderForIdentifier(NSString *identifier) {
    // Default ordering for surfaces
    static NSDictionary *orderMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        orderMap = @{
            // Home group
            @"Dock": @(10),
            @"FolderIcons": @(20),
            @"FolderIcon": @(20),
            @"AppIcons": @(30),
            @"OpenFolder": @(40),
            @"ContextMenu": @(50),
            @"Banner": @(60),
            @"Alerts": @(70),
            @"ControlCenter": @(80),
            @"SearchPill": @(90),
            @"Spotlight": @(100),
            @"Widgets": @(110),
            // Lock group
            @"Notifications": @(200),
            @"NotificationCenter": @(210),
            @"DynamicIsland": @(220),
            @"QuickActions": @(230),
            @"Passcode": @(240),
            @"Clock": @(250),
            @"CoverSheet": @(260),
            // Library group
            @"AppLibraryPods": @(300),
            @"AppLibrarySearch": @(310),
            // System group
            @"GlobalControls": @(400),
            @"Keyboard": @(410),
            @"TabBar": @(420),
        };
    });
    NSNumber *order = orderMap[identifier];
    return order ? order.integerValue : 500;
}

#pragma mark - Separate Light/Dark Appearance Mode

// LGIsSeparateAppearanceModeEnabled is implemented in LGSharedSupport.m

static NSString * const kLGAppearanceEditModeKey = @"LGAppearanceEditMode";

LGAppearanceEditMode LGCurrentAppearanceEditMode(void) {
    if (!LGIsSeparateAppearanceModeEnabled()) {
        return LGAppearanceEditModeUnified;
    }
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kLGAppearanceEditModeKey];
    if (stored) {
        LGAppearanceEditMode mode = stored.integerValue;
        if (mode == LGAppearanceEditModeLight || mode == LGAppearanceEditModeDark) {
            return mode;
        }
    }
    return LGAppearanceEditModeLight;
}

void LGSetCurrentAppearanceEditMode(LGAppearanceEditMode mode) {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kLGAppearanceEditModeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSArray<NSDictionary *> *LGItemsWithAppearanceMode(NSArray<NSDictionary *> *items, LGAppearanceEditMode mode) {
    if (mode == LGAppearanceEditModeUnified || items.count == 0) {
        return items;
    }
    NSString *suffix = (mode == LGAppearanceEditModeDark) ? @".Dark" : @".Light";
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSMutableDictionary *mutableItem = [item mutableCopy];
        NSString *key = mutableItem[@"key"];
        // Skip tint colors - they are already mode-specific by their nature
        if (key.length && ![key hasSuffix:suffix] &&
            ![key hasSuffix:@"LightTintColor"] && ![key hasSuffix:@"DarkTintColor"]) {
            mutableItem[@"key"] = [key stringByAppendingString:suffix];
        }
        // Also handle visible_key if present
        NSString *visibleKey = mutableItem[@"visible_key"];
        if (visibleKey.length && ![visibleKey hasSuffix:suffix] &&
            ![visibleKey hasSuffix:@"LightTintColor"] && ![visibleKey hasSuffix:@"DarkTintColor"]) {
            mutableItem[@"visible_key"] = [visibleKey stringByAppendingString:suffix];
        }
        [result addObject:[mutableItem copy]];
    }
    return result;
}

NSArray<NSDictionary *> *LGSortedItemsBySectionGroups(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSDictionary *> *leadingItems = [NSMutableArray array];
    NSMutableArray<NSArray<NSDictionary *> *> *groups = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *currentGroup = nil;
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"section"]) {
            NSString *title = item[@"title"];
            NSString *subtitle = item[@"subtitle"];
            if (!title.length && !subtitle.length) {
                if (currentGroup) {
                    [currentGroup addObject:item];
                } else {
                    [leadingItems addObject:item];
                }
                continue;
            }
            if (currentGroup.count) {
                [groups addObject:[currentGroup copy]];
            }
            currentGroup = [NSMutableArray arrayWithObject:item];
            continue;
        }
        if (currentGroup) {
            [currentGroup addObject:item];
        } else {
            [leadingItems addObject:item];
        }
    }
    if (currentGroup.count) {
        [groups addObject:[currentGroup copy]];
    }

    // Determine sort mode
    NSString *sortMode = LGReadPreferenceObject(@"SurfaceSort.Mode", @"default");
    if (![sortMode isKindOfClass:[NSString class]]) sortMode = @"default";

    NSArray<NSArray<NSDictionary *> *> *sortedGroups;
    if ([sortMode isEqualToString:@"alphabetical"]) {
        sortedGroups = [groups sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSDictionary *> *lhs,
                                                                                                               NSArray<NSDictionary *> *rhs) {
            NSString *leftTitle = LGSurfaceGroupSortTitle(lhs);
            NSString *rightTitle = LGSurfaceGroupSortTitle(rhs);
            NSComparisonResult result = [leftTitle localizedCaseInsensitiveCompare:rightTitle];
            if (result != NSOrderedSame) return result;
            return [leftTitle compare:rightTitle];
        }];
    } else if ([sortMode isEqualToString:@"custom"]) {
        // Custom order based on user's saved order
        NSArray *customOrder = LGReadPreferenceObject(@"SurfaceSort.CustomOrder", nil);
        if ([customOrder isKindOfClass:[NSArray class]] && customOrder.count > 0) {
            NSMutableDictionary<NSString *, NSNumber *> *orderMap = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < customOrder.count; i++) {
                NSString *ident = customOrder[i];
                if ([ident isKindOfClass:[NSString class]]) {
                    orderMap[ident] = @(i);
                }
            }
            sortedGroups = [groups sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSDictionary *> *lhs,
                                                                                                                   NSArray<NSDictionary *> *rhs) {
                NSString *leftId = LGSurfaceGroupIdentifier(lhs);
                NSString *rightId = LGSurfaceGroupIdentifier(rhs);
                NSInteger leftOrder = orderMap[leftId] ? [orderMap[leftId] integerValue] : NSIntegerMax;
                NSInteger rightOrder = orderMap[rightId] ? [orderMap[rightId] integerValue] : NSIntegerMax;
                if (leftOrder < rightOrder) return NSOrderedAscending;
                if (leftOrder > rightOrder) return NSOrderedDescending;
                return [leftId compare:rightId];
            }];
        } else {
            // Fall back to default if no custom order saved
            sortMode = @"default";
        }
    }

    if ([sortMode isEqualToString:@"default"]) {
        sortedGroups = [groups sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSDictionary *> *lhs,
                                                                                                               NSArray<NSDictionary *> *rhs) {
            NSString *leftId = LGSurfaceGroupIdentifier(lhs);
            NSString *rightId = LGSurfaceGroupIdentifier(rhs);
            NSInteger leftOrder = LGSurfaceDefaultOrderForIdentifier(leftId);
            NSInteger rightOrder = LGSurfaceDefaultOrderForIdentifier(rightId);
            if (leftOrder < rightOrder) return NSOrderedAscending;
            if (leftOrder > rightOrder) return NSOrderedDescending;
            return [leftId compare:rightId];
        }];
    }

    NSMutableArray<NSDictionary *> *sortedItems = [leadingItems mutableCopy];
    for (NSArray<NSDictionary *> *group in sortedGroups) {
        [sortedItems addObjectsFromArray:group];
    }
    return [sortedItems copy];
}

NSArray<NSDictionary *> *LGDockItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"Dock"),
        LGModuleResetItem(@"resetDockToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_dock")),
    ]);
}

NSArray<NSDictionary *> *LGKeyboardItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"Keyboard"),
        LGSettingsControlledByKey(@[
            LGSectionSetting(LGLocalized(@"prefs.section.keyboard_geometry.title"),
                             LGLocalized(@"prefs.section.keyboard_geometry.subtitle")),
            LGSliderSetting(@"Keyboard.CornerRadius",
                            LGLocalized(@"prefs.control.corner_radius"),
                            LGLocalized(@"prefs.subtitle.corner_radius"),
                            LGKeyboardDefaultCornerRadius, 0.0, 60.0, 1),
            LGSliderSetting(@"Keyboard.Overhang",
                            LGLocalized(@"prefs.control.keyboard_overhang"),
                            LGLocalized(@"prefs.subtitle.keyboard_overhang"),
                            LGKeyboardDefaultOverhang, 0.0, 60.0, 1),
        ], @"Keyboard.Enabled", @YES),
    ]);
}

NSArray<NSDictionary *> *LGFolderItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.folder_icons.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"FolderIcon"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.folder_open.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"OpenFolder"),
        LGModuleResetItem(@"resetFolderToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_folder")),
    ]);
}

NSArray<NSDictionary *> *LGAppIconItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.app_icons.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"AppIcons"),
        LGModuleResetItem(@"resetAppIconsToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_app_icons")),
    ]);
}

NSArray<NSDictionary *> *LGSearchPillItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"SearchPill"),
        LGModuleResetItem(@"resetSearchPillToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_search_pill")),
    ]);
}

NSArray<NSDictionary *> *LGContextMenuItems(void) {
    return LGRendererItemsForHostPrefix(@"ContextMenu");
}

static NSArray<NSDictionary *> *LGControlCenterFullscreenBackdropItems(BOOL includeSection) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    if (includeSection) {
        [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.control_center_fullscreen.title"), nil)];
    }
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"ControlCenter.FullscreenBackdropBlurRadius",
                        LGLocalized(@"prefs.control_center.fullscreen_backdrop_blur_radius.title"),
                        LGLocalized(@"prefs.control_center.fullscreen_backdrop_blur_radius.subtitle"),
                        8.0, 0.0, 50.0, 1),
        @"ControlCenter.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(@{
        @"type": @"color",
        @"key": @"ControlCenter.FullscreenBackdropDimColor",
        @"title": LGLocalized(@"prefs.control_center.fullscreen_backdrop_dim_color.title"),
        @"subtitle": LGLocalized(@"prefs.control_center.fullscreen_backdrop_dim_color.subtitle"),
        @"default": @"#00000033"
    }, @"ControlCenter.Enabled", @YES)];
    return [items copy];
}

static NSArray<NSDictionary *> *LGControlCenterCustomBackgroundItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.control_center_custom_bg.title"), nil),
        LGNavSetting(LGLocalized(@"prefs.control_center_custom_bg.title"),
                     LGLocalized(@"prefs.control_center_custom_bg.subtitle"),
                     @"openCustomCCBgSettings"),
    ];
}

static NSArray<NSDictionary *> *LGControlCenterSliderHapticItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.slider_haptics.title"),
                         LGLocalized(@"prefs.section.slider_haptics.subtitle")),
        LGSwitchSetting(@"ControlCenter.SliderHaptics.Enabled",
                        LGLocalized(@"prefs.control.slider_haptics"),
                        LGLocalized(@"prefs.subtitle.slider_haptics"),
                        YES),
        LGSettingControlledByKey(
            LGSliderSetting(@"ControlCenter.SliderHaptics.Intensity",
                            LGLocalized(@"prefs.control.slider_haptics_intensity"),
                            LGLocalized(@"prefs.subtitle.slider_haptics_intensity"),
                            0.5, 0.0, 1.0, 2),
            @"ControlCenter.SliderHaptics.Enabled", @YES),
        LGSettingControlledByKey(
            LGSwitchSetting(@"ControlCenter.SliderHaptics.EdgeFeedback",
                            LGLocalized(@"prefs.control.slider_edge_feedback"),
                            LGLocalized(@"prefs.subtitle.slider_edge_feedback"),
                            YES),
            @"ControlCenter.SliderHaptics.Enabled", @YES),
    ];
}

static NSArray<NSDictionary *> *LGControlCenterSliderDisplayItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.slider_display.title"),
                         LGLocalized(@"prefs.section.slider_display.subtitle")),
        LGSwitchSetting(@"ControlCenter.SliderPercent.Enabled",
                        LGLocalized(@"prefs.control.slider_percent"),
                        LGLocalized(@"prefs.subtitle.slider_percent"),
                        YES),
        LGSwitchSetting(@"ControlCenter.SliderPercent.RandomColor",
                        LGLocalized(@"prefs.control.slider_random_color"),
                        LGLocalized(@"prefs.subtitle.slider_random_color"),
                        NO),
        LGSliderSetting(@"ControlCenter.SliderCornerRadius",
                        LGLocalized(@"prefs.control.slider_corner_radius"),
                        LGLocalized(@"prefs.subtitle.slider_corner_radius"),
                        -1.0, -1.0, 30.0, 1),
    ];
}

NSArray<NSDictionary *> *LGControlCenterItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"ControlCenter"),
        LGControlCenterFullscreenBackdropItems(YES),
        LGControlCenterSliderDisplayItems(),
        LGControlCenterSliderHapticItems(),
        LGControlCenterCustomBackgroundItems(),
        LGModuleResetItem(@"resetControlCenterToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_control_center")),
    ]);
}

static NSArray<NSDictionary *> *LGClockVariableFontItems(void) {

    NSMutableDictionary *variableFontEnabled = [LGSwitchSetting(@"Clock.VariableFont.Enabled",
                                                                  LGLocalized(@"prefs.control.variable_font"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font"),
                                                                  YES) mutableCopy];
    variableFontEnabled[@"controls_following_panel"] = @YES;
    return @[
        LGSpacerSetting(8.0, 0.0),
        variableFontEnabled.copy,
        LGSettingControlledByKey(LGMenuSetting(@"Clock.VariableFont.Name",
                                                LGLocalized(@"prefs.control.variable_font_name"),
                                                LGLocalized(@"prefs.subtitle.variable_font_name"),
                                                @"adaptive",
                                                @[
            @{ @"value": @"soft", @"title": LGLocalized(@"prefs.clock_font.soft_adaptive") },
            @{ @"value": @"adaptive", @"title": LGLocalized(@"prefs.clock_font.adaptive") },
            @{ @"value": @"newyork", @"title": LGLocalized(@"prefs.clock_font.newyork_adaptive") },
        ]), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGNavSetting(LGLocalized(@"prefs.control.variable_font_weight_preset"),
                                                LGLocalized(@"prefs.subtitle.variable_font_weight_preset"),
                                                @"presentClockFontWeightPresets"),
                                  @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Weight",
                                                  LGLocalized(@"prefs.control.variable_font_weight"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_weight"),
                                                  750.0, 1.0, 1000.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.SizeScale",
                                                  LGLocalized(@"prefs.control.variable_font_size"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_size"),
                                                  1.4, 0.8, 2.0, 2), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Width",
                                                  LGLocalized(@"prefs.control.variable_font_width"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_width"),
                                                  100.0, 60.0, 100.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Height",
                                                  LGLocalized(@"prefs.control.variable_font_height"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_height"),
                                                  350.0, 100.0, 500.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Softness",
                                                  LGLocalized(@"prefs.control.variable_font_softness"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_softness"),
                                                  56.0, 0.0, 100.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGNavSetting(LGLocalized(@"prefs.clock_font.reset_default"),
                                                LGLocalized(@"prefs.clock_font.reset_default_subtitle"),
                                                @"resetClockFontToDefault"),
                                  @"Clock.VariableFont.Enabled", @YES),
    ];
}

static NSArray<NSDictionary *> *LGClockDateFormatItems(void) {
    NSMutableDictionary *dateFormatEnabled = [LGSwitchSetting(@"Clock.DateFormat.Enabled",
                                                              LGLocalized(@"prefs.control.custom_date_format"),
                                                              LGLocalized(@"prefs.subtitle.custom_date_format"),
                                                              NO) mutableCopy];
    dateFormatEnabled[@"controls_following_panel"] = @YES;
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.date_format.title"), nil),
        dateFormatEnabled.copy,
        LGSettingControlledByKey(LGNavSetting(LGLocalized(@"prefs.control.date_format"),
                                                LGLocalized(@"prefs.subtitle.date_format"),
                                                @"presentClockDateFormatEditor"),
                                  @"Clock.DateFormat.Enabled", @YES),
    ];
}

NSArray<NSDictionary *> *LGClockItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"Clock"),
        LGClockVariableFontItems(),
        LGClockDateFormatItems(),
        LGModuleResetItem(@"resetClockToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_clock")),
    ]);
}

NSArray<NSDictionary *> *LGTabBarItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"TabBar"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.surface.tab_bar_selection.title"), nil),
        ],
        LGSettingsControlledByKey(
            LGRendererItemsForHostPrefix(@"TabBarSelection"),
            @"TabBar.Enabled", @YES),
        LGModuleResetItem(@"resetTabBarToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_tab_bar")),
    ]);
}

NSArray<NSDictionary *> *LGLockscreenItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_notifications.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"Notification"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.notification_center.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"NotificationCenter"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.dynamic_island.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"DynamicIsland"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_quick_actions.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"QuickActions"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_passcode.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"Passcode"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_clock.title"), nil),
        ],
        LGClockItems(),
        LGModuleResetItem(@"resetLockscreenToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_lockscreen")),
    ]);
}

NSArray<NSDictionary *> *LGAppLibraryItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.category_pods.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"AppLibrary"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.search_field.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"AppLibSearch"),
        LGModuleResetItem(@"resetAppLibraryToDefault",
                          LGLocalized(@"prefs.control.reset_module"),
                          LGLocalized(@"prefs.subtitle.reset_app_library")),
    ]);
}

NSArray<NSDictionary *> *LGWidgetItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"Widgets"),
        @[
            LGKeyedNavSetting(@"RWB.ThirdPartyBundleIDs",
                              LGLocalized(@"prefs.misc.rwb_third_party.title"),
                              LGLocalized(@"prefs.misc.rwb_third_party.subtitle"),
                              @"editThirdPartyAppRWB"),
        ],
    ]);
}

NSArray<NSDictionary *> *LGHomescreenItems(void) {
    NSMutableArray<NSDictionary *> *rendererItems = [NSMutableArray array];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.dock.title"), nil)];
    [rendererItems addObjectsFromArray:LGDockItems()];
    [rendererItems addObjectsFromArray:LGFolderItems()];
    [rendererItems addObjectsFromArray:LGAppIconItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.context_menu.title"), nil)];
    [rendererItems addObjectsFromArray:LGContextMenuItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.alerts.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"Alerts")];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.banner.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"Banner")];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.control_center.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"ControlCenter")];
    [rendererItems addObjectsFromArray:LGControlCenterFullscreenBackdropItems(NO)];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.search_pill.title"), nil)];
    [rendererItems addObjectsFromArray:LGSearchPillItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.spotlight.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"Spotlight")];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.widgets.title"), nil)];
    [rendererItems addObjectsFromArray:LGWidgetItems()];
    return LGSortedItemsBySectionGroups(rendererItems);
}

NSArray<NSDictionary *> *LGAllSurfaceItems(void) {
    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    [all addObject:LGSwitchSetting(@"Global.Enabled", LGLocalized(@"prefs.control.enabled"), LGLocalized(@"prefs.subtitle.global_enabled"), NO)];
    [all addObject:LGGlassQualitySetting(@"Global.Quality", 1.0, 0.1, 1.0, 2)];
    [all addObjectsFromArray:LGHomescreenItems()];
    [all addObjectsFromArray:LGLockscreenItems()];
    [all addObjectsFromArray:LGAppLibraryItems()];
    return [all copy];
}

NSArray<NSDictionary *> *LGPrefsSettingsItems(void) {
    return @[
        LGMenuSetting(kLGPrefsLanguageKey,
                      LGLocalized(@"prefs.misc.language.title"),
                      @"",
                      @"zh-Hans",
                      LGAvailableLanguageChoices()),
        LGSpacerSetting(2.0, 0.0),
        LGAboutContentSetting(),
    ];
}

NSArray<NSDictionary *> *LGGlobalControlsItems(void) {
    return @[
        LGKeyedNavSetting(@"GlobalControls.Exclusions",
                          LGLocalized(@"prefs.global_controls.exclusions.title"),
                          LGLocalized(@"prefs.global_controls.exclusions.subtitle"),
                          @"editGlobalControlsExclusions"),
        LGSectionSetting(LGLocalized(@"prefs.global_controls.section.title"),
                         LGLocalized(@"prefs.global_controls.section.subtitle")),
        LGSwitchSetting(@"GlobalControls.Switches.Enabled",
                        LGLocalized(@"prefs.global_controls.switches.title"),
                        LGLocalized(@"prefs.global_controls.switches.subtitle"), YES),
        LGSwitchSetting(@"GlobalControls.Sliders.Enabled",
                        LGLocalized(@"prefs.global_controls.sliders.title"),
                        LGLocalized(@"prefs.global_controls.sliders.subtitle"), NO),
        LGSwitchSetting(@"GlobalControls.Segmented.Enabled",
                        LGLocalized(@"prefs.global_controls.segmented.title"),
                        LGLocalized(@"prefs.global_controls.segmented.subtitle"), NO),
    ];
}

NSArray<NSDictionary *> *LGMoreOptionsItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.appearance_mode.title"),
                                      LGLocalized(@"prefs.section.appearance_mode.subtitle"))];
    [items addObject:LGSwitchSetting(@"Appearance.SeparateModes",
                                     LGLocalized(@"prefs.control.separate_appearance_modes"),
                                     LGLocalized(@"prefs.subtitle.separate_appearance_modes"),
                                     NO)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.options_section.title"),
                                      LGLocalized(@"prefs.misc.options_section.subtitle"))];
    [items addObject:LGSliderSetting(@"Renderer.FresnelGlareStrength",
                                     LGLocalized(@"prefs.control.fresnel_glare"),
                                     LGLocalized(@"prefs.subtitle.fresnel_glare"),
                                     0.5, 0.0, 1.0, 2)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"SettingsControls.Enabled",
                        LGLocalized(@"prefs.misc.settings_controls.title"),
                        LGLocalized(@"prefs.misc.settings_controls.subtitle"),
                        YES),
        @"Global.Enabled",
        @NO)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.motion_highlights.title"),
                                      LGLocalized(@"prefs.section.motion_highlights.subtitle"))];
    [items addObject:LGSwitchSetting(@"Specular.Motion.Enabled",
                                     LGLocalized(@"prefs.control.motion_highlights"),
                                     LGLocalized(@"prefs.subtitle.motion_highlights"),
                                     YES)];
    [items addObject:LGSliderSetting(@"Specular.Motion.Sensitivity",
                                     LGLocalized(@"prefs.control.motion_highlights_sensitivity"),
                                     LGLocalized(@"prefs.subtitle.motion_highlights_sensitivity"),
                                     2.0,
                                     0.0,
                                     8.0,
                                     2)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.wallpaper_tint.title"),
                                      LGLocalized(@"prefs.section.wallpaper_tint.subtitle"))];
    [items addObject:LGSwitchSetting(@"WallpaperTint.Enabled",
                                     LGLocalized(@"prefs.control.wallpaper_tint"),
                                     LGLocalized(@"prefs.subtitle.wallpaper_tint"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"WallpaperTint.Strength",
                        LGLocalized(@"prefs.control.wallpaper_tint_strength"),
                        LGLocalized(@"prefs.subtitle.wallpaper_tint_strength"),
                        0.6, 0.0, 1.0, 2),
        @"WallpaperTint.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.adaptive_blur.title"),
                                      LGLocalized(@"prefs.section.adaptive_blur.subtitle"))];
    [items addObject:LGSwitchSetting(@"AdaptiveBlur.Enabled",
                                     LGLocalized(@"prefs.control.adaptive_blur"),
                                     LGLocalized(@"prefs.subtitle.adaptive_blur"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"AdaptiveBlur.Intensity",
                        LGLocalized(@"prefs.control.adaptive_blur_intensity"),
                        LGLocalized(@"prefs.subtitle.adaptive_blur_intensity"),
                        0.5, 0.0, 1.0, 2),
        @"AdaptiveBlur.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"AdaptiveBlur.MinBlur",
                        LGLocalized(@"prefs.control.adaptive_blur_min"),
                        LGLocalized(@"prefs.subtitle.adaptive_blur_min"),
                        10.0, 0.0, 40.0, 1),
        @"AdaptiveBlur.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"AdaptiveBlur.MaxBlur",
                        LGLocalized(@"prefs.control.adaptive_blur_max"),
                        LGLocalized(@"prefs.subtitle.adaptive_blur_max"),
                        40.0, 10.0, 50.0, 1),
        @"AdaptiveBlur.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.landscape_volume.title"),
                                      LGLocalized(@"prefs.section.landscape_volume.subtitle"))];
    [items addObject:LGSwitchSetting(@"LandscapeVolumeGlass.Enabled",
                                     LGLocalized(@"prefs.control.landscape_volume_glass"),
                                     LGLocalized(@"prefs.subtitle.landscape_volume_glass"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"LandscapeVolumeGlass.CornerRadius",
                        LGLocalized(@"prefs.control.landscape_volume_radius"),
                        LGLocalized(@"prefs.subtitle.landscape_volume_radius"),
                        16.0, 0.0, 40.0, 1),
        @"LandscapeVolumeGlass.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"LandscapeVolumeGlass.Blur",
                        LGLocalized(@"prefs.control.landscape_volume_blur"),
                        LGLocalized(@"prefs.subtitle.landscape_volume_blur"),
                        20.0, 0.0, 50.0, 1),
        @"LandscapeVolumeGlass.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.volume_hud.title"),
                                      LGLocalized(@"prefs.section.volume_hud.subtitle"))];
    [items addObject:LGSwitchSetting(@"VolumeHUDGlass.Enabled",
                                     LGLocalized(@"prefs.control.volume_hud_glass"),
                                     LGLocalized(@"prefs.subtitle.volume_hud_glass"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"VolumeHUDGlass.CornerRadius",
                        LGLocalized(@"prefs.control.volume_hud_radius"),
                        LGLocalized(@"prefs.subtitle.volume_hud_radius"),
                        20.0, 0.0, 50.0, 1),
        @"VolumeHUDGlass.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"VolumeHUDGlass.Blur",
                        LGLocalized(@"prefs.control.volume_hud_blur"),
                        LGLocalized(@"prefs.subtitle.volume_hud_blur"),
                        15.0, 0.0, 50.0, 1),
        @"VolumeHUDGlass.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.banner_animation.title"),
                                      LGLocalized(@"prefs.section.banner_animation.subtitle"))];
    [items addObject:LGSwitchSetting(@"Banner.Animation.SmoothGlass",
                                     LGLocalized(@"prefs.control.banner_smooth_glass"),
                                     LGLocalized(@"prefs.subtitle.banner_smooth_glass"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"Banner.Animation.Duration",
                        LGLocalized(@"prefs.control.banner_animation_duration"),
                        LGLocalized(@"prefs.subtitle.banner_animation_duration"),
                        0.5, 0.2, 1.2, 2),
        @"Banner.Animation.SmoothGlass", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"Banner.Animation.SpringEffect",
                        LGLocalized(@"prefs.control.banner_spring"),
                        LGLocalized(@"prefs.subtitle.banner_spring"),
                        YES),
        @"Banner.Animation.SmoothGlass", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.low_power.title"),
                                      LGLocalized(@"prefs.section.low_power.subtitle"))];
    [items addObject:LGSwitchSetting(@"LowPower.Enabled",
                                     LGLocalized(@"prefs.control.low_power_mode"),
                                     LGLocalized(@"prefs.subtitle.low_power_mode"),
                                     YES)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"LowPower.BlurReduction",
                        LGLocalized(@"prefs.control.low_power_blur_reduction"),
                        LGLocalized(@"prefs.subtitle.low_power_blur_reduction"),
                        0.5, 0.0, 1.0, 2),
        @"LowPower.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"LowPower.DisableDispersion",
                        LGLocalized(@"prefs.control.low_power_disable_dispersion"),
                        LGLocalized(@"prefs.subtitle.low_power_disable_dispersion"),
                        YES),
        @"LowPower.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.focus_mode.title"),
                                      LGLocalized(@"prefs.section.focus_mode.subtitle"))];
    [items addObject:LGSwitchSetting(@"FocusMode.Enabled",
                                     LGLocalized(@"prefs.control.focus_mode"),
                                     LGLocalized(@"prefs.subtitle.focus_mode"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"FocusMode.BlurReduction",
                        LGLocalized(@"prefs.control.focus_blur_reduction"),
                        LGLocalized(@"prefs.subtitle.focus_blur_reduction"),
                        0.3, 0.0, 1.0, 2),
        @"FocusMode.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"FocusMode.ThicknessReduction",
                        LGLocalized(@"prefs.control.focus_thickness_reduction"),
                        LGLocalized(@"prefs.subtitle.focus_thickness_reduction"),
                        0.2, 0.0, 1.0, 2),
        @"FocusMode.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"FocusMode.DisableDispersion",
                        LGLocalized(@"prefs.control.focus_disable_dispersion"),
                        LGLocalized(@"prefs.subtitle.focus_disable_dispersion"),
                        NO),
        @"FocusMode.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.dynamic_quality.title"),
                                      LGLocalized(@"prefs.section.dynamic_quality.subtitle"))];
    [items addObject:LGSwitchSetting(@"DynamicQuality.Enabled",
                                     LGLocalized(@"prefs.control.dynamic_quality"),
                                     LGLocalized(@"prefs.subtitle.dynamic_quality"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"DynamicQuality.Aggressiveness",
                        LGLocalized(@"prefs.control.dynamic_aggressiveness"),
                        LGLocalized(@"prefs.subtitle.dynamic_aggressiveness"),
                        0.4, 0.1, 1.0, 2),
        @"DynamicQuality.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.memory_saving.title"),
                                      LGLocalized(@"prefs.section.memory_saving.subtitle"))];
    [items addObject:LGSwitchSetting(@"MemorySaving.Enabled",
                                     LGLocalized(@"prefs.control.memory_saving"),
                                     LGLocalized(@"prefs.subtitle.memory_saving"),
                                     NO)];
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"MemorySaving.Level",
                        LGLocalized(@"prefs.control.memory_saving_level"),
                        LGLocalized(@"prefs.subtitle.memory_saving_level"),
                        0.5, 0.0, 1.0, 2),
        @"MemorySaving.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"MemorySaving.PressureBoost",
                        LGLocalized(@"prefs.control.memory_pressure_boost"),
                        LGLocalized(@"prefs.subtitle.memory_pressure_boost"),
                        YES),
        @"MemorySaving.Enabled", @YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.app_exclusion.title"),
                                      LGLocalized(@"prefs.section.app_exclusion.subtitle"))];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.control.app_exclusion_list"),
                                  LGLocalized(@"prefs.subtitle.app_exclusion_list"),
                                  @"editAppExclusionList")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.cc_quick_toggle.title"),
                                      LGLocalized(@"prefs.section.cc_quick_toggle.subtitle"))];
    [items addObject:LGSwitchSetting(@"QuickToggle.CCEnabled",
                                     LGLocalized(@"prefs.control.cc_quick_toggle"),
                                     LGLocalized(@"prefs.subtitle.cc_quick_toggle"),
                                     YES)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.surface_sort.title"),
                                      LGLocalized(@"prefs.section.surface_sort.subtitle"))];
    [items addObject:LGMenuSetting(@"SurfaceSort.Mode",
                                   LGLocalized(@"prefs.control.surface_sort_mode"),
                                   LGLocalized(@"prefs.subtitle.surface_sort_mode"),
                                   @"default",
                                   @[
        @{@"value": @"default", @"title": LGLocalized(@"prefs.surface_sort.default")},
        @{@"value": @"alphabetical", @"title": LGLocalized(@"prefs.surface_sort.alphabetical")},
        @{@"value": @"custom", @"title": LGLocalized(@"prefs.surface_sort.custom")},
    ])];
    [items addObject:LGSettingControlledByKey(
        LGNavSetting(LGLocalized(@"prefs.control.custom_sort_order"),
                     LGLocalized(@"prefs.subtitle.custom_sort_order"),
                     @"configureCustomSort"),
        @"SurfaceSort.Mode", @"custom")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.preset_themes.title"),
                                      LGLocalized(@"prefs.section.preset_themes.subtitle"))];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.control.browse_themes"),
                                  LGLocalized(@"prefs.subtitle.browse_themes"),
                                  @"browsePresetThemes")];
    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.import_export_section.title"),
                                      LGLocalized(@"prefs.misc.import_export_section.subtitle"))];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.export_prefs.title"),
                                  LGLocalized(@"prefs.misc.export_prefs.subtitle"),
                                  @"exportPreferences")];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.import_prefs.title"),
                                  LGLocalized(@"prefs.misc.import_prefs.subtitle"),
                                  @"importPreferences")];
    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.debug_section.title"),
                                      LGLocalized(@"prefs.misc.debug_section.subtitle"))];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.copy_debug_info.title"),
                                  LGLocalized(@"prefs.misc.copy_debug_info.subtitle"),
                                  @"copyDebugInfo")];

    return [items copy];
}

NSString *LGDebugInfoString(void) {
    NSMutableString *info = [NSMutableString string];

    // App & version
    [info appendFormat:@"Ai液态玻璃 %@\n", LG_PACKAGE_VERSION];

    // Device info
    UIDevice *device = [UIDevice currentDevice];
    [info appendFormat:@"Device: %@\n", device.model];
    [info appendFormat:@"iOS: %@\n", device.systemVersion];
    [info appendFormat:@"Language: %@\n", LGCurrentPrefsLanguageCode() ?: @"unknown"];

    // Key settings
    [info appendString:@"\n--- Key Settings ---\n"];
    [info appendFormat:@"Global.Enabled: %@\n", LGReadPreferenceObject(@"Global.Enabled", @YES)];
    [info appendFormat:@"Global.Quality: %@\n", LGReadPreferenceObject(@"Global.Quality", @(1.0))];
    [info appendFormat:@"SurfaceSort.Mode: %@\n", LGReadPreferenceObject(@"SurfaceSort.Mode", @"default")];
    [info appendFormat:@"PresetTheme.Current: %@\n", LGReadPreferenceObject(@"PresetTheme.Current", @"balanced")];

    // Performance features
    [info appendString:@"\n--- Performance ---\n"];
    [info appendFormat:@"LowPower.Enabled: %@\n", LGReadPreferenceObject(@"LowPower.Enabled", @YES)];
    [info appendFormat:@"FocusMode.Enabled: %@\n", LGReadPreferenceObject(@"FocusMode.Enabled", @NO)];
    [info appendFormat:@"DynamicQuality.Enabled: %@\n", LGReadPreferenceObject(@"DynamicQuality.Enabled", @YES)];
    [info appendFormat:@"MemorySaving.Enabled: %@\n", LGReadPreferenceObject(@"MemorySaving.Enabled", @NO)];
    [info appendFormat:@"AdaptiveBlur.Enabled: %@\n", LGReadPreferenceObject(@"AdaptiveBlur.Enabled", @YES)];

    // Host enabled status
    [info appendString:@"\n--- Surfaces ---\n"];
    NSArray *surfaces = @[
        @"Dock", @"FolderIcon", @"OpenFolder", @"AppIcons",
        @"ControlCenter", @"Notification", @"NotificationCenter",
        @"DynamicIsland", @"CoverSheet", @"Widgets", @"ContextMenu",
        @"Alerts", @"QuickActions", @"Passcode", @"Clock",
        @"TabBar", @"Keyboard", @"AppLibrary", @"Spotlight",
        @"SearchPill", @"Banner", @"LandscapeVolume"
    ];
    for (NSString *surface in surfaces) {
        NSString *key = [NSString stringWithFormat:@"%@.Enabled", surface];
        NSNumber *enabled = LGReadPreferenceObject(key, nil);
        if (enabled) {
            [info appendFormat:@"%@.Enabled: %@\n", surface, enabled];
        }
    }

    return [info copy];
}

NSString *LGExportPreferencesJSONString(void) {
    NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, id> *defaults = LGExportablePreferenceDefaults();
    for (NSString *key in LGExportablePreferenceKeys()) {
        // 优先用用户设置的值，没有则用默认值
        // 这样备份文件包含所有参数，导入后能完整恢复
        id value = LGReadPreferenceObject(key, nil);
        if (!value) {
            value = defaults[key];
        }
        if (!value) continue;
        preferences[key] = value;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"format"] = @"liquidass-prefs";
    payload[@"version"] = @"1";
    payload[@"preferences"] = preferences;
    NSString *languageCode = LGCurrentPrefsLanguageCode();
    if (languageCode.length) {
        payload[@"ui_language"] = languageCode;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

BOOL LGImportPreferencesJSONString(NSString *jsonString, NSError **error) {
    if (!jsonString.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_empty")}];
        }
        return NO;
    }

    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSString *format = payload[@"format"];
    NSString *version = payload[@"version"];
    if (![format isKindOfClass:[NSString class]] ||
        ![format isEqualToString:@"liquidass-prefs"] ||
        ![version isKindOfClass:[NSString class]] ||
        ![version isEqualToString:@"1"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSDictionary *preferences = payload[@"preferences"];
    if (![preferences isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSSet<NSString *> *allowedKeys = [NSSet setWithArray:LGExportablePreferenceKeys()];
    __block NSUInteger importedCount = 0;
    [preferences enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:[NSString class]]) return;
        if (![allowedKeys containsObject:key]) return;
        if (!obj || obj == [NSNull null]) {
            LGRemovePreference(key);
        } else {
            LGWritePreferenceObject(key, obj);
        }
        importedCount += 1;
    }];

    NSString *languageCode = payload[@"ui_language"];
    if ([languageCode isKindOfClass:[NSString class]] && languageCode.length) {
        LGSetCurrentPrefsLanguageCode(languageCode);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];

    if (importedCount == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_empty")}];
        }
        return NO;
    }
    return YES;
}

void LGResetAllPreferences(void) {
    CFArrayRef allKeys = CFPreferencesCopyKeyList((__bridge CFStringRef)LGPrefsDomain,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost);
    NSArray *keys = CFBridgingRelease(allKeys);
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([(NSString *)key isEqualToString:@"Global.Enabled"]) continue;
        if ([(NSString *)key hasPrefix:kLGDynamicDefaultPrefix]) continue;
        LGRemovePreference((NSString *)key);
    }
    [LGPrefsUIStateDefaults() removeObjectForKey:kLGPrefsLanguageKey];
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
}

void LGResetPreferencesForKeys(NSArray<NSString *> *keys) {
    if (![keys isKindOfClass:[NSArray class]] || keys.count == 0) return;

    NSMutableOrderedSet<NSString *> *uniqueKeys = [NSMutableOrderedSet orderedSet];
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if (![(NSString *)key length]) continue;
        if ([(NSString *)key isEqualToString:@"Global.Enabled"]) continue;
        if ([(NSString *)key hasPrefix:kLGDynamicDefaultPrefix]) continue;
        [uniqueKeys addObject:(NSString *)key];
    }
    if (uniqueKeys.count == 0) return;

    for (NSString *key in uniqueKeys) {
        LGRemovePreference(key);
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
}

NSArray<NSString *> *LGKeysFromItems(NSArray<NSDictionary *> *items) {
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *item in items) {
        NSString *key = item[@"key"];
        if (key.length) [keys addObject:key];
    }
    return keys.array;
}

static NSArray<NSDictionary *> *LGModuleResetItem(NSString *actionName, NSString *title, NSString *subtitle) {
    return @[
        LGSectionSetting(@"", @""),
        LGNavSetting(title, subtitle, actionName),
    ];
}

#pragma mark - Preset Themes

static NSString * const kLGPresetThemeKey = @"PresetTheme.Current";

NSArray<NSDictionary *> *LGPresetThemes(void) {
    return @[
        @{
            @"id": @"balanced",
            @"name": LGLocalized(@"prefs.theme.balanced"),
            @"subtitle": LGLocalized(@"prefs.theme.balanced.subtitle"),
        },
        @{
            @"id": @"light",
            @"name": LGLocalized(@"prefs.theme.light"),
            @"subtitle": LGLocalized(@"prefs.theme.light.subtitle"),
        },
        @{
            @"id": @"deep",
            @"name": LGLocalized(@"prefs.theme.deep"),
            @"subtitle": LGLocalized(@"prefs.theme.deep.subtitle"),
        },
        @{
            @"id": @"matte",
            @"name": LGLocalized(@"prefs.theme.matte"),
            @"subtitle": LGLocalized(@"prefs.theme.matte.subtitle"),
        },
        @{
            @"id": @"crystal",
            @"name": LGLocalized(@"prefs.theme.crystal"),
            @"subtitle": LGLocalized(@"prefs.theme.crystal.subtitle"),
        },
        @{
            @"id": @"neon",
            @"name": LGLocalized(@"prefs.theme.neon"),
            @"subtitle": LGLocalized(@"prefs.theme.neon.subtitle"),
        },
        @{
            @"id": @"paper",
            @"name": LGLocalized(@"prefs.theme.paper"),
            @"subtitle": LGLocalized(@"prefs.theme.paper.subtitle"),
        },
        @{
            @"id": @"aurora",
            @"name": LGLocalized(@"prefs.theme.aurora"),
            @"subtitle": LGLocalized(@"prefs.theme.aurora.subtitle"),
        },
    ];
}

NSString *LGCurrentPresetTheme(void) {
    id value = LGReadPreferenceObject(kLGPresetThemeKey, @"balanced");
    if ([value isKindOfClass:[NSString class]]) return value;
    return @"balanced";
}

static NSDictionary *LGThemePresets(NSString *themeId) {
    // Theme presets define global quality and per-host multiplier values
    // These are applied on top of defaults to create the theme feel

    static NSDictionary *themes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        themes = @{
            @"balanced": @{
                @"Global.Quality": @(1.0),
                // Default balanced look - no overrides needed
            },
            @"light": @{
                @"Global.Quality": @(1.0),
                // Light & Airy: lighter tint, less blur, thinner glass
                @"blurMultiplier": @(0.6),
                @"thicknessMultiplier": @(0.7),
                @"refractionMultiplier": @(0.8),
                @"lightTint": @"#FFFFFF0D",
                @"darkTint": @"#00000000",
            },
            @"deep": @{
                @"Global.Quality": @(1.0),
                // Deep & Rich: thicker glass, stronger refraction, more blur
                @"blurMultiplier": @(1.4),
                @"thicknessMultiplier": @(1.4),
                @"refractionMultiplier": @(1.3),
                @"dispersionMultiplier": @(1.2),
                @"lightTint": @"#FFFFFF26",
                @"darkTint": @"#00000066",
            },
            @"matte": @{
                @"Global.Quality": @(0.9),
                // Matte Frosted: high blur, low refraction, no dispersion
                @"blurMultiplier": @(1.8),
                @"thicknessMultiplier": @(0.8),
                @"refractionMultiplier": @(0.3),
                @"dispersionMultiplier": @(0.0),
                @"specularMultiplier": @(0.5),
                @"lightTint": @"#FFFFFF1A",
                @"darkTint": @"#00000033",
            },
            @"crystal": @{
                @"Global.Quality": @(1.0),
                // Crystal Clear: minimal blur, high refraction, strong dispersion
                @"blurMultiplier": @(0.3),
                @"thicknessMultiplier": @(1.2),
                @"refractionMultiplier": @(1.5),
                @"dispersionMultiplier": @(2.0),
                @"specularMultiplier": @(1.3),
                @"lightTint": @"#FFFFFF0A",
                @"darkTint": @"#0000001A",
            },
            @"neon": @{
                @"Global.Quality": @(1.0),
                // Neon Glow: cyberpunk style with intense dispersion and deep tint
                @"blurMultiplier": @(0.8),
                @"thicknessMultiplier": @(1.1),
                @"refractionMultiplier": @(1.6),
                @"dispersionMultiplier": @(2.5),
                @"specularMultiplier": @(1.5),
                @"lightTint": @"#00FFFF14",
                @"darkTint": @"#FF00FF40",
            },
            @"paper": @{
                @"Global.Quality": @(0.8),
                // Paper Texture: warm matte paper feel with soft diffusion
                @"blurMultiplier": @(2.0),
                @"thicknessMultiplier": @(0.6),
                @"refractionMultiplier": @(0.2),
                @"dispersionMultiplier": @(0.0),
                @"specularMultiplier": @(0.3),
                @"lightTint": @"#FFF5E633",
                @"darkTint": @"#2D24164D",
            },
            @"aurora": @{
                @"Global.Quality": @(1.0),
                // Aurora Dream: dreamy gradient with flowing dispersion
                @"blurMultiplier": @(1.1),
                @"thicknessMultiplier": @(1.0),
                @"refractionMultiplier": @(1.2),
                @"dispersionMultiplier": @(1.8),
                @"specularMultiplier": @(0.9),
                @"lightTint": @"#7FFF7F1A",
                @"darkTint": @"#4B008259",
            },
        };
    });
    return themes[themeId];
}

void LGApplyPresetTheme(NSString *themeId) {
    if (!themeId.length) return;

    NSDictionary *theme = LGThemePresets(themeId);
    if (!theme) return;

    // Reset all preferences first to get a clean slate
    LGResetAllPreferences();

    // Save the current theme identifier
    LGWritePreferenceObject(kLGPresetThemeKey, themeId);

    // Apply global quality
    NSNumber *quality = theme[@"Global.Quality"];
    if (quality) LGWritePreference(@"Global.Quality", quality);

    // Apply per-host multipliers by iterating through all host definitions
    for (size_t i = 0; i < LGHostIdentifierCount; ++i) {
        const LGHostDefinition *host = &kLGHostRegistry[i];
        NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
        if (!prefix.length || [prefix isEqualToString:@"Default"]) continue;

        // Blur multiplier
        NSNumber *blurMult = theme[@"blurMultiplier"];
        if (blurMult) {
            CGFloat baseBlur = host->blur;
            CGFloat newBlur = baseBlur * blurMult.floatValue;
            LGWritePreference([prefix stringByAppendingString:@".Blur"], @(newBlur));
        }

        // Thickness multiplier
        NSNumber *thickMult = theme[@"thicknessMultiplier"];
        if (thickMult) {
            CGFloat baseThick = host->glassThickness;
            CGFloat newThick = baseThick * thickMult.floatValue;
            LGWritePreference([prefix stringByAppendingString:@".GlassThickness"], @(newThick));
        }

        // Refraction multiplier
        NSNumber *refrMult = theme[@"refractionMultiplier"];
        if (refrMult) {
            CGFloat baseRefr = host->refractionScale;
            CGFloat newRefr = baseRefr * refrMult.floatValue;
            LGWritePreference([prefix stringByAppendingString:@".RefractionScale"], @(newRefr));
        }

        // Dispersion multiplier
        NSNumber *dispMult = theme[@"dispersionMultiplier"];
        if (dispMult) {
            CGFloat baseDisp = host->dispersionStrength;
            CGFloat newDisp = baseDisp * dispMult.floatValue;
            LGWritePreference([prefix stringByAppendingString:@".DispersionStrength"], @(newDisp));
            LGWritePreference([prefix stringByAppendingString:@".DispersionEnabled"],
                              @(newDisp > 0.01f));
        }

        // Specular multiplier
        NSNumber *specMult = theme[@"specularMultiplier"];
        if (specMult) {
            CGFloat baseSpec = host->specularOpacity;
            CGFloat newSpec = baseSpec * specMult.floatValue;
            LGWritePreference([prefix stringByAppendingString:@".SpecularOpacity"], @(newSpec));
        }

        // Tint colors
        NSString *lightTint = theme[@"lightTint"];
        if (lightTint) {
            LGWritePreferenceObject([prefix stringByAppendingString:@".LightTintColor"], lightTint);
        }
        NSString *darkTint = theme[@"darkTint"];
        if (darkTint) {
            LGWritePreferenceObject([prefix stringByAppendingString:@".DarkTintColor"], darkTint);
        }
    }

    // Post notification to refresh UI
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
}
