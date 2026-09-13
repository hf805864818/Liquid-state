// =============================================================================
//  LGDI2PrefsPanelController.m — 灵动岛2 设置面板
//
//  互斥模式选择器（DI1 / DI2 / 全部关闭）
//  DI2 参数调节（位置、尺寸、圆角、HideWhenInactive 等）
//  按 Banana deb 方式：HideWhenInactive 单一开关
// =============================================================================

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGDI2Mutex.h"
#import "../Shared/LGGlassKit.h"

@interface LGDI2PrefsPanelController : PSListController
@end

@implementation LGDI2PrefsPanelController

- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"LGDI2Prefs"
                                                  target:self];
    }
    return _specifiers;
}

#pragma mark - 互斥模式选择

// 读取模式选择器的值
- (id)readPreferenceValueForKey:(NSString *)key {
    if ([key isEqualToString:@"DI_ModeSelector"]) {
        return @(LGDIActiveMode());
    }
    return LGGlassPreferenceValue(key);
}

// 写入模式选择器的值（触发互斥切换 + Respring）
- (void)writePreferenceValue:(id)value forKey:(NSString *)key {
    if ([key isEqualToString:@"DI_ModeSelector"]) {
        LGDISetMode((LGDIMode)[value integerValue]);
        return;
    }
    CFPreferencesSetAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFTypeRef)value,
        (__bridge CFStringRef)LGPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
    notify_post(LGPrefsChangedNotificationCString);
}

#pragma mark - Slider 值读取

- (CGFloat)readFloatForKey:(NSString *)key fallback:(CGFloat)fallback {
    id v = LGGlassPreferenceValue(key);
    if ([v isKindOfClass:[NSNumber class]]) {
        return [v floatValue];
    }
    return fallback;
}

- (void)writeFloat:(CGFloat)value forKey:(NSString *)key {
    [self writePreferenceValue:@(value) forKey:key];
}

@end
