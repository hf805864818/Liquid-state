export TARGET ?= iphone:clang:16.5:14.0
export ARCHS ?= arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LGCCToggle

LGCCToggle_FILES = LGCCToggleModule.m
LGCCToggle_CFLAGS = -fobjc-arc
LGCCToggle_FRAMEWORKS = UIKit Foundation CoreGraphics
LGCCToggle_INSTALL_PATH = /Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard" || true
