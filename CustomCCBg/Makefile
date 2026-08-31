export TARGET ?= iphone:clang:16.5:14.0
export ARCHS ?= arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CustomCCBg

CustomCCBg_FILES = Tweak.x
CustomCCBg_CFLAGS = -fobjc-arc
CustomCCBg_FRAMEWORKS = UIKit Foundation AVFoundation AVKit QuartzCore

include $(THEOS)/makefiles/tweak.mk
