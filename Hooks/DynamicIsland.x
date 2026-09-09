#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

static void LGDILog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDILog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI] %@", s);
}

#pragma mark - Cross-process glyph mask

static NSString *LGDIMaskPath(void) {
    return @"/var/mobile/Library/Accessibility/liquidglass-dynamicisland-mask.bin";
}
static CFStringRef const LGDIMaskReloadNotification =
    CFSTR("dylv.liquidglass/DynamicIslandMaskReload");

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    float    imageScale;
    float    bezelWidthPoints;
    float    originX;
    float    originY;
    uint64_t generation;
} LGDynamicIslandMaskHeader;

#define LG_DI_MASK_MAGIC 0x4c474449 // "LGDI"

static BOOL LGDIWriteMaskImage(UIImage *image, CGPoint screenOrigin, uint64_t generation) {
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

        LGDynamicIslandMaskHeader header = {
            LG_DI_MASK_MAGIC,
            (uint32_t)width,
            (uint32_t)height,
            (float)MAX(image.scale, 1.0),
            18.0f,
            (float)screenOrigin.x,
            (float)screenOrigin.y,
            generation,
        };
        NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
        [data appendBytes:alpha length:width * height];
        if ([data writeToFile:LGDIMaskPath() options:NSDataWritingAtomic error:nil]) {
            wrote = YES;
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 LGDIMaskReloadNotification,
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

#pragma mark - Association keys

static void *kLGDIPillGlassKey = &kLGDIPillGlassKey;
static void *kLGDIExpandedGlassKey = &kLGDIExpandedGlassKey;
static void *kLGDIPillMaskLayerKey = &kLGDIPillMaskLayerKey;
static void *kLGDIExpandedMaskLayerKey = &kLGDIExpandedMaskLayerKey;
static void *kLGDIDisplayLinkKey = &kLGDIDisplayLinkKey;
static void *kLGDIOrigBgColorKey = &kLGDIOrigBgColorKey;

static uint64_t sLGDIMaskNextGeneration = 0;

#pragma mark - Utility: view hierarchy dump

static NSString *LGDIDumpViewHierarchy(UIView *view, NSInteger indent) {
    NSMutableString *result = [NSMutableString string];
    NSString *indentStr = [@"" stringByPaddingToLength:indent * 2 withString:@"  " startingAtIndex:0];
    NSString *clsName = NSStringFromClass(view.class);
    CGRect frame = view.frame;
    UIColor *bgColor = view.backgroundColor;
    NSString *bgDesc = bgColor ? [bgColor description] : @"(nil)";
    if (bgDesc.length > 50) bgDesc = [bgDesc substringToIndex:50];

    [result appendFormat:@"%@<%@: hidden=%d alpha=%.2f frame=%.1f,%.1f %.1fx%.1f bg=%@>\n",
                         indentStr, clsName, view.hidden, view.alpha,
                         frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                         bgDesc];

    for (UIView *subview in view.subviews) {
        [result appendString:LGDIDumpViewHierarchy(subview, indent + 1)];
    }
    return result;
}

#pragma mark - Mask rendering

static UIImage *LGDIRenderAlphaMaskFromView(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return nil;

    CGSize size = view.bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;

    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    [view.layer renderInContext:ctx];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

static void LGDIUpdateGlassMask(UIView *glassView, UIImage *maskImage, void *maskLayerKey) {
    if (!glassView || !maskImage) return;

    CALayer *maskLayer = objc_getAssociatedObject(glassView, maskLayerKey);
    if (!maskLayer) {
        maskLayer = [CALayer layer];
        maskLayer.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(glassView, maskLayerKey, maskLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.layer.mask = maskLayer;
    }

    maskLayer.frame = glassView.bounds;
    maskLayer.contents = (__bridge id _Nullable)(maskImage.CGImage);
}

#pragma mark - Mask generation and cross-process delivery

static void LGDIUpdateMask(UIView *sourceView, UIView *glassView, void *maskLayerKey) {
    if (!sourceView || !sourceView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;

    CGPoint origin = [sourceView convertPoint:CGPointZero toView:nil];

    UIImage *maskImage = LGDIRenderAlphaMaskFromView(sourceView);
    if (!maskImage) return;

    if (glassView) {
        LGDIUpdateGlassMask(glassView, maskImage, maskLayerKey);
    }

    uint64_t generation = ++sLGDIMaskNextGeneration;
    if (LGDIWriteMaskImage(maskImage, origin, generation)) {
        if (glassView) {
            [glassView.layer setNeedsDisplay];
        }
    }
}

#pragma mark - Throttled mask update (30fps)

static NSTimeInterval sLGDILastMaskUpdateTime = 0.0;
static BOOL sLGDIMaskUpdatePending = NO;
static const NSTimeInterval kLGDIMaskUpdateThrottle = 1.0 / 30.0;

static void LGDIScheduleMaskUpdate(UIView *sourceView, UIView *glassView, void *maskLayerKey) {
    if (!sourceView) return;

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval timeSinceLast = now - sLGDILastMaskUpdateTime;

    if (timeSinceLast >= kLGDIMaskUpdateThrottle) {
        sLGDILastMaskUpdateTime = now;
        LGDIUpdateMask(sourceView, glassView, maskLayerKey);
    } else if (!sLGDIMaskUpdatePending) {
        sLGDIMaskUpdatePending = YES;
        NSTimeInterval delay = kLGDIMaskUpdateThrottle - timeSinceLast;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sLGDIMaskUpdatePending = NO;
            if (sourceView) {
                sLGDILastMaskUpdateTime = CACurrentMediaTime();
                LGDIUpdateMask(sourceView, glassView, maskLayerKey);
            }
        });
    }
}

#pragma mark - Create glass view

static LGLiveBackdropView *LGDIEnsureGlassView(UIView *containerView, void *glassKey,
                                                UIView *anchorView, NSString *logTag) {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, glassKey);
    if (glassView) return glassView;

    // 打印视图层级（首次安装时）
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LGDILog(@"=== Dynamic Island view hierarchy ===\n%@",
                LGDIDumpViewHierarchy(containerView, 0));
    });

    glassView = LGCreateRegisteredGlass(containerView.bounds, nil, @"DynamicIsland");
    if (!glassView) {
        LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil for %@", logTag);
        return nil;
    }

    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = UIColor.clearColor;
    glassView.layer.cornerRadius = 0.0;
    glassView.layer.masksToBounds = YES;

    // 插入到 anchorView 下方
    if (anchorView.superview) {
        [anchorView.superview insertSubview:glassView belowSubview:anchorView];
    } else {
        [containerView insertSubview:glassView atIndex:0];
    }

    objc_setAssociatedObject(containerView, glassKey, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 延迟重试 applyFilters
    __weak LGLiveBackdropView *weakGlass = glassView;
    for (NSNumber *delay in @[ @1.0, @2.5, @5.0, @8.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakGlass applyFilters];
        });
    }

    LGDILog(@"Created glass %@ anchor=%@ size=%.1fx%.1f",
            logTag, NSStringFromClass(anchorView.class),
            containerView.bounds.size.width, containerView.bounds.size.height);

    return glassView;
}

#pragma mark - Expanded state CADisplayLink (展开态实时刷新)

// Mango 用 CADisplayLink 驱动展开态的实时刷新，我们也这样做

@interface LGDIDisplayLinkProxy : NSObject
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UIView *glassView;
@property (nonatomic, assign) void *maskLayerKey;
- (void)tick:(CADisplayLink *)link;
@end

@implementation LGDIDisplayLinkProxy
- (void)tick:(CADisplayLink *)link {
    UIView *src = self.sourceView;
    UIView *glass = self.glassView;
    if (!src || !glass || !src.window) {
        [link invalidate];
        return;
    }
    LGDIScheduleMaskUpdate(src, glass, self.maskLayerKey);
}
@end

static void LGDIStartExpandedDisplayLink(UIView *sourceView, UIView *glassView, void *maskLayerKey) {
    if (!sourceView || !glassView) return;

    CADisplayLink *existingLink = objc_getAssociatedObject(glassView, kLGDIDisplayLinkKey);
    if (existingLink) return; // 已经在运行

    LGDIDisplayLinkProxy *proxy = [[LGDIDisplayLinkProxy alloc] init];
    proxy.sourceView = sourceView;
    proxy.glassView = glassView;
    proxy.maskLayerKey = maskLayerKey;

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:proxy
                                                       selector:@selector(tick:)];
    link.preferredFramesPerSecond = 30; // 30fps
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    // 用 proxy 保持引用（通过 glassView 关联）
    objc_setAssociatedObject(glassView, kLGDIDisplayLinkKey, proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glassView, (__bridge void *)(@"displayLink"), link,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LGDILog(@"Started expanded display link for %@",
            NSStringFromClass(sourceView.class));
}

static void LGDIStopExpandedDisplayLink(UIView *glassView) {
    CADisplayLink *link = objc_getAssociatedObject(glassView,
                                                    (__bridge void *)(@"displayLink"));
    if (link) {
        [link invalidate];
        objc_setAssociatedObject(glassView, (__bridge void *)(@"displayLink"), nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGDILog(@"Stopped expanded display link");
    }
    objc_setAssociatedObject(glassView, kLGDIDisplayLinkKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Install glass (收缩态)

// 灵动岛收缩态尺寸限制（点）
// 真实灵动岛收缩态约 126x37，展开态最大约 390x174
// 超过 420x200 的一定不是灵动岛，跳过
static BOOL LGDIIsPlausibleIslandSize(CGSize size) {
    if (size.width <= 0 || size.height <= 0) return NO;
    if (size.width > 420 || size.height > 200) return NO;
    if (size.width < 80 || size.height < 20) return NO;
    return YES;
}

static void LGDIInstallPillGlass(UIView *containerView, UIView *pillView) {
    if (!containerView || !containerView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    // 安全检查：必须有明确的 pillView，且尺寸合理
    // 绝不用容器视图作为 fallback（防止在全屏视图上插入玻璃）
    if (!pillView) return;
    if (!LGDIIsPlausibleIslandSize(pillView.bounds.size)) return;

    UIView *anchor = pillView;
    LGLiveBackdropView *glassView = LGDIEnsureGlassView(containerView, kLGDIPillGlassKey,
                                                         anchor, @"pill");

    if (!glassView) return;

    // 更新位置
    CGRect targetFrame = anchor.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIPillMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    // 确保 glassView 在 anchor 下方
    if (glassView.superview != anchor.superview && anchor.superview) {
        [anchor.superview insertSubview:glassView belowSubview:anchor];
    }

    // 更新 mask
    LGDIScheduleMaskUpdate(anchor, glassView, kLGDIPillMaskLayerKey);
}

#pragma mark - Install glass (展开态)

static void LGDIInstallExpandedGlass(UIView *containerView, UIView *expandedView) {
    if (!containerView || !containerView.window || !expandedView) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGIsAtLeastiOS16()) return;

    // 安全检查：尺寸必须在灵动岛范围内
    if (!LGDIIsPlausibleIslandSize(expandedView.bounds.size)) return;

    LGLiveBackdropView *glassView = LGDIEnsureGlassView(containerView, kLGDIExpandedGlassKey,
                                                         expandedView, @"expanded");

    if (!glassView) return;

    // 更新位置
    CGRect targetFrame = expandedView.frame;
    if (!CGRectEqualToRect(glassView.frame, targetFrame)) {
        glassView.frame = targetFrame;
        CALayer *maskLayer = objc_getAssociatedObject(glassView, kLGDIExpandedMaskLayerKey);
        if (maskLayer) maskLayer.frame = glassView.bounds;
    }

    // 确保 glassView 在 expandedView 下方
    if (glassView.superview != expandedView.superview && expandedView.superview) {
        [expandedView.superview insertSubview:glassView belowSubview:expandedView];
    }

    // 启动 CADisplayLink 实时刷新
    LGDIStartExpandedDisplayLink(expandedView, glassView, kLGDIExpandedMaskLayerKey);

    // 立即更新一次 mask
    LGDIScheduleMaskUpdate(expandedView, glassView, kLGDIExpandedMaskLayerKey);
}

#pragma mark - Remove glass

static void LGDIRemovePillGlass(UIView *containerView) {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDIPillGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(containerView, kLGDIPillGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(containerView, kLGDIPillMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGDIRemoveExpandedGlass(UIView *containerView) {
    LGLiveBackdropView *glassView = objc_getAssociatedObject(containerView, kLGDIExpandedGlassKey);
    if (glassView) {
        LGDIStopExpandedDisplayLink(glassView);
        [glassView removeFromSuperview];
        objc_setAssociatedObject(containerView, kLGDIExpandedGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(containerView, kLGDIExpandedMaskLayerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Find views in aperture hierarchy

// 在视图层级中查找包含指定类名关键字的子视图
static UIView *LGDFindViewWithClassContaining(UIView *root, NSString *keyword) {
    if (!root) return nil;
    for (UIView *subview in root.subviews) {
        NSString *clsName = NSStringFromClass(subview.class);
        if ([clsName containsString:keyword]) return subview;

        UIView *found = LGDFindViewWithClassContaining(subview, keyword);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Active content detection

// 检测灵动岛是否有活跃内容
//
// 核心逻辑：
// - 灵动岛硬件黑条始终可见（这是传感器区域，物理存在的）
// - 但"灵动岛内容"（音乐封面、计时器、通话状态等）只有在
//   用户开始播放音乐/设置计时器/接打电话等操作后才出现
// - 在静态状态下，Pill 视图内部几乎没有内容子视图
// - 在活跃状态下，Pill 视图内有可见的内容子视图（封面、波形、文字等）
//
// 因此：只有在检测到活跃内容时，才安装液态玻璃效果
static BOOL LGDIPillViewHasActiveContent(UIView *pillView) {
    if (!pillView) return NO;

    // 递归扫描 Pill 视图，统计可见的内容子视图
    __block NSUInteger contentCount = 0;
    void (^scan)(UIView *) = ^(UIView *v) {
        for (UIView *sub in v.subviews) {
            if (sub.hidden || sub.alpha < 0.1) continue;

            NSString *cls = NSStringFromClass(sub.class);

            // 跳过纯背景/阴影/容器视图（这些在静态状态下也存在）
            if ([cls containsString:@"Background"] ||
                [cls containsString:@"Backdrop"] ||
                [cls containsString:@"Shadow"] ||
                [cls containsString:@"Container"]) {
                scan(sub);
                continue;
            }

            // 有实际尺寸的可见视图算作内容
            if (sub.bounds.size.width > 5 && sub.bounds.size.height > 5) {
                contentCount++;
            }
            scan(sub);
        }
    };
    scan(pillView);

    return contentCount > 0;
}

// 查找可能包含展开内容的视图（当灵动岛展开时出现的视图）
static UIView *LGDFindExpandedContentView(UIView *containerView) {
    if (!containerView) return nil;

    // 灵动岛展开时，内容视图通常比收缩态大很多
    // 或者类名包含 "Expanded", "Content", "Stack" 等
    UIView *expanded = LGDFindViewWithClassContaining(containerView, @"Expanded");
    if (expanded) return expanded;

    // 查找比容器大很多的子视图（展开态）
    CGFloat containerArea = containerView.bounds.size.width * containerView.bounds.size.height;
    for (UIView *subview in containerView.subviews) {
        CGFloat subArea = subview.bounds.size.width * subview.bounds.size.height;
        if (subArea > containerArea * 1.5 && !subview.hidden && subview.alpha > 0.5) {
            return subview;
        }
    }

    return nil;
}

#pragma mark - Hook SBSystemApertureViewController

// iOS 17+ 上，灵动岛由 SBSystemApertureViewController 管理
// 这是 Mango 使用的类名，在 iOS 17 上存在
@interface SBSystemApertureViewController : UIViewController
@end

%hook SBSystemApertureViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGDILog(@"SBSystemApertureViewController viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 不在这里安装玻璃！
    //
    // SBSystemApertureViewController 在系统启动时就出现（respring 后立即触发），
    // 但此时灵动岛并没有活跃内容（用户还没有播放音乐/开启计时器等）。
    // 如果在这里安装玻璃，会导致静态状态下也出现玻璃效果，
    // 可能干扰触摸事件，导致屏幕无响应。
    //
    // 正确的做法是在 viewDidLayoutSubviews 中检测到活跃内容后才安装。
    LGDILog(@"SBSystemApertureViewController viewDidAppear (waiting for active content)");
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    LGDILog(@"SBSystemApertureViewController viewWillDisappear");
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGDILog(@"SBSystemApertureViewController viewDidDisappear");
    LGDIRemovePillGlass(self.view);
    LGDIRemoveExpandedGlass(self.view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = self.view;
    if (!view || !view.window) return;

    // ===== 收缩态（Pill）玻璃 =====
    UIView *pillView = LGDFindViewWithClassContaining(view, @"Pill");

    if (pillView && LGDIIsPlausibleIslandSize(pillView.bounds.size)) {
        // 关键：只在灵动岛有活跃内容时才安装玻璃
        // 静态状态下（没开音乐等），Pill 视图没有内容子视图，不安装玻璃
        if (LGDIPillViewHasActiveContent(pillView)) {
            LGDIInstallPillGlass(view, pillView);
        } else {
            // 没有活跃内容，移除已安装的玻璃
            LGDIRemovePillGlass(view);
        }
    } else {
        // 没有找到 Pill 视图，移除已安装的玻璃
        LGDIRemovePillGlass(view);
    }

    // ===== 展开态玻璃 =====
    UIView *expandedView = LGDFindExpandedContentView(view);
    if (expandedView && LGDIIsPlausibleIslandSize(expandedView.bounds.size)) {
        LGDIInstallExpandedGlass(view, expandedView);
    } else {
        LGDIRemoveExpandedGlass(view);
    }
}

%end

#pragma mark - 偏好设置变更监听

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
    }
}

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (!LGIsAtLeastiOS16()) return;

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LGDIPrefsChanged,
                                    CFSTR("dylv.liquidglass/PrefsReloaded"),
                                    NULL, 0);

    LGDILog(@"Dynamic Island tweak initialized (SBSystemApertureViewController mode)");
}
