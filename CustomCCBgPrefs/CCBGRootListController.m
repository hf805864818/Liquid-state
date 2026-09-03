#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import "CCBGProgressHUD.h"
#import "CCBGMediaManager.h"
#import "CCBGThumbnailButtonCell.h"

// MARK: - 文件日志（可在 Filza 中查看）
static NSString * const kCCBgLogFile = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media/debug.log";

static void ccbg_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ccbg_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    NSLog(@"[CCBg] %@", message);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [kCCBgLogFile stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    if (![fm fileExistsAtPath:kCCBgLogFile]) {
        [logLine writeToFile:kCCBgLogFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kCCBgLogFile];
        [handle seekToEndOfFile];
        [handle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}

// MARK: - 常量

static NSString * const kCCBgPrefsDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";

// 发送跨进程通知（NSNotification + Darwin 通知）
static void ccbgPostReloadNotification(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("dylv.Deepliquid.ccbg.reload"),
        NULL, NULL, TRUE);
}

// 偏好设置 key
static NSString * const kCCBgEnabledKey = @"Enabled";
static NSString * const kCCBgBlurAlphaKey = @"BlurAlpha";
static NSString * const kCCBgBackgroundModeKey = @"BackgroundMode"; // 0=全屏, 1=模块级
static NSString * const kCCBgFullscreenEnabledKey = @"FullscreenBgEnabled";
static NSString * const kCCBgConnectModuleEnabledKey = @"ConnectModuleBgEnabled";
static NSString * const kCCBgMediaModuleEnabledKey = @"MediaModuleBgEnabled";

// MARK: - Preferences framework additions
//
// IMPORTANT — iOS 17 crash fix:
//   +[PSSpecifier groupSpecifierWithProperties:]  -> does NOT exist on any iOS,
//   -[PSListController specifierForIndexPath:]    -> does NOT exist on any iOS.
// Calling them threw "unrecognized selector" the moment the page opened.
// Use the real, stable private APIs instead (present on iOS 9 - 18):
//   +[PSSpecifier groupSpecifierWithName:]
//   -[PSListController specifierAtIndexPath:]
// Declared here because the Theos headers do not always expose them.
@interface PSSpecifier (CCBgExtras)
+ (id)groupSpecifierWithName:(id)name;
- (void)setButtonAction:(SEL)action;
@end

@interface PSListController (CCBgExtras)
- (id)specifierAtIndexPath:(id)indexPath;
@end

// PHPickerFilter runtime class method declarations (iOS 14+)
@interface PHPickerFilter : NSObject
+ (instancetype)imagesFilter;
+ (instancetype)videosFilter;
+ (instancetype)anyFilterMatchingSubfilters:(NSArray<PHPickerFilter *> *)subfilters;
@end

@interface CCBGRootListController : PSListController <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
- (PSSpecifier *)groupSpecifierWithName:(NSString *)name footerText:(NSString *)footer;
- (PSSpecifier *)switchSpecifierWithKey:(NSString *)key title:(NSString *)title defaultValue:(id)defaultValue;
- (PSSpecifier *)sliderSpecifierWithKey:(NSString *)key title:(NSString *)title defaultValue:(id)defaultValue min:(id)min max:(id)max;
- (PSSpecifier *)buttonSpecifierWithTitle:(NSString *)title action:(SEL)action;
- (PSSpecifier *)thumbnailButtonSpecifierWithTitle:(NSString *)title action:(SEL)action;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@implementation CCBGRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // 分组1：全局开关
        [specs addObject:[self groupSpecifierWithName:@"全局开关" footerText:nil]];
        [specs addObject:[self switchSpecifierWithKey:kCCBgEnabledKey
                                                  title:@"开启自定义控制中心背景"
                                               defaultValue:@(NO)]];

        // 分组2：背景设置
        [specs addObject:[self groupSpecifierWithName:@"背景设置" footerText:nil]];
        [specs addObject:[self thumbnailButtonSpecifierWithTitle:@"选择控制中心背景 (图片/视频)"
                                                            action:@selector(chooseMedia:)]];
        [specs addObject:[self buttonSpecifierWithTitle:@"清除背景"
                                                   action:@selector(clearMedia:)]];

        // 分组3：背景模糊度调节
        [specs addObject:[self groupSpecifierWithName:@"背景模糊度调节"
                                            footerText:@"调整控制中心背景的毛玻璃强度"]];
        [specs addObject:[self sliderSpecifierWithKey:kCCBgBlurAlphaKey
                                                   title:nil
                                              defaultValue:@(0.3)
                                                     min:@(0.0)
                                                     max:@(1.0)]];

        // 分组4：背景模式（三选一，互斥）
        [specs addObject:[self groupSpecifierWithName:@"背景模式"
                                            footerText:@"三种模式互斥，开启一个会自动关闭其它"]];
        [specs addObject:[self switchSpecifierWithKey:kCCBgFullscreenEnabledKey
                                                  title:@"全屏背景"
                                               defaultValue:@(YES)]];
        [specs addObject:[self switchSpecifierWithKey:kCCBgConnectModuleEnabledKey
                                                  title:@"连接模块背景"
                                               defaultValue:@(NO)]];
        [specs addObject:[self switchSpecifierWithKey:kCCBgMediaModuleEnabledKey
                                                  title:@"播放控制模块背景"
                                               defaultValue:@(NO)]];

        // 分组5：高级选项
        [specs addObject:[self groupSpecifierWithName:@"高级选项" footerText:nil]];
        [specs addObject:[self buttonSpecifierWithTitle:@"跳转 Filza 路径"
                                                   action:@selector(openFilzaPath:)]];

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 页面出现时刷新缩略图 (PSListController exposes `table`, not `tableView`)
    [self.table reloadData];
}

#pragma mark - 偏好读写

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return nil;
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kCCBgPrefsDomain);
    return CFBridgingRelease(value);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kCCBgPrefsDomain);

    // 三选一互斥：开启某个背景模式时，自动关闭其它两个
    if ([value isKindOfClass:[NSNumber class]] && [value boolValue]) {
        if ([key isEqualToString:kCCBgFullscreenEnabledKey]) {
            // 全屏 ON → 关闭模块开关，开启 Enabled，模式=0
            ccbg_log(@"switch: fullscreen ON → enabled=YES, connect=NO, media=NO");
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgConnectModuleEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgMediaModuleEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgEnabledKey, kCFBooleanTrue, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey, (__bridge CFPropertyListRef)@(0), (__bridge CFStringRef)kCCBgPrefsDomain);
        } else if ([key isEqualToString:kCCBgConnectModuleEnabledKey]) {
            // 连接模块 ON → 关闭其它，关闭 Enabled（特定模块模式不需要 Enabled），模式=0
            ccbg_log(@"switch: connect ON → enabled=NO, fullscreen=NO, media=NO");
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgFullscreenEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgMediaModuleEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey, (__bridge CFPropertyListRef)@(0), (__bridge CFStringRef)kCCBgPrefsDomain);
        } else if ([key isEqualToString:kCCBgMediaModuleEnabledKey]) {
            // 播放模块 ON → 关闭其它，关闭 Enabled，模式=0
            ccbg_log(@"switch: media ON → enabled=NO, fullscreen=NO, connect=NO");
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgFullscreenEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgConnectModuleEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgEnabledKey, kCFBooleanFalse, (__bridge CFStringRef)kCCBgPrefsDomain);
            CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey, (__bridge CFPropertyListRef)@(0), (__bridge CFStringRef)kCCBgPrefsDomain);
        }
    }

    CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);
    ccbgPostReloadNotification();

    // 互斥开关变更后刷新 UI 以反映自动关闭的状态
    if ([key isEqualToString:kCCBgFullscreenEnabledKey] ||
        [key isEqualToString:kCCBgConnectModuleEnabledKey] ||
        [key isEqualToString:kCCBgMediaModuleEnabledKey]) {
        [self.table reloadData];
    }
}

#pragma mark - Actions

- (void)chooseMedia:(PSSpecifier *)specifier {
    // 使用 UIImagePickerController — 比 PHPicker 更可靠地处理视频
    // PHPicker 在 iOS 17 上不报告视频 UTI，导致视频被误判为图片
    [self presentUnifiedImagePicker];
}

- (void)chooseBackgroundMode:(PSSpecifier *)specifier {
    NSInteger currentMode = 0;
    CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey,
                                                      (__bridge CFStringRef)kCCBgPrefsDomain);
    if (val) {
        currentMode = [(__bridge NSNumber *)val integerValue];
        CFRelease(val);
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"背景模式"
                                                                   message:@"选择背景的显示方式"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"全屏背景%@", currentMode == 0 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey, (__bridge CFPropertyListRef)@(0),
                                (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);
        ccbgPostReloadNotification();
        [self reloadSpecifiers];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"模块级背景%@", currentMode == 1 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey, (__bridge CFPropertyListRef)@(1),
                                (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);
        ccbgPostReloadNotification();
        [self reloadSpecifiers];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearMedia:(PSSpecifier *)specifier {
    ccbg_log(@"clearMedia requested");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除背景"
                                                                   message:@"确定要清除当前设置的控制中心背景吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[CCBGMediaManager sharedManager] clearAllMedia];
        ccbgPostReloadNotification();
        [self.table reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFilzaPath:(PSSpecifier *)specifier {
    NSString *path = [@"filza://" stringByAppendingString:[CCBGMediaManager sharedManager].mediaDirectory];
    NSURL *url = [NSURL URLWithString:path];
    ccbg_log(@"openFilzaPath: url=%@", path);
    // iOS 9+ canOpenURL: requires LSApplicationQueriesSchemes — skip it and just try opening.
    // The completion handler tells us if it actually worked.
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            ccbg_log(@"openFilzaPath: failed to open (Filza not installed?)");
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开 Filza"
                                                                               message:@"请确认已安装 Filza 文件管理器"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        }
    }];
}

#pragma mark - 统一图片/视频选择器 (UIImagePickerController)

- (void)presentUnifiedImagePicker {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"无法访问相册"
                                     message:@"请在「设置 → 隐私 → 照片」中允许此设备访问相册"
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                ccbg_log(@"photo permission denied");
                return;
            }
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.mediaTypes = @[@"public.image", @"public.movie"];
            picker.delegate = self;
            picker.allowsEditing = NO;
            [self presentViewController:picker animated:YES completion:nil];
            ccbg_log(@"UIImagePickerController presented (image+video)");
        });
    }];
}

#pragma mark - PHPicker (iOS 14+) — 备用，不再首选

- (void)presentPHPicker API_AVAILABLE(ios(14)) {
    // PHPicker 不需要权限申请，用户自己选择
    Class PHPickerConfigurationClass = NSClassFromString(@"PHPickerConfiguration");
    Class PHPickerViewControllerClass = NSClassFromString(@"PHPickerViewController");
    Class PHPickerFilterClass = NSClassFromString(@"PHPickerFilter");

    if (!PHPickerConfigurationClass || !PHPickerViewControllerClass) {
        // 降级
        [self presentLegacyPickerWithActionSheet];
        return;
    }

    id config = [[PHPickerConfigurationClass alloc] init];

    // filter = [PHPickerFilter anyFilterMatchingSubfilters:@[images, videos]]
    id imagesFilter = [PHPickerFilterClass imagesFilter];
    id videosFilter = [PHPickerFilterClass videosFilter];
    id anyFilter = [PHPickerFilterClass anyFilterMatchingSubfilters:@[imagesFilter, videosFilter]];
    [config setValue:anyFilter forKey:@"filter"];

    [config setValue:@(1) forKey:@"selectionLimit"]; // 单选

    UIViewController *picker = [[PHPickerViewControllerClass alloc] initWithConfiguration:config];
    [picker setValue:self forKey:@"delegate"];
    [self presentViewController:picker animated:YES completion:nil];
}

// PHPickerViewControllerDelegate 方法（用运行时实现，避免编译依赖）
- (void)picker:(UIViewController *)picker didFinishPicking:(NSArray *)results API_AVAILABLE(ios(14)) {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) return;

    id result = results.firstObject;

    // 显示处理中 HUD
    [CCBGProgressHUD showInView:self.view text:@"处理中..."];

    // 用 NSItemProvider 加载媒体（itemIdentifier 是可选的，保存不需要它）
    NSItemProvider *provider = [result valueForKey:@"itemProvider"];
    if (!provider) {
        [CCBGProgressHUD dismissFromView:self.view];
        [self showSaveResultAlertWithSuccess:NO message:@"未能获取所选媒体，请重试"];
        return;
    }

    // 先判断类型 — 检查多个视频 UTI（iOS 17 可能不报告 public.movie）
    NSArray *videoUTIs = @[
        @"public.movie",
        @"public.mpeg-4",
        @"public.video",
        @"public.audiovisual-content",
        @"public.quicktime-movie",
        @"com.apple.m4v-video",
        @"com.apple.quicktime-movie"
    ];
    NSString *videoType = nil;
    for (NSString *uti in videoUTIs) {
        if ([provider hasItemConformingToTypeIdentifier:uti]) {
            videoType = uti;
            break;
        }
    }
    NSLog(@"[CCBg] provider registeredTypeIdentifiers: %@", provider.registeredTypeIdentifiers);
    NSLog(@"[CCBg] detected videoType: %@", videoType);
    ccbg_log(@"PHPicker provider UTIs: %@", provider.registeredTypeIdentifiers);
    ccbg_log(@"PHPicker detected videoType: %@", videoType);

    if (videoType) {
        // 视频
        [provider loadFileRepresentationForTypeIdentifier:videoType
                                        completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
            if (url && !error) {
                // 先复制到临时目录（loadFileRepresentation 的 URL 是临时的，结束后会删除）
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ccbg_temp_video.mp4"];
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:tempPath error:nil];
                NSError *copyError = nil;
                [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tempPath] error:&copyError];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[CCBGMediaManager sharedManager] saveVideoFromURL:[NSURL fileURLWithPath:tempPath]
                                                            completion:^(BOOL success) {
                        [self didFinishSavingMedia:success];
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [CCBGProgressHUD dismissFromView:self.view];
                    [self showSaveResultAlertWithSuccess:NO message:@"视频加载失败，请重试"];
                });
            }
        }];
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.image"]) {
        // 图片
        [provider loadObjectOfClass:[UIImage class]
                  completionHandler:^(id<NSItemProviderReading>  _Nullable object, NSError * _Nullable error) {
            if (object && [object isKindOfClass:[UIImage class]]) {
                UIImage *image = (UIImage *)object;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[CCBGMediaManager sharedManager] saveImage:image
                                                    completion:^(BOOL success) {
                        [self didFinishSavingMedia:success];
                    }];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [CCBGProgressHUD dismissFromView:self.view];
                    [self showSaveResultAlertWithSuccess:NO message:@"图片加载失败，请重试"];
                });
            }
        }];
    } else {
        [CCBGProgressHUD dismissFromView:self.view];
        [self showSaveResultAlertWithSuccess:NO message:@"不支持的媒体类型"];
    }
}

#pragma mark - 旧版选择器（iOS 13 及以下）

- (void)presentLegacyPickerWithActionSheet {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择背景"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"从相册选择图片"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self presentLegacyImagePickerWithMediaType:@"public.image"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"从相册选择视频"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self presentLegacyImagePickerWithMediaType:@"public.movie"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentLegacyImagePickerWithMediaType:(NSString *)mediaType {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法访问相册"
                                                                               message:@"请在设置中允许访问相册"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }

            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.mediaTypes = @[mediaType];
            picker.delegate = self;
            picker.allowsEditing = NO;
            [self presentViewController:picker animated:YES completion:nil];
        });
    }];
}

#pragma mark - UIImagePickerControllerDelegate (旧版)

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSString *mediaType = info[UIImagePickerControllerMediaType];
    ccbg_log(@"picker returned mediaType=%@", mediaType);

    // 显示处理中 HUD
    [CCBGProgressHUD showInView:self.view text:@"处理中..."];

    if ([mediaType isEqualToString:@"public.image"]) {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        ccbg_log(@"image picked, size=%.0fx%.0f", image.size.width, image.size.height);
        [[CCBGMediaManager sharedManager] saveImage:image completion:^(BOOL success) {
            ccbg_log(@"image save result: %d", success);
            [self didFinishSavingMedia:success];
        }];
    } else if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        ccbg_log(@"video picked, url=%@", videoURL);
        [[CCBGMediaManager sharedManager] saveVideoFromURL:videoURL completion:^(BOOL success) {
            ccbg_log(@"video save result: %d", success);
            [self didFinishSavingMedia:success];
        }];
    } else {
        ccbg_log(@"unknown media type: %@", mediaType);
        [CCBGProgressHUD dismissFromView:self.view];
        [self showSaveResultAlertWithSuccess:NO message:@"不支持的媒体类型"];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 保存完成回调

- (void)didFinishSavingMedia:(BOOL)success {
    [CCBGProgressHUD dismissFromView:self.view];
    ccbg_log(@"didFinishSavingMedia: success=%d", success);

    if (success) {
        // 自动开启全屏背景模式（默认模式），关闭其它模式
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgFullscreenEnabledKey,
                                 kCFBooleanTrue,
                                 (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgEnabledKey,
                                 kCFBooleanTrue,
                                 (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey,
                                 (__bridge CFPropertyListRef)@(0),
                                 (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgConnectModuleEnabledKey,
                                 kCFBooleanFalse,
                                 (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgMediaModuleEnabledKey,
                                 kCFBooleanFalse,
                                 (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);

        ccbgPostReloadNotification();
        [self.table reloadData];
    }

    [self showSaveResultAlertWithSuccess:success
                                   message:success ? @"背景已保存，已自动开启自定义背景开关"
                                                   : @"保存背景失败，请重试"];
}

- (void)showSaveResultAlertWithSuccess:(BOOL)success message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:success ? @"设置成功" : @"设置失败"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDelegate（自定义缩略图 cell）

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // specifierAtIndexPath: is the real API; specifierForIndexPath: does not exist.
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *actionName = [specifier propertyForKey:@"action"];

    // 如果是缩略图按钮 cell
    if ([actionName isEqualToString:NSStringFromSelector(@selector(chooseMedia:))]) {
        static NSString *thumbCellId = @"CCBgThumbnailButtonCell";
        CCBGThumbnailButtonCell *cell = [tableView dequeueReusableCellWithIdentifier:thumbCellId];
        if (!cell) {
            cell = [[CCBGThumbnailButtonCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:thumbCellId];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.text = specifier.name;
        [cell setThumbnailImage:[[CCBGMediaManager sharedManager] currentThumbnail]];
        return cell;
    }

    // 其他 cell 走默认
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *actionName = [specifier propertyForKey:@"action"];

    // On iOS 17, PSListController's standard performButtonActionForSpecifier:
    // uses the buttonAction SEL ivar, not the "action" string property we set.
    // So we intercept ALL button taps here and call the action directly.
    if (actionName.length) {
        SEL action = NSSelectorFromString(actionName);
        if ([self respondsToSelector:action]) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:action withObject:specifier];
            #pragma clang diagnostic pop
            return;
        }
    }

    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

#pragma mark - Helper

- (PSSpecifier *)groupSpecifierWithName:(NSString *)name footerText:(NSString *)footer {
    // groupSpecifierWithName: is the real API present on every iOS version.
    // (The old groupSpecifierWithProperties: never existed and crashed on load.)
    PSSpecifier *spec = [PSSpecifier groupSpecifierWithName:name];
    if (footer.length) {
        // PSListController renders the section footer from the group specifier's
        // "footerText" property — the same key plist-based preference bundles use.
        [spec setProperty:footer forKey:@"footerText"];
    }
    return spec;
}

- (PSSpecifier *)switchSpecifierWithKey:(NSString *)key title:(NSString *)title defaultValue:(id)defaultValue {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:nil
                                                        cell:PSSwitchCell
                                                        edit:nil];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:defaultValue forKey:@"default"];
    return spec;
}

- (PSSpecifier *)sliderSpecifierWithKey:(NSString *)key title:(NSString *)title defaultValue:(id)defaultValue min:(id)min max:(id)max {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:nil
                                                        cell:PSSliderCell
                                                        edit:nil];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:defaultValue forKey:@"default"];
    [spec setProperty:min forKey:@"min"];
    [spec setProperty:max forKey:@"max"];
    return spec;
}

- (PSSpecifier *)buttonSpecifierWithTitle:(NSString *)title action:(SEL)action {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:self
                                                         set:nil
                                                         get:nil
                                                      detail:nil
                                                        cell:PSButtonCell
                                                        edit:nil];
    [spec setProperty:NSStringFromSelector(action) forKey:@"action"];
    [spec setButtonAction:action]; // iOS 17: also set the SEL ivar for standard button handling
    return spec;
}

- (PSSpecifier *)thumbnailButtonSpecifierWithTitle:(NSString *)title action:(SEL)action {
    // 用 PSButtonCell 类型，但在 cellForRow 里替换为自定义 cell
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:self
                                                         set:nil
                                                         get:nil
                                                      detail:nil
                                                        cell:PSButtonCell
                                                        edit:nil];
    [spec setProperty:NSStringFromSelector(action) forKey:@"action"];
    [spec setButtonAction:action]; // iOS 17: also set the SEL ivar for standard button handling
    // 标记这是缩略图按钮
    [spec setProperty:@(YES) forKey:@"hasThumbnail"];
    return spec;
}

@end
