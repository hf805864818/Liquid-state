

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "Shared/LGSharedSupport.h"
#import "Shared/LGLiveBackdropView.h"

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone                   = 0,
    SBSRelaunchActionOptionsRestartRenderServer    = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition     = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition  = 1 << 2,
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

static NSString * const kLGRespringNote = @"dylv.liquidassprefs/Respring";

static void LG_requestRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

    Class actionClass  = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;

    SBSRelaunchAction *restart =
        [actionClass actionWithReason:@"LiquidAss"
                              options:(SBSRelaunchActionOptionsRestartRenderServer |
                                       SBSRelaunchActionOptionsFadeToBlackTransition)
                            targetURL:nil];
    if (!restart) return;
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restart] withResult:nil];
}

static void LG_respringRequested(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ LG_requestRespring(); });
}

static void LG_updateAppearanceMode(void) {
    if (!LGIsSeparateAppearanceModeEnabled()) {
        LGSetGlassAppearanceMode(UIUserInterfaceStyleUnspecified);
        return;
    }
    UIUserInterfaceStyle style = LGCurrentSystemAppearance();
    LGSetGlassAppearanceMode(style);
}

static void LG_appearanceChanged(NSNotification *note) {
    LG_updateAppearanceMode();
    LGInvalidateGlassPreferenceCache();
    // Post Darwin notification to refresh all glass views with new parameters
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("dylv.liquidglass/ParametersReloaded"),
                                         NULL, NULL, true);
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LG_respringRequested, (__bridge CFStringRef)kLGRespringNote,
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
    
    if (LGIsSpringBoardProcess()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LG_updateAppearanceMode();
            // Observe system appearance changes
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                LG_appearanceChanged(note);
            }];
            
            // Observe trait collection changes on main screen
            if (@available(iOS 13.0, *)) {
                [[NSNotificationCenter defaultCenter] addObserverForName:@"_UIScreenTraitCollectionDidChangeNotification"
                                                                  object:nil
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(NSNotification *note) {
                    LG_appearanceChanged(note);
                }];
            }
        });
    }
}
