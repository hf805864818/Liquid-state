export TARGET ?= iphone:clang:16.5:14.0
export ARCHS ?= arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LGCCToggle

LG_PACKAGE_VERSION := $(shell sed -n 's/^Version: //p' ../control | head -n 1)

LGCCToggle_FILES = LGCCToggleModule.m
LGCCToggle_CFLAGS = -fobjc-arc -DLG_PACKAGE_VERSION=@\"$(LG_PACKAGE_VERSION)\"
LGCCToggle_FRAMEWORKS = UIKit Foundation CoreGraphics
LGCCToggle_INSTALL_PATH = /Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	# Sync version from control file into Info.plist
	plutil -replace CFBundleShortVersionString -string "$(LG_PACKAGE_VERSION)" $(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/$(BUNDLE_NAME).bundle/Info.plist
	plutil -replace CFBundleVersion -string "$(LG_PACKAGE_VERSION)" $(THEOS_STAGING_DIR)/Library/ControlCenter/Bundles/$(BUNDLE_NAME).bundle/Info.plist

after-install::
	install.exec "killall -9 SpringBoard" || true
