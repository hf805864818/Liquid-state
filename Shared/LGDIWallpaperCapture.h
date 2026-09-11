#pragma once
#import <Foundation/Foundation.h>

// Shared constants for cross-process wallpaper capture.
// SpringBoard captures wallpaper content at the Dynamic Island's screen rect
// into an IOSurface, writes the IOSurfaceID to a dedicated plist file, and
// backboardd reads it to create an MTLTexture used as a fallback when
// CABackdropLayer cross-window capture fails.
//
// Communication uses direct file I/O + Darwin notifications (same pattern as
// the main prefs reload mechanism) because CFPreferences cross-process is
// unreliable on some jailbreaks (roothide path redirection).

#define LG_DI_WALLPAPER_SURFACE_ID_KEY     @"DI.WallpaperSurfaceID"
#define LG_DI_WALLPAPER_SURFACE_WIDTH_KEY   @"DI.WallpaperSurfaceWidth"
#define LG_DI_WALLPAPER_SURFACE_HEIGHT_KEY  @"DI.WallpaperSurfaceHeight"
#define LG_DI_WALLPAPER_CAPTURE_READY_NOTIFY "dylv.liquidass/WallpaperCaptureReady"

// Dedicated plist file for wallpaper surface metadata (separate from main
// prefs to avoid cache invalidation issues with LGGlassPreferenceValue).
#define LG_DI_WALLPAPER_PREFS_PATH  \
    "/var/mobile/Library/Preferences/dylv.liquidass.di_wallpaper.plist"

// SpringBoard-side: create/refresh the wallpaper IOSurface.
// Captures the wallpaper window's content at the given screen rect into the
// IOSurface. Called periodically (e.g., every 2s) while glass is active.
void LGDIEnsureWallpaperSurface(CGSize size);
void LGDICaptureWallpaperIntoSurface(CGRect screenRect);
void LGDITeardownWallpaperSurface(void);

// backboardd-side: read IOSurfaceID from the plist file, create MTLTexture.
// Returns nil if no surface is available. Thread-safe.
id<MTLTexture> LGDIGetWallpaperTexture(id<MTLDevice> device);
BOOL LGDIHasWallpaperTexture(void);
