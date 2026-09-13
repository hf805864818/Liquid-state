// =============================================================================
//  LGDI2Mutex.m — 灵动岛互斥开关实现
// =============================================================================

#import "LGDI2Mutex.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

void LGDISetMode(LGDIMode mode) {
    CFStringRef domain = (__bridge CFStringRef)LGPrefsDomain;

    if (mode == LGDIModeCustom) {
        // 开 DI2，关 DI1
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanFalse, domain);
        CFPreferencesSetAppValue(CFSTR("DynamicIsland2.Enabled"),
                                 kCFBooleanTrue, domain);
    } else if (mode == LGDIModeOriginal) {
        // 开 DI1，关 DI2
        CFPreferencesSetAppValue(CFSTR("DynamicIsland2.Enabled"),
                                 kCFBooleanFalse, domain);
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanTrue, domain);
    } else {
        // 全部关闭
        CFPreferencesSetAppValue(CFSTR("DynamicIsland.Enabled"),
                                 kCFBooleanFalse, domain);
        CFPreferencesSetAppValue(CFSTR("DynamicIsland2.Enabled"),
                                 kCFBooleanFalse, domain);
    }

    CFPreferencesAppSynchronize(domain);

    // 发送偏好变更通知
    notify_post(LGPrefsChangedNotificationCString);

    // 触发 Respring 以重建灵动岛窗口
    notify_post(LGPrefsRespringNotificationCString);
}
