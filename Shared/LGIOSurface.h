#pragma once
#import <CoreFoundation/CoreFoundation.h>

// Minimal IOSurface API declarations.
// The IOSurface framework is private but the SDK already declares some
// functions (e.g. IOSurfaceLock/Unlock) in other system headers.
// We only declare what the SDK does NOT provide.

CF_IMPLICIT_BRIDGING_ENABLED

#ifndef __IOSURFACE_REF_DEFINED
#define __IOSURFACE_REF_DEFINED
typedef struct __IOSurface *IOSurfaceRef;
#endif

CF_EXTERN_C_BEGIN

// IOSurface property keys — not declared in the public SDK
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfaceBytesPerElement;
// kIOSurfaceIsGlobal 自 iOS 11 起废弃且 -Werror 会命中；
// 需要全局 surface 时直接用 CFSTR("IOSurfaceIsGlobal") 原始键名。

// Pixel format for BGRA8 (same as kCVPixelFormatType_32BGRA)
// 'BGRA' = 0x42475241 in big-endian
#define LG_IOSURFACE_PF_BGRA8 ((unsigned)0x42475241)

// Lifecycle — not in public SDK headers
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern IOSurfaceRef IOSurfaceLookup(uint32_t csid);
extern uint32_t IOSurfaceGetID(IOSurfaceRef buffer);

// Lock / unlock — already declared by the SDK (IOKit/libsystem),
// do NOT redeclare here to avoid conflicting types errors.

// Properties — not in public SDK headers
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
extern size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
extern size_t IOSurfaceGetHeight(IOSurfaceRef buffer);

CF_EXTERN_C_END

CF_IMPLICIT_BRIDGING_DISABLED
