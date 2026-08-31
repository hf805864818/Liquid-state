#import "LGSharedSupport.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>

__attribute__((weak)) int __isOSVersionAtLeast(int major, int minor, int patch) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != major) return version.majorVersion > major;
    if (version.minorVersion != minor) return version.minorVersion > minor;
    return version.patchVersion >= patch;
}

NSString * const LGPrefsDomain = @"dylv.liquidassprefs";
CFStringRef const LGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
CFStringRef const LGPrefsRespringNotification = CFSTR("dylv.liquidassprefs/Respring");
const char * const LGPrefsChangedNotificationCString = "dylv.liquidassprefs/Reload";
const char * const LGPrefsRespringNotificationCString = "dylv.liquidassprefs/Respring";
const CGFloat LGKeyboardDefaultCornerRadius = 28.0;
const CGFloat LGKeyboardDefaultOverhang = 20.0;
const CGFloat LGBannerDefaultCornerRadius = 18.5;
const CGFloat LGBannerDefaultBezelWidth = 18.0;
const CGFloat LGBannerDefaultBlur = 40.0;
const CGFloat LGBannerDefaultDarkTintAlpha = 0.5;
const CGFloat LGBannerDefaultGlassThickness = 150.0;
const CGFloat LGBannerDefaultLightTintAlpha = 0.8;
const CGFloat LGBannerDefaultRefractionScale = 1.5;
const CGFloat LGBannerDefaultRefractiveIndex = 4.0;
const CGFloat LGBannerDefaultSpecularOpacity = 0.6;
const CGFloat LGBannerDefaultWallpaperScale = 1.0;
NSString * const LGBannerWindowClassName = @"SBBannerWindow";
NSString * const LGBannerContentViewClassName = @"BNContentViewControllerView";
NSString * const LGBannerControllerClassName = @"BNContentViewController";
NSString * const LGBannerPresentableControllerClassName = @"SBNotificationPresentableViewController";
NSString * const LGAppLibrarySidebarMarkerClassName = @"_SBHLibraryFrozenSafeAreaInsetsView";
NSString * const LGTintOverrideSystem = @"system";
NSString * const LGTintOverrideLight = @"light";
NSString * const LGTintOverrideDark = @"dark";
static NSString * const LGPrefsDidReloadInProcessNotification = @"dylv.liquidassprefs.InProcessReload";

static NSDictionary<NSString *, id> *sLGCachedPreferences = nil;
static os_unfair_lock sLGPrefsLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t sLGPrefsSetupOnce;
#if LIQUIDASS_DEBUG
static dispatch_queue_t sLGLogQueue;
static NSFileHandle *sLGLogHandle;
#endif
static void *kLGImageStableCacheKeyAssociation = &kLGImageStableCacheKeyAssociation;
#if LIQUIDASS_DEBUG
static const unsigned long long kLGLogMaxFileSize = 10ULL * 1024ULL * 1024ULL;
#endif

static NSDictionary<NSString *, id> *LGCopyPreferencesDictionary(void);

#if LIQUIDASS_DEBUG
static void LGCloseLogHandle(void) {
    if (!sLGLogHandle) return;
    if (@available(iOS 13.0, *)) {
        [sLGLogHandle closeAndReturnError:nil];
    } else {
        [sLGLogHandle closeFile];
    }
    sLGLogHandle = nil;
}

static void LGCloseLogHandleAtExit(void) {
    if (!sLGLogQueue) {
        LGCloseLogHandle();
        return;
    }
    dispatch_sync(sLGLogQueue, ^{
        LGCloseLogHandle();
    });
}

static NSString *LGLogFilePath(void) {
    static NSString *sPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if TARGET_OS_SIMULATOR
        sPath = @"/tmp/liquidglass.log";
#else

        if ([NSBundle.mainBundle.bundleIdentifier
                isEqualToString:@"com.apple.mobilesafari"]) {
            NSString *temporaryDirectory = NSTemporaryDirectory();
            sPath = [temporaryDirectory
                stringByAppendingPathComponent:@"liquidglass.log"];
        } else {
            sPath = @"/var/mobile/Library/Accessibility/liquidglass.log";
        }
#endif
    });
    return sPath;
}

static void LGTrimLogFileIfNeeded(NSString *path, NSUInteger incomingLength) {
    if (!path.length || incomingLength == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary<NSFileAttributeKey, id> *attributes = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long currentSize = attributes.fileSize;
    if (currentSize + incomingLength <= kLGLogMaxFileSize) return;

    LGCloseLogHandle();

    NSData *existingData = [NSData dataWithContentsOfFile:path];
    NSUInteger keepLength = (NSUInteger)MIN((unsigned long long)existingData.length, kLGLogMaxFileSize / 2ULL);
    NSData *tailData = keepLength > 0 ? [existingData subdataWithRange:NSMakeRange(existingData.length - keepLength, keepLength)] : NSData.data;
    NSMutableData *trimmedData = [NSMutableData data];
    NSString *marker = [NSString stringWithFormat:@"[LiquidAss] log truncated at %@\n", [NSDate date]];
    NSData *markerData = [marker dataUsingEncoding:NSUTF8StringEncoding];
    if (markerData.length) [trimmedData appendData:markerData];
    if (tailData.length) [trimmedData appendData:tailData];
    [trimmedData writeToFile:path atomically:YES];
}

static void LGAppendLogLine(NSString *line, BOOL capped) {
    NSString *path = LGLogFilePath();
    if (!path.length || !line.length) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGLogQueue = dispatch_queue_create("dylv.liquidass.logfile", DISPATCH_QUEUE_SERIAL);
        atexit(LGCloseLogHandleAtExit);
    });

    dispatch_async(sLGLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            NSError *createError = nil;
            [NSData.data writeToFile:path options:NSDataWritingAtomic error:&createError];
            if (createError) {
                NSLog(@"[LiquidAss] log file create failed %@", createError.localizedDescription ?: @"unknown");
                return;
            }
        }

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length) {
            return;
        }
        if (capped) {
            LGTrimLogFileIfNeeded(path, data.length);
        }

        if (!sLGLogHandle) {
            sLGLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (!sLGLogHandle) {
            NSLog(@"[LiquidAss] log file open failed %@", path);
            return;
        }

        NSError *handleError = nil;
        if (@available(iOS 13.0, *)) {
            [sLGLogHandle seekToEndReturningOffset:nil error:&handleError];
            if (!handleError) {
                [sLGLogHandle writeData:data error:&handleError];
            }
        } else {
            @try {
                [sLGLogHandle seekToEndOfFile];
                [sLGLogHandle writeData:data];
            } @catch (NSException *exception) {
                handleError = [NSError errorWithDomain:@"dylv.liquidass.logfile"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"NSFileHandle exception"}];
            }
        }

        if (handleError) {
            LGCloseLogHandle();
            NSLog(@"[LiquidAss] log file append failed %@", handleError.localizedDescription ?: @"unknown");
        }
    });
}
#endif

static NSDictionary<NSString *, id> *LGCopyPreferencesDictionary(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    CFDictionaryRef values = CFPreferencesCopyMultiple(NULL,
                                                       (__bridge CFStringRef)LGPrefsDomain,
                                                       kCFPreferencesCurrentUser,
                                                       kCFPreferencesAnyHost);
    NSDictionary *dictionary = CFBridgingRelease(values);
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return dictionary;
}

static void LGPreferencesChanged(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGReloadPreferences();
        [[NSNotificationCenter defaultCenter] postNotificationName:LGPrefsDidReloadInProcessNotification object:nil];
    });
}

static void LGEnsurePreferenceCacheInitialized(void) {
    dispatch_once(&sLGPrefsSetupOnce, ^{
        LGReloadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        LGPreferencesChanged,
                                        LGPrefsChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

NSString *LGMainBundleIdentifier(void) {
    static NSString *bundleID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundleID = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"";
    });
    return bundleID;
}

BOOL LGIsSpringBoardProcess(void) {
    return [LGMainBundleIdentifier() isEqualToString:@"com.apple.springboard"];
}

BOOL LGIsPreferencesProcess(void) {
    return [LGMainBundleIdentifier() isEqualToString:@"com.apple.Preferences"];
}

BOOL LGIsAtLeastiOS16(void) {
    static BOOL cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return cached;
}

NSString *LGRWBDefaultWidgetBundleIDsText(void) {
    static NSString *text;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        text = [@[
            @"com.apple.mobiletimer.WorldClockWidget",
            @"com.apple.mobilecal.CalendarWidgetExtension",
            @"com.apple.mobilemail.MailWidgetExtension",
            @"com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension",
            @"com.apple.reminders.WidgetExtension",
            @"com.apple.weather.widget",
            @"com.apple.Fitness.FitnessWidget",
            @"com.apple.Passbook.PassbookWidgets",
            @"com.apple.Health.Sleep.SleepWidgetExtension",
            @"com.apple.tips.TipsSwift",
            @"com.apple.Music.MusicWidgets",
            @"com.apple.gamecenter.widgets.extension",
            @"com.apple.tv.TVWidgetExtension",
            @"com.apple.news.widget",
            @"com.apple.Maps.GeneralMapsWidget",
        ] componentsJoinedByString:@"\n"];
    });
    return text;
}

CGFloat LGEffectiveBannerBlur(CGFloat configuredBlur) {
    return fmin(80.0, fmax(0.0, configuredBlur) * 2.2);
}

void LGReloadPreferences(void) {
    NSDictionary<NSString *, id> *dictionary = LGCopyPreferencesDictionary();
    os_unfair_lock_lock(&sLGPrefsLock);
    sLGCachedPreferences = dictionary;
    os_unfair_lock_unlock(&sLGPrefsLock);
}

void LGObservePreferenceChanges(dispatch_block_t block) {
    if (!block) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:LGPrefsDidReloadInProcessNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        block();
    }];
}

static id LGPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    LGEnsurePreferenceCacheInitialized();
    NSDictionary<NSString *, id> *preferences = nil;
    os_unfair_lock_lock(&sLGPrefsLock);
    preferences = sLGCachedPreferences;
    os_unfair_lock_unlock(&sLGPrefsLock);
    return preferences[key];
}

BOOL LGHasExplicitPreferenceValue(NSString *key) {
    if (!key.length) return NO;
    LGEnsurePreferenceCacheInitialized();
    NSDictionary<NSString *, id> *preferences = nil;
    os_unfair_lock_lock(&sLGPrefsLock);
    preferences = sLGCachedPreferences;
    os_unfair_lock_unlock(&sLGPrefsLock);
    return preferences[key] != nil;
}

BOOL LG_prefBool(NSString *key, BOOL fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return fallback;
}

CGFloat LG_prefFloat(NSString *key, CGFloat fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return (CGFloat)[value doubleValue];
    return fallback;
}

NSInteger LG_prefInteger(NSString *key, NSInteger fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    return fallback;
}

NSString *LG_prefString(NSString *key, NSString *fallback) {
    id value = LGPreferenceValue(key);
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return fallback;
}

BOOL LG_globalEnabled(void) {
    return LG_prefBool(@"Global.Enabled", NO);
}

BOOL LG_currentAppIsExcluded(void) {
    static BOOL sChecked = NO;
    static BOOL sExcluded = NO;
    if (sChecked) return sExcluded;

    // SpringBoard and Preferences processes are never excluded
    if (LGIsSpringBoardProcess() || LGIsPreferencesProcess()) {
        sChecked = YES;
        sExcluded = NO;
        return NO;
    }

    id stored = LGPreferenceValue(@"AppExclusion.List");
    NSString *exclusions = [stored isKindOfClass:NSString.class]
        ? (NSString *)stored : @"";
    if (!exclusions.length) {
        sChecked = YES;
        sExcluded = NO;
        return NO;
    }

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n,;"];

    for (NSString *rawEntry in [exclusions componentsSeparatedByCharactersInSet:separators]) {
        NSString *entry = [rawEntry stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (!entry.length || [entry hasPrefix:@"#"]) continue;
        if ([entry isEqualToString:bundleID] || [entry isEqualToString:executable] ||
            [entry isEqualToString:processName]) {
            sExcluded = YES;
            break;
        }
    }
    sChecked = YES;
    return sExcluded;
}

void LGLog(NSString *format, ...) {
#if LIQUIDASS_DEBUG
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss] %@", message);
    LGAppendLogLine([NSString stringWithFormat:@"[LiquidAss] %@\n", message], YES);
#else
    (void)format;
#endif
}

CGColorSpaceRef LGSharedRGBColorSpace(void) {
    static CGColorSpaceRef sColorSpace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sColorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return sColorSpace;
}

UIImage *LGNormalizedImageForUpload(UIImage *image) {
    if (!image) return nil;
    if (image.imageOrientation == UIImageOrientationUp) return image;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

NSNumber *LGTextureScaleKey(CGFloat scale) {
    NSInteger milli = (NSInteger)lrint(scale * 1000.0);
    return @(MAX(milli, 1));
}

NSNumber *LGBlurSettingKey(CGFloat blur) {
    NSInteger milli = (NSInteger)lrint(fmax(0.0, blur) * 1000.0);
    return @(MAX(milli, 0));
}

NSString *LGImageStableCacheKey(UIImage *image) {
    if (!image) return nil;
    return objc_getAssociatedObject(image, kLGImageStableCacheKeyAssociation);
}

void LGSetImageStableCacheKey(UIImage *image, NSString *cacheKey) {
    if (!image) return;
    objc_setAssociatedObject(image,
                             kLGImageStableCacheKeyAssociation,
                             [cacheKey copy],
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

UIColor *LGAverageColorOfImage(UIImage *image) {
    if (!image) return nil;

    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return nil;

    // Downscale for performance - use a thumbnail size
    size_t thumbSize = 50;
    CGFloat scale = MIN((CGFloat)thumbSize / width, (CGFloat)thumbSize / height);
    size_t scaledWidth = MAX(1, (size_t)(width * scale));
    size_t scaledHeight = MAX(1, (size_t)(height * scale));

    CGColorSpaceRef colorSpace = LGSharedRGBColorSpace();
    unsigned char *buffer = calloc(scaledWidth * scaledHeight * 4, sizeof(unsigned char));
    if (!buffer) return nil;

    CGContextRef context = CGBitmapContextCreate(buffer,
                                                  scaledWidth,
                                                  scaledHeight,
                                                  8,
                                                  scaledWidth * 4,
                                                  colorSpace,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) {
        free(buffer);
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, scaledWidth, scaledHeight), cgImage);
    CGContextRelease(context);

    CGFloat totalR = 0.0, totalG = 0.0, totalB = 0.0;
    NSUInteger pixelCount = scaledWidth * scaledHeight;

    for (NSUInteger i = 0; i < pixelCount; i++) {
        NSUInteger offset = i * 4;
        CGFloat r = buffer[offset] / 255.0;
        CGFloat g = buffer[offset + 1] / 255.0;
        CGFloat b = buffer[offset + 2] / 255.0;
        CGFloat a = buffer[offset + 3] / 255.0;
        if (a < 0.01) continue; // skip fully transparent pixels

        totalR += r;
        totalG += g;
        totalB += b;
    }

    free(buffer);

    if (pixelCount == 0) return [UIColor grayColor];

    CGFloat avgR = totalR / pixelCount;
    CGFloat avgG = totalG / pixelCount;
    CGFloat avgB = totalB / pixelCount;

    return [UIColor colorWithRed:avgR green:avgG blue:avgB alpha:1.0];
}

UIColor *LGAdjustedTintColorFromAverageColor(UIColor *averageColor, BOOL darkMode) {
    if (!averageColor) return nil;

    CGFloat r = 0, g = 0, b = 0, a = 0;
    [averageColor getRed:&r green:&g blue:&b alpha:&a];

    // Convert to HSB for better color adjustment
    CGFloat hue = 0, saturation = 0, brightness = 0;
    [averageColor getHue:&hue saturation:&saturation brightness:&brightness alpha:nil];

    if (darkMode) {
        // Dark mode: boost saturation slightly, keep brightness moderate
        saturation = MIN(1.0, saturation * 1.2);
        brightness = MAX(0.2, brightness * 0.6);
    } else {
        // Light mode: boost saturation, lower brightness for better tint effect
        saturation = MIN(1.0, saturation * 1.3);
        brightness = MAX(0.3, brightness * 0.75);
    }

    return [UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1.0];
}
