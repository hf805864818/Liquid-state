#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Photos/Photos.h>
#import <MobileCoreServices/MobileCoreServices.h>

static NSString * const kCCBgPrefsDomain = @"dylv.Deepliquid.ccbg";
static NSString * const kCCBgReloadNotification = @"dylv.Deepliquid.ccbg/ReloadPrefs";
static NSString * const kCCBgMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
static NSString * const kCCBgImageFileName = @"background.jpg";
static NSString * const kCCBgVideoFileName = @"background.mp4";

@interface CCBGRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation CCBGRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        // 全局开关组
        [specs addObject:[self groupSpecifierWithName:@"全局开关"]];
        [specs addObject:[self switchSpecifierWithKey:@"Enabled"
                                                  title:@"开启自定义控制中心背景"
                                               defaultValue:@(NO)]];
        
        // 背景设置组
        [specs addObject:[self groupSpecifierWithName:@"背景设置"]];
        [specs addObject:[self buttonSpecifierWithTitle:@"选择控制中心背景 (图片/视频)"
                                                   action:@selector(chooseMedia:)]];
        [specs addObject:[self buttonSpecifierWithTitle:@"清除背景"
                                                   action:@selector(clearMedia:)]];
        
        // 模糊度组
        [specs addObject:[self groupSpecifierWithName:@"背景模糊度调节" footerText:@"调整控制中心背景的毛玻璃强度"]];
        [specs addObject:[self sliderSpecifierWithKey:@"BlurAlpha"
                                                   title:nil
                                              defaultValue:@(0.3)
                                                     min:@(0.0)
                                                     max:@(1.0)]];
        
        // 高级选项
        [specs addObject:[self groupSpecifierWithName:@"高级选项"]];
        [specs addObject:[self buttonSpecifierWithTitle:@"跳转 Filza 路径"
                                                   action:@selector(openFilzaPath:)]];
        
        _specifiers = specs;
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return nil;
    return [[NSUserDefaults standardUserDefaults] objectForKey:key inDomain:kCCBgPrefsDomain];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:key inDomain:kCCBgPrefsDomain];
    [[NSNotificationCenter defaultCenter] postNotificationName:(id)kCCBgReloadNotification object:nil];
}

#pragma mark - Actions

- (void)chooseMedia:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择背景"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"从相册选择图片"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self presentImagePickerWithSourceType:UIImagePickerControllerSourceTypePhotoLibrary mediaType:(NSString *)kUTTypeImage];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"从相册选择视频"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self presentImagePickerWithSourceType:UIImagePickerControllerSourceTypePhotoLibrary mediaType:(NSString *)kUTTypeMovie];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad 适配
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentImagePickerWithSourceType:(UIImagePickerControllerSourceType)type mediaType:(NSString *)mediaType {
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
            picker.sourceType = type;
            picker.mediaTypes = @[mediaType];
            picker.delegate = self;
            picker.allowsEditing = NO;
            [self presentViewController:picker animated:YES completion:nil];
        });
    }];
}

- (void)clearMedia:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除背景"
                                                                   message:@"确定要清除当前设置的控制中心背景吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = kCCBgMediaDirectory;
        NSError *error = nil;
        for (NSString *fname in @[kCCBgImageFileName, kCCBgVideoFileName]) {
            NSString *path = [dir stringByAppendingPathComponent:fname];
            if ([fm fileExistsAtPath:path]) {
                [fm removeItemAtPath:path error:&error];
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFilzaPath:(PSSpecifier *)specifier {
    NSString *path = [@"filza://" stringByAppendingString:kCCBgMediaDirectory];
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

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    NSString *mediaType = info[UIImagePickerControllerMediaType];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mediaDir = kCCBgMediaDirectory;
    NSError *error = nil;
    
    // 确保目录存在
    [fm createDirectoryAtPath:mediaDir withIntermediateDirectories:YES attributes:nil error:&error];
    
    if ([mediaType isEqualToString:(NSString *)kUTTypeImage]) {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        NSData *imageData = UIImageJPEGRepresentation(image, 0.85);
        NSString *destPath = [mediaDir stringByAppendingPathComponent:kCCBgImageFileName];
        // 先清除旧视频
        [fm removeItemAtPath:[mediaDir stringByAppendingPathComponent:kCCBgVideoFileName] error:nil];
        [imageData writeToFile:destPath atomically:YES];
    } else if ([mediaType isEqualToString:(NSString *)kUTTypeMovie]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        NSString *destPath = [mediaDir stringByAppendingPathComponent:kCCBgVideoFileName];
        // 先清除旧图片
        [fm removeItemAtPath:[mediaDir stringByAppendingPathComponent:kCCBgImageFileName] error:nil];
        [fm copyItemAtPath:videoURL.path toPath:destPath error:&error];
    }
    
    // 自动开启
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"Enabled" inDomain:kCCBgPrefsDomain];
    [self reloadSpecifiers];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kCCBgReloadNotification object:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Helper

- (PSSpecifier *)groupSpecifierWithName:(NSString *)name {
    return [PSSpecifier groupSpecifierWithProperties:@{
        @"name": name ?: @"",
    }];
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

@end
