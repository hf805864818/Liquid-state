export TARGET ?= iphone:clang:16.5:14.0
export ARCHS ?= arm64 arm64e
LIQUIDASS_DEBUG ?= 0
export LIQUIDASS_DEBUG

INSTALL_TARGET_PROCESSES = backboardd SpringBoard
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = liquidass

liquidass_FILES     = Tweak.x Hooks/Dock.x Hooks/Folder.x Hooks/AppIcons.x Hooks/Banner.x Hooks/ControlCenter.x \
                      Hooks/AppLibrary.x Hooks/SearchPill.x Hooks/Spotlight.x Hooks/Widgets.x Hooks/ContextMenu.x \
                      Hooks/QuickActions.x Hooks/Passcode.x Hooks/Clock.x Hooks/Alerts.x \
                      Hooks/PreferencesControls.x Hooks/CoverSheet.x Hooks/TabBar.x \
                      Hooks/Keyboard.x Hooks/LandscapeVolume.x Hooks/NotificationCenter.x Hooks/DynamicIsland.x \
                      LiquidAssPrefs/LGPrefsLiquidSlider.m \
                      LiquidAssPrefs/LGPrefsLiquidSwitch.m \
                      Shared/LGGlassKit.x Shared/LGLiveBackdropView.m \
                      Shared/LGSharedSupport.m
liquidass_CFLAGS    = -fobjc-arc -DLIQUIDASS_DEBUG=$(LIQUIDASS_DEBUG)
liquidass_FRAMEWORKS = UIKit QuartzCore CoreText CoreGraphics CoreMotion

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += LiquidAssBackboardd
SUBPROJECTS += LiquidAssRWB
SUBPROJECTS += LiquidAssPrefs
SUBPROJECTS += CustomCCBg
SUBPROJECTS += CustomCCBgPrefs
SUBPROJECTS += LGCCToggle
include $(THEOS_MAKE_PATH)/aggregate.mk

# originally i tried to add `release::` here but apparently that keeps breaking for whatever fucking reason so i decided to create `release.sh`
