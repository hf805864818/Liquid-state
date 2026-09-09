// =============================================================================
//  DynamicIsland.x — 灵动岛液态玻璃
//
//  事件源：
//  1. _SBGainMapView didMoveToWindow  → pill 出现信号（触发安装）
//  2. _SBGainMapView layoutSubviews   → 布局变化时更新玻璃
//  3. _SBGainMapView setHidden:       → 显隐同步
//  4. _SBSystemApertureMagiciansCurtainView setHidden: → 阻止 curtainView 重新显示
//
//  架构：
//  - 玻璃加在 SpringBoard 主桌面窗口上（这样 backdrop 能看到桌面壁纸）
//  - 灵动岛窗口（SBSystemApertureWindow）设为透明，让玻璃透上来
//  - 隐藏 curtainView（黑色背景）
//  - frame 跟随 gainMapView 用屏幕坐标更新
//  - touch passthrough：玻璃不拦截任何触控
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

// CydiaSubstrate (for MSHookMessageEx, same as Mango uses)
#ifdef __cplusplus
extern "C"
#endif
void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *origImp);

static void LGDILog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void LGDILog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    LGLog(@"[DI] %@", s);
}

#pragma mark - Process / OS checks

static inline BOOL LGIsSpringBoardProcess(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}
static inline BOOL LGIsAtLeastiOS16(void) {
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}

#pragma mark - Cross-process glyph mask (暂时未使用，保留供后续恢复)

__attribute__((unused))
static NSString *LGDIMaskPath(void) {
    return @"/var/mobile/Library/Accessibility/liquidglass-dynamicisland-mask.bin";
}
__attribute__((unused))
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

__attribute__((unused))
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

static uint64_t sLGDIMaskNextGeneration __attribute__((unused)) = 0;

#pragma mark - Mask rendering (暂时未使用，保留供后续恢复)

__attribute__((unused))
static UIImage *LGDIRenderAlphaMaskFromView(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return nil;
    CGSize size = view.bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return nil; }
    // 用 drawViewHierarchyInRect 替代 renderInContext
    // renderInContext 不会捕捉 layer.mask，而 drawViewHierarchyInRect 会
    [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

__attribute__((unused))
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

__attribute__((unused))
static void LGDIUpdateMask(UIView *sourceView, UIView *glassView, void *maskLayerKey) {
    if (!sourceView || !sourceView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    CGPoint origin = [sourceView convertPoint:CGPointZero toView:nil];
    UIImage *maskImage = LGDIRenderAlphaMaskFromView(sourceView);
    if (!maskImage) return;
    if (glassView) LGDIUpdateGlassMask(glassView, maskImage, maskLayerKey);
    uint64_t generation = ++sLGDIMaskNextGeneration;
    if (LGDIWriteMaskImage(maskImage, origin, generation)) {
        if (glassView) [glassView.layer setNeedsDisplay];
    }
}

static NSTimeInterval sLGDILastMaskUpdateTime __attribute__((unused)) = 0.0;
static BOOL sLGDIMaskUpdatePending __attribute__((unused)) = NO;
static const NSTimeInterval kLGDIMaskUpdateThrottle __attribute__((unused)) = 1.0 / 30.0;

__attribute__((unused))
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

#pragma mark - Association keys

static void *kLGDIPillGlassKey = &kLGDIPillGlassKey;
static void *kLGDIPillMaskLayerKey __attribute__((unused)) = &kLGDIPillMaskLayerKey;
static void *kLGDIInstanceNumberKey = &kLGDIInstanceNumberKey;

#pragma mark - Size validation

static BOOL LGDIIsPlausibleIslandSize(CGSize size) {
    if (size.width <= 0 || size.height <= 0) return NO;
    if (size.width > 500 || size.height > 300) return NO;
    if (size.width < 80 || size.height < 20) return NO;
    return YES;
}

// =============================================================================
//  View finding helpers
// =============================================================================

// 递归查找 _SBGainMapView
static UIView *LGDIFindGainMapViewInView(UIView *root) {
    if (!root) return nil;
    Class gainMapClass = objc_getClass("_SBGainMapView");
    if (!gainMapClass) return nil;
    if ([root isKindOfClass:gainMapClass]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = LGDIFindGainMapViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static UIView *LGDIFindExistingGainMapView(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIView *found = LGDIFindGainMapViewInView(window);
        if (found) return found;
    }
    return nil;
}

// =============================================================================
// =============================================================================
//  Glass installation — 安装在 window 上，用坐标转换跟随 gainMapView
//
//  为什么装在 window 上：
//    elementContainer 及以下层级都被 clipsToBounds 裁剪，
//    玻璃加在这些层里完全不可见（逐层探测实验确认）。
//
//  方案：
//    - 玻璃直接加到 window 上（确保 100% 可见）
//    - frame 通过 convertRect 从 gainMapView 转换到 window 坐标
//    - 形状用 cornerRadius 做胶囊形（height/2）
//    - layoutSubviews 时同步更新位置和大小
// =============================================================================

#pragma mark - Touch passthrough category
// 确保 LGLiveBackdropView 完全不拦截触控事件

@interface LGLiveBackdropView (LGDITouchPassthrough)
@end

@implementation LGLiveBackdropView (LGDITouchPassthrough)

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *result = [super hitTest:point withEvent:event];
    if (result == self) {
        return nil; // 完全透传，不拦截任何触控
    }
    return result;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO; // 永远不响应点击
}

@end

#pragma mark - Glass installation (on main SpringBoard window)

// 找到 SpringBoard 主窗口（桌面所在的窗口，不是灵动岛窗口）
static UIWindow *LGDIFindMainSpringBoardWindow(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        // 跳过灵动岛窗口
        if ([NSStringFromClass(window.class) containsString:@"Aperture"]) continue;
        // 跳过其他特殊窗口
        if ([NSStringFromClass(window.class) containsString:@"Banner"]) continue;
        if (window.windowLevel > UIWindowLevelNormal) continue;
        // 主窗口应该是 keyWindow 或者有 rootViewController
        if (window.rootViewController && !window.hidden) {
            return window;
        }
    }
    // fallback: 返回第一个普通窗口
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.windowLevel == UIWindowLevelNormal && !window.hidden) {
            return window;
        }
    }
    return nil;
}

// 调试：打印视图层级（简洁版）
__attribute__((unused))
static void LGDIDumpViewHierarchy(UIView *startView) {
    UIView *view = startView;
    NSInteger level = 0;
    while (view) {
        LGDILog(@"  L%ld %@  hidden=%d  frame=%@",
                (long)level,
                NSStringFromClass(view.class),
                view.hidden,
                NSStringFromCGRect(view.frame));
        view = view.superview;
        level++;
        if (level > 8) break;
    }
}

static void LGDIInstallPillGlass(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;
    if (!lgHostEnabled(@"DynamicIsland")) return;
    if (!LGDIIsPlausibleIslandSize(gainMapView.bounds.size)) return;

    // 已经装过了
    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (glassView) return;

    // gainMapView.superview = curtainView（黑色背景）
    UIView *curtainView = gainMapView.superview;
    if (!curtainView) return;

    // 灵动岛所在的窗口（SBSystemApertureWindow）
    UIWindow *islandWindow = gainMapView.window;

    // 找到主桌面窗口（玻璃装在这里才能看到桌面壁纸）
    UIWindow *mainWindow = LGDIFindMainSpringBoardWindow();
    if (!mainWindow) {
        LGDILog(@"ERROR: cannot find main SpringBoard window");
        return;
    }

    // 把 gainMapView 的 bounds 转换到屏幕（主窗口）坐标系
    // 注意：gainMapView 在灵动岛窗口上，toView:nil 返回的是屏幕坐标
    CGRect glassFrame = [gainMapView convertRect:gainMapView.bounds toView:nil];
    glassView = LGCreateRegisteredGlass(glassFrame, nil, @"DynamicIsland");
    if (!glassView) {
        LGDILog(@"ERROR: LGCreateRegisteredGlass returned nil");
        return;
    }

    glassView.userInteractionEnabled = NO;
    glassView.backgroundColor = UIColor.clearColor;
    glassView.layer.borderWidth = 0;

    // 直接使用 gainMapView 的 cornerRadius，确保形状完全一致
    CGFloat sourceCornerRadius = gainMapView.layer.cornerRadius;
    glassView.layer.cornerRadius = sourceCornerRadius > 0 ? sourceCornerRadius : glassFrame.size.height / 2.0;

    // 匹配系统连续圆角风格
    if (@available(iOS 13.0, *)) {
        glassView.layer.cornerCurve = kCACornerCurveContinuous;
    }

    glassView.layer.masksToBounds = YES;
    glassView.frame = glassFrame;

    // 关键1：玻璃加在主桌面窗口的最上层（在桌面图标上面，但在灵动岛窗口下面）
    // 因为灵动岛窗口 windowLevel 更高，所以玻璃自然在灵动岛内容下面
    [mainWindow addSubview:glassView];

    // 关键2：灵动岛窗口变透明，这样能看到下面的玻璃
    islandWindow.opaque = NO;
    islandWindow.backgroundColor = UIColor.clearColor;

    // 隐藏 curtainView（黑色背景）
    curtainView.hidden = YES;

    LGDILog(@"glass installed on mainWindow (%@), size=%@ CR=%.1f, "
            "islandWindow=%@ opaque=NO, curtainView hidden=YES",
            NSStringFromClass(mainWindow.class),
            NSStringFromCGSize(glassFrame.size),
            glassView.layer.cornerRadius,
            NSStringFromClass(islandWindow.class));

    // 关联到 gainMapView 上
    objc_setAssociatedObject(gainMapView, kLGDIPillGlassKey, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 延迟应用滤镜
    __weak LGLiveBackdropView *weakGlass = glassView;
    for (NSNumber *delay in @[ @0.5, @1.5, @3.0, @6.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakGlass applyFilters];
        });
    }
}

static void LGDIRemovePillGlass(UIView *gainMapView) {
    if (!gainMapView) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (glassView) {
        [glassView removeFromSuperview];
        objc_setAssociatedObject(gainMapView, kLGDIPillGlassKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 恢复 curtainView
        UIView *curtainView = gainMapView.superview;
        if (curtainView) {
            curtainView.hidden = NO;
        }

        LGDILog(@"glass removed, curtainView restored");
    }
}

static void LGDIRefreshPillGlass(UIView *gainMapView) {
    if (!gainMapView || !gainMapView.window) return;

    LGLiveBackdropView *glassView = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
    if (!glassView) return;

    // 玻璃在 window 上，用 window 坐标系
    CGRect targetFrame = [gainMapView convertRect:gainMapView.bounds toView:nil];
    CGFloat targetCR = gainMapView.layer.cornerRadius;
    BOOL frameChanged = !CGRectEqualToRect(glassView.frame, targetFrame);
    BOOL crChanged = ABS(glassView.layer.cornerRadius - targetCR) > 0.5;

    if (frameChanged || crChanged) {
        glassView.frame = targetFrame;
        if (targetCR > 0) {
            glassView.layer.cornerRadius = targetCR;
        } else {
            glassView.layer.cornerRadius = targetFrame.size.height / 2.0;
        }
        LGDILog(@"glass updated: size=%@ cornerRadius=%.1f (gainMapCR=%.1f) [window coords]",
                NSStringFromCGSize(targetFrame.size),
                glassView.layer.cornerRadius,
                targetCR);
    }
}

// =============================================================================
//  Hook: _SBGainMapView
//  Mango 二进制确认：hook 了 didMoveToWindow / layoutSubviews / setHidden:
//  作用：检测 pill 出现/消失时机，驱动玻璃安装/更新
//  玻璃不装在 gainMapView 上，装在它的 superview 上
// =============================================================================

@interface _SBGainMapView : UIView
@end

%group GainMapViewHook
%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;

    // 给每个实例分配一个编号（方便追踪）
    static NSInteger sInstanceCounter = 0;
    NSNumber *instNum = objc_getAssociatedObject(self, kLGDIInstanceNumberKey);
    if (!instNum) {
        instNum = @(++sInstanceCounter);
        objc_setAssociatedObject(self, kLGDIInstanceNumberKey, instNum,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (self.window) {
        LGDILog(@"[_SBGainMapView didMoveToWindow] ADDED #%@ bounds=%@",
                instNum,
                NSStringFromCGRect(self.bounds));
        LGDIInstallPillGlass(self);
    } else {
        LGDILog(@"[_SBGainMapView didMoveToWindow] REMOVED #%@", instNum);
        LGDIRemovePillGlass(self);
    }
}

- (void)layoutSubviews {
    %orig;

    if (!CGRectIsEmpty(self.bounds)) {
        LGDILog(@"[_SBGainMapView layoutSubviews] bounds=%@", NSStringFromCGRect(self.bounds));

        // 如果还没有 glass，且 size 合理，就创建
        LGLiveBackdropView *existingGlass = objc_getAssociatedObject(self, kLGDIPillGlassKey);
        if (!existingGlass && self.window && LGDIIsPlausibleIslandSize(self.bounds.size)) {
            LGDILog(@"[_SBGainMapView layoutSubviews] creating glass for new instance size=%@",
                    NSStringFromCGSize(self.bounds.size));
            LGDIInstallPillGlass(self);
        } else {
            LGDIRefreshPillGlass(self);
        }
    }
}

- (void)setFrame:(CGRect)frame {
    %orig;

    if (!CGRectIsEmpty(self.bounds)) {
        LGDILog(@"[_SBGainMapView setFrame:] newFrame=%@ bounds=%@",
                NSStringFromCGRect(frame),
                NSStringFromCGRect(self.bounds));

        LGLiveBackdropView *existingGlass = objc_getAssociatedObject(self, kLGDIPillGlassKey);
        if (!existingGlass && self.window && LGDIIsPlausibleIslandSize(self.bounds.size)) {
            LGDIInstallPillGlass(self);
        } else {
            LGDIRefreshPillGlass(self);
        }
    }
}

- (void)setBounds:(CGRect)bounds {
    %orig;

    if (!CGRectIsEmpty(bounds)) {
        LGDILog(@"[_SBGainMapView setBounds:] newBounds=%@", NSStringFromCGRect(bounds));
        LGDIRefreshPillGlass(self);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;

    // glass 直接关联在 gainMapView 上
    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGDIPillGlassKey);
    if (glass) glass.hidden = hidden;
}

%end
%end

// =============================================================================
//  Hook: _SBSystemApertureMagiciansCurtainView
//  Mango 二进制确认：hook 了 didMoveToWindow / setHidden:
//  作用：窗帘视图显隐变化时同步玻璃显隐（通过 gainMapView 间接驱动）
//  注意：glass 直接装在 gainMapView 上，不由 curtainView 管理
// =============================================================================

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end

%group CurtainViewHook
%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;
    LGDILog(@"[CurtainView didMoveToWindow] hasWindow=%d bounds=%@",
            self.window != nil,
            NSStringFromCGRect(self.bounds));

    // 如果 glass 存在，确保 curtainView 保持隐藏（玻璃取代黑色背景）
    if (self.window) {
        UIView *gainMapView = nil;
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:NSClassFromString(@"_SBGainMapView")]) {
                gainMapView = subview;
                break;
            }
        }
        if (gainMapView) {
            LGLiveBackdropView *glass = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
            if (glass && !self.hidden) {
                self.hidden = YES;
                LGDILog(@"[CurtainView didMoveToWindow] re-hiding curtainView (glass exists)");
            }
        }
    }
}

- (void)layoutSubviews {
    %orig;
    if (!CGRectIsEmpty(self.bounds)) {
        LGDILog(@"[CurtainView layoutSubviews] bounds=%@", NSStringFromCGRect(self.bounds));
    }
}

- (void)setFrame:(CGRect)frame {
    %orig;
    if (!CGRectIsEmpty(frame)) {
        LGDILog(@"[CurtainView setFrame:] frame=%@ bounds=%@",
                NSStringFromCGRect(frame),
                NSStringFromCGRect(self.bounds));
    }
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    if (!CGRectIsEmpty(bounds)) {
        LGDILog(@"[CurtainView setBounds:] bounds=%@", NSStringFromCGRect(bounds));
    }
}

- (void)setHidden:(BOOL)hidden {
    // 如果 glass 存在，强制保持 curtainView 隐藏
    UIView *gainMapView = nil;
    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_SBGainMapView")]) {
            gainMapView = subview;
            break;
        }
    }
    if (gainMapView) {
        LGLiveBackdropView *glass = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
        if (glass && hidden == NO) {
            LGDILog(@"[CurtainView setHidden:NO] blocked (glass exists, keeping hidden)");
            %orig; // 先调用原方法
            self.hidden = YES; // 再强制隐藏
            return;
        }
    }
    %orig;
    LGDILog(@"[CurtainView setHidden:] hidden=%d", hidden);
}

%end
%end

// =============================================================================
//  Hook: FBSceneLayerManager._setLayers:
//  保留作为场景状态跟踪（Mango 也有此 hook）
// =============================================================================

%group SceneLayerManager
%hook FBSceneLayerManager

- (void)_setLayers:(id)layers {
    %orig;
    // 场景图层变化时，layoutSubviews 会自动触发 mask 更新
}

%end
%end

// =============================================================================
//  偏好设置变更监听
// =============================================================================

static void LGDIPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        LGDILog(@"Prefs changed");
        // 找到已存在的 gainMapView 并重新应用滤镜
        UIView *gainMapView = LGDIFindExistingGainMapView();
        if (gainMapView) {
            LGLiveBackdropView *glass = objc_getAssociatedObject(gainMapView, kLGDIPillGlassKey);
            if (glass && [glass isKindOfClass:[LGLiveBackdropView class]]) {
                [glass applyFilters];
            }
        }
    }
}

// =============================================================================
//  Constructor — 安装所有 hooks
// =============================================================================

__attribute__((constructor))
static void LGDynamicIslandInit(void) {
    if (!LGIsSpringBoardProcess()) return;
    if (!LGIsAtLeastiOS16()) return;

    // 1. Darwin 通知监听
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LGDIPrefsChanged,
                                    CFSTR("dylv.liquidglass/PrefsReloaded"),
                                    NULL, 0);

    // 2. Hook: _SBGainMapView
    %init(GainMapViewHook);

    // 3. Hook: _SBSystemApertureMagiciansCurtainView
    %init(CurtainViewHook);

    // 4. Hook: FBSceneLayerManager._setLayers:
    %init(SceneLayerManager);

    // 5. 类检查
    Class gainMapClass = objc_getClass("_SBGainMapView");
    Class curtainClass = objc_getClass("_SBSystemApertureMagiciansCurtainView");
    Class sceneLayerMgrClass = objc_getClass("FBSceneLayerManager");
    LGDILog(@"Class check: gainMap=%@ curtain=%@ sceneLayerMgr=%@",
            gainMapClass ? @"YES" : @"NO",
            curtainClass ? @"YES" : @"NO",
            sceneLayerMgrClass ? @"YES" : @"NO");

    LGDILog(@"Dynamic Island initialized (gainMap trigger + curtain mask)");

    // 6. 主动查找已存在的 gainMapView 并安装玻璃
    //    SpringBoard 启动时灵动岛已经在窗口上，didMoveToWindow 早调用过了
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *existingGainMap = LGDIFindExistingGainMapView();
        if (existingGainMap) {
            LGDILog(@"constructor: found existing gainMapView %@",
                    NSStringFromCGRect(existingGainMap.frame));
            LGDIInstallPillGlass(existingGainMap);
        } else {
            LGDILog(@"constructor: no existing gainMapView found");
        }
    });
}
