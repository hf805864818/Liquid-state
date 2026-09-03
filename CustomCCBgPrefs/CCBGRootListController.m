#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import "CCBGProgressHUD.h"
#import "CCBGMediaManager.h"
#import "CCBGThumbnailButtonCell.h"

// MARK: - 常量

static NSString * const kCCBgPrefsDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";

// 偏好设置 key
static NSString * const kCCBgEnabledKey = @"Enabled";
static NSString * const kCCBgBlurAlphaKey = @"BlurAlpha";
static NSString * const kCCBgBackgroundModeKey = @"BackgroundMode"; // 0=全屏, 1=模块级
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

        // 分组4：特定模块背景
        [specs addObject:[self groupSpecifierWithName:@"特定模块背景"
                                            footerText:@"关闭全屏背景时生效，仅在指定模块内显示背景"]];
        [specs addObject:[self switchSpecifierWithKey:kCCBgConnectModuleEnabledKey
                                                  title:@"连接模块背景"
                                               defaultValue:@(NO)]];
        [specs addObject:[self switchSpecifierWithKey:kCCBgMediaModuleEnabledKey
                                                  title:@"播放控制模块背景"
                                               defaultValue:@(NO)]];

        // 分组5：高级选项
        [specs addObject:[self groupSpecifierWithName:@"高级选项" footerText:nil]];
        [specs addObject:[self buttonSpecifierWithTitle:@"背景模式选择"
                                                   action:@selector(chooseBackgroundMode:)]];
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
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);
    [[NSNotificationCenter defaultCenter] postNotificationName:(id)kCCBgReloadNotification object:nil];
}

#pragma mark - Actions

- (void)chooseMedia:(PSSpecifier *)specifier {
    // 直接打开 PHPicker（图片和视频都可以选）
    if (@available(iOS 14, *)) {
        [self presentPHPicker];
    } else {
        // iOS 13 及以下降级：先弹窗选类型
        [self presentLegacyPickerWithActionSheet];
    }
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
        [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
        [self reloadSpecifiers];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"模块级背景%@", currentMode == 1 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgBackgroundModeKey, (__bridge CFPropertyListRef)@(1),
                                (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);
        [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除背景"
                                                                   message:@"确定要清除当前设置的控制中心背景吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[CCBGMediaManager sharedManager] clearAllMedia];
        [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
        [self.table reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFilzaPath:(PSSpecifier *)specifier {
    NSString *path = [@"filza://" stringByAppendingString:[CCBGMediaManager sharedManager].mediaDirectory];
    NSURL *url = [NSURL URLWithString:path];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开 Filza"
                                                                       message:@"请确认已安装 Filza 文件管理器"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - PHPicker (iOS 14+)

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
    NSString *itemIdentifier = [result valueForKey:@"itemIdentifier"];
    if (!itemIdentifier) return;

    // 显示处理中 HUD
    [CCBGProgressHUD showInView:self.view text:@"处理中..."];

    // 用 NSItemProvider 加载
    NSItemProvider *provider = [result valueForKey:@"itemProvider"];
    if (!provider) {
        [CCBGProgressHUD dismissFromView:self.view];
        return;
    }

    // 先判断类型
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        // 视频
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
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
                });
            }
        }];
    } else {
        [CCBGProgressHUD dismissFromView:self.view];
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

    // 显示处理中 HUD
    [CCBGProgressHUD showInView:self.view text:@"处理中..."];

    if ([mediaType isEqualToString:@"public.image"]) {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        [[CCBGMediaManager sharedManager] saveImage:image completion:^(BOOL success) {
            [self didFinishSavingMedia:success];
        }];
    } else if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        [[CCBGMediaManager sharedManager] saveVideoFromURL:videoURL completion:^(BOOL success) {
            [self didFinishSavingMedia:success];
        }];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 保存完成回调

- (void)didFinishSavingMedia:(BOOL)success {
    [CCBGProgressHUD dismissFromView:self.view];

    if (success) {
        // 自动开启
        CFPreferencesSetAppValue((__bridge CFStringRef)kCCBgEnabledKey,
                                 kCFBooleanTrue,
                                 (__bridge CFStringRef)kCCBgPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCCBgPrefsDomain);

        [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
        [self.table reloadData];
    }
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
    // specifierAtIndexPath: is the real API; specifierForIndexPath: does not exist.
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *actionName = [specifier propertyForKey:@"action"];

    // 缩略图按钮点击
    if ([actionName isEqualToString:NSStringFromSelector(@selector(chooseMedia:))]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self chooseMedia:specifier];
        return;
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
    // 标记这是缩略图按钮
    [spec setProperty:@(YES) forKey:@"hasThumbnail"];
    return spec;
}

@end
