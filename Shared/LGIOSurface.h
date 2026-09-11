#pragma once
#import <CoreFoundation/CoreFoundation.h>

// Minimal IOSurface API declarations.
// The IOSurface framework is private and its headers are not included in
// the public iPhoneOS SDK. This header provides just the functions and
// constants we need for cross-process wallpaper capture.
//
// The SDK already has some IOSurface declarations (e.g. in IOKit headers),
// so we guard against redeclaration conflicts.

CF_IMPLICIT_BRIDGING_ENABLED

#ifndef __IOSURFACE_REF_DEFINED
#define __IOSURFACE_REF_DEFINED
typedef struct __IOSurface *IOSurfaceRef;
#endif

// IOSurface property keys — declared as extern; the actual symbols
// are resolved at link time from the IOSurface framework.
CF_EXTERN_C_BEGIN

extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfaceBytesPerElement;

// Pixel format for BGRA8 (same as kCVPixelFormatType_32BGRA)
// 'BGRA' = 0x42475241 in big-endian
#define LG_IOSURFACE_PF_BGRA8 ((unsigned)0x42475241)

// Lifecycle
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern IOSurfaceRef IOSurfaceLookup(uint32_t csid);
extern uint32_t IOSurfaceGetID(IOSurfaceRef buffer);

// Lock / unlock — use kern_return_t (available via CoreFoundation) instead
// of IOReturn which requires IOKit headers not present in this SDK.
extern kern_return_t IOSurfaceLock(IOSurfaceRef buffer, uint32_t options, void *seed);
extern kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer, uint32_t options, void *seed);

// Properties
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
extern size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
extern size_t IOSurfaceGetHeight(IOSurfaceRef buffer);

CF_EXTERN_C_END

CF_IMPLICIT_BRIDGING_DISABLED
