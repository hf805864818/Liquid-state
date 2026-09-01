#pragma once
#import <UIKit/UIKit.h>

void LGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#ifndef jbroot
#define jbroot(path) (path)
#endif
#endif

id LGGlassPreferenceValue(NSString *key);
void LGInvalidateGlassPreferenceCache(void);
NSString *LGFilterTypeForHostPrefix(NSString *prefix);

// Appearance mode support for separate light/dark parameters
void LGSetGlassAppearanceMode(UIUserInterfaceStyle mode);
UIUserInterfaceStyle LGGetGlassAppearanceMode(void);

@interface LGLiveBackdropView : UIView

@property (nonatomic, copy) NSString *lgFilterType;

@property (nonatomic, copy) NSNumber *lgSpecularEnabledOverride;

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName;

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName
                   filterType:(NSString *)filterType;
- (void)applyFilters;
@end

// Call to notify that SpringBoard is in foreground (icons visible) or background (app in front)
void LGSetSpringBoardInForeground(BOOL inForeground);

void LGInjectGlassIntoMaterialGroupType(UIView *materialView, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType);

void LGResyncGlassGeometry(UIView *materialView, const void *assocKey);
void LGRemoveGlassFromMaterial(UIView *materialView, const void *assocKey);

BOOL LGMaterialHasGlass(UIView *materialView, const void *assocKey);
