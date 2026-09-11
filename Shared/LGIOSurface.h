#pragma once
#import <CoreFoundation/CoreFoundation.h>

// Minimal IOSurface API declarations.
// The IOSurface framework is private and its headers are not included in
// the public iPhoneOS SDK. This header provides just the functions and
// constants we need for cross-process wallpaper capture.

CF_IMPLICIT_BRIDGING_ENABLED

typedef struct __IOSurface *IOSurfaceRef;

// IOSurface property keys
CF_EXTERN_C_BEGIN
const CFStringRef kIOSurfaceWidth;
const CFStringRef kIOSurfaceHeight;
const CFStringRef kIOSurfacePixelFormat;
const CFStringRef kIOSurfaceBytesPerElement;

// Pixel format for BGRA8 (same as kCVPixelFormatType_32BGRA)
// 'BGRA' = 0x42475241 in big-endian
#define LG_IOSURFACE_PF_BGRA8 ((unsigned)0x42475241)

// Lifecycle
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
IOSurfaceRef IOSurfaceLookup(uint32_t csid);
uint32_t IOSurfaceGetID(IOSurfaceRef buffer);

// Lock / unlock
IOReturn IOSurfaceLock(IOSurfaceRef buffer, uint32_t options, void *seed);
IOReturn IOSurfaceUnlock(IOSurfaceRef buffer, uint32_t options, void *seed);

// Properties
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);

CF_EXTERN_C_END

CF_IMPLICIT_BRIDGING_DISABLED
