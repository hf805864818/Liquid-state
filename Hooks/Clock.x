#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <objc/runtime.h>

extern BOOL LG_prefBool(NSString *key, BOOL fallback);
extern CGFloat LG_prefFloat(NSString *key, CGFloat fallback);
extern NSString *LG_prefString(NSString *key, NSString *fallback);

#define LG_FLOAT_PREF_FUNC(fn, key, def)        static CGFloat fn(void) { return LG_prefFloat(@key, (CGFloat)(def)); }
#define LG_BOOL_PREF_FUNC(fn, key, def)         static BOOL fn(void) { return LG_prefBool(@key, (def)); }
#define LG_STRING_PREF_FUNC(fn, key, def)       static NSString *fn(void) { return LG_prefString(@key, (def)); }

static void LGClockLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGClockLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[CLK] %@", s);
}

#pragma mark - Cross-process glyph mask

static NSString *LGClockMaskPath(void) {
    return @"/var/mobile/Library/Accessibility/liquidglass-clock-mask.bin";
}
static CFStringRef const LGClockMaskReloadNotification =
    CFSTR("dylv.liquidglass/ClockMaskReload");

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    float imageScale;
    float bezelWidthPoints;
    uint64_t generation;
} LGClockMaskHeader;

// backboardd reads this packed alpha mask directly
static BOOL LGWriteClockMaskImage(UIImage *image, uint64_t generation) {
    CGImageRef cg = image.CGImage;
    if (!cg) return NO;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    if (!width || !height || width > UINT32_MAX || height > UINT32_MAX) return NO;

    size_t rgbaBytes = width * height * 4;
    uint8_t *rgba = (uint8_t *)calloc(1, rgbaBytes);
    uint8_t *alpha = (uint8_t *)malloc(width * height);
    BOOL wrote = NO;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = rgba && alpha
        ? CGBitmapContextCreate(rgba, width, height, 8, width * 4, colorSpace,
                                kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast)
        : NULL;
    if (context) {

        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
        for (size_t i = 0; i < width * height; i++) alpha[i] = rgba[i * 4 + 3];

        LGClockMaskHeader header = {
            0x4c474333,
            (uint32_t)width,
            (uint32_t)height,
            (float)MAX(image.scale, 1.0),
            20.0f, // 原 12.0f，加大边缘宽度增强液态立体感
            generation,
        };
        NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
        [data appendBytes:alpha length:width * height];
        if ([data writeToFile:LGClockMaskPath() options:NSDataWritingAtomic error:nil]) {
            wrote = YES;
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 LGClockMaskReloadNotification,
                                                 NULL, NULL, true);
        }
    }
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    free(alpha);
    free(rgba);
    return wrote;
}

static inline BOOL LGIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}
static inline BOOL LGIsAtLeastiOS16(void) {
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}
static inline BOOL LGHasAncestorClassNamed(UIView *v, NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) return NO;
    for (UIView *a = v.superview; a; a = a.superview)
        if ([a isKindOfClass:c]) return YES;
    return NO;
}
static void LGTraverseViews(UIView *root, void (^block)(UIView *)) {
    if (!root) return;
    block(root);
    for (UIView *s in root.subviews) LGTraverseViews(s, block);
}

// 诊断用: 递归 dump 视图树结构
static void LGClockDumpViewTree(UIView *view, NSInteger depth, NSMutableString *out) {
    if (!view || !out) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    [out appendFormat:@"\n%@%@ frame=%@ hidden=%d alpha=%.2f clips=%d",
     indent, NSStringFromClass(view.class),
     NSStringFromCGRect(view.bounds), view.hidden, view.alpha, view.clipsToBounds];
    for (UIView *s in view.subviews) {
        LGClockDumpViewTree(s, depth + 1, out);
    }
}
#pragma mark - Display-link lifecycle

typedef struct { __unsafe_unretained CADisplayLink *link; } LGClockDisplayLink;

@interface LGClockDisplayLinkTarget : NSObject
@property (nonatomic, copy) void (^tick)(void);
@end
@implementation LGClockDisplayLinkTarget
- (void)fire { if (self.tick) self.tick(); }
@end

static void LGStartClockDisplayLinkDriver(LGClockDisplayLink *state, void (^tick)(void)) {
    if (state->link) return;
    LGClockDisplayLinkTarget *target = [LGClockDisplayLinkTarget new];
    target.tick = tick;
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(fire)];

    if (@available(iOS 15.0, *))
        displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 60.0, 60.0);
    [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    state->link = displayLink;
}
static void LGStopClockDisplayLinkDriver(LGClockDisplayLink *state) {
    [state->link invalidate];
    state->link = nil;
}

#pragma mark - Clock live backdrop

@interface LGClockBackdropView : LGLiveBackdropView
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic, strong) UIImage *shapeMaskImage;
@property (nonatomic, strong) UIImageView *shapeMaskView;
@end
@implementation LGClockBackdropView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame groupName:nil
                    filterType:LGFilterTypeForHostPrefix(@"Clock")];
    if (self) self.hidden = YES;
    return self;
}
- (void)setCornerRadius:(CGFloat)r { _cornerRadius = r; self.layer.cornerRadius = r; }
- (void)setShapeMaskImage:(UIImage *)image {
    _shapeMaskImage = image;
    if (!image) {
        self.maskView = nil;
        self.shapeMaskView = nil;
        return;
    }

    UIImageView *mask = self.shapeMaskView;
    if (!mask) {
        mask = [[UIImageView alloc] initWithFrame:self.bounds];
        mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        mask.contentMode = UIViewContentModeScaleToFill;
        mask.layer.minificationFilter = kCAFilterLinear;
        mask.layer.magnificationFilter = kCAFilterLinear;
        mask.layer.actions = @{
            @"contents": NSNull.null,
            @"bounds": NSNull.null,
            @"position": NSNull.null,
        };
        self.shapeMaskView = mask;
        self.maskView = mask;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = self.bounds;
    mask.image = image;
    [mask.layer setNeedsDisplay];
    [self.layer setNeedsDisplay];
    self.hidden = NO;
    [CATransaction commit];
}
@end

static uint64_t sLGClockMaskNextGeneration = 0;

// generation keeps stale async masks from winning
static void LGQueueClockMaskImage(UIImage *image, LGClockBackdropView *target) {
    if (!image || !target) return;
    uint64_t generation = ++sLGClockMaskNextGeneration;
    if (LGWriteClockMaskImage(image, generation)) {
        target.shapeMaskImage = image;
        [target.layer setNeedsDisplay];
    }
}

static void LGRefreshAllClockHosts(void);

static void *kLGClockOverlayKey = &kLGClockOverlayKey;
static void *kLGClockOriginalAlphaKey = &kLGClockOriginalAlphaKey;
static void *kLGClockOriginalLayerOpacityKey = &kLGClockOriginalLayerOpacityKey;
static void *kLGClockScrollObserverKey = &kLGClockScrollObserverKey;
static void *kLGClockScrollKVOContext = &kLGClockScrollKVOContext;
static void *kLGClockAttachedKey = &kLGClockAttachedKey;
static void *kLGClockLegacyNotificationOriginalFrameKey = &kLGClockLegacyNotificationOriginalFrameKey;
static void *kLGClockLegacyNotificationPendingKey = &kLGClockLegacyNotificationPendingKey;
static void *kLGClockLegacyNotificationApplyingKey = &kLGClockLegacyNotificationApplyingKey;
static void *kLGClockLegacyNotificationLastRelayoutKey = &kLGClockLegacyNotificationLastRelayoutKey;
static void *kLGClockLegacyRevealHintPendingKey = &kLGClockLegacyRevealHintPendingKey;
static void *kLGClockApplyingDateTextKey = &kLGClockApplyingDateTextKey;
static void *kLGClockOriginalDateTextKey = &kLGClockOriginalDateTextKey;
static void *kLGClockLastCustomDateTextKey = &kLGClockLastCustomDateTextKey;
static void *kLGClockLastBailReasonKey = &kLGClockLastBailReasonKey;
static void *kLGClockDeferredApplyPendingKey = &kLGClockDeferredApplyPendingKey;
static void *kLGClockLastDeferredApplyTimeKey = &kLGClockLastDeferredApplyTimeKey;
static LGClockDisplayLink sClockDisplayLink = {0};
static NSHashTable<UIView *> *sClockHosts = nil;
static NSHashTable<UIView *> *sClockNotificationObstacleViews = nil;
static NSHashTable<UIView *> *sClockLegacyRevealHintViews = nil;
static CFTimeInterval sClockActiveFPSUntil = 0.0;
static BOOL sClockCoverSheetVisible = NO;
static BOOL sClockObstacleRefreshPending = NO;
static BOOL sClockRecoveryRefreshPending = NO;
static void LGClockMarkMotionActiveForDuration(CFTimeInterval duration);
static void LGClockSyncDisplayLinkActivity(void);
static NSHashTable<UIView *> *LGClockHostRegistry(void);
static void LGClockSetCoverSheetVisible(BOOL visible);
static void LGRefreshRegisteredClockHosts(void);
static void LGScheduleClockApply(UIView *host, BOOL includeRecoveryRetry, CFTimeInterval minimumInterval);
static void LGScheduleClockRecoveryRefresh(void);
static void LGClockCleanupRegisteredHosts(void);
static void LGClockRegisterNotificationObstacleView(UIView *view);
static void LGClockRegisterLegacyRevealHintView(UIView *view);
static void LGScheduleClockRefreshForLegacyRevealHint(UIView *view);

@interface UIView (LGClockDisplayLinkRefresh)
- (void)refreshForDisplayLink;
@end

LG_BOOL_PREF_FUNC(LGClockVariableFontEnabled, "Clock.VariableFont.Enabled", YES)
LG_STRING_PREF_FUNC(LGClockVariableFontName, "Clock.VariableFont.Name", @"adaptive")
LG_FLOAT_PREF_FUNC(LGClockVariableFontSizeScale, "Clock.VariableFont.SizeScale", 1.4)
LG_FLOAT_PREF_FUNC(LGClockVariableFontWeight, "Clock.VariableFont.Weight", 750.0)
LG_FLOAT_PREF_FUNC(LGClockVariableFontWidth, "Clock.VariableFont.Width", 100.0)
LG_FLOAT_PREF_FUNC(LGClockVariableFontHeight, "Clock.VariableFont.Height", 350.0)
LG_FLOAT_PREF_FUNC(LGClockVariableFontSoftness, "Clock.VariableFont.Softness", 56.0)
LG_BOOL_PREF_FUNC(LGClockDateFormatEnabled, "Clock.DateFormat.Enabled", NO)

static BOOL LGClockViewIsVisiblyPresent(UIView *view);
static BOOL LGClockHasBlockingPresentation(UIView *host);
static CGFloat LGClockNearestNotificationTop(UIView *host, UIView *container, CGRect sourceFrame);
static UIView *LGClockFindLegacyClockHostInWindow(UIWindow *window);
static UIView *LGClockFindModernClockHostInWindow(UIWindow *window);
static UIView *LGClockNearestHostForView(UIView *view);
static BOOL LGClockShouldMutateStockLayoutForView(UIView *view);

static void LGSetLayerTreeOpacity(CALayer *layer, float opacity) {
    if (!layer) return;
    layer.opacity = opacity;
    for (CALayer *sub in layer.sublayers) {
        LGSetLayerTreeOpacity(sub, opacity);
    }
}

static BOOL LGClockEnabled(void) {
    return lgHostEnabled(@"Clock");
}

static BOOL LGClockFrostedModeEnabled(void) {
    // 直接从 CFPreferences 读取，避免 plist 文件缓存不同步
    CFTypeRef cfValue = CFPreferencesCopyAppValue(CFSTR("Clock.FrostedMode"),
                                                  CFSTR("dylv.liquidassprefs"));
    BOOL result = NO;
    if (cfValue) {
        if (CFGetTypeID(cfValue) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)cfValue);
        } else if (CFGetTypeID(cfValue) == CFNumberGetTypeID()) {
            // 用 char 类型代替 kCFNumberBoolType（旧版 SDK 不支持）
            char boolVal = 0;
            if (CFNumberGetValue((CFNumberRef)cfValue, kCFNumberCharType, &boolVal)) {
                result = boolVal ? YES : NO;
            }
        }
        CFRelease(cfValue);
    }
    return result;
}

static NSHashTable<UIView *> *LGClockNotificationObstacleViews(void) {
    if (!sClockNotificationObstacleViews) {
        sClockNotificationObstacleViews = [NSHashTable weakObjectsHashTable];
    }
    return sClockNotificationObstacleViews;
}

static NSHashTable<UIView *> *LGClockLegacyRevealHintViews(void) {
    if (!sClockLegacyRevealHintViews) {
        sClockLegacyRevealHintViews = [NSHashTable weakObjectsHashTable];
    }
    return sClockLegacyRevealHintViews;
}

static BOOL LGClockViewIsNearAnyClockHost(UIView *view) {
    if (!view || !view.window) return NO;
    UIWindow *window = view.window;
    CGRect cellFrame = [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(cellFrame)) return NO;
    for (UIView *host in LGClockHostRegistry().allObjects) {
        if (!host.window || host.window != window) continue;
        if (!LGClockViewIsVisiblyPresent(host)) continue;
        CGRect hostFrame = [host convertRect:host.bounds toView:window];
        if (CGRectIsEmpty(hostFrame)) continue;
        CGFloat dist = 0.0;
        if (CGRectGetMinY(cellFrame) > CGRectGetMaxY(hostFrame))
            dist = CGRectGetMinY(cellFrame) - CGRectGetMaxY(hostFrame);
        else if (CGRectGetMaxY(cellFrame) < CGRectGetMinY(hostFrame))
            dist = CGRectGetMinY(hostFrame) - CGRectGetMaxY(cellFrame);
        if (dist <= 500.0) return YES;
    }
    return NO;
}

static void LGClockRegisterNotificationObstacleView(UIView *view) {
    if (!view) return;

    [LGClockNotificationObstacleViews() addObject:view];

    if (!view.window || sClockObstacleRefreshPending) return;
    if (!LGClockViewIsNearAnyClockHost(view)) return;
    sClockObstacleRefreshPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sClockObstacleRefreshPending = NO;
        LGRefreshRegisteredClockHosts();
    });
}

static void LGClockRegisterLegacyRevealHintView(UIView *view) {
    if (!view) return;
    [LGClockLegacyRevealHintViews() addObject:view];
}

static void LGScheduleClockRefreshForLegacyRevealHint(UIView *view) {
    if (!view || LGIsAtLeastiOS16()) return;
    LGClockRegisterLegacyRevealHintView(view);
    if ([objc_getAssociatedObject(view, kLGClockLegacyRevealHintPendingKey) boolValue]) return;
    objc_setAssociatedObject(view, kLGClockLegacyRevealHintPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(view, kLGClockLegacyRevealHintPendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (view.window) {
            LGRefreshRegisteredClockHosts();
        }
    });
}

static void LGClockSeedObstacleRegistriesFromWindow(UIWindow *window) {
    if (!window) return;
    LGTraverseViews(window, ^(UIView *view) {
        NSString *className = NSStringFromClass(view.class);
        if ([className isEqualToString:@"PLPlatterView"] ||
            [className isEqualToString:@"NCNotificationShortLookView"] ||
            [className isEqualToString:@"NCNotificationLongLookView"]) {
            LGClockRegisterNotificationObstacleView(view);
        } else if ([className isEqualToString:@"NCNotificationListSectionRevealHintView"]) {
            LGClockRegisterLegacyRevealHintView(view);
        }
    });
}

#pragma mark - Variable font loading

static NSString *LGClockVariableFontFileName(void) {
    NSString *fontName = LGClockVariableFontName();
    if ([fontName isEqualToString:@"soft"]) return @"LWAdaptiveSoftNumeric.ttf";
    if ([fontName isEqualToString:@"newyork"]) return @"LWNewYorkAdaptiveNumeric.ttf";
    // default: adaptive
    return @"LWAdaptiveNumeric.ttf";
}

static NSArray<NSString *> *LGClockVariableFontDylibRelativePaths(void) {
    Dl_info info = {0};
    if (dladdr((const void *)&LGClockVariableFontDylibRelativePaths, &info) == 0) return @[];
    if (!info.dli_fname) return @[];

    NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
    if (!dylibPath.length) return @[];

    NSString *fontFileName = LGClockVariableFontFileName();
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
    NSArray<NSString *> *bases = @[
        dylibPath,
        [dylibPath stringByResolvingSymlinksInPath],
    ];

    for (NSString *basePath in bases) {
        if (!basePath.length) continue;
        NSString *cursor = [basePath stringByDeletingLastPathComponent];
        for (NSUInteger depth = 0; depth < 8 && cursor.length > 1; depth++) {
            [candidates addObject:[[cursor stringByAppendingPathComponent:@"Library/PreferenceBundles/LiquidAssPrefs.bundle"]
                stringByAppendingPathComponent:fontFileName]];
            NSString *parent = [cursor stringByDeletingLastPathComponent];
            if ([parent isEqualToString:cursor]) break;
            cursor = parent;
        }
    }

    return candidates.array ?: @[];
}

static NSString *LGClockVariableFontPath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *fontFileName = LGClockVariableFontFileName();
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        [candidates addObjectsFromArray:LGClockVariableFontDylibRelativePaths()];
        [candidates addObjectsFromArray:@[
            jbroot([@"/Library/PreferenceBundles/LiquidAssPrefs.bundle" stringByAppendingPathComponent:fontFileName]),
        ]];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *candidate in candidates) {
            if ([fm fileExistsAtPath:candidate]) {
                path = [candidate copy];
                break;
            }
        }
        if (!path.length) {
            LGClockLog(@"clock variable font path not found candidates=%@", candidates);
        }
    });
    return path;
}

static BOOL LGAxisNameMatches(NSString *axisName, NSString *needle, NSString *shortNeedle) {
    if (![axisName isKindOfClass:[NSString class]]) return NO;
    NSString *lower = axisName.lowercaseString;
    return [lower containsString:needle] || [lower containsString:shortNeedle];
}

static NSDictionary<NSString *, NSNumber *> *sClockVariableAxisIdentifiers = nil;
static NSDictionary<NSString *, NSArray<NSNumber *> *> *sClockVariableAxisRanges = nil;
static NSString *sClockVariablePostScriptName = nil;
static CGFontRef sClockVariableCGFont = NULL;
static CTFontRef LGClockVariableCTFont(CGFloat pointSize);
static CTFontRef LGClockVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue);
static CTFontRef LGClockLegacyVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue);
static CGRect LGClockExpandedModernFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject,
                                                NSTextAlignment alignment);
static CGRect LGClockExpandedLegacyFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject);

static CGFloat LGClockModernSyntheticEmbolden(void) {
    if (!LGIsAtLeastiOS16()) return 0.0;
    if (!LGClockVariableFontEnabled()) return 0.0;
    CGFloat weight = LGClockVariableFontWeight();
    if (weight <= 400.0) return 0.0;
    return MIN(2.0, ((weight - 400.0) / 600.0) * 2.0);
}
static void LGApplyClockReplacement(UIView *host);

static BOOL LGClockLegacyUsesVariableFont(void) {
    return LGClockVariableFontEnabled();
}

static BOOL LGClockLegacyNotificationShiftEnabled(void) {
    return LGClockLegacyUsesVariableFont();
}

static CGFloat LGClockLegacyNotificationClockGap(void) {
    return 28.0;
}

static NSHashTable<UIView *> *LGClockHostRegistry(void) {
    if (!sClockHosts) {
        sClockHosts = [NSHashTable weakObjectsHashTable];
    }
    return sClockHosts;
}

static void LGEnsureClockVariableFontMetadata(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *fontPath = LGClockVariableFontPath();
        if (!fontPath.length) return;

        NSURL *fontURL = [NSURL fileURLWithPath:fontPath];
        NSData *fontData = [NSData dataWithContentsOfURL:fontURL];
        if (![fontData isKindOfClass:[NSData class]] || fontData.length == 0) {
            LGClockLog(@"clock variable font read failed path=%@", fontPath);
            return;
        }

        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)fontData);
        if (!provider) {
            LGClockLog(@"clock variable font provider create failed path=%@", fontPath);
            return;
        }
        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            LGClockLog(@"clock variable font CGFont create failed path=%@", fontPath);
            return;
        }
        sClockVariableCGFont = cgFont;

        sClockVariablePostScriptName = CFBridgingRelease(CGFontCopyPostScriptName(cgFont));
        CFErrorRef registerError = NULL;
        BOOL registered = CTFontManagerRegisterGraphicsFont(cgFont, &registerError);
        if (!registered && registerError) {
            NSError *error = CFBridgingRelease(registerError);
            LGClockLog(@"clock variable font register failed postscript=%@ error=%@",
                  sClockVariablePostScriptName ?: @"(null)",
                  error);
        }

        CTFontRef baseFont = CTFontCreateWithGraphicsFont(cgFont, 60.0, NULL, NULL);
        NSArray *axes = baseFont ? CFBridgingRelease(CTFontCopyVariationAxes(baseFont)) : nil;
        if (!axes.count) {
            LGClockLog(@"clock variable font has no variation axes postscript=%@", sClockVariablePostScriptName ?: @"(null)");
        }
        NSMutableDictionary<NSString *, NSNumber *> *ids = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *ranges = [NSMutableDictionary dictionary];
        for (NSDictionary *axis in axes) {
            NSString *name = axis[(id)kCTFontVariationAxisNameKey];
            NSNumber *identifier = axis[(id)kCTFontVariationAxisIdentifierKey];
            NSNumber *minimum = axis[(id)kCTFontVariationAxisMinimumValueKey];
            NSNumber *maximum = axis[(id)kCTFontVariationAxisMaximumValueKey];
            if (![identifier isKindOfClass:[NSNumber class]]) continue;

            NSString *key = nil;
            if (LGAxisNameMatches(name, @"weight", @"wght")) key = @"weight";
            else if (LGAxisNameMatches(name, @"width", @"wdth")) key = @"width";
            else if (LGAxisNameMatches(name, @"height", @"hght")) key = @"height";
            else if (LGAxisNameMatches(name, @"soft", @"soft")) key = @"softness";
            if (!key.length) continue;

            ids[key] = identifier;
            ranges[key] = @[
                @([minimum isKindOfClass:[NSNumber class]] ? minimum.doubleValue : -CGFLOAT_MAX),
                @([maximum isKindOfClass:[NSNumber class]] ? maximum.doubleValue : CGFLOAT_MAX),
            ];
        }
        sClockVariableAxisIdentifiers = [ids copy];
        sClockVariableAxisRanges = [ranges copy];

        if (baseFont) CFRelease(baseFont);
    });
}

static CGFloat LGClockClampedAxisValue(NSString *axisKey, CGFloat value) {
    NSArray<NSNumber *> *range = sClockVariableAxisRanges[axisKey];
    if (range.count != 2) return value;
    CGFloat minimum = range[0].doubleValue;
    CGFloat maximum = range[1].doubleValue;
    return MIN(MAX(value, minimum), maximum);
}

static NSCache<NSString *, id> *LGClockVariableCTFontCache(void) {
    static NSCache<NSString *, id> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 256;
    });
    return cache;
}

static NSString *LGClockVariableCTFontCacheKey(CGFloat pointSize, CGFloat heightValue) {
    return [NSString stringWithFormat:@"%@|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f",
            sClockVariablePostScriptName ?: @"",
            pointSize,
            LGClockClampedAxisValue(@"weight", LGClockVariableFontWeight()),
            LGClockClampedAxisValue(@"width", LGClockVariableFontWidth()),
            LGClockClampedAxisValue(@"height", heightValue),
            LGClockClampedAxisValue(@"softness", LGClockVariableFontSoftness()),
            LGClockVariableFontSizeScale()];
}

static NSMutableDictionary *LGClockRequestedVariations(void) {
    NSMutableDictionary *variations = [NSMutableDictionary dictionary];
    NSNumber *weightAxis = sClockVariableAxisIdentifiers[@"weight"];
    NSNumber *widthAxis = sClockVariableAxisIdentifiers[@"width"];
    NSNumber *heightAxis = sClockVariableAxisIdentifiers[@"height"];
    NSNumber *softAxis = sClockVariableAxisIdentifiers[@"softness"];
    if (weightAxis) variations[weightAxis] = @(LGClockClampedAxisValue(@"weight", LGClockVariableFontWeight()));
    if (widthAxis) variations[widthAxis] = @(LGClockClampedAxisValue(@"width", LGClockVariableFontWidth()));
    if (heightAxis) variations[heightAxis] = @(LGClockClampedAxisValue(@"height", LGClockVariableFontHeight()));
    if (softAxis) variations[softAxis] = @(LGClockClampedAxisValue(@"softness", LGClockVariableFontSoftness()));
    return variations;
}

static NSMutableDictionary *LGClockRequestedVariationsForHeight(CGFloat heightValue) {
    NSMutableDictionary *variations = LGClockRequestedVariations();
    NSNumber *heightAxis = sClockVariableAxisIdentifiers[@"height"];
    if (heightAxis) {
        variations[heightAxis] = @(LGClockClampedAxisValue(@"height", heightValue));
    }
    return variations;
}

static const CGFloat kLGClockHeightAxisStep = 4.0;

static CTFontRef LGClockCreateVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue) {
    LGEnsureClockVariableFontMetadata();
    if (!sClockVariablePostScriptName.length) return NULL;

    heightValue = round(heightValue / kLGClockHeightAxisStep) * kLGClockHeightAxisStep;
    NSString *cacheKey = LGClockVariableCTFontCacheKey(pointSize, heightValue);
    id cachedFontObject = cacheKey.length ? [LGClockVariableCTFontCache() objectForKey:cacheKey] : nil;
    if (cachedFontObject) {
        CTFontRef cachedFont = (__bridge CTFontRef)cachedFontObject;
        if (cachedFont) {
            return (CTFontRef)CFRetain(cachedFont);
        }
    }

    NSMutableDictionary *variations = LGClockRequestedVariationsForHeight(heightValue);

    CTFontDescriptorRef descriptor = NULL;
    if (sClockVariablePostScriptName.length) {
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        attributes[(id)kCTFontNameAttribute] = sClockVariablePostScriptName;
        if (variations.count > 0) {
            attributes[(id)kCTFontVariationAttribute] = variations;
        }
        descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    }

    CTFontRef renderFont = descriptor ? CTFontCreateWithFontDescriptor(descriptor, pointSize, NULL) : NULL;
    if (descriptor) CFRelease(descriptor);
    if (!renderFont) {
        LGClockLog(@"clock variable CTFont descriptor create failed postscript=%@ size=%.2f variations=%@",
              sClockVariablePostScriptName,
              pointSize,
              variations);
        return NULL;
    }
    if (cacheKey.length) {
        [LGClockVariableCTFontCache() setObject:(__bridge id)renderFont forKey:cacheKey];
    }
    return renderFont;
}

static UIFont *LGClockVariableFont(CGFloat pointSize) {
    if (!LGClockVariableFontEnabled()) return nil;
    CTFontRef renderFont = LGClockVariableCTFont(pointSize);
    if (!renderFont) return nil;
    return (__bridge_transfer UIFont *)renderFont;
}

static UIFont *LGClockLegacyVariableFont(CGFloat pointSize) {
    if (!LGClockLegacyUsesVariableFont()) return nil;
    CTFontRef renderFont = LGClockLegacyVariableCTFontForHeight(pointSize, LGClockVariableFontHeight());
    if (!renderFont) return nil;
    return (__bridge_transfer UIFont *)renderFont;
}

static CTFontRef LGClockVariableCTFont(CGFloat pointSize) {
    return LGClockVariableCTFontForHeight(pointSize, LGClockVariableFontHeight());
}

static CTFontRef LGClockVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue) {
    if (!LGClockVariableFontEnabled()) return NULL;
    return LGClockCreateVariableCTFontForHeight(pointSize, heightValue);
}

static CTFontRef LGClockLegacyVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue) {
    if (!LGClockLegacyUsesVariableFont()) return NULL;
    return LGClockCreateVariableCTFontForHeight(pointSize, heightValue);
}

static BOOL LGIsModernClockHost(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"CSProminentTimeView");
    return cls && [view isKindOfClass:cls];
}

static BOOL LGIsLegacyClockHost(UIView *view) {
    if (LGIsAtLeastiOS16()) return NO;
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFLockScreenDateView");
    return cls && [view isKindOfClass:cls];
}

#pragma mark - Host and source discovery

static BOOL LGIsClockHost(UIView *view) {
    return LGIsModernClockHost(view) || LGIsLegacyClockHost(view);
}

static NSString *LGClockHostKind(UIView *host) {
    if (LGIsModernClockHost(host)) return @"modern";
    if (LGIsLegacyClockHost(host)) return @"legacy";
    return NSStringFromClass(host.class);
}

static BOOL LGIsModernClockSourceLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    if (!LGHasAncestorClassNamed(view, @"CSProminentTimeView")) return NO;

    // FIX: Broaden label class matching for iOS 26 compatibility.
    NSString *clsName = NSStringFromClass(view.class);
    if ([clsName isEqualToString:@"_UIAnimatingLabel"]) return YES;
    // iOS 26 alternatives — any label with "animating"/"time"/"clock" in name
    if ([clsName rangeOfString:@"Animating" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([clsName rangeOfString:@"TimeLabel" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([clsName rangeOfString:@"ClockLabel" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;

    UILabel *label = (UILabel *)view;
    NSString *text = label.text.length ? label.text : label.attributedText.string;

    // FIX: Accept labels with empty text inside CSProminentTimeView.
    // On iOS 26, the text may be set asynchronously AFTER didMoveToWindow.
    // If we reject empty-text labels, the clock overlay never gets created
    // and the stock label gets hidden with no replacement — causing the
    // intermittent "no time displayed" bug.
    if (text.length == 0) {
        // Accept if the font is large enough to be a time label
        if (label.font.pointSize >= 30.0) return YES;
        return NO;
    }
    if (label.font.pointSize < 30.0) return NO;
    return YES;
}

static BOOL LGIsLegacyClockTextLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    if (!LGHasAncestorClassNamed(view, @"SBUILegibilityLabel")) return NO;
    if (!LGHasAncestorClassNamed(view, @"SBFLockScreenDateView")) return NO;
    UILabel *label = (UILabel *)view;
    if (label.text.length == 0) return NO;
    if (label.font.pointSize < 20.0) return NO;
    return YES;
}

static NSArray<UILabel *> *LGClockSourceLabelsForHost(UIView *host) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LGTraverseViews(host, ^(UIView *view) {
        if (LGIsModernClockSourceLabel(view) || LGIsLegacyClockTextLabel(view))
            [labels addObject:(UILabel *)view];
    });
    return labels;
}

static UIView *LGClockLegacyVisibleSourceViewForLabel(UILabel *label) {
    UIView *cursor = label;
    while (cursor) {
        if ([NSStringFromClass(cursor.class) isEqualToString:@"SBUILegibilityLabel"]) {
            return cursor;
        }
        cursor = cursor.superview;
    }
    return label;
}

static void LGPositionLegacyDateSubtitleAboveClock(UIView *subtitleView) {
    if (!subtitleView || LGIsAtLeastiOS16()) return;
    if (!LGClockEnabled()) return;

    UIView *clockHost = subtitleView;
    while (clockHost && !LGIsLegacyClockHost(clockHost)) {
        clockHost = clockHost.superview;
    }
    if (!clockHost || !clockHost.superview || !subtitleView.superview) return;
    if (!LGClockShouldMutateStockLayoutForView(clockHost)) return;

    UIView *container = clockHost.superview;
    clockHost.clipsToBounds = NO;
    clockHost.layer.masksToBounds = NO;
    CGRect clockFrame = [container convertRect:clockHost.frame fromView:clockHost.superview];
    CGRect subtitleFrame = [container convertRect:subtitleView.frame fromView:subtitleView.superview];
    subtitleFrame.origin.x = round(CGRectGetMidX(clockFrame) - CGRectGetWidth(subtitleFrame) * 0.5);
    subtitleFrame.origin.y = round(CGRectGetMinY(clockFrame) - CGRectGetHeight(subtitleFrame) + 10.0);
    CGRect localFrame = [subtitleView.superview convertRect:subtitleFrame fromView:container];
    subtitleView.frame = localFrame;
    [subtitleView.superview bringSubviewToFront:subtitleView];
}

static BOOL LGIsLegacyClockDateLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    return LGHasAncestorClassNamed(view, @"SBFLockScreenDateSubtitleDateView");
}

static BOOL LGIsModernClockDateLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    return LGHasAncestorClassNamed(view, @"CSProminentSubtitleDateView");
}

static NSString *LGClockDateFormatString(void) {
    NSString *format = LG_prefString(@"Clock.DateFormat.Format", @"EEE MMM d");
    return format.length ? format : @"EEE MMM d";
}

static NSString *LGLunarDayString(NSInteger day) {
    static NSString *digits[] = {@"〇", @"一", @"二", @"三", @"四", @"五", @"六", @"七", @"八", @"九"};
    if (day == 10) return @"初十";
    if (day == 20) return @"二十";
    if (day == 30) return @"三十";
    if (day < 1 || day > 30) return [NSString stringWithFormat:@"%ld", (long)day];
    if (day < 10) return [NSString stringWithFormat:@"初%@", digits[day]];
    if (day < 20) return [NSString stringWithFormat:@"十%@", digits[day - 10]];
    return [NSString stringWithFormat:@"廿%@", digits[day - 20]];
}

static NSString *LGLunarDateString(void) {
    NSCalendar *chinese = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierChinese];
    if (!chinese) return @"";

    NSDateComponents *comps = [chinese components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                         fromDate:[NSDate date]];
    if (!comps) return @"";

    NSInteger cycleYear = comps.year;
    NSInteger month = comps.month;
    NSInteger day = comps.day;

    static NSString *stems[] = {@"甲", @"乙", @"丙", @"丁", @"戊", @"己", @"庚", @"辛", @"壬", @"癸"};
    static NSString *branches[] = {@"子", @"丑", @"寅", @"卯", @"辰", @"巳", @"午", @"未", @"申", @"酉", @"戌", @"亥"};

    NSInteger stemIdx = (cycleYear - 1) % 10;
    NSInteger branchIdx = (cycleYear - 1) % 12;
    if (stemIdx < 0) stemIdx = 0;
    if (branchIdx < 0) branchIdx = 0;

    NSString *yearStr = [NSString stringWithFormat:@"%@%@年", stems[stemIdx], branches[branchIdx]];
    NSString *monthStr = comps.leapMonth
        ? [NSString stringWithFormat:@"闰%ld月", (long)month]
        : [NSString stringWithFormat:@"%ld月", (long)month];
    NSString *dayStr = LGLunarDayString(day);

    return [NSString stringWithFormat:@"%@%@%@", yearStr, monthStr, dayStr];
}

static NSString *LGClockCustomDateString(void) {
    NSString *format = LGClockDateFormatString();
    BOOL hasLunar = [format containsString:@"{lunar}"];
    NSString *solarFormat = hasLunar
        ? [format stringByReplacingOccurrencesOfString:@"{lunar}" withString:@""]
        : format;

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
    });

    formatter.locale = [NSLocale autoupdatingCurrentLocale];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = solarFormat.length ? solarFormat : @"EEE MMM d";

    NSString *text = [formatter stringFromDate:[NSDate date]];

    if (hasLunar) {
        NSString *lunar = LGLunarDateString();
        if (lunar.length) {
            text = text.length
                ? [NSString stringWithFormat:@"%@ %@", text, lunar]
                : lunar;
        }
    }

    if (text.length == 0) return text;

    text = [text stringByReplacingOccurrencesOfString:@"," withString:@""];
    while ([text containsString:@"  "]) {
        text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void LGApplyAbbreviatedDateTextToLabel(UILabel *label) {
    if (!label) return;
    if (!LGIsLegacyClockDateLabel(label) && !LGIsModernClockDateLabel(label)) return;

    if ([objc_getAssociatedObject(label, kLGClockApplyingDateTextKey) boolValue]) return;

    BOOL dateFormatEnabled = LGClockEnabled() && LGClockDateFormatEnabled();

    if (!dateFormatEnabled) {
        NSString *lastCustomText = objc_getAssociatedObject(label, kLGClockLastCustomDateTextKey);
        if (lastCustomText.length && [label.text isEqualToString:lastCustomText]) {
            NSString *originalText = objc_getAssociatedObject(label, kLGClockOriginalDateTextKey);
            if (originalText.length) {
                objc_setAssociatedObject(label, kLGClockApplyingDateTextKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                label.text = originalText;
                objc_setAssociatedObject(label, kLGClockApplyingDateTextKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
        }
        objc_setAssociatedObject(label, kLGClockLastCustomDateTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(label, kLGClockOriginalDateTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return;
    }

    NSString *text = LGClockCustomDateString();
    if (text.length == 0) return;
    if ([label.text isEqualToString:text]) return;

    NSString *lastCustomText = objc_getAssociatedObject(label, kLGClockLastCustomDateTextKey);
    if (label.text.length && ![label.text isEqualToString:lastCustomText]) {
        objc_setAssociatedObject(label, kLGClockOriginalDateTextKey, label.text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    objc_setAssociatedObject(label, kLGClockLastCustomDateTextKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(label, kLGClockApplyingDateTextKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    label.text = text;
    objc_setAssociatedObject(label, kLGClockApplyingDateTextKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGApplyAbbreviatedDateTextInView(UIView *root) {
    if (!root) return;
    LGTraverseViews(root, ^(UIView *view) {
        if (LGIsLegacyClockDateLabel(view) || LGIsModernClockDateLabel(view)) {
            LGApplyAbbreviatedDateTextToLabel((UILabel *)view);
        }
    });
}

static CGRect LGClockOffsetFrame(CGRect frame) {
    return frame;
}

static void LGPositionLegacyDateSubtitleForClockHost(UIView *clockHost) {
    if (!clockHost || !LGIsLegacyClockHost(clockHost)) return;
    __block UIView *subtitleView = nil;
    LGTraverseViews(clockHost, ^(UIView *view) {
        if (subtitleView) return;
        if ([NSStringFromClass(view.class) isEqualToString:@"SBFLockScreenDateSubtitleDateView"]) {
            subtitleView = view;
        }
    });
    if (subtitleView) {
        LGPositionLegacyDateSubtitleAboveClock(subtitleView);
    }
}

static NSArray<UIView *> *LGClockVisibleSourceViewsForHost(UIView *host, UILabel *sourceLabel) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    if (LGIsModernClockHost(host)) {
        [views addObjectsFromArray:LGClockSourceLabelsForHost(host)];
        return views;
    }

    if (LGIsLegacyClockHost(host) && sourceLabel) {
        UIView *visibleSourceView = LGClockLegacyVisibleSourceViewForLabel(sourceLabel);
        if (visibleSourceView) {
            [views addObject:visibleSourceView];
        }
    }
    return views;
}

static UILabel *LGClockPrimarySourceLabelForHost(UIView *host) {
    NSArray<UILabel *> *labels = LGClockSourceLabelsForHost(host);
    if (labels.count == 0) return nil;
    if (!LGIsLegacyClockHost(host)) return labels.firstObject;

    UILabel *best = nil;
    for (UILabel *label in labels) {
        if (!best || label.font.pointSize > best.font.pointSize) {
            best = label;
        }
    }
    return best ?: labels.firstObject;
}

static UIView *LGClockFindDescendantOfClass(UIView *view, Class targetClass) {
    if (!view || !targetClass) return nil;
    if ([view isKindOfClass:targetClass]) return view;
    for (UIView *subview in view.subviews) {
        UIView *match = LGClockFindDescendantOfClass(subview, targetClass);
        if (match) return match;
    }
    return nil;
}

static UIView *LGClockFindLegacyClockHostInWindow(UIWindow *window) {
    if (!window) return nil;
    __block UIView *match = nil;
    LGTraverseViews(window, ^(UIView *view) {
        if (match) return;
        if (LGIsLegacyClockHost(view) && !view.hidden && view.alpha > 0.01) {
            match = view;
        }
    });
    return match;
}

static UIView *LGClockFindModernClockHostInWindow(UIWindow *window) {
    if (!window) return nil;
    __block UIView *match = nil;
    LGTraverseViews(window, ^(UIView *view) {
        if (match) return;
        if (!LGIsModernClockHost(view)) return;
        match = view;
    });
    return match;
}

static CGRect LGAdjustedLegacyNotificationListFrame(UIView *notificationListView, CGRect proposedFrame) {
    if (!notificationListView || !notificationListView.window) return proposedFrame;
    if (LGIsAtLeastiOS16()) return proposedFrame;
    if (!LGClockEnabled()) return proposedFrame;
    if (!LGClockLegacyNotificationShiftEnabled()) return proposedFrame;
    NSValue *originalFrameValue = objc_getAssociatedObject(notificationListView, kLGClockLegacyNotificationOriginalFrameKey);
    if (!originalFrameValue) {
        originalFrameValue = [NSValue valueWithCGRect:proposedFrame];
        objc_setAssociatedObject(notificationListView,
                                 kLGClockLegacyNotificationOriginalFrameKey,
                                 originalFrameValue,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    static Class listViewClass = Nil;
    static dispatch_once_t listOnceToken;
    dispatch_once(&listOnceToken, ^{
        listViewClass = NSClassFromString(@"NCNotificationListView");
    });
    if (listViewClass && [notificationListView.superview isKindOfClass:listViewClass]) {
        return proposedFrame;
    }

    if (!notificationListView.superview) {
        return proposedFrame;
    }

    UIView *containerView = notificationListView.superview;
    CGRect currentFrame = proposedFrame;
    CGFloat desiredMinY = CGRectGetMinY(originalFrameValue.CGRectValue);
    CGRect anchorRectInContainer = CGRectZero;
    UIView *clockHost = LGClockFindLegacyClockHostInWindow(notificationListView.window);
    if (!LGClockShouldMutateStockLayoutForView(clockHost ?: notificationListView)) {
        return proposedFrame;
    }
    if (clockHost) {
        anchorRectInContainer = [containerView convertRect:clockHost.bounds fromView:clockHost];
        desiredMinY = CGRectGetMaxY(anchorRectInContainer) + LGClockLegacyNotificationClockGap();
    }

    CGFloat delta = desiredMinY - CGRectGetMinY(currentFrame);

    CGFloat newHeight = currentFrame.size.height - delta;
    if (newHeight <= 120.0 || fabs(delta) <= 0.5) {
        return proposedFrame;
    }

    currentFrame.origin.y = desiredMinY;
    currentFrame.size.height = newHeight;
    return currentFrame;
}

#pragma mark - Legacy lock-screen layout

static void LGRelayoutLegacyNotificationListView(UIView *notificationListView) {
    if (!notificationListView || !notificationListView.window) return;
    if (LGIsAtLeastiOS16()) return;
    if (!LGClockEnabled()) return;
    if (!LGClockLegacyNotificationShiftEnabled()) return;
    if ([objc_getAssociatedObject(notificationListView, kLGClockLegacyNotificationApplyingKey) boolValue]) return;

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRelayoutTime = objc_getAssociatedObject(notificationListView, kLGClockLegacyNotificationLastRelayoutKey);
    if (lastRelayoutTime.doubleValue > 0.0 && now - lastRelayoutTime.doubleValue < (1.0 / 15.0)) return;
    objc_setAssociatedObject(notificationListView,
                             kLGClockLegacyNotificationLastRelayoutKey,
                             @(now),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGRect adjustedFrame = LGAdjustedLegacyNotificationListFrame(notificationListView, notificationListView.frame);
    if (CGRectEqualToRect(adjustedFrame, notificationListView.frame)) return;

    objc_setAssociatedObject(notificationListView,
                             kLGClockLegacyNotificationApplyingKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    notificationListView.frame = adjustedFrame;
    objc_setAssociatedObject(notificationListView,
                             kLGClockLegacyNotificationApplyingKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGScheduleLegacyNotificationListRelayout(UIView *notificationListView) {
    if (!notificationListView || !notificationListView.window) return;
    NSNumber *pending = objc_getAssociatedObject(notificationListView, kLGClockLegacyNotificationPendingKey);
    if (pending.boolValue) return;

    objc_setAssociatedObject(notificationListView,
                             kLGClockLegacyNotificationPendingKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(notificationListView,
                                 kLGClockLegacyNotificationPendingKey,
                                 @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (notificationListView.window) {
            LGRelayoutLegacyNotificationListView(notificationListView);
        }
    });
}

static void LGRelayoutLegacyNotificationListForController(UIViewController *controller) {
    if (!controller || LGIsAtLeastiOS16()) return;

    static Class listViewClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        listViewClass = NSClassFromString(@"NCNotificationListView");
    });
    if (!listViewClass) return;

    UIView *listView = LGClockFindDescendantOfClass(controller.view, listViewClass);
    if (listView) {
        LGRelayoutLegacyNotificationListView(listView);
    }
}

static void LGStartClockDisplayLink(void) {
    if (sClockDisplayLink.link || !LGClockEnabled()) return;
    LGStartClockDisplayLinkDriver(&sClockDisplayLink, ^{
        BOOL activityChanged = NO;
        for (UIView *host in LGClockHostRegistry().allObjects) {
            if (!host.window || !LGClockViewIsVisiblyPresent(host)) {
                activityChanged = YES;
                continue;
            }
            if (!LGIsClockHost(host)) continue;
            UIView *overlay = objc_getAssociatedObject(host, kLGClockOverlayKey);
            if (!overlay || overlay.superview == nil) {
                LGScheduleClockApply(host, YES, 1.0 / 30.0);
                continue;
            }
            [(id)overlay refreshForDisplayLink];
        }
        if (activityChanged) LGClockSyncDisplayLinkActivity();
    });
}

static void LGStopClockDisplayLink(void) {
    LGStopClockDisplayLinkDriver(&sClockDisplayLink);
}

static void LGAttachClockHostIfNeeded(UIView *host) {
    if (!host || !LGIsClockHost(host)) return;
    [LGClockHostRegistry() addObject:host];
    if ([objc_getAssociatedObject(host, kLGClockAttachedKey) boolValue]) {
        LGClockSyncDisplayLinkActivity();
        return;
    }
    objc_setAssociatedObject(host, kLGClockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGClockSyncDisplayLinkActivity();
    LGClockMarkMotionActiveForDuration(0.25);
}

static void LGDetachClockHostIfNeeded(UIView *host) {
    if (!host) return;
    if (![objc_getAssociatedObject(host, kLGClockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(host, kLGClockAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [LGClockHostRegistry() removeObject:host];
    LGClockSyncDisplayLinkActivity();
}

static void LGClockSyncDisplayLinkActivity(void) {
    NSInteger visibleHostCount = 0;
    for (UIView *host in LGClockHostRegistry().allObjects) {
        if (!LGIsClockHost(host)) continue;
        if (!LGClockViewIsVisiblyPresent(host)) continue;
        if (LGClockHasBlockingPresentation(host)) continue;
        visibleHostCount++;
    }
    if (visibleHostCount > 0 && LGClockEnabled()) {
        LGStartClockDisplayLink();
    } else {
        LGStopClockDisplayLink();
    }
}

static void LGClockSetCoverSheetVisible(BOOL visible) {
    if (sClockCoverSheetVisible == visible) return;
    sClockCoverSheetVisible = visible;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (visible) {
            LGRefreshRegisteredClockHosts();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LGRefreshAllClockHosts();
            });
        } else {
            LGClockCleanupRegisteredHosts();
        }
    });
}

#pragma mark - Font resolution

static UIFont *LGClockPreferredRenderFont(UILabel *label, UIView *host) {
    UIFont *sourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CGFloat pointSize = sourceFont.pointSize;
    if (LGIsLegacyClockHost(host)) {
        if (LGClockLegacyUsesVariableFont()) {
            pointSize = MAX(sourceFont.pointSize * LGClockVariableFontSizeScale(), 1.0);
            UIFont *variableFont = LGClockLegacyVariableFont(pointSize);
            if (variableFont) return variableFont;
        }
        return sourceFont;
    } else if (LGClockVariableFontEnabled()) {
        pointSize = MAX(sourceFont.pointSize * LGClockVariableFontSizeScale(), 1.0);
        UIFont *variableFont = LGClockVariableFont(pointSize);
        if (variableFont) return variableFont;
    }
    return sourceFont;
}

static UIScrollView *LGClockAncestorScrollView(UIView *view) {
    UIView *cursor = view.superview;
    while (cursor) {
        if ([cursor isKindOfClass:[UIScrollView class]])
            return (UIScrollView *)cursor;
        cursor = cursor.superview;
    }
    return nil;
}

static CGFloat LGClockResolvedLineHeight(UIFont *font, id ctFontObject) {
    if (ctFontObject) {
        CTFontRef ctFont = (__bridge CTFontRef)ctFontObject;
        return ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont));
    }
    return ceil(font.lineHeight);
}

static BOOL LGClockContainerClips(UIView *view) {
    if (!view) return NO;
    return view.clipsToBounds || view.layer.masksToBounds;
}

static BOOL LGClockViewOpacityAllowsOverlay(UIView *view) {
    if (!view) return NO;
    CALayer *presentation = view.layer.presentationLayer;
    CGFloat viewAlpha = view.alpha;
    CGFloat modelOpacity = view.layer.opacity;
    CGFloat presentationOpacity = presentation ? presentation.opacity : modelOpacity;
    return viewAlpha > 0.01 || modelOpacity > 0.01 || presentationOpacity > 0.01;
}

static NSString *LGClockViewOpacityDebugString(UIView *view) {
    if (!view) return @"nil";
    CALayer *presentation = view.layer.presentationLayer;
    return [NSString stringWithFormat:@"%@-alpha(view=%.2f layer=%.2f presentation=%.2f)",
            NSStringFromClass(view.class),
            view.alpha,
            view.layer.opacity,
            presentation ? presentation.opacity : view.layer.opacity];
}

static BOOL LGClockHostCanReceiveOverlay(UIView *view) {
    if (!view || !view.window || view.hidden) return NO;
    UIWindow *window = view.window;
    if (window.hidden || !LGClockViewOpacityAllowsOverlay(window)) return NO;
    BOOL isModernClockHost = LGIsModernClockHost(view);
    UIView *current = view;
    while (current && current != window) {
        if (current.hidden) return NO;
        if (!isModernClockHost && !LGClockViewOpacityAllowsOverlay(current)) return NO;
        current = current.superview;
    }
    if (CGRectGetWidth(view.bounds) <= 1.0 || CGRectGetHeight(view.bounds) <= 1.0) return NO;
    return YES;
}

static NSString *LGClockHostIneligibilityReason(UIView *view) {
    if (!view) return @"nil-host";
    if (!view.window) return @"no-window";
    if (view.hidden) return @"host-hidden";
    UIWindow *window = view.window;
    if (window.hidden) return @"window-hidden";
    if (!LGClockViewOpacityAllowsOverlay(window)) return LGClockViewOpacityDebugString(window);
    BOOL isModernClockHost = LGIsModernClockHost(view);
    UIView *current = view;
    while (current && current != window) {
        if (current.hidden) return [NSString stringWithFormat:@"%@-hidden", NSStringFromClass(current.class)];
        if (!isModernClockHost && !LGClockViewOpacityAllowsOverlay(current)) return LGClockViewOpacityDebugString(current);
        current = current.superview;
    }
    if (CGRectGetWidth(view.bounds) <= 1.0 || CGRectGetHeight(view.bounds) <= 1.0) return @"empty-bounds";
    return @"unknown";
}

static BOOL LGClockViewIsVisiblyPresent(UIView *view) {
    if (!LGClockHostCanReceiveOverlay(view)) return NO;
    CALayer *layer = view.layer.presentationLayer ?: view.layer;
    CGRect bounds = layer.bounds;
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) return NO;
    CGRect screenFrame = CGRectZero;
    if (@available(iOS 13.0, *)) {
        screenFrame = [view convertRect:view.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    } else {
        screenFrame = [view convertRect:view.bounds toView:nil];
    }
    if (CGRectGetWidth(screenFrame) <= 1.0 || CGRectGetHeight(screenFrame) <= 1.0) return NO;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    if (@available(iOS 8.0, *)) {
        id<UICoordinateSpace> space = UIScreen.mainScreen.coordinateSpace;
        if (space && !CGRectIsEmpty(space.bounds)) screenBounds = space.bounds;
    }
    return CGRectIntersectsRect(CGRectInset(screenBounds, -8.0, -8.0), screenFrame);
}

static BOOL LGClockViewLooksLikePresentationBlocker(UIView *view, UIView *host) {
    if (!LGClockViewIsVisiblyPresent(view)) return NO;
    if (view == host || [view isDescendantOfView:host] || [host isDescendantOfView:view]) return NO;

    NSString *className = NSStringFromClass(view.class);

    if ([className isEqualToString:@"CSPasscodeBackgroundView"]) return NO;
    if ([className isEqualToString:@"PBUISnapshotReplicaView"]) return YES;
    if ([className isEqualToString:@"CAMViewfinderView"]) return YES;
    if ([className isEqualToString:@"CAMPreviewView"]) return YES;
    if ([className isEqualToString:@"CAMPreviewViewControllerView"]) return YES;
    if ([className isEqualToString:@"CAMFullscreenViewfinderView"]) return YES;

    return NO;
}

static BOOL LGClockHasBlockingPresentation(UIView *host) {
    if (!host.window) return NO;
    __block BOOL blocked = NO;
    UIView *scanRoot = host.window;
    LGTraverseViews(scanRoot, ^(UIView *view) {
        if (blocked) return;
        if (!LGClockViewLooksLikePresentationBlocker(view, host)) return;

        CGRect frameInWindow = [view convertRect:view.bounds toView:host.window];
        if (CGRectIsEmpty(frameInWindow)) return;
        CGFloat coverage = CGRectGetWidth(frameInWindow) * CGRectGetHeight(frameInWindow);
        if (coverage < 20000.0 && ![NSStringFromClass(view.class) isEqualToString:@"CSPasscodeBackgroundView"]) return;
        blocked = YES;
    });
    return blocked;
}

static UIView *LGClockNearestHostForView(UIView *view) {
    UIView *cursor = view;
    while (cursor) {
        if (LGIsClockHost(cursor)) return cursor;
        cursor = cursor.superview;
    }
    return nil;
}

static BOOL LGClockShouldMutateStockLayoutForView(UIView *view) {
    if (!view || !view.window) return NO;
    UIView *host = LGClockNearestHostForView(view);
    if (!host) {
        host = LGIsAtLeastiOS16()
            ? LGClockFindModernClockHostInWindow(view.window)
            : LGClockFindLegacyClockHostInWindow(view.window);
    }
    if (!host) return NO;
    if (!LGClockHostCanReceiveOverlay(host)) return NO;
    if (LGClockHasBlockingPresentation(host)) return NO;
    return YES;
}

static BOOL LGClockIsNotificationObstacleView(UIView *view) {
    if (!LGClockViewIsVisiblyPresent(view)) return NO;
    if (LGHasAncestorClassNamed(view, @"NCNotificationShortLookView")) return NO;
    if (LGHasAncestorClassNamed(view, @"NCNotificationLongLookView")) return NO;
    NSString *className = NSStringFromClass(view.class);
    return [className isEqualToString:@"PLPlatterView"]
        || [className isEqualToString:@"NCNotificationShortLookView"]
        || [className isEqualToString:@"NCNotificationLongLookView"];
}

static BOOL LGClockIsLegacyRevealHintObstacleView(UIView *view) {
    if (LGIsAtLeastiOS16()) return NO;
    if (!LGClockViewIsVisiblyPresent(view)) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"NCNotificationListSectionRevealHintView"];
}

static BOOL LGClockLegacyObstacleFrameLooksLikeNotificationCard(UIView *view, CGRect frame) {
    if (CGRectIsEmpty(frame)) return NO;
    if (CGRectGetWidth(frame) < 180.0) return NO;

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"PLPlatterView"] && CGRectGetHeight(frame) < 72.0) {
        return NO;
    }

    return CGRectGetHeight(frame) >= 48.0;
}

static CGRect LGClockPresentationFrameForView(UIView *view, UIView *container) {
    if (!view || !container) return CGRectNull;
    if (view.window == container.window) {
        CALayer *presentationLayer = view.layer.presentationLayer;
        if (presentationLayer) {
            CALayer *containerLayer = container.layer.presentationLayer ?: container.layer;
            CGRect presentationFrame = [presentationLayer convertRect:presentationLayer.bounds
                                                              toLayer:containerLayer];
            if (!CGRectIsNull(presentationFrame) && !CGRectIsEmpty(presentationFrame)) {
                return presentationFrame;
            }
        }
    }
    return [view convertRect:view.bounds toView:container];
}

static CGRect LGClockSourceFrameForLabel(UILabel *label, UIView *container) {
    CGRect frame = LGClockPresentationFrameForView(label, container);
    if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) {
        frame = [label convertRect:label.bounds toView:container];
    }
    return frame;
}

static CGFloat LGClockNearestNotificationTop(UIView *host, UIView *container, CGRect sourceFrame) {
    if (!host || !container) return CGFLOAT_MAX;

    CGRect clockBand = CGRectInset(sourceFrame, -32.0, 0.0);
    UIWindow *window = container.window;
    CGFloat nearestTop = CGFLOAT_MAX;
    CGFloat nearestLegacyRevealHintTop = CGFLOAT_MAX;

    for (UIView *view in LGClockNotificationObstacleViews()) {
        if (!view.window || (window && view.window != window)) continue;
        if (view == host || [view isDescendantOfView:host]) continue;
        if (!LGClockIsNotificationObstacleView(view)) continue;

        CGRect obstacleFrame = LGClockPresentationFrameForView(view, container);
        if (CGRectIsEmpty(obstacleFrame)) continue;
        if (!LGIsAtLeastiOS16() && !LGClockLegacyObstacleFrameLooksLikeNotificationCard(view, obstacleFrame)) {
            continue;
        }
        if (CGRectGetMaxX(obstacleFrame) < CGRectGetMinX(clockBand) ||
            CGRectGetMinX(obstacleFrame) > CGRectGetMaxX(clockBand)) {
            continue;
        }
        if (CGRectGetMaxY(obstacleFrame) <= CGRectGetMinY(sourceFrame) + 1.0) continue;

        CGFloat obstacleTop = CGRectGetMinY(obstacleFrame);
        if (obstacleTop < nearestTop) {
            nearestTop = obstacleTop;
        }
    }

    if (nearestTop == CGFLOAT_MAX && !LGIsAtLeastiOS16()) {
        for (UIView *view in LGClockLegacyRevealHintViews()) {
            if (!view.window || (window && view.window != window)) continue;
            if (view == host || [view isDescendantOfView:host]) continue;
            if (!LGClockIsLegacyRevealHintObstacleView(view)) continue;

            CGRect hintFrame = LGClockPresentationFrameForView(view, container);
            if (CGRectIsEmpty(hintFrame)) continue;
            if (CGRectGetMaxX(hintFrame) < CGRectGetMinX(clockBand) ||
                CGRectGetMinX(hintFrame) > CGRectGetMaxX(clockBand)) {
                continue;
            }
            if (CGRectGetMaxY(hintFrame) <= CGRectGetMinY(sourceFrame) + 1.0) continue;
            nearestLegacyRevealHintTop = MIN(nearestLegacyRevealHintTop, CGRectGetMinY(hintFrame));
        }
    }

    if (nearestTop == CGFLOAT_MAX) return nearestLegacyRevealHintTop;
    return nearestTop;
}

static CGFloat LGClockSnapScalar(CGFloat value, CGFloat step) {
    if (!isfinite(value) || step <= 0.0) return value;
    return round(value / step) * step;
}

static CGRect LGClockSnapRect(CGRect rect, CGFloat step) {
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect)) return rect;
    return CGRectMake(LGClockSnapScalar(CGRectGetMinX(rect), step),
                      LGClockSnapScalar(CGRectGetMinY(rect), step),
                      LGClockSnapScalar(CGRectGetWidth(rect), step),
                      LGClockSnapScalar(CGRectGetHeight(rect), step));
}

static const CGFloat kLGClockModernGeometrySnapStep = 2.0;

static void LGClockMarkMotionActiveForDuration(CFTimeInterval duration) {
    sClockActiveFPSUntil = MAX(sClockActiveFPSUntil, CACurrentMediaTime() + duration);
}

static CGFloat LGClockModernGlyphBottomForSourceFrame(CGRect sourceFrame,
                                                      NSString *text,
                                                      UIFont *font,
                                                      id ctFontObject,
                                                      CGFloat topInset) {
    if (CGRectIsEmpty(sourceFrame) || text.length == 0 || !font) return CGRectGetMaxY(sourceFrame);

    CGRect expanded = LGClockExpandedModernFrameForRect(sourceFrame,
                                                        nil,
                                                        text,
                                                        font,
                                                        ctFontObject,
                                                        NSTextAlignmentCenter);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGRect glyphBounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    if (CGRectIsNull(glyphBounds) || CGRectIsEmpty(glyphBounds)) {
        glyphBounds = CGRectMake(0.0, -descent, 0.0, ascent + descent);
    }
    CGFloat baseline = floor(CGRectGetHeight(expanded) - MAX(0.0, topInset) - ascent);
    CGFloat localBottom = CGRectGetHeight(expanded) - (baseline + CGRectGetMinY(glyphBounds));
    CFRelease(line);
    return CGRectGetMinY(expanded) + localBottom;
}

static CGFloat LGClockLegacyGlyphBottomForSourceFrame(CGRect sourceFrame,
                                                      NSString *text,
                                                      UIFont *font,
                                                      id ctFontObject) {
    if (CGRectIsEmpty(sourceFrame) || text.length == 0 || !font) return CGRectGetMaxY(sourceFrame);

    CGRect expanded = LGClockExpandedLegacyFrameForRect(sourceFrame,
                                                        nil,
                                                        text,
                                                        font,
                                                        ctFontObject);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGRect glyphBounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    if (CGRectIsNull(glyphBounds) || CGRectIsEmpty(glyphBounds)) {
        glyphBounds = CGRectMake(0.0, -descent, 0.0, ascent + descent);
    }
    CGFloat baseline = floor(CGRectGetHeight(expanded) - ascent);
    CGFloat localBottom = CGRectGetHeight(expanded) - (baseline + CGRectGetMinY(glyphBounds));
    CFRelease(line);
    return CGRectGetMinY(expanded) + localBottom;
}

static CGFloat LGClockLegacyRenderedInkBottomForSourceFrame(CGRect sourceFrame,
                                                            NSString *text,
                                                            UIFont *font,
                                                            id ctFontObject) {
    if (CGRectIsEmpty(sourceFrame) || text.length == 0 || !font) return CGRectGetMaxY(sourceFrame);

    CGRect expanded = LGClockExpandedLegacyFrameForRect(sourceFrame,
                                                        nil,
                                                        text,
                                                        font,
                                                        ctFontObject);
    size_t widthPx = (size_t)MAX(1.0, ceil(CGRectGetWidth(expanded)));
    size_t heightPx = (size_t)MAX(1.0, ceil(CGRectGetHeight(expanded)));
    size_t bytesPerRow = widthPx * 4;
    unsigned char *pixels = calloc(heightPx, bytesPerRow);
    if (!pixels) {
        return LGClockLegacyGlyphBottomForSourceFrame(sourceFrame, text, font, ctFontObject);
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels,
                                             widthPx,
                                             heightPx,
                                             8,
                                             bytesPerRow,
                                             colorSpace,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (!ctx) {
        free(pixels);
        return LGClockLegacyGlyphBottomForSourceFrame(sourceFrame, text, font, ctFontObject);
    }

    CGContextTranslateCTM(ctx, 0.0, (CGFloat)heightPx);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGFloat x = floor(((CGFloat)widthPx - width) * 0.5);
    CGFloat baseline = floor((CGFloat)heightPx - ascent);

    CGContextSetTextPosition(ctx, x, baseline);
    CTLineDraw(line, ctx);

    NSInteger minRow = NSIntegerMax;
    NSInteger maxRow = NSIntegerMin;
    for (size_t y = 0; y < heightPx; y++) {
        unsigned char *row = pixels + y * bytesPerRow;
        for (size_t xPx = 0; xPx < widthPx; xPx++) {
            if (row[xPx * 4 + 3] <= 8) continue;
            minRow = MIN(minRow, (NSInteger)y);
            maxRow = MAX(maxRow, (NSInteger)y);
            break;
        }
    }

    CGFloat bottom = CGRectGetMaxY(expanded);
    if (minRow != NSIntegerMax && maxRow != NSIntegerMin) {
        CGFloat topMemoryBottom = CGRectGetMinY(expanded) + (CGFloat)(maxRow + 1);
        CGFloat bottomMemoryBottom = CGRectGetMinY(expanded) + ((CGFloat)heightPx - (CGFloat)minRow);
        bottom = MIN(topMemoryBottom, bottomMemoryBottom);
    }

    if (line) CFRelease(line);
    CGContextRelease(ctx);
    free(pixels);
    return bottom;
}

static CGFloat LGClockLineWidthForText(NSString *text, UIFont *font, id ctFontObject) {
    if (text.length == 0 || !font) return 0.0;

    static NSCache<NSString *, NSNumber *> *widthCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ widthCache = [NSCache new]; widthCache.countLimit = 512; });
    NSString *key = [NSString stringWithFormat:@"%.1f|%.1f|%@",
                     font.pointSize, LGClockVariableFontWidth(), text];
    NSNumber *cached = [widthCache objectForKey:key];
    if (cached) return cached.doubleValue;

    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CFRelease(line);
    width = ceil(width);
    [widthCache setObject:@(width) forKey:key];
    return width;
}

static CGFloat LGClockDynamicHeightAxisForContext(UILabel *label,
                                                  UIView *host,
                                                  UIView *container,
                                                  CGRect sourceFrame) {
    CGFloat requestedHeight = LGClockVariableFontHeight();
    BOOL modernHost = LGIsModernClockHost(host);
    BOOL legacyVariableHost = LGIsLegacyClockHost(host) && LGClockLegacyUsesVariableFont();
    if ((!modernHost && !legacyVariableHost) || !label.text.length) return requestedHeight;
    if (modernHost && !LGClockVariableFontEnabled()) return requestedHeight;

    CGFloat minimumHeight = 100.0;
    NSArray<NSNumber *> *heightRange = sClockVariableAxisRanges[@"height"];
    if (heightRange.count == 2) {
        minimumHeight = MAX(minimumHeight, heightRange[0].doubleValue);
    }
    if (requestedHeight <= minimumHeight + 0.5) return requestedHeight;

    CGFloat nearestTop = LGClockNearestNotificationTop(host, container, sourceFrame);
    if (nearestTop == CGFLOAT_MAX) return requestedHeight;

    UIFont *sourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CGFloat pointSize = modernHost
        ? MAX(sourceFont.pointSize * LGClockVariableFontSizeScale(), 1.0)
        : MAX(sourceFont.pointSize * LGClockVariableFontSizeScale(), 1.0);
    static const CGFloat kClockBottomClearance = 10.0;

    CTFontRef requestedCTFont = modernHost
        ? LGClockVariableCTFontForHeight(pointSize, requestedHeight)
        : LGClockLegacyVariableCTFontForHeight(pointSize, requestedHeight);
    id requestedFontObject = requestedCTFont ? (__bridge_transfer id)requestedCTFont : nil;
    UIFont *requestedFont = requestedFontObject ? (UIFont *)requestedFontObject : sourceFont;
    CGFloat requestedBottom = modernHost
        ? LGClockModernGlyphBottomForSourceFrame(sourceFrame,
                                                 label.text,
                                                 requestedFont,
                                                 requestedFontObject,
                                                 CGRectGetMinY(label.bounds))
        : LGClockLegacyRenderedInkBottomForSourceFrame(sourceFrame,
                                                       label.text,
                                                       requestedFont,
                                                       requestedFontObject);
    if (requestedBottom + kClockBottomClearance <= nearestTop) return requestedHeight;

    CGFloat low = minimumHeight;
    CGFloat high = requestedHeight;
    for (NSUInteger i = 0; i < 8; i++) {
        CGFloat mid = floor((low + high) * 0.5);
        CTFontRef midCTFont = modernHost
            ? LGClockVariableCTFontForHeight(pointSize, mid)
            : LGClockLegacyVariableCTFontForHeight(pointSize, mid);
        id midFontObject = midCTFont ? (__bridge_transfer id)midCTFont : nil;
        UIFont *midFont = midFontObject ? (UIFont *)midFontObject : sourceFont;
        CGFloat midBottom = modernHost
            ? LGClockModernGlyphBottomForSourceFrame(sourceFrame,
                                                     label.text,
                                                     midFont,
                                                     midFontObject,
                                                     CGRectGetMinY(label.bounds))
            : LGClockLegacyRenderedInkBottomForSourceFrame(sourceFrame,
                                                           label.text,
                                                           midFont,
                                                           midFontObject);
        if (midBottom + kClockBottomClearance <= nearestTop) {
            low = mid;
        } else {
            high = mid;
        }
    }

    return floor(low);
}

static CGRect LGClockExpandedModernFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject,
                                                NSTextAlignment alignment) {
    if (CGRectIsEmpty(frame)) return frame;

    CGFloat resolvedLineHeight = MAX(CGRectGetHeight(frame), LGClockResolvedLineHeight(font, ctFontObject));
    CGFloat extraBottom = MAX(18.0, ceil(resolvedLineHeight - CGRectGetHeight(frame)) + ceil(resolvedLineHeight * 0.18) + 18.0);
    CGRect expanded = frame;
    expanded.size.height += extraBottom;

    CGFloat textWidth = LGClockLineWidthForText(text, font, ctFontObject);
    CGFloat syntheticEmbolden = LGClockModernSyntheticEmbolden();
    CGFloat desiredWidth = MAX(CGRectGetWidth(expanded), textWidth + 18.0 + ceil(syntheticEmbolden * 4.0));
    if (desiredWidth > CGRectGetWidth(expanded)) {
        CGFloat delta = desiredWidth - CGRectGetWidth(expanded);
        switch (alignment) {
            case NSTextAlignmentRight:
                expanded.origin.x -= delta;
                break;
            case NSTextAlignmentLeft:
            case NSTextAlignmentNatural:
            case NSTextAlignmentJustified:
                break;
            case NSTextAlignmentCenter:
            default:
                expanded.origin.x -= floor(delta * 0.5);
                break;
        }
        expanded.size.width = desiredWidth;
    }

    if (host) {
        CGFloat minX = CGRectGetMinX(host.bounds);
        CGFloat maxX = CGRectGetMaxX(host.bounds);
        if (CGRectGetMinX(expanded) < minX) {
            expanded.origin.x = minX;
        }
        if (CGRectGetMaxX(expanded) > maxX) {
            CGFloat overflow = CGRectGetMaxX(expanded) - maxX;
            expanded.size.width = MAX(0.0, expanded.size.width - overflow);
        }
        CGFloat minY = CGRectGetMinY(host.bounds);
        CGFloat maxY = CGRectGetMaxY(host.bounds);
        if (CGRectGetMinY(expanded) < minY) {
            expanded.origin.y = minY;
        }
        if (CGRectGetMaxY(expanded) > maxY) {
            CGFloat overflow = CGRectGetMaxY(expanded) - maxY;
            expanded.size.height = MAX(0.0, expanded.size.height - overflow);
        }
    }
    return expanded;
}

static CGRect LGClockExpandedLegacyFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject) {
    if (CGRectIsEmpty(frame)) return frame;

    CGRect expanded = LGClockExpandedModernFrameForRect(frame,
                                                        nil,
                                                        text,
                                                        font,
                                                        ctFontObject,
                                                        NSTextAlignmentCenter);
    CGFloat textWidth = LGClockLineWidthForText(text, font, ctFontObject);
    CGFloat desiredWidth = MAX(CGRectGetWidth(expanded), textWidth + 18.0);
    if (desiredWidth > CGRectGetWidth(expanded)) {
        CGFloat delta = desiredWidth - CGRectGetWidth(expanded);
        expanded.origin.x -= floor(delta * 0.5);
        expanded.size.width = desiredWidth;
    }

    if (host) {
        CGFloat minX = CGRectGetMinX(host.bounds);
        CGFloat maxX = CGRectGetMaxX(host.bounds);
        if (CGRectGetMinX(expanded) < minX) {
            expanded.origin.x = minX;
        }
        if (CGRectGetMaxX(expanded) > maxX) {
            CGFloat overflow = CGRectGetMaxX(expanded) - maxX;
            expanded.size.width = MAX(0.0, expanded.size.width - overflow);
        }
        if (CGRectGetMaxY(expanded) > CGRectGetMaxY(host.bounds)) {
            CGFloat overflow = CGRectGetMaxY(expanded) - CGRectGetMaxY(host.bounds);
            expanded.size.height = MAX(0.0, expanded.size.height - overflow);
        }
    }
    return expanded;
}

static UIView *LGClockBestModernOverlayContainer(UIView *host, UILabel *label, UIFont *font, id ctFontObject) {
    if (!host || !label) return host;

    for (UIView *candidate = host.superview; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIWindow class]]) break;
        if (!LGClockViewOpacityAllowsOverlay(candidate)) continue;
        CGRect sourceFrame = [label convertRect:label.bounds toView:candidate];
        CGRect expanded = LGClockExpandedModernFrameForRect(sourceFrame,
                                                            nil,
                                                            label.text,
                                                            font,
                                                            ctFontObject,
                                                            label.textAlignment);
        BOOL fitsVertically = CGRectGetMinY(expanded) >= 0.0 && CGRectGetMaxY(expanded) <= CGRectGetHeight(candidate.bounds);
        BOOL fitsHorizontally = CGRectGetMinX(expanded) >= -1.0 && CGRectGetMaxX(expanded) <= CGRectGetWidth(candidate.bounds) + 1.0;
        if (!LGClockContainerClips(candidate) && fitsVertically && fitsHorizontally) {
            return candidate;
        }
    }

    return host.superview ?: host;
}

static UIView *LGClockOverlayContainerForHost(UIView *host) {
    if (!host) return nil;
    UIView *container = host.superview ?: host;
    for (UIView *cursor = host; cursor; cursor = cursor.superview) {
        cursor.clipsToBounds = NO;
        cursor.layer.masksToBounds = NO;
        if (cursor == container) break;
    }
    return container;
}

#pragma mark - Clock overlay

@interface LGClockGlassView : UIView
@property (nonatomic, strong) LGClockBackdropView *glassView;
@property (nonatomic, strong) UIView *frostedTintView;  // 磨砂模式的颜色覆盖层
@property (nonatomic, strong) UILabel *maskLabel;
@property (nonatomic, copy) NSString *displayText;
@property (nonatomic, copy) NSAttributedString *displayAttributedText;
@property (nonatomic, strong) UIFont *displayFont;
@property (nonatomic, strong) UIFont *displaySourceFont;
@property (nonatomic, strong) id displayCTFont;
@property (nonatomic, assign) NSTextAlignment displayAlignment;
@property (nonatomic, assign) CGFloat displayTopInset;
@property (nonatomic, weak) UIView *clockHost;
@property (nonatomic, weak) UILabel *sourceLabel;
@property (nonatomic, assign) CGRect cachedSourceFrameInContainer;
@property (nonatomic, assign) CGFloat cachedNearestNotificationTop;
@property (nonatomic, assign) BOOL lastSyncedMotionActive;
@property (nonatomic, assign) CGFloat cachedDynamicHeightAxis;
@property (nonatomic, assign) CGRect cachedMaskBounds;
@property (nonatomic, copy) NSString *cachedMaskText;
@property (nonatomic, copy) NSAttributedString *cachedMaskAttributedText;
@property (nonatomic, strong) UIFont *cachedMaskFont;
@property (nonatomic, strong) id cachedMaskCTFont;
@property (nonatomic, assign) NSTextAlignment cachedMaskAlignment;
@property (nonatomic, assign) CGFloat cachedMaskTopInset;
@property (nonatomic, strong) UIImage *cachedMaskImage;
- (void)syncFromSourceLabel:(UILabel *)label;
- (void)refreshForDisplayLink;
@end

@interface LGClockScrollObserver : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) LGClockGlassView *overlay;
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, assign) BOOL observing;
- (instancetype)initWithScrollView:(UIScrollView *)scrollView
                              host:(UIView *)host
                           overlay:(LGClockGlassView *)overlay;
- (void)invalidate;
@end

@implementation LGClockGlassView

- (BOOL)lg_rect:(CGRect)a differsFromRect:(CGRect)b {
    return fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) > 0.5 ||
           fabs(CGRectGetMinY(a) - CGRectGetMinY(b)) > 0.5 ||
           fabs(CGRectGetWidth(a) - CGRectGetWidth(b)) > 0.5 ||
           fabs(CGRectGetHeight(a) - CGRectGetHeight(b)) > 0.5;
}

- (BOOL)lg_size:(CGSize)a differsFromSize:(CGSize)b {
    return fabs(a.width - b.width) > 0.5 || fabs(a.height - b.height) > 0.5;
}

- (BOOL)lg_fontObject:(id)a equivalentTo:(id)b {
    if (a == b) return YES;
    if (!a || !b) return NO;
    CFTypeRef left = (__bridge CFTypeRef)a;
    CFTypeRef right = (__bridge CFTypeRef)b;
    if (CFGetTypeID(left) == CTFontGetTypeID() && CFGetTypeID(right) == CTFontGetTypeID()) {
        return CFEqual(left, right);
    }
    return [a isEqual:b];
}

- (BOOL)lg_attributedString:(NSAttributedString *)a equalTo:(NSAttributedString *)b {
    if (a == b) return YES;
    if (a.length == 0 && b.length == 0) return YES;
    if (!a || !b) return NO;
    return [a isEqualToAttributedString:b];
}

- (BOOL)lg_maskNeedsRebuildForBounds:(CGRect)bounds {
    if (!self.cachedMaskImage) return YES;
    if ([self lg_rect:self.cachedMaskBounds differsFromRect:bounds]) return YES;
    if (![(self.cachedMaskText ?: @"") isEqualToString:(self.displayText ?: @"")]) return YES;
    if (![self lg_attributedString:self.cachedMaskAttributedText equalTo:self.displayAttributedText]) return YES;
    if (![self lg_fontObject:self.cachedMaskFont equivalentTo:self.displayFont]) return YES;
    if (![self lg_fontObject:self.cachedMaskCTFont equivalentTo:self.displayCTFont]) return YES;
    if (self.cachedMaskAlignment != self.displayAlignment) return YES;
    if (fabs(self.cachedMaskTopInset - self.displayTopInset) > 0.01) return YES;
    return NO;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;

    _glassView = [[LGClockBackdropView alloc] initWithFrame:self.bounds];
    _glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glassView.cornerRadius = 0.0;
    [self addSubview:_glassView];

    // 磨砂模式的颜色覆盖层（默认隐藏）
    _frostedTintView = [[UIView alloc] initWithFrame:self.bounds];
    _frostedTintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _frostedTintView.hidden = YES;
    [self addSubview:_frostedTintView];

    _maskLabel = [[UILabel alloc] initWithFrame:self.bounds];
    _maskLabel.textColor = UIColor.whiteColor;
    _maskLabel.backgroundColor = UIColor.clearColor;
    _maskLabel.numberOfLines = 1;

    return self;
}

- (void)lg_applyMaskLabel {
    UILabel *mask = self.maskLabel;

    UIFont *font    = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    NSString *text  = self.displayText ?: @"";
    NSTextAlignment align = self.displayAlignment;

    if (self.displayAttributedText.length > 0) {
        NSMutableAttributedString *m = [self.displayAttributedText mutableCopy];
        NSRange r = NSMakeRange(0, m.length);
        [m addAttribute:NSForegroundColorAttributeName value:UIColor.whiteColor range:r];
        if (self.displayFont) [m addAttribute:NSFontAttributeName value:self.displayFont range:r];
        mask.attributedText = m;
    } else {
        mask.attributedText = nil;
        mask.font = font;
        mask.text = text;
        mask.textAlignment = align;
        mask.textColor = UIColor.whiteColor;
    }
    self.hidden = (text.length == 0 && self.displayAttributedText.length == 0);
}

- (NSAttributedString *)lg_maskAttributedString {
    if (LGClockVariableFontEnabled() && self.displayText.length > 0 &&
        (self.displayCTFont || self.displayFont)) {
        UIFont *font = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
        id ctFontObject = self.displayCTFont;
        CTFontRef ctFont = NULL;
        if (!ctFontObject) {
            ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                    font.pointSize,
                                                    NULL);
            ctFontObject = (__bridge id)ctFont;
        }
        NSDictionary *attrs = @{
            (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
        };
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:self.displayText ?: @"" attributes:attrs];
        if (ctFont) CFRelease(ctFont);
        return string;
    }

    if (self.displayAttributedText.length > 0) {
        NSMutableAttributedString *copy = [self.displayAttributedText mutableCopy];
        [copy beginEditing];
        NSRange fullRange = NSMakeRange(0, copy.length);
        [copy enumerateAttribute:NSFontAttributeName
                         inRange:fullRange
                         options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *font = [value isKindOfClass:[UIFont class]] ? (UIFont *)value : self.displayFont;
            if (!font) font = [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
            [copy removeAttribute:NSFontAttributeName range:range];
            CTFontRef ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                              font.pointSize,
                                                              NULL);
            if (ctFont) {
                [copy addAttribute:(__bridge NSString *)kCTFontAttributeName value:(__bridge id)ctFont range:range];
                CFRelease(ctFont);
            }
        }];
        [copy removeAttribute:NSForegroundColorAttributeName range:fullRange];
        [copy removeAttribute:(__bridge NSString *)kCTForegroundColorAttributeName range:fullRange];
        [copy addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName
                     value:(id)UIColor.whiteColor.CGColor
                     range:fullRange];
        [copy endEditing];
        return copy;
    }

    UIFont *font = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    id ctFontObject = self.displayCTFont;
    CTFontRef ctFont = NULL;
    if (!ctFontObject) {
        ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                font.pointSize,
                                                NULL);
        ctFontObject = (__bridge id)ctFont;
    }
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:self.displayText ?: @"" attributes:attrs];
    if (ctFont) CFRelease(ctFont);
    return string;
}

- (UIImage *)lg_maskImageForBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds) || self.displayText.length == 0 || !self.displayFont) return nil;

    CGFloat scale = UIScreen.mainScreen.scale ?: 1.0;
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    CGContextTranslateCTM(ctx, 0.0, bounds.size.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    UIView *host = self.clockHost;
    if (!host) {
        host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
    }
    BOOL legacyHost = LGIsLegacyClockHost(host);

    NSAttributedString *attributed = [self lg_maskAttributedString];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

    CGFloat x = 0.0;
    switch (self.displayAlignment) {
        case NSTextAlignmentCenter:
            x = floor((bounds.size.width - width) * 0.5);
            break;
        case NSTextAlignmentRight:
            x = floor(bounds.size.width - width);
            break;
        default:
            x = 0.0;
            break;
    }
    CGFloat baseline = 0.0;
    if (legacyHost) {
        baseline = floor(bounds.size.height - ascent);
    } else {
        CGFloat topInset = MAX(0.0, self.displayTopInset);
        baseline = floor(bounds.size.height - topInset - ascent);
    }
    if (legacyHost) {
        CGContextSetTextPosition(ctx, x, baseline);
        CTLineDraw(line, ctx);
    } else {
        CGFloat embolden = LGClockModernSyntheticEmbolden();
        if (embolden > 0.0) {
            static const CGPoint offsets[] = {
                {0.0, 0.0},
                {-1.0, 0.0},
                {1.0, 0.0},
                {0.0, 1.0},
                {0.0, -1.0},
                {-0.7, -0.7},
                {0.7, -0.7},
                {-0.7, 0.7},
                {0.7, 0.7},
            };
            for (NSUInteger i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
                CGContextSetTextPosition(ctx, x + offsets[i].x * embolden, baseline + offsets[i].y * embolden);
                CTLineDraw(line, ctx);
            }
        } else {
            CGContextSetTextPosition(ctx, x, baseline);
            CTLineDraw(line, ctx);
        }
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (line) CFRelease(line);
    return image;
}

- (void)lg_updateMask {

    UIFont *font    = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CGFloat lineH   = ceil(font.lineHeight);
    CGFloat margin  = 12.0;
    BOOL    legacy  = LGIsLegacyClockHost(self.clockHost);
    CGFloat top     = legacy ? (self.bounds.size.height - lineH) : MAX(0.0, self.displayTopInset);
    CGRect  textFrame = CGRectMake(0.0, top - margin, self.bounds.size.width, lineH + margin * 2.0);

    self.maskLabel.frame = textFrame;
    [self lg_applyMaskLabel];

    if ([self lg_maskNeedsRebuildForBounds:self.bounds]) {
        UIImage *image = [self lg_maskImageForBounds:self.bounds];
        if (image) {
            self.cachedMaskBounds = self.bounds;
            self.cachedMaskText = self.displayText;
            self.cachedMaskAttributedText = self.displayAttributedText;
            self.cachedMaskFont = self.displayFont;
            self.cachedMaskCTFont = self.displayCTFont;
            self.cachedMaskAlignment = self.displayAlignment;
            self.cachedMaskTopInset = self.displayTopInset;
            self.cachedMaskImage = image;

            LGQueueClockMaskImage(image, self.glassView);
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glassView.frame = self.bounds;
    [self lg_updateMask];
}

- (void)syncFromSourceLabel:(UILabel *)label {
    if (!label) {
        return;
    }
    NSString *desiredText = label.text ?: @"";
    UIView *host = self.clockHost;
    if (!host) {
        host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
    }
    CGRect sourceFrame = LGClockSourceFrameForLabel(label, self.superview);
    CGRect desiredFrame = CGRectZero;
    UIFont *desiredFont = nil;
    id desiredCTFont = nil;
    UIFont *desiredSourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    NSTextAlignment desiredAlignment = label.textAlignment;
    NSAttributedString *desiredAttributed = nil;
    CGFloat desiredTopInset = 0.0;
    CGFloat desiredNearestNotificationTop = CGFLOAT_MAX;
    CGFloat desiredDynamicHeightAxis = 0.0;
    BOOL motionActive = CACurrentMediaTime() < sClockActiveFPSUntil;
    if (LGIsLegacyClockHost(host)) {
        UIView *container = self.superview ?: LGClockOverlayContainerForHost(host);
        sourceFrame = LGClockSourceFrameForLabel(label, container);
        sourceFrame = LGClockOffsetFrame(sourceFrame);
        UIFont *sourceFont = desiredSourceFont;
        BOOL useVariableFont = LGClockLegacyUsesVariableFont();
        CGFloat pointSize = useVariableFont
            ? MAX(sourceFont.pointSize * LGClockVariableFontSizeScale(), 1.0)
            : sourceFont.pointSize;
        CGFloat dynamicHeight = useVariableFont
            ? LGClockDynamicHeightAxisForContext(label, host, container, sourceFrame)
            : LGClockVariableFontHeight();
        desiredDynamicHeightAxis = dynamicHeight;
        CTFontRef renderCTFont = useVariableFont
            ? LGClockLegacyVariableCTFontForHeight(pointSize, dynamicHeight)
            : NULL;
        id renderFontObject = renderCTFont ? (__bridge_transfer id)renderCTFont : nil;
        desiredCTFont = renderFontObject;
        desiredFont = renderFontObject ? (UIFont *)renderFontObject : LGClockPreferredRenderFont(label, host);
        CGRect glyphFrame = LGClockExpandedLegacyFrameForRect(sourceFrame,
                                                               nil,
                                                               desiredText,
                                                               desiredFont,
                                                               desiredCTFont);
        if (motionActive && useVariableFont) {
            CTFontRef canvasCTFont = LGClockLegacyVariableCTFontForHeight(pointSize,
                                                                           LGClockVariableFontHeight());
            id canvasFontObject = canvasCTFont ? (__bridge_transfer id)canvasCTFont : nil;
            UIFont *canvasFont = canvasFontObject ? (UIFont *)canvasFontObject : desiredFont;
            CGRect canvasFrame = LGClockExpandedLegacyFrameForRect(sourceFrame,
                                                                    nil,
                                                                    desiredText,
                                                                    canvasFont,
                                                                    canvasFontObject);
            desiredFrame = CGRectUnion(glyphFrame, canvasFrame);
        } else {
            desiredFrame = glyphFrame;
        }
        desiredAlignment = NSTextAlignmentCenter;
        desiredAttributed = nil;
        desiredTopInset = 0.0;
    } else {
        UIFont *sourceFont = desiredSourceFont;
        UIView *container = self.superview ?: LGClockBestModernOverlayContainer(host,
                                                                                label,
                                                                                sourceFont,
                                                                                nil);
        sourceFrame = LGClockSourceFrameForLabel(label, container);
        sourceFrame = LGClockOffsetFrame(sourceFrame);
        sourceFrame = LGClockSnapRect(sourceFrame, kLGClockModernGeometrySnapStep);
        desiredNearestNotificationTop = LGClockNearestNotificationTop(host, container, sourceFrame);
        if (desiredNearestNotificationTop != CGFLOAT_MAX) {
            desiredNearestNotificationTop = LGClockSnapScalar(desiredNearestNotificationTop,
                                                              kLGClockModernGeometrySnapStep);
        }
        CGFloat pointSize = MAX(sourceFont.pointSize * LGClockVariableFontSizeScale(), 1.0);
        CGFloat dynamicHeight = LGClockDynamicHeightAxisForContext(label, host, container, sourceFrame);
        desiredDynamicHeightAxis = dynamicHeight;
        CTFontRef renderCTFont = LGClockVariableCTFontForHeight(pointSize, dynamicHeight);
        id renderFontObject = renderCTFont ? (__bridge_transfer id)renderCTFont : nil;
        desiredCTFont = renderFontObject;
        desiredFont = renderFontObject ? (UIFont *)renderFontObject : LGClockPreferredRenderFont(label, host);
        CGRect glyphFrame = LGClockExpandedModernFrameForRect(sourceFrame,
                                                              nil,
                                                              desiredText,
                                                              desiredFont,
                                                              desiredCTFont,
                                                              label.textAlignment);

        if (motionActive) {
            CTFontRef canvasCTFont = LGClockVariableCTFontForHeight(pointSize,
                                                                    LGClockVariableFontHeight());
            id canvasFontObject = canvasCTFont ? (__bridge_transfer id)canvasCTFont : nil;
            UIFont *canvasFont = canvasFontObject ? (UIFont *)canvasFontObject : desiredFont;
            CGRect canvasFrame = LGClockExpandedModernFrameForRect(sourceFrame,
                                                                   nil,
                                                                   desiredText,
                                                                   canvasFont,
                                                                   canvasFontObject,
                                                                   label.textAlignment);
            desiredFrame = CGRectUnion(glyphFrame, canvasFrame);
        } else {
            desiredFrame = glyphFrame;
        }
        desiredAlignment = label.textAlignment;
        desiredAttributed = label.attributedText;
        desiredTopInset = MAX(0.0, CGRectGetMinY(label.bounds));
    }
    self.sourceLabel = label;
    self.cachedSourceFrameInContainer = sourceFrame;
    self.cachedNearestNotificationTop = desiredNearestNotificationTop;
    self.cachedDynamicHeightAxis = desiredDynamicHeightAxis;
    self.displayText = desiredText;
    self.displayAttributedText = desiredAttributed;
    self.displaySourceFont = desiredSourceFont;
    self.displayFont = desiredFont;
    self.displayCTFont = desiredCTFont;
    self.displayAlignment = desiredAlignment;
    self.displayTopInset = desiredTopInset;
    self.lastSyncedMotionActive = motionActive;
    self.frame = desiredFrame;
    self.hidden = !self.displayText.length;
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)refreshForDisplayLink {
    UILabel *label = self.sourceLabel;
    if (!label || !self.superview || !self.clockHost.window) {
        return;
    }
    if (LGIsModernClockHost(self.clockHost)) {
        BOOL textChanged = ![(self.displayText ?: @"") isEqualToString:(label.text ?: @"")];
        BOOL attributedChanged = (self.displayAttributedText || label.attributedText)
            && ![self.displayAttributedText isEqualToAttributedString:(label.attributedText ?: [[NSAttributedString alloc] initWithString:@""])];
        UIFont *currentSourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
        BOOL fontChanged = ![self lg_fontObject:self.displaySourceFont equivalentTo:currentSourceFont];
        BOOL alignmentChanged = self.displayAlignment != label.textAlignment;
        BOOL topInsetChanged = fabs(self.displayTopInset - MAX(0.0, CGRectGetMinY(label.bounds))) > 0.01;
        BOOL motionActive = CACurrentMediaTime() < sClockActiveFPSUntil;
        BOOL motionActiveStateChanged = (self.lastSyncedMotionActive != motionActive);
        UIFont *sourceFont = currentSourceFont;
        UIView *container = self.superview ?: LGClockBestModernOverlayContainer(self.clockHost,
                                                                                label,
                                                                                sourceFont,
                                                                                nil);
        CGRect sourceFrame = LGClockSourceFrameForLabel(label, container);
        sourceFrame = LGClockOffsetFrame(sourceFrame);
        sourceFrame = LGClockSnapRect(sourceFrame, kLGClockModernGeometrySnapStep);
        CGFloat nearestTop = LGClockNearestNotificationTop(self.clockHost, container, sourceFrame);
        if (nearestTop != CGFLOAT_MAX) {
            nearestTop = LGClockSnapScalar(nearestTop, kLGClockModernGeometrySnapStep);
        }
        CGFloat proposedDynamicHeightAxis = 0.0;
        if (label.font) {
            proposedDynamicHeightAxis = LGClockDynamicHeightAxisForContext(label,
                                                                           self.clockHost,
                                                                           container,
                                                                           sourceFrame);
        }
        BOOL dynamicHeightChanged = fabs(self.cachedDynamicHeightAxis - proposedDynamicHeightAxis) > 0.5;
        BOOL sourceFrameChanged = [self lg_rect:self.cachedSourceFrameInContainer differsFromRect:sourceFrame];
        if (textChanged || attributedChanged || fontChanged || alignmentChanged || topInsetChanged ||
            dynamicHeightChanged || sourceFrameChanged || motionActiveStateChanged) {
            LGClockMarkMotionActiveForDuration(0.25);
            [self syncFromSourceLabel:label];
            [self layoutIfNeeded];
            return;
        }
        return;
    }
    BOOL textChanged = ![(self.displayText ?: @"") isEqualToString:(label.text ?: @"")];
    BOOL attributedChanged = (self.displayAttributedText || label.attributedText)
        && ![self.displayAttributedText isEqualToAttributedString:(label.attributedText ?: [[NSAttributedString alloc] initWithString:@""])];
    UIFont *currentSourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    BOOL fontChanged = ![self lg_fontObject:self.displaySourceFont equivalentTo:currentSourceFont];
    BOOL alignmentChanged = self.displayAlignment != label.textAlignment;
    BOOL topInsetChanged = fabs(self.displayTopInset - MAX(0.0, CGRectGetMinY(label.bounds))) > 0.01;
    CGRect sourceFrame = LGClockSourceFrameForLabel(label, self.superview);
    if (textChanged || attributedChanged || fontChanged || alignmentChanged || topInsetChanged ||
        [self lg_rect:self.cachedSourceFrameInContainer differsFromRect:sourceFrame]) {
        [self syncFromSourceLabel:label];
        [self layoutIfNeeded];
        return;
    }
}

@end

@implementation LGClockScrollObserver

- (instancetype)initWithScrollView:(UIScrollView *)scrollView
                              host:(UIView *)host
                           overlay:(LGClockGlassView *)overlay {
    self = [super init];
    if (!self) return nil;
    _scrollView = scrollView;
    _host = host;
    _overlay = overlay;
    if (scrollView) {
        [scrollView addObserver:self
                     forKeyPath:@"contentOffset"
                        options:NSKeyValueObservingOptionNew
                        context:kLGClockScrollKVOContext];
        [scrollView addObserver:self
                     forKeyPath:@"bounds"
                        options:NSKeyValueObservingOptionNew
                        context:kLGClockScrollKVOContext];
        _observing = YES;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (!_observing) return;
    UIScrollView *scrollView = _scrollView;
    _observing = NO;
    if (!scrollView) return;
    @try {
        [scrollView removeObserver:self forKeyPath:@"contentOffset" context:kLGClockScrollKVOContext];
        [scrollView removeObserver:self forKeyPath:@"bounds" context:kLGClockScrollKVOContext];
    } @catch (NSException *exception) {
        LGClockLog(@"clock scroll observer cleanup failed %@ %@", exception.name, exception.reason);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != kLGClockScrollKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    UIView *host = self.host;
    LGClockGlassView *overlay = self.overlay;
    if (!host.window || !overlay || !overlay.superview) return;

    LGClockMarkMotionActiveForDuration(0.35);
    UILabel *sourceLabel = overlay.sourceLabel;
    if (sourceLabel) {
        [overlay syncFromSourceLabel:sourceLabel];
    } else {
        [overlay setNeedsLayout];
    }
}

@end

static void LGRestoreClockSourceView(UIView *view) {
    if (!view) return;
    NSNumber *originalAlpha = objc_getAssociatedObject(view, kLGClockOriginalAlphaKey);
    NSNumber *originalLayerOpacity = objc_getAssociatedObject(view, kLGClockOriginalLayerOpacityKey);
    view.alpha = originalAlpha ? originalAlpha.doubleValue : 1.0;
    view.layer.opacity = originalLayerOpacity ? originalLayerOpacity.floatValue : 1.0f;
    LGSetLayerTreeOpacity(view.layer, view.layer.opacity);
    objc_setAssociatedObject(view, kLGClockOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kLGClockOriginalLayerOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGDetachClockScrollObserver(UIView *host) {
    LGClockScrollObserver *observer = objc_getAssociatedObject(host, kLGClockScrollObserverKey);
    [observer invalidate];
    objc_setAssociatedObject(host, kLGClockScrollObserverKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGDetachClockHostIfNeeded(host);
}

static void LGEnsureClockScrollObserver(UIView *host, LGClockGlassView *overlay) {
    UIScrollView *scrollView = LGClockAncestorScrollView(host);
    LGClockScrollObserver *observer = objc_getAssociatedObject(host, kLGClockScrollObserverKey);
    if (observer && observer.scrollView == scrollView) {
        observer.overlay = overlay;
        return;
    }

    [observer invalidate];
    if (!scrollView) {
        objc_setAssociatedObject(host, kLGClockScrollObserverKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    observer = [[LGClockScrollObserver alloc] initWithScrollView:scrollView host:host overlay:overlay];
    objc_setAssociatedObject(host, kLGClockScrollObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Host installation and cleanup

static void LGApplyClockReplacement(UIView *host) {
    if (!LGIsClockHost(host)) {
        return;
    }

    UILabel *sourceLabel = LGClockPrimarySourceLabelForHost(host);
    NSArray<UIView *> *visibleSourceViews = LGClockVisibleSourceViewsForHost(host, sourceLabel);
    LGClockGlassView *overlay = objc_getAssociatedObject(host, kLGClockOverlayKey);
    BOOL enabled = LGClockEnabled();
    BOOL frostedMode = LGClockFrostedModeEnabled();
    BOOL overlayEligible = LGClockHostCanReceiveOverlay(host);
    BOOL blocking = LGClockHasBlockingPresentation(host);
    // 诊断: 打印磨砂模式状态
    LGClockLog(@"clock apply check kind=%@ enabled=%d frostedMode=%d eligible=%d blocking=%d hasOverlay=%d",
               LGClockHostKind(host),
               enabled,
               frostedMode,
               overlayEligible,
               blocking,
               overlay ? 1 : 0);
    // 磨砂模式不再移除 overlay，而是切换 filter 类型（液态玻璃 ↔ 磨砂玻璃）
    // 两种模式都用我们自己的渲染，稳定可靠
    if (!enabled || !overlayEligible || !sourceLabel || blocking) {
        NSString *reason = !enabled ? @"disabled"
            : !overlayEligible ? @"not-eligible"
            : !sourceLabel ? @"no-source"
            : @"blocked";
        NSString *lastReason = objc_getAssociatedObject(host, kLGClockLastBailReasonKey);
        if (![lastReason isEqualToString:reason]) {
            objc_setAssociatedObject(host, kLGClockLastBailReasonKey, reason, OBJC_ASSOCIATION_COPY_NONATOMIC);
            // When no source label is found, dump all UILabels in the host for debugging
            if (!sourceLabel) {
                NSMutableString *labelDump = [NSMutableString string];
                LGTraverseViews(host, ^(UIView *view) {
                    if ([view isKindOfClass:[UILabel class]]) {
                        UILabel *l = (UILabel *)view;
                        [labelDump appendFormat:@"\n  cls=%@ fontSize=%.1f text=%@ hidden=%d alpha=%.2f",
                         NSStringFromClass(l.class),
                         l.font.pointSize,
                         l.text.length > 20 ? [[l.text substringToIndex:20] stringByAppendingString:@"..."] : l.text ?: @"(nil)",
                         l.hidden, l.alpha];
                    }
                });
                LGClockLog(@"clock skip kind=%@ reason=%@ detail=%@ host=%@ frame=%@ labels=%lu eligible=%d blocking=%d allLabels:%@",
                           LGClockHostKind(host),
                           reason,
                           !overlayEligible ? LGClockHostIneligibilityReason(host) : @"",
                           NSStringFromClass(host.class),
                           NSStringFromCGRect(host.frame),
                           (unsigned long)LGClockSourceLabelsForHost(host).count,
                           overlayEligible,
                           blocking,
                           labelDump.length > 0 ? labelDump : @" (none)");
            } else {
                LGClockLog(@"clock skip kind=%@ reason=%@ detail=%@ host=%@ frame=%@ labels=%lu eligible=%d blocking=%d",
                           LGClockHostKind(host),
                           reason,
                           !overlayEligible ? LGClockHostIneligibilityReason(host) : @"",
                           NSStringFromClass(host.class),
                           NSStringFromCGRect(host.frame),
                           (unsigned long)LGClockSourceLabelsForHost(host).count,
                           overlayEligible,
                           blocking);
            }
        }
        if (overlay) {
            LGClockLog(@"clock cleanup kind=%@ reason=%@ host=%@ frame=%@",
                       LGClockHostKind(host),
                       reason,
                       NSStringFromClass(host.class),
                       NSStringFromCGRect(host.frame));
        }
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, kLGClockOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
        LGDetachClockScrollObserver(host);
        // Restore previously hidden source views
        for (UIView *view in visibleSourceViews) {
            LGRestoreClockSourceView(view);
        }
        // FIX: Also scan the entire host subtree for any views that had their
        // alpha set to 0 but are no longer in visibleSourceViews (e.g. because
        // source label detection failed on iOS 26). This ensures the stock clock
        // is always restored even if label detection fails.
        LGTraverseViews(host, ^(UIView *view) {
            NSNumber *originalAlpha = objc_getAssociatedObject(view, kLGClockOriginalAlphaKey);
            if (originalAlpha) {
                LGRestoreClockSourceView(view);
            }
        });
        return;
    }
    objc_setAssociatedObject(host, kLGClockLastBailReasonKey, nil, OBJC_ASSOCIATION_ASSIGN);

    for (UIView *view in visibleSourceViews) {
        if (!objc_getAssociatedObject(view, kLGClockOriginalAlphaKey)) {
            objc_setAssociatedObject(view, kLGClockOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kLGClockOriginalLayerOpacityKey, @(view.layer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.alpha = 0.0;
        LGSetLayerTreeOpacity(view.layer, 0.0f);
    }

    UIFont *preferredFont = LGClockPreferredRenderFont(sourceLabel, host);
    UIView *overlayContainer = LGIsLegacyClockHost(host)
        ? LGClockOverlayContainerForHost(host)
        : LGClockBestModernOverlayContainer(host, sourceLabel, preferredFont, nil);

    if (!overlay) {
        overlay = [[LGClockGlassView alloc] initWithFrame:sourceLabel.frame];
        objc_setAssociatedObject(host, kLGClockOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [overlayContainer addSubview:overlay];
        LGClockLog(@"clock glass CREATED kind=%@ host=%@ frame=%@ label=%@ font=%@",
                   LGClockHostKind(host),
                   NSStringFromClass(host.class),
                   NSStringFromCGRect(overlay.frame),
                   sourceLabel.text ?: @"(nil)",
                   NSStringFromClass(sourceLabel.font.class));
        // 诊断: 检查 glassView 的 layer 类型和 filter
        LGClockBackdropView *glassView = overlay.glassView;
        Class backdropCls = NSClassFromString(@"CABackdropLayer");
        BOOL isBackdrop = backdropCls && [glassView.layer isKindOfClass:backdropCls];
        LGClockLog(@"  DIAG: glassView=%@ layerClass=%@ isBackdrop=%@ filterType=%@",
                   NSStringFromClass(glassView.class),
                   NSStringFromClass(glassView.layer.class),
                   isBackdrop ? @"YES" : @"NO",
                   glassView.lgFilterType ?: @"(nil)");
    } else if (overlay.superview != overlayContainer) {
        [overlay removeFromSuperview];
        [overlayContainer addSubview:overlay];
    }

    // 磨砂模式：始终使用我们自己的液态渲染 filter，不切换到系统高斯模糊。
    // 磨砂观感由 backboardd 在渲染时用 v0.1.73b 参数预设（弱折射/无色散/#FFFFFF66 着色）实现。
    LGClockBackdropView *glassView = overlay.glassView;
    NSString *liquidFilterType = LGFilterTypeForHostPrefix(@"Clock");
    NSString *targetFilterType = liquidFilterType;
    NSString *currentFilterType = glassView.lgFilterType;
    
    if (![currentFilterType isEqualToString:targetFilterType]) {
        LGClockLog(@"clock filter ensure: %@ → %@ (frosted=%d)",
                   currentFilterType ?: @"(nil)",
                   targetFilterType,
                   frostedMode);
        glassView.lgFilterType = targetFilterType;
        // 强制重新应用 filter
        @try {
            [glassView setValue:@NO forKey:@"_filterAttached"];
        } @catch (NSException *e) {
            LGClockLog(@"  WARN: could not reset _filterAttached: %@", e.reason);
        }
        [glassView applyFilters];
    }
    
    // 磨砂着色由 backboardd 参数预设处理，无需额外的颜色覆盖层
    overlay.frostedTintView.hidden = YES;

    overlay.clockHost = host;
    LGAttachClockHostIfNeeded(host);
    LGEnsureClockScrollObserver(host, overlay);
    LGClockSeedObstacleRegistriesFromWindow(host.window);
    [overlay syncFromSourceLabel:sourceLabel];
    [overlay.superview bringSubviewToFront:overlay];
}

static void LGClockRunDeferredApply(UIView *host) {
    objc_setAssociatedObject(host,
                             kLGClockLastDeferredApplyTimeKey,
                             @(CACurrentMediaTime()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (host.window) LGApplyClockReplacement(host);
}

static void LGScheduleClockApply(UIView *host, BOOL includeRecoveryRetry, CFTimeInterval minimumInterval) {
    if (!host || !LGIsClockHost(host)) return;
    if ([objc_getAssociatedObject(host, kLGClockDeferredApplyPendingKey) boolValue]) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastApplyTime = objc_getAssociatedObject(host, kLGClockLastDeferredApplyTimeKey);
    CFTimeInterval delay = 0.0;
    if (minimumInterval > 0.0 && lastApplyTime.doubleValue > 0.0) {
        delay = MAX(0.0, minimumInterval - (now - lastApplyTime.doubleValue));
    }
    objc_setAssociatedObject(host, kLGClockDeferredApplyPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_block_t applyBlock = ^{
        LGClockRunDeferredApply(host);
        if (!includeRecoveryRetry) {
            objc_setAssociatedObject(host, kLGClockDeferredApplyPendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
            return;
        }
        // FIX: Added more retry passes at increasing intervals.
        // On iOS 26, source label text may be set asynchronously and may not
        // be available at the 0.05s retry. We now retry at 0.05s, 0.15s, 0.3s.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGClockRunDeferredApply(host);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LGClockRunDeferredApply(host);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    LGClockRunDeferredApply(host);
                    objc_setAssociatedObject(host, kLGClockDeferredApplyPendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
                });
            });
        });
    };
    if (delay <= 0.0) {
        dispatch_async(dispatch_get_main_queue(), applyBlock);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(),
                       applyBlock);
    }
}

static void LGRequestClockApplyForSourceMutation(UIView *host) {
    if (!host || !LGIsClockHost(host)) return;
    if (LGIsModernClockHost(host) && host.window) {
        LGScheduleClockApply(host, NO, 1.0 / 30.0);
        return;
    }
    LGApplyClockReplacement(host);
}

static void LGRefreshClockHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGClockSeedObstacleRegistriesFromWindow(window);
        LGTraverseViews(window, ^(UIView *view) {
            if (LGIsClockHost(view)) LGApplyClockReplacement(view);
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in app.windows) refreshWindow(window);
    }
}

static void LGRefreshRegisteredClockHosts(void) {
    for (UIView *host in LGClockHostRegistry().allObjects) {
        if (!host.window) continue;
        LGApplyClockReplacement(host);
    }
    LGClockSyncDisplayLinkActivity();
}

static void LGScheduleClockRecoveryRefresh(void) {
    if (sClockRecoveryRefreshPending) return;
    sClockRecoveryRefreshPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sClockRecoveryRefreshPending = NO;
        LGRefreshAllClockHosts();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGRefreshAllClockHosts();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LGRefreshAllClockHosts();
    });
}

void LGScheduleClockRecoveryRefreshForPresentationChange(void) {
    LGScheduleClockRecoveryRefresh();
}

static void LGClockCleanupRegisteredHosts(void) {
    for (UIView *host in LGClockHostRegistry().allObjects) {
        LGClockGlassView *overlay = objc_getAssociatedObject(host, kLGClockOverlayKey);
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, kLGClockOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
        LGDetachClockScrollObserver(host);

        UILabel *sourceLabel = LGClockPrimarySourceLabelForHost(host);
        for (UIView *view in LGClockVisibleSourceViewsForHost(host, sourceLabel)) {
            LGRestoreClockSourceView(view);
        }
    }
    LGStopClockDisplayLink();
}

static void LGRefreshAllClockHosts(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        LGApplyAbbreviatedDateTextInView(window);
    }
    LGRefreshClockHosts();
    LGRefreshRegisteredClockHosts();
}

#pragma mark - SpringBoard hooks

%group LGClockSpringBoard

%hook CSProminentTimeView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    LGClockLog(@"CSProminentTimeView didMoveToWindow (hasWindow=%d frame=%@)",
               self_.window != nil, NSStringFromCGRect(self_.frame));
    if (self_.window) {
        // 诊断: dump 子视图结构和所有 UILabel
        NSMutableString *dump = [NSMutableString stringWithString:@"\n  --- CSProminentTimeView subview tree ---"];
        LGClockDumpViewTree(self_, 1, dump);
        [dump appendString:@"\n  --- All UILabels in host ---"];
        LGTraverseViews(self_, ^(UIView *view) {
            if ([view isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)view;
                [dump appendFormat:@"\n    cls=%@ fontSize=%.1f text='%@' hidden=%d alpha=%.2f frame=%@",
                 NSStringFromClass(l.class),
                 l.font.pointSize,
                 l.text.length > 20 ? [[l.text substringToIndex:20] stringByAppendingString:@"..."] : l.text ?: @"(nil)",
                 l.hidden, l.alpha, NSStringFromCGRect(l.frame)];
            }
        });
        [dump appendString:@"\n  ----------------------------------"];
        LGClockLog(@"%@", dump);
        LGScheduleClockApply(self_, YES, 0.0);
    }
    else LGApplyClockReplacement(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) LGScheduleClockApply(self_, NO, 1.0 / 30.0);
}

%end

%hook SBFLockScreenDateView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    LGPositionLegacyDateSubtitleForClockHost(self_);
    LGApplyClockReplacement(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    LGPositionLegacyDateSubtitleForClockHost(self_);
    LGApplyClockReplacement(self_);
}

%end

%hook SBFLockScreenDateSubtitleDateView

- (void)didMoveToWindow {
    %orig;
    LGApplyAbbreviatedDateTextInView((UIView *)self);
    LGPositionLegacyDateSubtitleAboveClock((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyAbbreviatedDateTextInView((UIView *)self);
    LGPositionLegacyDateSubtitleAboveClock((UIView *)self);
}

%end

%hook CSProminentSubtitleDateView

- (void)setFrame:(CGRect)frame {
    %orig(frame);
}

- (void)didMoveToWindow {
    %orig;
    LGApplyAbbreviatedDateTextInView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyAbbreviatedDateTextInView((UIView *)self);
}

%end

%hook NCNotificationListView

- (void)setFrame:(CGRect)frame {
    UIView *self_ = (UIView *)self;
    if (![objc_getAssociatedObject(self_, kLGClockLegacyNotificationApplyingKey) boolValue]) {
        frame = LGAdjustedLegacyNotificationListFrame(self_, frame);
    }
    %orig(frame);
}

- (void)didMoveToWindow {
    %orig;
    LGScheduleLegacyNotificationListRelayout((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGScheduleLegacyNotificationListRelayout((UIView *)self);
}

%end

%hook PLPlatterView

- (void)didMoveToWindow {
    %orig;
    LGClockRegisterNotificationObstacleView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGClockRegisterNotificationObstacleView((UIView *)self);
}

%end

%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    LGClockRegisterNotificationObstacleView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGClockRegisterNotificationObstacleView((UIView *)self);
}

%end

%hook NCNotificationLongLookView

- (void)didMoveToWindow {
    %orig;
    LGClockRegisterNotificationObstacleView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGClockRegisterNotificationObstacleView((UIView *)self);
}

%end

%hook NCNotificationListSectionRevealHintView

- (void)didMoveToWindow {
    %orig;
    LGScheduleClockRefreshForLegacyRevealHint((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGScheduleClockRefreshForLegacyRevealHint((UIView *)self);
}

%end

%hook NCNotificationStructuredListViewController

- (void)viewWillLayoutSubviews {
    %orig;
    LGRelayoutLegacyNotificationListForController((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    LGRelayoutLegacyNotificationListForController((UIViewController *)self);
}

%end

%hook SBCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGClockSetCoverSheetVisible(YES);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGClockSetCoverSheetVisible(YES);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGClockSetCoverSheetVisible(NO);
}

%end

%hook SBDashBoardViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGClockSetCoverSheetVisible(YES);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGClockSetCoverSheetVisible(YES);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGClockSetCoverSheetVisible(NO);
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    %orig;
    if (LGIsLegacyClockDateLabel((UIView *)self)) {
        LGApplyAbbreviatedDateTextToLabel((UILabel *)self);
        return;
    }
    if (LGIsModernClockSourceLabel((UIView *)self) || LGIsLegacyClockTextLabel((UIView *)self)) {
        UIView *host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
        if (host) LGRequestClockApplyForSourceMutation(host);
    }
}

- (void)setFont:(UIFont *)font {
    %orig;
    if (LGIsModernClockSourceLabel((UIView *)self) || LGIsLegacyClockTextLabel((UIView *)self)) {
        UIView *host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
        if (host) LGRequestClockApplyForSourceMutation(host);
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    lgObservePreferenceReload(^{
        // 诊断: 打印所有 Clock 相关的偏好设置
        NSDictionary *allPrefs = [NSDictionary dictionaryWithContentsOfFile:
            jbroot(@"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist")] ?: @{};
        NSMutableArray *clockKeys = [NSMutableArray array];
        for (NSString *key in allPrefs) {
            if ([key hasPrefix:@"Clock."]) {
                [clockKeys addObject:[NSString stringWithFormat:@"%@=%@", key, allPrefs[key]]];
            }
        }
        LGClockLog(@"prefs reload triggered — all Clock.* keys: %@", clockKeys);
        LGClockLog(@"  frostedMode via CFPreferences=%d", LGClockFrostedModeEnabled());
        id glassVal = LGGlassPreferenceValue(@"Clock.FrostedMode");
        LGClockLog(@"  frostedMode via LGGlassPreferenceValue=%@ (class=%@)",
                   glassVal ?: @"(nil)",
                   NSStringFromClass([glassVal class]));
        LGRefreshAllClockHosts();
    });
    BOOL cspExists = NSClassFromString(@"CSProminentTimeView") != nil;
    BOOL sbfExists = NSClassFromString(@"SBFLockScreenDateView") != nil;
    BOOL csSubExists = NSClassFromString(@"CSProminentSubtitleDateView") != nil;
    BOOL uiAnimLabelExists = NSClassFromString(@"_UIAnimatingLabel") != nil;
    BOOL camPreviewExists = NSClassFromString(@"CAMPreviewView") != nil;
    BOOL pbuiSnapshotExists = NSClassFromString(@"PBUISnapshotReplicaView") != nil;
    Class glassCls = NSClassFromString(@"LGLiveBackdropView");
    BOOL backdropClsExists = NSClassFromString(@"CABackdropLayer") != nil;
    BOOL caFilterExists = NSClassFromString(@"CAFilter") != nil;

    LGClockLog(@"=== DIAGNOSTIC: Clock Module Init ===");
    LGClockLog(@"CSProminentTimeView: %@", cspExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"SBFLockScreenDateView: %@", sbfExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"CSProminentSubtitleDateView: %@", csSubExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"_UIAnimatingLabel: %@", uiAnimLabelExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"LGLiveBackdropView: %@", glassCls ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"CABackdropLayer: %@", backdropClsExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"CAFilter: %@", caFilterExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"CAMPreviewView (blocker): %@", camPreviewExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"PBUISnapshotReplicaView (blocker): %@", pbuiSnapshotExists ? @"FOUND" : @"NOT FOUND");
    LGClockLog(@"Clock.Enabled: %d", LGClockEnabled());
    LGClockLog(@"Clock.FrostedMode: %d", LGClockFrostedModeEnabled());
    LGClockLog(@"Global.Enabled: %d", [[LGGlassPreferenceValue(@"Global.Enabled") isKindOfClass:[NSNumber class]] ? LGGlassPreferenceValue(@"Global.Enabled") : @(YES) boolValue]);
    LGClockLog(@"fontPath: %@", LGClockVariableFontPath() ?: @"(none)");
    LGClockLog(@"Filter type for Clock: %@", LGFilterTypeForHostPrefix(@"Clock") ?: @"(nil)");
    LGClockLog(@"======================================");

    %init(LGClockSpringBoard);
}
