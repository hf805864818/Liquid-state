export TARGET ?= iphone:clang:16.5:14.0
export ARCHS ?= arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CustomCCBgPrefs

CustomCCBgPrefs_FILES = CCBGRootListController.m \
                        CCBGProgressHUD.m \
                        CCBGMediaManager.m \
                        CCBGThumbnailButtonCell.m

CustomCCBgPrefs_CFLAGS = -fobjc-arc
CustomCCBgPrefs_FRAMEWORKS = UIKit Foundation Photos MobileCoreServices AVFoundation
CustomCCBgPrefs_PRIVATE_FRAMEWORKS = Preferences
CustomCCBgPrefs_INSTALL_PATH = /Library/PreferenceBundles
CustomCCBgPrefs_RESOURCE_DIRS = Resources

include $(THEOS)/makefiles/bundle.mk

after-stage::
	ldid -S $(THEOS_STAGING_DIR)/Library/PreferenceBundles/CustomCCBgPrefs.bundle/CustomCCBgPrefs
