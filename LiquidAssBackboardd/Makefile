include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssBackboardd

LiquidAssBackboardd_FILES     = Tweak.mm LGSymbolResolver.mm
LiquidAssBackboardd_CFLAGS    = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions -DLIQUIDASS_DEBUG=$(LIQUIDASS_DEBUG)
LiquidAssBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation IOSurface
LiquidAssBackboardd_LDFLAGS   = -lc++

include $(THEOS_MAKE_PATH)/tweak.mk
