
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "../Shared/LGIOSurface.h"
#import "../Shared/LGHostRegistry.h"
#import "LGSymbolResolver.h"
#import "../Shared/LGCoverSheetState.h"
#import "../Shared/LGDIWallpaperCapture.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <sys/time.h>
#include <errno.h>
#include <dlfcn.h>
#include <unistd.h>

#if __has_include(<roothide.h>)
#include <roothide.h>
#else
#ifndef jbroot
#define jbroot(path) (path)
#endif
#endif

// backboardd can write here outside its temporary path
#define LG_LOG_PATH "/var/mobile/Library/Accessibility/liquidglass.log"

static void lglog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void lglog(const char *fmt, ...) {
#if LIQUIDASS_DEBUG
    FILE *f = fopen(LG_LOG_PATH, "a");
    if (!f) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm *t = localtime(&tv.tv_sec);
    char ts[32]; strftime(ts, sizeof(ts), "%H:%M:%S", t);
    fprintf(f, "[LG %s.%03d] ", ts, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
#else
    (void)fmt;
#endif
}
#import <simd/simd.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <os/lock.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <algorithm>
#include <cmath>
#include <fcntl.h>

static void *logResolveResult(const char *label, void *resolved) {
    if (resolved)
        lglog("resolve %s: scanner -> %p", label, resolved);
    else
        lglog("resolve %s: FAILED, build not supported by scanner (no fallback)", label);
    return resolved;
}

// must match the springboard filter type
static const char *kCustomFilterTypeName = "dylv.liquidglass.refraction";

// resolved from quartzcore at startup
static ptrdiff_t g_cmdBufOffset = -1;

static ptrdiff_t g_sourceTextureOffset = -1;
static ptrdiff_t g_destinationTextureOffset = -1;
static ptrdiff_t g_contextDestSurfaceOffset = -1;
static ptrdiff_t g_filterAtomOffset = 0x18;

// cloned descriptors need every slot through edge info
static const size_t kVtableSlots = 22;

// match msl natural 8-byte alignment for float2 to prevent struct field layout desync from padding
typedef struct {
    simd_float2 resolution;
    simd_float2 outputResolution;
    simd_float2 screenResolution;
    simd_float2 cardOrigin;
    simd_float2 wallpaperResolution;
    simd_float2 lensOrigin;
    float       radius;
    float       bezelWidth;
    float       glassThickness;
    float       refractionScale;
    float       refractiveIndex;
    simd_float2 wallpaperOrigin;
    simd_float2 samplingTransformX;
    simd_float2 samplingTransformY;
    simd_float2 samplingTransformOffset;
    float       samplingOrientation;
    float       backdropZoom;
    float       useGlyphMask;
    float       dispersionStrength;
    float       fresnelGlareStrength;
    float       centerTintFactor;
    simd_float4 tintColor;
    simd_float2 maskResolution;
    // 跨窗口 backdrop 采样为空时的兜底策略（灵动岛独立合成域可能捕获不到
    // 下方窗口画面）：0=整像素透明（旧行为）；1=深色玻璃底色 + 边缘高光；
    // 2=洋红色调试渲染，用于设备上一锤定音确认"空捕获"。
    float       captureFallbackMode;
    // [路线B] 壁纸纹理是否可用：与 shader Uniforms 对应
    float       hasWallpaperTexture;
    float       _pad0, _pad1;
} LGUniforms;

typedef void (*Render13Fn)(void*,
                           void*,
                           void*,
                           void*,
                           float,
                           void*,
                           float,
                           bool,
                           void*,
                           void*,
                           float*);
typedef void (*Render14Fn)(void*,
                           void*,
                           void*,
                           void*,
                           float,
                           void*,
                           float,
                           simd_float2,
                           void*,
                           void*,
                           float*);
typedef void     (*StopEncodersFn)(void*);
typedef uint32_t (*InternAtomFn)(const char*);
typedef void     (*AddFilterFn)(uint32_t, void*);
typedef int      (*IdentityFn)(void*, void*);
typedef uint64_t (*EdgeInfoFn)(void*, void*, void*, void*, void*,
                               simd_float2*, bool*);

static StopEncodersFn  g_stopEncoders   = nullptr;
static InternAtomFn    g_internAtom     = nullptr;
static AddFilterFn     g_addFilter      = nullptr;
static Render13Fn      g_origGaussR13   = nullptr; // original render we call after our pass
static Render14Fn      g_origGaussR14   = nullptr;
static IdentityFn      g_origGaussIdentity = nullptr;
static EdgeInfoFn      g_origGaussEdgeInfo = nullptr;
static void           *g_gaussCtxValue  = nullptr; // raw gaussian vtable ptr (stripped)
static bool            g_filterRegistered = false;

static void  **g_customVtable = nullptr; // mmapped 22-slot cloned gaussian vtable
static void   *g_customCtx    = nullptr; // mmapped filtersubclass-shaped block

typedef void (*MSHookFunctionFn)(void *, void *, void **);
static MSHookFunctionFn g_hookFunction = nullptr;
static bool             g_useHookPath = false;
static bool             g_legacyRenderABI = false;
static bool             g_clockFrostedMode = false;  // Clock 磨砂模式开关
static bool             g_clockMaskDebug = false;    // Clock mask 调试模式（渲染灰度 mask）
static bool             g_diEmptyCaptureDebug = false; // 灵动岛空捕获诊断：空采样渲染洋红

// 磨砂时钟独立参数（浅色/深色两套 + 着色），对应设置页 Clock.Frosted.* 键
typedef struct {
    float glassThickness;
    float refractionScale;
    float refractiveIndex;
    float dispersionStrength;
    float blur;
    float tintR, tintG, tintB, tintStrength;
} LGFrostedClockVariant;

static LGFrostedClockVariant g_frostedClockLight = { 28.0f, 2.5f, 1.65f, 0.0f, 4.0f, 1.0f, 1.0f, 1.0f, 0.4f };
static LGFrostedClockVariant g_frostedClockDark  = { 28.0f, 2.5f, 1.65f, 0.0f, 4.0f, 1.0f, 1.0f, 1.0f, 0.4f };

static thread_local bool g_inLegacyRender = false;
static thread_local simd_float2 g_legacyRenderOffset = { 0.0f, 0.0f };
static std::unordered_set<uint32_t> g_customAtoms;
static os_unfair_lock g_customAtomsLock = OS_UNFAIR_LOCK_INIT;
static std::unordered_set<uint32_t> g_loggedRenderAtoms;
static os_unfair_lock g_loggedRenderAtomsLock = OS_UNFAIR_LOCK_INIT;

static const bool kIsPACSlice =
#if __has_feature(ptrauth_calls)
    true;
#else
    false;
#endif
static const char *kForceHookPath =
    "/var/mobile/Library/Accessibility/lg_force_hook";

static id<MTLLibrary>              g_shaderLibrary = nil;
static id<MTLBuffer>               g_uniformsBuf  = nil;
static std::unordered_map<NSUInteger, id<MTLRenderPipelineState>> *g_renderPipelines = nullptr;
static id<MTLTexture>              g_clockMaskTexture = nil;
static NSData                     *g_clockMaskData = nil;
static uint32_t                    g_clockMaskWidth = 0;
static uint32_t                    g_clockMaskHeight = 0;
static float                       g_clockMaskImageScale = 1.0f;
static float                       g_clockMaskBezelWidthPoints = 24.0f;
static uint64_t                    g_clockMaskGeneration = 0;
static uint64_t                    g_clockMaskUploadedGeneration = 0;

// [路线B] 壁纸 fallback 纹理：从 SpringBoard 创建的 IOSurface 中加载，
// 当 CABackdropLayer 跨窗口捕获失败时作为折射源
static id<MTLTexture>             g_wallpaperTex = nil;
static IOSurfaceRef               g_wallpaperSurface = NULL;
static uint32_t                   g_wallpaperSurfaceID = 0;
static uint32_t                   g_lastWallpaperSurfaceID = 0;
static os_unfair_lock             g_wallpaperLock = OS_UNFAIR_LOCK_INIT;
// 通知到达时置位，渲染线程下一帧强制重新加载 plist
static volatile int32_t          g_wallpaperReloadFlag = 0;

// 壁纸 surface 元数据文件路径（与 SpringBoard 端 LGDIWallpaperPrefsPath 对应）
static NSString *lgWallpaperPrefsPath(void) {
    NSString *standard = @LG_DI_WALLPAPER_PREFS_PATH;
    if ([[NSFileManager defaultManager] fileExistsAtPath:standard]) return standard;
    NSString *jb = jbroot(@LG_DI_WALLPAPER_PREFS_PATH);
    return jb ?: standard;
}

// [路线B] 从 plist 文件读取 IOSurfaceID，创建/刷新 MTLTexture
static void LGDILoadWallpaperTexture(id<MTLDevice> device) {
    if (!device) return;

    // 从 plist 文件读取 surface ID（跨进程通信：文件 I/O）
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:lgWallpaperPrefsPath()];
    NSNumber *idNum = info[LG_DI_WALLPAPER_SURFACE_ID_KEY];
    uint32_t surfaceID = 0;
    if (idNum && [idNum isKindOfClass:[NSNumber class]]) {
        surfaceID = idNum.unsignedIntValue;
    }

    // surface ID 为 0：壁纸捕获已关闭，清理旧纹理
    if (surfaceID == 0) {
        os_unfair_lock_lock(&g_wallpaperLock);
        if (g_wallpaperTex) {
            g_wallpaperTex = nil;
            g_lastWallpaperSurfaceID = 0;
            if (g_wallpaperSurface) { CFRelease(g_wallpaperSurface); g_wallpaperSurface = NULL; }
            lglog("[路线B] wallpaper texture cleared (surfaceID=0)");
        }
        os_unfair_lock_unlock(&g_wallpaperLock);
        return;
    }

    os_unfair_lock_lock(&g_wallpaperLock);
    if (surfaceID == g_lastWallpaperSurfaceID && g_wallpaperTex) {
        // Same surface, texture already cached
        os_unfair_lock_unlock(&g_wallpaperLock);
        return;
    }
    os_unfair_lock_unlock(&g_wallpaperLock);

    // Look up the IOSurface by ID (cross-process)
    IOSurfaceRef surface = IOSurfaceLookup(surfaceID);
    if (!surface) {
        static int sLogCount = 0;
        if (__sync_fetch_and_add(&sLogCount, 1) < 5) {
            lglog("[路线B] IOSurfaceLookup failed for ID=%u", surfaceID);
        }
        return;
    }

    // Create MTLTexture from IOSurface
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:IOSurfaceGetWidth(surface)
                                                                                    height:IOSurfaceGetHeight(surface)
                                                                                 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [device newTextureWithDescriptor:desc
                                              iosurface:surface
                                                  plane:0];
    if (!tex) {
        static int sLogCount2 = 0;
        if (__sync_fetch_and_add(&sLogCount2, 1) < 5) {
            lglog("[路线B] newTextureWithDescriptor:iosurface: failed for ID=%u", surfaceID);
        }
        CFRelease(surface);
        return;
    }

    os_unfair_lock_lock(&g_wallpaperLock);
    if (g_wallpaperSurface) CFRelease(g_wallpaperSurface);
    g_wallpaperSurface = surface;  // retains
    g_wallpaperTex = tex;
    g_lastWallpaperSurfaceID = surfaceID;
    os_unfair_lock_unlock(&g_wallpaperLock);

    lglog("[路线B] wallpaper texture loaded: ID=%u dims=%lux%lu",
          surfaceID, (unsigned long)tex.width, (unsigned long)tex.height);
}

id<MTLTexture> LGDIGetWallpaperTexture(id<MTLDevice> device) {
    os_unfair_lock_lock(&g_wallpaperLock);
    id<MTLTexture> tex = g_wallpaperTex;
    os_unfair_lock_unlock(&g_wallpaperLock);
    return tex;
}

BOOL LGDIHasWallpaperTexture(void) {
    os_unfair_lock_lock(&g_wallpaperLock);
    BOOL has = (g_wallpaperTex != nil);
    os_unfair_lock_unlock(&g_wallpaperLock);
    return has;
}

static os_unfair_lock g_pipelineLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_clockMaskLock = OS_UNFAIR_LOCK_INIT;
static bool           g_pipelineInit = false;

// 充电/热状态降级: 从偏好文件读取 (SpringBoard 写入)
static BOOL g_chargingActive = NO;  // 设备是否正在充电
static NSUInteger g_thermalState = 0; // NSProcessInfoThermalState

static NSString * const kClockMaskPath =
    @"/var/mobile/Library/Accessibility/liquidglass-clock-mask.bin";
static CFStringRef const kClockMaskReloadNotification =
CFSTR("dylv.liquidglass/ClockMaskReload");

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    float    imageScale;
    float    bezelWidthPoints;
    uint64_t generation;
} LGClockMaskHeader;

// clear arc globals before cxa finalization
__attribute__((destructor))
static void liquidGlassShutdown(void) {
    g_shaderLibrary = nil;
    g_uniformsBuf  = nil;
    g_clockMaskTexture = nil;
    g_clockMaskData = nil;
}

static const char *kShaderSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 outputResolution;
    float2 screenResolution;
    float2 cardOrigin;
    float2 wallpaperResolution;
    float2 lensOrigin;
    float  radius;
    float  bezelWidth;
    float  glassThickness;
    float  refractionScale;
    float  refractiveIndex;
    float2 wallpaperOrigin;
    float2 samplingTransformX;
    float2 samplingTransformY;
    float2 samplingTransformOffset;
    float  samplingOrientation;
    float  backdropZoom;
    float  useGlyphMask;
    float  dispersionStrength;
    float  fresnelGlareStrength;
    float  centerTintFactor;
    float4 tintColor;
    float2 maskResolution;
    // 0=空采样透明（旧行为）；1=深色玻璃底色兜底；2=洋红调试
    float  captureFallbackMode;
    // [路线B] 壁纸纹理是否可用：>0.5 时，空捕获回退使用 wallpaperTex 而非纯色
    float  hasWallpaperTexture;
    float  _pad0, _pad1;  // 对齐到 8 字节边界（Metal natural alignment）
};

float surfaceConvexSquircle(float x) {
    return pow(1.0 - pow(1.0 - x, 4.0), 0.25);
}

float2 refractRay(float2 normal, float eta) {
    float cosI = -normal.y;
    float k    = 1.0 - eta * eta * (1.0 - cosI * cosI);
    if (k < 0.0) return float2(0.0);
    float sq = sqrt(k);
    return float2(-(eta * cosI + sq) * normal.x,
                    eta - (eta * cosI + sq) * normal.y);
}

float rawRefraction(float br, float gt, float bw, float eta) {
    float x  = clamp(br, 0.05, 0.95);
    float y  = surfaceConvexSquircle(x);
    float y2 = surfaceConvexSquircle(x + 0.001);
    float d  = (y2 - y) / 0.001;
    float m  = sqrt(d * d + 1.0);
    float2 n = float2(-d / m, -1.0 / m);
    float2 r = refractRay(n, eta);
    if (length(r) < 0.0001 || abs(r.y) < 0.0001) return 0.0;
    return r.x * (y * bw + gt) / r.y;
}

float displacementAtRatio(float br, float gt, float bw, float eta) {
    float peak = rawRefraction(0.05, gt, bw, eta);
    if (abs(peak) < 0.0001) return 0.0;
    float raw = rawRefraction(br, gt, bw, eta);
    return (raw / peak) * (1.0 - smoothstep(0.0, 1.0, br));
}

float fresnelAtRatio(float br, float refractiveIndex) {
    float x = clamp(br, 0.02, 0.98);
    float y0 = surfaceConvexSquircle(max(0.001, x - 0.001));
    float y1 = surfaceConvexSquircle(min(0.999, x + 0.001));
    float slope = (y1 - y0) / 0.002;
    float cosTheta = rsqrt(1.0 + slope * slope);
    float f0Base = (refractiveIndex - 1.0) / (refractiveIndex + 1.0);
    float f0 = f0Base * f0Base;
    float grazing = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    float fresnel = f0 + (1.0 - f0) * grazing;
    return fresnel * (1.0 - smoothstep(0.0, 1.0, br));
}

float linearize(float c) {
    return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92;
}
float gammaEncode(float c) {
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 srgbToXyz(float3 rgb) {
    float3 l = float3(linearize(rgb.r), linearize(rgb.g), linearize(rgb.b));
    return float3(dot(l, float3(0.4124, 0.3576, 0.1805)),
                  dot(l, float3(0.2126, 0.7152, 0.0722)),
                  dot(l, float3(0.0193, 0.1192, 0.9505)));
}
float3 xyzToSrgb(float3 xyz) {
    float3 l = float3(dot(xyz, float3( 3.2406,-1.5372,-0.4986)),
                      dot(xyz, float3(-0.9689, 1.8758, 0.0415)),
                      dot(xyz, float3( 0.0557,-0.2040, 1.0570)));
    return clamp(float3(gammaEncode(l.r), gammaEncode(l.g), gammaEncode(l.b)), 0.0, 1.0);
}

float labF(float t)    { float t3 = t*t*t; return t3>0.008856? pow(t,1.0/3.0) : 7.787*t+16.0/116.0; }
float labInvF(float t) { float t3 = t*t*t; return t3>0.008856? t3 : (t-16.0/116.0)/7.787; }

float3 xyzToLab(float3 xyz) {
    float3 n = xyz / float3(0.95047, 1.0, 1.08883);
    float fx = labF(n.x), fy = labF(n.y), fz = labF(n.z);
    return float3(116.0*fy - 16.0, 500.0*(fx-fy), 200.0*(fy-fz));
}
float3 labToXyz(float3 lab) {
    float fy = (lab.x+16.0)/116.0, fx = fy+lab.y/500.0, fz = fy-lab.z/200.0;
    return float3(0.95047*labInvF(fx), labInvF(fy), 1.08883*labInvF(fz));
}
float3 srgbToLch(float3 rgb) {
    float3 lab = xyzToLab(srgbToXyz(rgb));
    return float3(lab.x, length(lab.yz), atan2(lab.z, lab.y));
}
float3 lchToSrgb(float3 lch) {
    float3 lab = float3(lch.x, cos(lch.z)*lch.y, sin(lch.z)*lch.y);
    return xyzToSrgb(labToXyz(lab));
}

float bottomRoundedBoxDistance(float2 point, float2 size, float radius) {
    float2 halfSize = size * 0.5;
    float2 centered = point - halfSize;
    float selectedRadius = centered.y > 0.0 ? radius : 0.0;
    float2 q = abs(centered) - halfSize + selectedRadius;
    return min(max(q.x, q.y), 0.0)
         + length(max(q, float2(0.0))) - selectedRadius;
}

constant float kDispersionRedIndex   = 0.98;
constant float kDispersionGreenIndex = 1.00;
constant float kDispersionBlueIndex  = 1.02;

float dispersionOffsetScale(float channelIndex, float strength) {
    return 1.0 - (channelIndex - 1.0) * strength;
}

float2 backdropSampleUV(float2 capturePx,
                        float2 logicalPx,
                        float2 displacementPx,
                        bool isCoverSheet,
                        constant Uniforms &u)
{
    float2 sampleUV;
    if (isCoverSheet) {
        sampleUV = (capturePx + displacementPx) / u.resolution;
    } else {
        float2 screenPx = u.cardOrigin + logicalPx + displacementPx;
        float2 mapped   = u.samplingTransformOffset
                        + screenPx.x * u.samplingTransformX
                        + screenPx.y * u.samplingTransformY;
        float2 imgPx    = mapped - u.wallpaperOrigin;
        sampleUV = imgPx / u.wallpaperResolution;

        int ori = int(round(u.samplingOrientation));
        if      (ori == 2) sampleUV = float2(1.0 - sampleUV.x, 1.0 - sampleUV.y);
        else if (ori == 3) sampleUV = float2(1.0 - sampleUV.y,       sampleUV.x);
        else if (ori == 4) sampleUV = float2(      sampleUV.y,  1.0 - sampleUV.x);
    }

    float zoom = max(u.backdropZoom, 0.01);
    sampleUV = float2(0.5) + (sampleUV - float2(0.5)) / zoom;
    return clamp(sampleUV, 0.0, 1.0);
}

float4 liquidGlassPixel(texture2d<float, access::sample> src,
                        texture2d<float, access::sample> glyphMask,
                        texture2d<float, access::sample> wallpaperTex,
                        constant Uniforms &u, uint2 gid, uint2 dimensions)
{
    const uint W = dimensions.x, H = dimensions.y;

    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 localUV = (float2(gid) + 0.5) / float2(W, H);
    bool isCoverSheet = u.useGlyphMask < -0.5;
    float2 captureUV = localUV;
    float2 capturePx = localUV * u.resolution;
    float2 px = capturePx;
    float fw = u.resolution.x, fh = u.resolution.y;
    float coverOrientation = isCoverSheet ? -u.useGlyphMask : 0.0;
    if (isCoverSheet && coverOrientation == 2.0) {

        px = float2(u.resolution.x - capturePx.x,
                    u.resolution.y - capturePx.y);
    } else if (isCoverSheet && coverOrientation == 3.0) {

        px = float2(capturePx.y, u.resolution.x - capturePx.x);
        fw = u.resolution.y;
        fh = u.resolution.x;
    } else if (isCoverSheet && coverOrientation == 4.0) {

        px = float2(u.resolution.y - capturePx.y, capturePx.x);
        fw = u.resolution.y;
        fh = u.resolution.x;
    }
    float  R        = u.radius, bezel = u.bezelWidth;
    float  eta      = 1.0 / u.refractiveIndex;
    float  shortest = min(fw, fh);

    float signedDistance;
    float distFromSide;
    float2 dir;
    float edgeOpacity;
    if (u.useGlyphMask > 0.5) {

        // [DEBUG] mask 诊断模式：当 useGlyphMask > 1.5 时直接渲染 mask 灰度
        float maskAtPixel = glyphMask.sample(s, localUV).r;
        if (u.useGlyphMask > 1.5) {
            return float4(maskAtPixel, maskAtPixel, maskAtPixel, 1.0);
        }

        float bestDistance = bezel + 1.0;
        float2 bestDirection = float2(0.0, -1.0);
        constexpr int directionCount = 12;
        for (int directionIndex = 0; directionIndex < directionCount; directionIndex++) {
            float angle = (6.28318530718 * float(directionIndex)) / float(directionCount);
            float2 candidateDirection = float2(cos(angle), sin(angle));
            float low = 0.0;
            float high = bezel + 1.0;
            float probe = 1.0;
            for (int level = 0; level < 6; level++) {
                probe = min(probe, bezel);
                float2 probeUV = localUV + candidateDirection * (probe / u.resolution);
                if (glyphMask.sample(s, probeUV).r < 0.15) {
                    high = probe;
                    break;
                }
                low = probe;
                probe *= 2.0;
            }
            if (high <= bezel) {
                for (int refinement = 0; refinement < 3; refinement++) {
                    float middle = (low + high) * 0.5;
                    float2 probeUV = localUV + candidateDirection * (middle / u.resolution);
                    if (glyphMask.sample(s, probeUV).r < 0.15) high = middle;
                    else low = middle;
                }
                if (high < bestDistance) {
                    bestDistance = high;
                    bestDirection = candidateDirection;
                }
            }
        }
        signedDistance = -bestDistance;
        distFromSide = bestDistance;
        dir = bestDirection;

        edgeOpacity = 1.0;
    } else {

        R = clamp(R, 0.0, shortest * 0.5);

        float2 lensPx = px - (isCoverSheet ? u.lensOrigin : float2(0.0));
        float2 halfSize = float2(fw, fh) * 0.5;
        float2 p = lensPx - halfSize;
        float2 core;
        if (isCoverSheet) {

            R = min(R, shortest * 0.5);
            core = halfSize;
            signedDistance = bottomRoundedBoxDistance(
                lensPx, float2(fw, fh), R);
        } else if (R >= shortest * 0.49 || R < 0.5) {
            core = max(halfSize - float2(R), float2(0.0));
            float2 q = abs(p) - core;
            signedDistance = length(max(q, float2(0.0)))
                           + min(max(q.x, q.y), 0.0) - R;
        } else {
            constexpr float continuousCornerExtent = 1.528;
            float2 extent = min(float2(R * continuousCornerExtent), halfSize);
            core = max(halfSize - extent, float2(0.0));
            float2 q = abs(p) - core;
            float2 corner = max(q, float2(0.0));
            float2 normalized = corner / max(extent, float2(0.001));
            float superLength = pow(pow(normalized.x, 4.0) +
                                    pow(normalized.y, 4.0), 0.25);
            if (q.x <= 0.0 && q.y <= 0.0) {

                signedDistance = -min(halfSize.x - abs(p.x),
                                      halfSize.y - abs(p.y));
            } else {
                signedDistance = (superLength - 1.0) * min(extent.x, extent.y);
            }
        }
        if (signedDistance > 1.0) {
            // [路线B] early return 路径也需要壁纸 fallback
            float4 earlySample = src.sample(s, captureUV);
            if (earlySample.a < 0.01 && u.hasWallpaperTexture > 0.5) {
                float2 wpUV = backdropSampleUV(capturePx, px, float2(0.0),
                                               isCoverSheet, u);
                earlySample = wallpaperTex.sample(s, wpUV);
            }
            return earlySample;
        }

        distFromSide = max(0.0, -signedDistance);
        float2 cornerDelta = max(abs(p) - core, float2(0.0));
        float2 normalDelta;
        if (isCoverSheet) {
            float2 size = float2(fw, fh);
            float dx = bottomRoundedBoxDistance(
                           lensPx + float2(1.0, 0.0), size, R)
                     - bottomRoundedBoxDistance(
                           lensPx - float2(1.0, 0.0), size, R);
            float dy = bottomRoundedBoxDistance(
                           lensPx + float2(0.0, 1.0), size, R)
                     - bottomRoundedBoxDistance(
                           lensPx - float2(0.0, 1.0), size, R);
            normalDelta = float2(dx, dy);
        } else if (R < shortest * 0.49 && R >= 0.5 &&
            cornerDelta.x > 0.0 && cornerDelta.y > 0.0) {

            normalDelta = sign(p) * pow(cornerDelta, float2(3.0));
        } else {
            float2 nearestCore = clamp(p, -core, core);
            normalDelta = p - nearestCore;
        }
        float normalLength = length(normalDelta);
        if (normalLength > 0.001) {
            dir = normalDelta / normalLength;
        } else {
            float dL = lensPx.x, dR = fw - lensPx.x;
            float dT = lensPx.y, dB = fh - lensPx.y;
            float dm = min(min(dL, dR), min(dT, dB));
            dir = float2((dL < dR && dL == dm) ? -1.0 : (dR <= dL && dR == dm) ?  1.0 : 0.0,
                         (dT < dB && dT == dm) ? -1.0 : (dB <= dT && dB == dm) ?  1.0 : 0.0);
        }
        edgeOpacity = clamp(1.0 - max(0.0, signedDistance), 0.0, 1.0);
    }

    if (R < shortest * 0.45 && distFromSide >= bezel) {
        float4 flat = src.sample(s, captureUV);
        if (flat.a < 0.01 && u.captureFallbackMode > 0.5) {
            // [路线B] backdrop 捕获为空。优先使用壁纸纹理采样。
            // 使用 backdropSampleUV 计算壁纸 UV（考虑屏幕坐标映射），
            // 这样壁纸内容会对准灵动岛在屏幕上的实际位置。
            if (u.hasWallpaperTexture > 0.5) {
                float2 wpUV = backdropSampleUV(capturePx, px, float2(0.0),
                                               isCoverSheet, u);
                flat = wallpaperTex.sample(s, wpUV);
            }
            if (flat.a < 0.01) {
                // 壁纸纹理也不可用或采样为空：回退到纯色兜底
                float3 fb = u.captureFallbackMode > 1.5
                            ? float3(1.0, 0.0, 1.0)
                            : float3(0.045, 0.045, 0.055);
                flat = float4(fb, 1.0);
            }
        }
        float centerTintAlpha = u.tintColor.a * u.centerTintFactor;
        flat.rgb = mix(flat.rgb, u.tintColor.rgb, centerTintAlpha);
        return flat;
    }

    float bezelRatio = clamp(distFromSide / bezel, 0.0, 1.0);
    float normDisp   = (distFromSide < bezel) ?
        displacementAtRatio(bezelRatio, u.glassThickness, bezel, eta) : 0.0;

    float2 textureDir = dir;
    if (isCoverSheet && coverOrientation == 2.0) {

        textureDir = -dir;
    } else if (isCoverSheet && coverOrientation == 3.0) {

        textureDir = float2(-dir.y, dir.x);
    } else if (isCoverSheet && coverOrientation == 4.0) {

        textureDir = float2(dir.y, -dir.x);
    }
    float2 dispPx = -textureDir * normDisp * bezel
                  * u.refractionScale * edgeOpacity;

    float dispersion = clamp(u.dispersionStrength, 0.0, 20.0);
    float greenScale = dispersionOffsetScale(kDispersionGreenIndex, dispersion);
    float2 greenUV = backdropSampleUV(capturePx, px, dispPx * greenScale,
                                      isCoverSheet, u);
    float4 greenSample = src.sample(s, greenUV);

    float4 fallback = float4(0.0);
    bool loadedFallback = false;
    bool captureEmpty = false;
    if (greenSample.a < 0.01) {
        // [路线B] backdrop 折射采样为空：尝试壁纸纹理
        if (u.hasWallpaperTexture > 0.5) {
            fallback = wallpaperTex.sample(s, greenUV);
            if (fallback.a > 0.01) {
                loadedFallback = true;
                greenSample = fallback;
            }
        }
        if (greenSample.a < 0.01) {
            fallback = src.sample(s, captureUV);
            loadedFallback = true;
            greenSample = fallback;
        }
    }
    if (greenSample.a < 0.01) {
        if (u.captureFallbackMode > 0.5) {
            // [路线B] backdrop 和壁纸都为空：深色玻璃底色兜底
            captureEmpty = true;
            float3 fb = u.captureFallbackMode > 1.5
                        ? float3(1.0, 0.0, 1.0)
                        : float3(0.045, 0.045, 0.055);
            greenSample = float4(fb, 1.0);
        } else {
            return float4(0.0);
        }
    }

    float4 bg = greenSample;
    if (!captureEmpty && dispersion > 0.001 && dot(dispPx, dispPx) > 0.0001) {
        float redScale = dispersionOffsetScale(kDispersionRedIndex, dispersion);
        float blueScale = dispersionOffsetScale(kDispersionBlueIndex, dispersion);

        float2 redUV = backdropSampleUV(capturePx, px, dispPx * redScale,
                                        isCoverSheet, u);
        float2 blueUV = backdropSampleUV(capturePx, px, dispPx * blueScale,
                                         isCoverSheet, u);
        float4 redSample = src.sample(s, redUV);
        float4 blueSample = src.sample(s, blueUV);

        // [路线B] 色散采样也为空时，优先用壁纸纹理 fallback
        if (redSample.a < 0.01 || blueSample.a < 0.01) {
            if (u.hasWallpaperTexture > 0.5) {
                if (!loadedFallback) {
                    fallback = wallpaperTex.sample(s, captureUV);
                    if (fallback.a > 0.01) loadedFallback = true;
                }
                if (redSample.a < 0.01 && fallback.a > 0.01)
                    redSample = wallpaperTex.sample(s, redUV);
                if (blueSample.a < 0.01 && fallback.a > 0.01)
                    blueSample = wallpaperTex.sample(s, blueUV);
            }
            // 如果壁纸纹理也不可用，回退到纯色
            if (redSample.a < 0.01 || blueSample.a < 0.01) {
                if (!loadedFallback) fallback = src.sample(s, captureUV);
                if (redSample.a < 0.01) redSample = fallback;
                if (blueSample.a < 0.01) blueSample = fallback;
            }
        }

        bg.r = redSample.r;
        bg.g = greenSample.g;
        bg.b = blueSample.b;
        bg.a = greenSample.a;
    }

    // 边框着色渐变：边缘全着色，向内逐渐过渡到中心低着色
    // 让中心区更通透、能看清背景，同时边缘保留液态玻璃的着色与高光
    float bezelTintAlpha = mix(u.tintColor.a * u.centerTintFactor, u.tintColor.a, 1.0 - bezelRatio);
    float3 outRGB = mix(bg.rgb, u.tintColor.rgb, bezelTintAlpha);
    float fresnel = fresnelAtRatio(bezelRatio, u.refractiveIndex) * edgeOpacity;
    float luminance = dot(outRGB, float3(0.2126, 0.7152, 0.0722));
    float glare = clamp(fresnel * 0.70 * mix(0.40, 1.0, luminance), 0.0, 0.18)
                * clamp(u.fresnelGlareStrength, 0.0, 1.0);
    outRGB = 1.0 - (1.0 - outRGB) * (1.0 - glare);
    return float4(outRGB, edgeOpacity);
}

struct LGVertexOut {
    float4 position [[position]];
};

vertex LGVertexOut liquidGlassVertex(uint vertexID [[vertex_id]])
{
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
    };
    LGVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment float4 liquidGlassFragment(
    LGVertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> glyphMask [[texture(1)]],
    texture2d<float, access::sample> wallpaperTex [[texture(2)]],
    constant Uniforms &u [[buffer(0)]])
{
    uint2 dimensions(src.get_width(), src.get_height());
    float2 sourcePosition =
        in.position.xy - (u.outputResolution - u.resolution) * 0.5;
    if (any(sourcePosition < float2(0.0)) ||
        any(sourcePosition >= u.resolution)) return float4(0.0);
    uint2 gid = min(uint2(sourcePosition), dimensions - 1);
    return liquidGlassPixel(src, glyphMask, wallpaperTex, u, gid, dimensions);
}

)MSL";

static void ensurePipeline(__unsafe_unretained id<MTLDevice> device) {
    os_unfair_lock_lock(&g_pipelineLock);
    if (!g_pipelineInit) {
        g_pipelineInit = true; // set first so a compile failure doesnt spin

        NSError *err = nil;
        NSString *src = [NSString stringWithUTF8String:kShaderSrc];
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            lglog("Metal compile failed: %s", err.localizedDescription.UTF8String);
            os_unfair_lock_unlock(&g_pipelineLock);
            return;
        }
        g_shaderLibrary = lib;
        lglog("shader library ready");
    }
    os_unfair_lock_unlock(&g_pipelineLock);
}

static id<MTLRenderPipelineState>
renderPipelineForFormat(__unsafe_unretained id<MTLDevice> device, MTLPixelFormat format) {
    ensurePipeline(device);
    if (!g_shaderLibrary || !g_renderPipelines) return nil;

    os_unfair_lock_lock(&g_pipelineLock);
    auto found = g_renderPipelines->find((NSUInteger)format);
    if (found != g_renderPipelines->end()) {
        id<MTLRenderPipelineState> pipeline = found->second;
        os_unfair_lock_unlock(&g_pipelineLock);
        return pipeline;
    }

    id<MTLFunction> vertex = [g_shaderLibrary newFunctionWithName:@"liquidGlassVertex"];
    id<MTLFunction> fragment = [g_shaderLibrary newFunctionWithName:@"liquidGlassFragment"];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = format;

    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline) {
        (*g_renderPipelines)[(NSUInteger)format] = pipeline;
        lglog("render pipeline ready fmt=%lu", (unsigned long)format);
    } else {
        lglog("Render pipeline state failed fmt=%lu: %s",
              (unsigned long)format, error.localizedDescription.UTF8String);
    }
    os_unfair_lock_unlock(&g_pipelineLock);
    return pipeline;
}

static void lgReloadClockMask(void) {
    NSData *data = [NSData dataWithContentsOfFile:kClockMaskPath
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data.length < sizeof(LGClockMaskHeader)) return;
    LGClockMaskHeader header;
    [data getBytes:&header length:sizeof(header)];
    uint64_t pixelCount = (uint64_t)header.width * (uint64_t)header.height;
    if (header.magic != 0x4c474333 || !header.width || !header.height ||
        !isfinite(header.imageScale) || header.imageScale < 0.5f || header.imageScale > 4.0f ||
        !isfinite(header.bezelWidthPoints) ||
        header.bezelWidthPoints < 0.0f || header.bezelWidthPoints > 100.0f ||
        pixelCount > SIZE_MAX ||
        data.length != sizeof(header) + (NSUInteger)pixelCount) {
        lglog("clock mask rejected bytes=%lu magic=0x%x dims=%ux%u",
              (unsigned long)data.length, header.magic, header.width, header.height);
        return;
    }

    os_unfair_lock_lock(&g_clockMaskLock);
    g_clockMaskData = data;
    g_clockMaskWidth = header.width;
    g_clockMaskHeight = header.height;
    g_clockMaskImageScale = header.imageScale;
    g_clockMaskBezelWidthPoints = header.bezelWidthPoints;
    g_clockMaskGeneration++;
    os_unfair_lock_unlock(&g_clockMaskLock);
}

static void lgClockMaskDidChange(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    @autoreleasepool { lgReloadClockMask(); }
}

static id<MTLTexture>
lgClockMaskTexture(__unsafe_unretained id<MTLDevice> device) {
    os_unfair_lock_lock(&g_clockMaskLock);
    if (!g_clockMaskData || !g_clockMaskWidth || !g_clockMaskHeight) {
        os_unfair_lock_unlock(&g_clockMaskLock);
        return nil;
    }
    NSUInteger width = g_clockMaskWidth, height = g_clockMaskHeight;
    if (!g_clockMaskTexture ||
        g_clockMaskUploadedGeneration != g_clockMaskGeneration ||
        g_clockMaskTexture.device != device) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                              width:width
                                                             height:height
                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture) {
            const uint8_t *bytes =
                (const uint8_t *)g_clockMaskData.bytes + sizeof(LGClockMaskHeader);
            [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                       mipmapLevel:0
                         withBytes:bytes
                       bytesPerRow:width];
            g_clockMaskTexture = texture;
            g_clockMaskUploadedGeneration = g_clockMaskGeneration;
        }
    }
    id<MTLTexture> texture = g_clockMaskTexture;
    os_unfair_lock_unlock(&g_clockMaskLock);
    return texture;
}

// radius and bezel scale from the shortest surface side

static const float kCornerRadiusRatio = 28.0f / 220.0f;
static const float kBezelWidthRatio   = kCornerRadiusRatio * 1.8f;

static const float kMaxBezelPx        = 34.0f;

static const float kCoverSheetMaxBezelPx = 96.0f;

static void ensureUniforms(__unsafe_unretained id<MTLDevice> device, uint64_t w, uint64_t h) {
    if (g_uniformsBuf) return; // buffer itself only needs allocating once

    g_uniformsBuf = [device newBufferWithLength:sizeof(LGUniforms)
                                        options:MTLResourceStorageModeShared];
    if (!g_uniformsBuf) return;

    LGUniforms *u = (LGUniforms *)g_uniformsBuf.contents;

    // unused placeholder kept for uniform layout
    u->screenResolution = simd_make_float2(750.f, 1334.f);
    u->cardOrigin               = simd_make_float2(0.f, 0.f);
    u->glassThickness          = 18.f;
    u->refractionScale         = 2.6f;
    u->refractiveIndex         = 1.85f;
    u->wallpaperOrigin         = simd_make_float2(0.f, 0.f);
    u->samplingTransformX      = simd_make_float2(1.f, 0.f);
    u->samplingTransformY      = simd_make_float2(0.f, 1.f);
    u->samplingTransformOffset = simd_make_float2(0.f, 0.f);
    u->samplingOrientation     = 1.f;
    u->backdropZoom            = 1.f;
    u->useGlyphMask            = 0.f;
    u->dispersionStrength      = 5.0f;
    u->fresnelGlareStrength    = 0.5f;
    u->centerTintFactor        = 1.0f;
    u->maskResolution          = simd_make_float2(0.f, 0.f);
    u->captureFallbackMode     = 0.f;
    u->hasWallpaperTexture     = 0.f;
    u->_pad0                   = 0.f;
    u->_pad1                   = 0.f;

    lglog("uniforms buffer allocated (geometry refreshed per-frame)");
}

static void updateUniformsForFrame(uint64_t w, uint64_t h) {
    if (!g_uniformsBuf) return;
    LGUniforms *u = (LGUniforms *)g_uniformsBuf.contents;

    float fw = (float)w, fh = (float)h;
    float shortest = fminf(fw, fh);

    u->resolution          = simd_make_float2(fw, fh);
    u->outputResolution    = simd_make_float2(fw, fh);
    u->wallpaperResolution = simd_make_float2(fw, fh);
    u->lensOrigin          = simd_make_float2(0.f, 0.f);
    u->radius              = kCornerRadiusRatio * shortest;
    u->bezelWidth           = fminf(kBezelWidthRatio * shortest, kMaxBezelPx);
}

typedef struct {
    const char *typeName;
    const char *prefPrefix;
    uint32_t    atom;
    float       radiusRatio;
    float       bezelRatio;
    float       glassThickness;
    float       refractionScale;
    float       refractiveIndex;
    float       blur;
    float       dispersionStrength;
    float       tintR, tintG, tintB, tintStrength;
    float       darkTintR, darkTintG, darkTintB, darkTintStrength;
    float       centerTintFactor;
    float       darkCenterTintFactor;
} LGHostParams;

static const LGHostParams kHostDefaults[] = {
#define LG_BACKBOARDD_HOST(identifier, type, prefix, radius, bezel, thickness, refraction, index, blurValue, specular, dispersion, lightTint, darkTint) \
    { type, prefix, 0, radius, bezel, thickness, refraction, index, blurValue, dispersion },
    LG_HOST_REGISTRY(LG_BACKBOARDD_HOST)
#undef LG_BACKBOARDD_HOST
};
static const int kHostCount = (int)(sizeof(kHostDefaults) / sizeof(kHostDefaults[0]));
static_assert(kHostCount == LGHostIdentifierCount, "registry and renderer host order diverged");
static LGHostParams g_hostParams[kHostCount];
static uint32_t g_darkAtoms[kHostCount];
static bool         g_hostParamsInit = false;
static float        g_fresnelGlareStrength = 0.5f;

struct LGRadiusRoute { int host; float radiusRatio; bool dark; };
static std::unordered_map<uint32_t, LGRadiusRoute> g_radiusRoutes;
struct LGHostRoute { int host; bool dark; };
static std::unordered_map<uint32_t, LGHostRoute> g_refreshRoutes;
static const int kDynamicRadiusSteps = 32;

static bool lgUsesDynamicRadiusRoute(int host) {

    return strcmp(kHostDefaults[host].prefPrefix, "Clock") != 0;
}

static const LGHostParams *lgHostParamsForAtom(uint32_t atom, bool *dark) {
    if (dark) *dark = false;
    auto route = g_radiusRoutes.find(atom);
    if (route != g_radiusRoutes.end()) {
        static thread_local LGHostParams routed;
        routed = g_hostParams[route->second.host];
        routed.radiusRatio = route->second.radiusRatio;
        if (dark) *dark = route->second.dark;
        return &routed;
    }
    auto refreshRoute = g_refreshRoutes.find(atom);
    if (refreshRoute != g_refreshRoutes.end()) {
        if (dark) *dark = refreshRoute->second.dark;
        return &g_hostParams[refreshRoute->second.host];
    }
    if (atom) for (int i = 1; i < kHostCount; i++)
        if (g_hostParams[i].atom == atom || g_darkAtoms[i] == atom) {
            if (dark) *dark = g_darkAtoms[i] == atom;
            return &g_hostParams[i];
        }
    return &g_hostParams[0];
}

static NSString *lgPrefsPath(void) {
    // 偏好设置文件路径：先尝试标准路径，找不到再用 jbroot() 路径。
    // 在 roothide 等 jailbreak 上，CFPreferences 实际写入的文件可能
    // 被 roothide 重定向到 jbroot 路径下，标准路径反而找不到文件。
    NSString *standardPath =
        @"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:standardPath]) {
        return standardPath;
    }
    NSString *jbPath = jbroot(@"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist");
    return jbPath ?: standardPath;
}
// 经 cfprefsd 读取单个偏好键。roothide 环境下设置进程经 CFPreferences
// 写入的值可能只驻留在 cfprefsd 守护进程内存里、从未 flush 成容器内
// plist 文件；本进程（backboardd）直读文件会永久读到 nil（诊断洋红
// 因此从不出现）。CFPreferencesAppSynchronize 先与守护进程对账，
// 再取当前用户/任意 host 的值，与设置进程看到的保持一致。
static id lgCFPrefsValue(NSString *key) {
    if (!key.length) return nil;
    @autoreleasepool {
        CFStringRef domain = CFSTR("dylv.liquidassprefs");
        CFPreferencesAppSynchronize(domain);
        return CFBridgingRelease(
            CFPreferencesCopyAppValue((CFStringRef)key, domain));
    }
}

static NSString * const kLGPrefsReloadNote = @"dylv.liquidassprefs/Reload";
static CFStringRef const kLGParametersReloadedNote =
    CFSTR("dylv.liquidglass/ParametersReloaded");

static bool lgDecodeTintColor(NSString *hex, simd_float4 *out);

static void lgApplyHistoricalTintDefault(int host, LGHostParams *p, bool dark) {
    if (host < 0 || host >= LGHostIdentifierCount || !p) return;
    const LGHostDefinition *definition = &kLGHostRegistry[host];
    NSString *hex = [NSString stringWithUTF8String:dark
        ? definition->darkTintHex : definition->lightTintHex];
    simd_float4 tint;
    if (!lgDecodeTintColor(hex, &tint)) return;
    float *c = dark ? &p->darkTintR : &p->tintR;
    c[0] = tint.x; c[1] = tint.y; c[2] = tint.z; c[3] = tint.w;
}

static bool lgDecodeTintColor(NSString *hex, simd_float4 *out) {
    if (![hex isKindOfClass:[NSString class]] || !out) return false;
    NSString *s = [[hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (s.length != 6 && s.length != 8) return false;
    unsigned value = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&value]) return false;
    float r, g, b, a;
    if (s.length == 6) { r = ((value >> 16) & 0xff) / 255.f; g = ((value >> 8) & 0xff) / 255.f; b = (value & 0xff) / 255.f; a = 1.f; }
    else { r = ((value >> 24) & 0xff) / 255.f; g = ((value >> 16) & 0xff) / 255.f; b = ((value >> 8) & 0xff) / 255.f; a = (value & 0xff) / 255.f; }
    *out = simd_make_float4(r, g, b, a);
    return true;
}

static void lgApplyFrostedVariant(NSDictionary *prefs, NSString *suffix, LGFrostedClockVariant *variant) {
    if (!prefs || !variant) return;
    static NSString * const kPrefix = @"Clock.Frosted";
    id v;
#define LG_FROSTED_NUM(field, name) \
    do { \
        v = prefs[[kPrefix stringByAppendingFormat:@".%@%@", name, suffix]]; \
        if ([v isKindOfClass:[NSNumber class]]) variant->field = [(NSNumber *)v floatValue]; \
    } while (0)
    LG_FROSTED_NUM(glassThickness, @"GlassThickness");
    LG_FROSTED_NUM(refractionScale, @"RefractionScale");
    LG_FROSTED_NUM(refractiveIndex, @"RefractiveIndex");
    LG_FROSTED_NUM(dispersionStrength, @"DispersionStrength");
    LG_FROSTED_NUM(blur, @"Blur");
#undef LG_FROSTED_NUM
    NSString *hexKey = [kPrefix stringByAppendingFormat:@".TintColor%@", suffix];
    simd_float4 tint;
    if (lgDecodeTintColor(prefs[hexKey], &tint)) {
        variant->tintR = tint.x;
        variant->tintG = tint.y;
        variant->tintB = tint.z;
        variant->tintStrength = tint.w;
    }
}

static void lgReloadHostPrefs(void) {
    NSString *prefsPath = lgPrefsPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
    NSNumber *fresnelStrength = prefs[@"Renderer.FresnelGlareStrength"];
    g_fresnelGlareStrength = [fresnelStrength isKindOfClass:NSNumber.class]
        ? fminf(1.0f, fmaxf(0.0f, fresnelStrength.floatValue)) : 0.5f;
    // Clock 磨砂模式：提前读取开关，下方据此应用 v0.1.73b 的磨砂参数预设
    // iOS 26 时钟开关（Clock.VariableFont.Enabled）关闭时禁用磨砂模式，恢复原生时钟
    NSNumber *frostedNum = prefs[@"Clock.FrostedMode"];
    NSNumber *variableFontNum = prefs[@"Clock.VariableFont.Enabled"];
    BOOL variableFontEnabled = variableFontNum ? [variableFontNum isKindOfClass:[NSNumber class]] ? [variableFontNum boolValue] : YES : YES;
    g_clockFrostedMode = (frostedNum && [frostedNum isKindOfClass:[NSNumber class]] && frostedNum.boolValue && variableFontEnabled);
    if (g_clockFrostedMode) lglog("Clock frosted mode: ON (v0.1.73b preset)");

    // Clock mask 调试模式：Clock.MaskDebug=1 时渲染灰度 mask 用于诊断
    NSNumber *maskDebugNum = prefs[@"Clock.MaskDebug"];
    g_clockMaskDebug = (maskDebugNum && [maskDebugNum isKindOfClass:[NSNumber class]] && maskDebugNum.boolValue);
    if (g_clockMaskDebug) lglog("Clock mask debug mode: ON (rendering grayscale mask)");

    // 灵动岛空捕获诊断：DynamicIsland.EmptyCaptureDebug=1 时，backdrop 采样
    // 为空的像素渲染洋红色，用于设备上确认"跨窗口捕获为空"这一根因。
    // 注意：与 SpringBoard 侧 LGDIReadBool 行为对齐，接受 NSNumber 及
    // NSString("1"/"YES"/"true")，避免两端类型判定不一致。
    // 优先 cfprefsd（含未落盘内存值），文件值仅作对照/兜底
    id diEmptyDbgCF = lgCFPrefsValue(@"DynamicIsland.EmptyCaptureDebug");
    id diEmptyDbg = diEmptyDbgCF ?: prefs[@"DynamicIsland.EmptyCaptureDebug"];
    bool diDbgOn = false;
    if ([diEmptyDbg isKindOfClass:[NSNumber class]]) {
        diDbgOn = [(NSNumber *)diEmptyDbg boolValue];
    } else if ([diEmptyDbg isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)diEmptyDbg lowercaseString];
        diDbgOn = [s isEqualToString:@"1"] || [s isEqualToString:@"yes"]
               || [s isEqualToString:@"true"] || [s isEqualToString:@"on"];
    }
    g_diEmptyCaptureDebug = diDbgOn;
    {
        // 诊断：每次 reload 打印该键的原始形态与两个候选路径状态，
        // 用于定位"SpringBoard 探针已激活但 backboardd mode 仍为 1"的分叉。
        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:prefsPath error:nil];
        NSString *mtime = attrs.fileModificationDate
            ? [attrs.fileModificationDate descriptionWithLocale:nil] : @"-";
        bool stdExists = [[NSFileManager defaultManager] fileExistsAtPath:
            @"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist"];
        id diFileDbg = prefs[@"DynamicIsland.EmptyCaptureDebug"];
        lglog("[DI] EmptyCaptureDebug cf=%s(%s) file=%s(%s) -> on=%d mode=%.0f | "
              "plist=%s inode=%llu size=%lld mtime=%s stdPathExists=%d keys=%lu",
              diEmptyDbgCF ? NSStringFromClass([diEmptyDbgCF class]).UTF8String : "nil",
              diEmptyDbgCF ? [diEmptyDbgCF description].UTF8String : "-",
              diFileDbg ? NSStringFromClass([diFileDbg class]).UTF8String : "nil",
              diFileDbg ? [diFileDbg description].UTF8String : "-",
              diDbgOn, diDbgOn ? 2.0 : 1.0,
              prefsPath.UTF8String,
              (unsigned long long)[attrs fileSystemFileNumber],
              (long long)[attrs fileSize],
              mtime.UTF8String, stdExists ? 1 : 0,
              (unsigned long)[prefs count]);
    }
    {
        static int sPrefsPathDiagCount = 0;
        if (sPrefsPathDiagCount < 5) {
            sPrefsPathDiagCount++;
            lglog("lgPrefsPath=%s prefs=%s count=%lu frostedMode=%d",
                  prefsPath.UTF8String,
                  prefs ? "loaded" : "nil",
                  (unsigned long)prefs.count,
                  g_clockFrostedMode ? 1 : 0);
        }
    }
    int overrides = 0;
    for (int i = 0; i < kHostCount; i++) {
        uint32_t keepAtom = g_hostParamsInit ? g_hostParams[i].atom : 0;
        uint32_t keepDarkAtom = g_hostParamsInit ? g_darkAtoms[i] : 0;
        g_hostParams[i] = kHostDefaults[i];
        g_hostParams[i].atom = keepAtom;
        g_darkAtoms[i] = keepDarkAtom;
        if (i > 0) { lgApplyHistoricalTintDefault(i, &g_hostParams[i], false); lgApplyHistoricalTintDefault(i, &g_hostParams[i], true); }
        g_hostParams[i].centerTintFactor = 1.0f;
        g_hostParams[i].darkCenterTintFactor = 1.0f;
        // 上下文菜单：中心区着色减弱，保持图标清晰可读
        if (!strcmp(g_hostParams[i].prefPrefix, "ContextMenu")) {
            g_hostParams[i].centerTintFactor = 0.20f;
            g_hostParams[i].darkCenterTintFactor = 0.20f;
        }
        if (!prefs) continue;
        NSString *p = [NSString stringWithUTF8String:kHostDefaults[i].prefPrefix];
        // 音量相关 surface 在设置页使用 *Glass 后缀的键名（如 LandscapeVolumeGlass.Blur），
        // 但注册表 prefix 无后缀（LandscapeVolume），需要额外检查
        NSString *glassP = [p stringByAppendingString:@"Glass"];
        NSNumber *v;
        #define LG_OVR(field, key) \
            if ((v = prefs[[p stringByAppendingString:@"." key]]) && \
                [v isKindOfClass:[NSNumber class]]) { g_hostParams[i].field = v.floatValue; overrides++; } \
            else if ((v = prefs[[glassP stringByAppendingString:@"." key]]) && \
                [v isKindOfClass:[NSNumber class]]) { g_hostParams[i].field = v.floatValue; overrides++; }

        LG_OVR(bezelRatio,      @"BezelRatio");
        LG_OVR(glassThickness,     @"GlassThickness");
        LG_OVR(refractionScale,    @"RefractionScale");
        LG_OVR(refractiveIndex,    @"RefractiveIndex");
        LG_OVR(dispersionStrength, @"DispersionStrength");
        LG_OVR(blur,               @"Blur");
        LG_OVR(tintR,           @"TintR");
        LG_OVR(tintG,           @"TintG");
        LG_OVR(tintB,           @"TintB");
        LG_OVR(tintStrength,    @"TintStrength");
        LG_OVR(centerTintFactor,     @"CenterTintFactor");
        LG_OVR(darkCenterTintFactor, @"CenterTintFactorDark");
        #undef LG_OVR
        NSNumber *dispersionEnabled = prefs[[p stringByAppendingString:@".DispersionEnabled"]]
            ?: prefs[[glassP stringByAppendingString:@".DispersionEnabled"]];
        if ([dispersionEnabled isKindOfClass:[NSNumber class]]) {
            if (!dispersionEnabled.boolValue) g_hostParams[i].dispersionStrength = 0.0f;
            overrides++;
        }
        NSString *tintHex = prefs[[p stringByAppendingString:@".LightTintColor"]]
            ?: prefs[[glassP stringByAppendingString:@".LightTintColor"]];
        simd_float4 tint;
        if (lgDecodeTintColor(tintHex, &tint)) {
            g_hostParams[i].tintR = tint.x; g_hostParams[i].tintG = tint.y;
            g_hostParams[i].tintB = tint.z; g_hostParams[i].tintStrength = tint.w;
            overrides++;
        }
        if (lgDecodeTintColor(prefs[[p stringByAppendingString:@".DarkTintColor"]]
                ?: prefs[[glassP stringByAppendingString:@".DarkTintColor"]], &tint)) {
            g_hostParams[i].darkTintR = tint.x; g_hostParams[i].darkTintG = tint.y;
            g_hostParams[i].darkTintB = tint.z; g_hostParams[i].darkTintStrength = tint.w;
            overrides++;
        }
    }

    // Wallpaper color tint override
    if (prefs) {
        NSNumber *wallpaperTintEnabled = prefs[@"WallpaperTint.Enabled"];
        if ([wallpaperTintEnabled isKindOfClass:[NSNumber class]] && wallpaperTintEnabled.boolValue) {
            simd_float4 wpLightTint;
            simd_float4 wpDarkTint;
            BOOL hasLight = lgDecodeTintColor(prefs[@"WallpaperTint.LightColor"], &wpLightTint);
            BOOL hasDark = lgDecodeTintColor(prefs[@"WallpaperTint.DarkColor"], &wpDarkTint);
            if (hasLight || hasDark) {
                int wpOverrides = 0;
                for (int i = 1; i < kHostCount; i++) {
                    if (hasLight) {
                        g_hostParams[i].tintR = wpLightTint.x;
                        g_hostParams[i].tintG = wpLightTint.y;
                        g_hostParams[i].tintB = wpLightTint.z;
                        g_hostParams[i].tintStrength = wpLightTint.w;
                        wpOverrides++;
                    }
                    if (hasDark) {
                        g_hostParams[i].darkTintR = wpDarkTint.x;
                        g_hostParams[i].darkTintG = wpDarkTint.y;
                        g_hostParams[i].darkTintB = wpDarkTint.z;
                        g_hostParams[i].darkTintStrength = wpDarkTint.w;
                        wpOverrides++;
                    }
                }
                lglog("wallpaper tint applied to %d hosts (light=%d dark=%d)", wpOverrides / 2, hasLight, hasDark);
            }
        }
    }

    // Adaptive blur based on screen brightness
    if (prefs) {
        NSNumber *adaptiveBlurEnabled = prefs[@"AdaptiveBlur.Enabled"];
        if ([adaptiveBlurEnabled isKindOfClass:[NSNumber class]] && adaptiveBlurEnabled.boolValue) {
            NSNumber *brightnessNum = prefs[@"AdaptiveBlur.CurrentBrightness"];
            NSNumber *intensityNum = prefs[@"AdaptiveBlur.Intensity"];
            NSNumber *minBlurNum = prefs[@"AdaptiveBlur.MinBlur"];
            NSNumber *maxBlurNum = prefs[@"AdaptiveBlur.MaxBlur"];

            CGFloat brightness = [brightnessNum isKindOfClass:[NSNumber class]] ? brightnessNum.floatValue : 0.5f;
            CGFloat intensity = [intensityNum isKindOfClass:[NSNumber class]] ? intensityNum.floatValue : 0.5f;
            CGFloat minBlur = [minBlurNum isKindOfClass:[NSNumber class]] ? minBlurNum.floatValue : 10.0f;
            CGFloat maxBlur = [maxBlurNum isKindOfClass:[NSNumber class]] ? maxBlurNum.floatValue : 40.0f;

            brightness = fminf(1.0f, fmaxf(0.0f, brightness));
            intensity = fminf(1.0f, fmaxf(0.0f, intensity));

            CGFloat adaptiveBlur = minBlur + (maxBlur - minBlur) * brightness;
            int blurOverrides = 0;

            for (int i = 1; i < kHostCount; i++) {
                CGFloat baseBlur = g_hostParams[i].blur;
                CGFloat finalBlur = baseBlur * (1.0f - intensity) + adaptiveBlur * intensity;
                g_hostParams[i].blur = fminf(50.0f, fmaxf(0.0f, finalBlur));
                blurOverrides++;
            }

            lglog("adaptive blur applied: brightness=%.2f intensity=%.2f adaptive=%.1f hosts=%d",
                  brightness, intensity, adaptiveBlur, blurOverrides);
        }
    }

    // Low Power Mode optimization
    if (prefs) {
        NSNumber *lowPowerEnabled = prefs[@"LowPower.Enabled"];
        NSNumber *lowPowerActive = prefs[@"LowPower.Active"];

        if ([lowPowerEnabled isKindOfClass:[NSNumber class]] && lowPowerEnabled.boolValue &&
            [lowPowerActive isKindOfClass:[NSNumber class]] && lowPowerActive.boolValue) {

            NSNumber *blurReduction = prefs[@"LowPower.BlurReduction"];
            NSNumber *disableDispersion = prefs[@"LowPower.DisableDispersion"];

            CGFloat blurReduceAmount = [blurReduction isKindOfClass:[NSNumber class]] ? blurReduction.floatValue : 0.5f;
            BOOL disableDisp = [disableDispersion isKindOfClass:[NSNumber class]] ? disableDispersion.boolValue : YES;

            blurReduceAmount = fminf(1.0f, fmaxf(0.0f, blurReduceAmount));

            int lpOverrides = 0;
            for (int i = 1; i < kHostCount; i++) {
                // Reduce blur
                CGFloat baseBlur = g_hostParams[i].blur;
                g_hostParams[i].blur = baseBlur * (1.0f - blurReduceAmount);

                // Reduce refraction
                g_hostParams[i].refractionScale *= 0.5f;

                // Reduce dispersion
                g_hostParams[i].dispersionStrength *= (disableDisp ? 0.0f : 0.4f);

                lpOverrides++;
            }

            lglog("low power mode active: blur reduced by %.0f%%, refraction halved, dispersion=%s, hosts=%d",
                  blurReduceAmount * 100.0f,
                  disableDisp ? "off" : "reduced",
                  lpOverrides);
        }
    }

    // 充电模式优化: 仅在热状态≥Fair时降低渲染参数
    // 充电+Nominal热状态时不降级，避免边缘模糊
    if (g_chargingActive && g_thermalState >= 2) {
        int chargeOverrides = 0;
        for (int i = 1; i < kHostCount; i++) {
            // 轻微减少折射 (保持边缘清晰度)
            g_hostParams[i].refractionScale *= 0.85f;
            // 减少色散 (色散不影响边缘)
            g_hostParams[i].dispersionStrength *= 0.5f;
            chargeOverrides++;
        }
        g_fresnelGlareStrength *= 0.7f;
        lglog("charging+thermal mode: refraction -15%%, dispersion -50%%, fresnel -30%%, hosts=%d",
              chargeOverrides);
    }

    // Focus Mode optimization
    if (prefs) {
        NSNumber *focusEnabled = prefs[@"FocusMode.Enabled"];
        NSNumber *focusActive = prefs[@"FocusMode.Active"];

        if ([focusEnabled isKindOfClass:[NSNumber class]] && focusEnabled.boolValue &&
            [focusActive isKindOfClass:[NSNumber class]] && focusActive.boolValue) {

            NSNumber *blurReduction = prefs[@"FocusMode.BlurReduction"];
            NSNumber *thicknessReduction = prefs[@"FocusMode.ThicknessReduction"];
            NSNumber *disableDispersion = prefs[@"FocusMode.DisableDispersion"];

            // Fallback to old QualityReduction key for backwards compatibility
            if (![blurReduction isKindOfClass:[NSNumber class]]) {
                NSNumber *qualityReduction = prefs[@"FocusMode.QualityReduction"];
                if ([qualityReduction isKindOfClass:[NSNumber class]]) {
                    blurReduction = qualityReduction;
                }
            }

            CGFloat blurReduceAmount = [blurReduction isKindOfClass:[NSNumber class]] ? blurReduction.floatValue : 0.3f;
            CGFloat thickReduceAmount = [thicknessReduction isKindOfClass:[NSNumber class]] ? thicknessReduction.floatValue : 0.2f;
            BOOL disableDisp = [disableDispersion isKindOfClass:[NSNumber class]] ? disableDispersion.boolValue : NO;

            blurReduceAmount = fminf(1.0f, fmaxf(0.0f, blurReduceAmount));
            thickReduceAmount = fminf(1.0f, fmaxf(0.0f, thickReduceAmount));

            int focusOverrides = 0;
            for (int i = 1; i < kHostCount; i++) {
                // Reduce blur
                CGFloat baseBlur = g_hostParams[i].blur;
                g_hostParams[i].blur = baseBlur * (1.0f - blurReduceAmount);

                // Reduce glass thickness
                g_hostParams[i].glassThickness *= (1.0f - thickReduceAmount);

                // Reduce refraction slightly (proportional to blur reduction)
                g_hostParams[i].refractionScale *= (1.0f - blurReduceAmount * 0.5f);

                // Reduce dispersion
                if (disableDisp) {
                    g_hostParams[i].dispersionStrength = 0.0f;
                } else {
                    g_hostParams[i].dispersionStrength *= (1.0f - blurReduceAmount * 0.3f);
                }

                focusOverrides++;
            }

            lglog("focus mode active: blur reduced by %.0f%%, thickness reduced by %.0f%%, dispersion=%s, hosts=%d",
                  blurReduceAmount * 100.0f,
                  thickReduceAmount * 100.0f,
                  disableDisp ? "off" : "reduced",
                  focusOverrides);
        }
    }

    // Memory Optimization - Memory Saving Mode
    if (prefs) {
        NSNumber *memorySavingEnabled = prefs[@"MemorySaving.Enabled"];

        if ([memorySavingEnabled isKindOfClass:[NSNumber class]] && memorySavingEnabled.boolValue) {

            NSNumber *memoryLevel = prefs[@"MemorySaving.Level"];
            CGFloat memLevel = [memoryLevel isKindOfClass:[NSNumber class]] ? memoryLevel.floatValue : 0.5f;
            memLevel = fminf(1.0f, fmaxf(0.0f, memLevel));

            int memOverrides = 0;
            for (int i = 1; i < kHostCount; i++) {
                // Reduce glass thickness (less volume = simpler render)
                g_hostParams[i].glassThickness *= (1.0f - memLevel * 0.4f);

                // Reduce refraction scale
                g_hostParams[i].refractionScale *= (1.0f - memLevel * 0.3f);

                // Reduce blur
                g_hostParams[i].blur *= (1.0f - memLevel * 0.25f);

                // Reduce or disable dispersion
                if (memLevel > 0.7f) {
                    g_hostParams[i].dispersionStrength = 0.0f;
                } else {
                    g_hostParams[i].dispersionStrength *= (1.0f - memLevel * 0.6f);
                }

                memOverrides++;
            }

            lglog("memory saving mode active: level=%.0f%%, hosts=%d",
                  memLevel * 100.0f, memOverrides);
        }
    }

    // Dynamic Quality - reduce quality during high-load scenes
    if (prefs) {
        NSNumber *dynamicQualityEnabled = prefs[@"DynamicQuality.Enabled"];

        if ([dynamicQualityEnabled isKindOfClass:[NSNumber class]] && dynamicQualityEnabled.boolValue) {

            NSNumber *dynamicLevel = prefs[@"DynamicQuality.Aggressiveness"];
            CGFloat aggressiveness = [dynamicLevel isKindOfClass:[NSNumber class]] ? dynamicLevel.floatValue : 0.4f;
            aggressiveness = fminf(1.0f, fmaxf(0.0f, aggressiveness));

            // Check if system is under high load (signaled by SpringBoard)
            NSNumber *highLoadActive = prefs[@"DynamicQuality.HighLoadActive"];
            BOOL isHighLoad = [highLoadActive isKindOfClass:[NSNumber class]] && highLoadActive.boolValue;

            if (isHighLoad) {
                int dqOverrides = 0;
                for (int i = 1; i < kHostCount; i++) {
                    // Temporarily reduce blur
                    g_hostParams[i].blur *= (1.0f - aggressiveness * 0.5f);

                    // Temporarily reduce refraction
                    g_hostParams[i].refractionScale *= (1.0f - aggressiveness * 0.4f);

                    // Reduce or disable dispersion during high load
                    if (aggressiveness > 0.6f) {
                        g_hostParams[i].dispersionStrength *= 0.3f;
                    } else {
                        g_hostParams[i].dispersionStrength *= (1.0f - aggressiveness * 0.5f);
                    }

                    dqOverrides++;
                }

                lglog("dynamic quality: high load active, aggressiveness=%.0f%%, hosts=%d",
                      aggressiveness * 100.0f, dqOverrides);
            }
        }
    }

    // Clock 磨砂模式：读取独立磨砂参数（浅色/深色两套），渲染时按当前深浅模式选用
    if (g_clockFrostedMode && prefs) {
        lgApplyFrostedVariant(prefs, @".Light", &g_frostedClockLight);
        lgApplyFrostedVariant(prefs, @".Dark",  &g_frostedClockDark);
        // 覆盖 Clock host 的 blur 参数（v0.1.73b 默认 4.0，当前液态默认 2.5）
        // blur 不在 Metal shader uniforms 里，而是通过 LGNativeBlurRadiusForFilterType 读取
        // 这里同步覆盖 g_hostParams 以保持日志一致，实际 blur 渲染在 SpringBoard 侧
        for (int i = 0; i < kHostCount; i++) {
            if (!strcmp(kHostDefaults[i].prefPrefix, "Clock")) {
                g_hostParams[i].blur = g_frostedClockLight.blur;
                break;
            }
        }
        lglog("Clock frosted params: light={thick=%.1f refr=%.2f idx=%.2f disp=%.3f blur=%.1f tint=%.3f} dark={thick=%.1f refr=%.2f idx=%.2f disp=%.3f blur=%.1f tint=%.3f}",
              g_frostedClockLight.glassThickness, g_frostedClockLight.refractionScale,
              g_frostedClockLight.refractiveIndex, g_frostedClockLight.dispersionStrength, g_frostedClockLight.blur, g_frostedClockLight.tintStrength,
              g_frostedClockDark.glassThickness, g_frostedClockDark.refractionScale,
              g_frostedClockDark.refractiveIndex, g_frostedClockDark.dispersionStrength, g_frostedClockDark.blur, g_frostedClockDark.tintStrength);
    }

    g_hostParamsInit = true;

    // 读取充电/热状态 (SpringBoard 写入，用于渲染降级)
    if (prefs) {
        NSNumber *chargingNum = prefs[@"Charging.Active"];
        NSNumber *thermalNum = prefs[@"Thermal.State"];
        if ([chargingNum isKindOfClass:[NSNumber class]]) {
            g_chargingActive = chargingNum.boolValue;
        }
        if ([thermalNum isKindOfClass:[NSNumber class]]) {
            g_thermalState = thermalNum.unsignedIntegerValue;
        }
        lglog("thermal/charging state: charging=%d thermal=%lu",
              g_chargingActive, (unsigned long)g_thermalState);
    }

    lglog("lgReloadHostPrefs: %s (%d hosts, %d overrides) banner.bezel=%.3f refr=%.2f",
          prefs ? "loaded prefs" : "defaults", kHostCount, overrides,
          g_hostParams[4].bezelRatio, g_hostParams[4].refractionScale);
}

static void lgPrefsReloadCallback(CFNotificationCenterRef c, void *o, CFStringRef n,
                                   const void *obj, CFDictionaryRef info) {
    lglog("prefs Reload received; re-reading %s", lgPrefsPath().UTF8String);
    lgReloadHostPrefs();

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        kLGParametersReloadedNote, NULL, NULL, true);
    lglog("prefs parameters ready notification posted");
}

static void lgStartPrefsObserver(void) {
    lgReloadHostPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, lgPrefsReloadCallback, (__bridge CFStringRef)kLGPrefsReloadNote,
        NULL, CFNotificationSuspensionBehaviorCoalesce);
}

// [路线B] 壁纸捕获就绪通知回调：设置标志位，渲染线程下一帧重新加载 plist
static void lgWallpaperCaptureReadyCallback(CFNotificationCenterRef c, void *o,
                                             CFStringRef n, const void *obj,
                                             CFDictionaryRef info) {
    __sync_bool_compare_and_swap(&g_wallpaperReloadFlag, 0, 1);
}

static void lgStartWallpaperObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, lgWallpaperCaptureReadyCallback,
        CFSTR(LG_DI_WALLPAPER_CAPTURE_READY_NOTIFY), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void ourCustomRender13(void *self, void *filter, void *layer, void *ctx,
                               float opacity, void *surface, float scale,
                               bool flag, void *cm, void *shape, float *out)
{
    static uint64_t tsum_stop = 0, tsum_ours = 0, tsum_gauss = 0, tcount = 0;
    uint64_t t_start = mach_absolute_time();

    // 注意: 不再使用隔帧渲染 (frame skipping)。
    // 隔帧渲染会在自定义液态渲染和原始 Gaussian 渲染之间交替，
    // 两条渲染路径的视觉差异 (折射/色散/高光) 会导致明显闪烁。
    // 改为始终使用自定义渲染器，仅通过参数降级 (refraction/dispersion/fresnel) 控制负载。

    // trace only the first calls so render logs stay usable
    static uint64_t g_traceCalls = 0;
    uint64_t callN = ++g_traceCalls;
#define R13TRACE(...) do { if (callN <= 3) lglog(__VA_ARGS__); } while (0)
    R13TRACE("R13[%llu] ENTER ctx=%p surface=%p opacity=%.2f scale=%.2f flag=%d",
             callN, ctx, surface, opacity, scale, (int)flag);

    auto *metalCtx = (uint8_t *)ctx;
    auto *surf     = (uint8_t *)surface;

    if (g_cmdBufOffset < 0) {
        lglog("ourCustomRender13: command-buffer offset unresolved, skipping");
        return;
    }

    void *rawCmdBuf  = *(void **)(metalCtx + g_cmdBufOffset);
    void *rawOrigTex = g_sourceTextureOffset >= 0
        ? *(void **)(surf + g_sourceTextureOffset) : nullptr;

    if (!rawCmdBuf || !rawOrigTex) {
        lglog("ourCustomRender13: early exit, cmdBuf=%p origTex=%p", rawCmdBuf, rawOrigTex);
        return;
    }

    __unsafe_unretained id<MTLCommandBuffer> cmdBuf  = (__bridge id<MTLCommandBuffer>)rawCmdBuf;
    __unsafe_unretained id<MTLTexture>       origTex = (__bridge id<MTLTexture>)rawOrigTex;

    __unsafe_unretained id<MTLDevice> device = origTex.device;
    if (!device) { lglog("ourCustomRender13: origTex has no device, skip"); return; }

    uint64_t w = (uint64_t)origTex.width;
    uint64_t h = (uint64_t)origTex.height;
    if (w == 0 || h == 0) { lglog("ourCustomRender13: zero dims, skip"); return; }
    R13TRACE("R13[%llu] cmdBuf=%p origTex=%p device=%p dims=%llux%llu", callN, rawCmdBuf, rawOrigTex, (__bridge void *)device, w, h);

    ensurePipeline(device);
    if (!g_shaderLibrary) { lglog("ourCustomRender13: no shader library"); return; }

    ensureUniforms(device, w, h);
    if (!g_uniformsBuf) { lglog("ourCustomRender13: no uniforms buf"); return; }
    updateUniformsForFrame(w, h);
    R13TRACE("R13[%llu] pipeline+uniforms ready", callN);

    LGUniforms lu = *(LGUniforms *)g_uniformsBuf.contents;
    uint32_t ftype = filter
        ? *(uint32_t *)((uint8_t *)filter + g_filterAtomOffset) : 0;
    bool darkTint = false;
    const LGHostParams *hp = lgHostParamsForAtom(ftype, &darkTint);
    float shortestF = fminf((float)w, (float)h);

    // Clock 磨砂模式：不再跳过自定义液态渲染。
    // 磨砂观感通过 lgReloadHostPrefs 里的 v0.1.73b 参数预设实现（弱折射/无色散/白色着色），
    // 仍然走我们自己的渲染器，避免退回系统高斯模糊导致"还原成原版"的问题。

    // [DIAG] QuickActions 全链路诊断
    // 在 atom 层面直接统计，不依赖 host 路由结果
    // 用于确认：atom 是否注册了 / 渲染函数是否被调用 / 路由是否正确
    {
        static int sQARawCount = 0;
        // 检查 atom 是否在 QuickActions 的注册范围内
        BOOL isQA = NO;
        int qaIdx = -1;
        for (int i = 0; i < kHostCount; i++) {
            if (!strcmp(kHostDefaults[i].prefPrefix, "QuickActions")) { qaIdx = i; break; }
        }
        if (qaIdx >= 0) {
            if (g_hostParams[qaIdx].atom == ftype || g_darkAtoms[qaIdx] == ftype) {
                isQA = YES;
            } else {
                auto route = g_radiusRoutes.find(ftype);
                if (route != g_radiusRoutes.end() && route->second.host == qaIdx) {
                    isQA = YES;
                } else {
                    auto refRoute = g_refreshRoutes.find(ftype);
                    if (refRoute != g_refreshRoutes.end() && refRoute->second.host == qaIdx) {
                        isQA = YES;
                    }
                }
            }
        }
        if (isQA && sQARawCount < 20) {
            sQARawCount++;
            BOOL routedCorrectly = !strcmp(hp->prefPrefix, "QuickActions");
            lglog("[QA DIAG] raw render #%d atom=0x%x dims=%llux%llu routedQA=%s host=%s",
                  sQARawCount, ftype, w, h,
                  routedCorrectly ? "YES" : "NO",
                  hp->prefPrefix);
        }
    }

    auto radiusIt = g_radiusRoutes.find(ftype);
    float radiusRatio = radiusIt != g_radiusRoutes.end()
        ? radiusIt->second.radiusRatio : hp->radiusRatio;
    lu.radius          = radiusRatio * shortestF;
    float maxBezel = !strcmp(hp->prefPrefix, "CoverSheet")
        ? kCoverSheetMaxBezelPx : kMaxBezelPx;
    lu.bezelWidth      = fminf(hp->bezelRatio * shortestF, maxBezel);
    lu.glassThickness     = hp->glassThickness;
    lu.refractionScale    = hp->refractionScale;
    lu.refractiveIndex    = hp->refractiveIndex;
    lu.dispersionStrength = hp->dispersionStrength;
    lu.fresnelGlareStrength = g_fresnelGlareStrength;
    lu.centerTintFactor     = darkTint ? hp->darkCenterTintFactor : hp->centerTintFactor;
    lu.tintColor          = darkTint ? simd_make_float4(hp->darkTintR, hp->darkTintG, hp->darkTintB, hp->darkTintStrength)
                                  : simd_make_float4(hp->tintR, hp->tintG, hp->tintB, hp->tintStrength);

    // Clock 磨砂模式：用独立磨砂参数覆盖（浅色/深色各一套几何 + 着色）
    if (g_clockFrostedMode && !strcmp(hp->prefPrefix, "Clock")) {
        const LGFrostedClockVariant *fv = darkTint ? &g_frostedClockDark : &g_frostedClockLight;
        lu.glassThickness     = fv->glassThickness;
        lu.refractionScale    = fv->refractionScale;
        lu.refractiveIndex    = fv->refractiveIndex;
        lu.dispersionStrength = fv->dispersionStrength;
        lu.tintColor          = simd_make_float4(fv->tintR, fv->tintG, fv->tintB, fv->tintStrength);
    }

    lu.backdropZoom    = !strcmp(hp->prefPrefix, "PrefsSwitch") ? 0.75f : 1.0f;

    // uniform 缓冲全局复用，每帧先复位 mask 模式：只有 Clock / CoverSheet
    // 分支会设置非 0 值，否则走几何 SDF 路径，避免残留上一帧的脏值
    //（典型：Clock 帧后紧跟 DynamicIsland 帧会错误采样空 mask 纹理）
    lu.useGlyphMask = 0.f;

    id<MTLTexture> glyphMaskTexture = nil;
    if (!strcmp(hp->prefPrefix, "Clock")) {
        glyphMaskTexture = lgClockMaskTexture(device);
        if (glyphMaskTexture) {
            // 调试模式：Clock.MaskDebug=1 时渲染 mask 灰度图，用于验证 mask 形状
            lu.useGlyphMask = g_clockMaskDebug ? 2.f : 1.f;
            lu.maskResolution = simd_make_float2(
                (float)glyphMaskTexture.width, (float)glyphMaskTexture.height);

            float maskPointWidth = (float)glyphMaskTexture.width / g_clockMaskImageScale;
            float maskPointHeight = (float)glyphMaskTexture.height / g_clockMaskImageScale;
            float pixelsPerPointX = maskPointWidth > 0.0f ? (float)w / maskPointWidth : 1.0f;
            float pixelsPerPointY = maskPointHeight > 0.0f ? (float)h / maskPointHeight : 1.0f;
            float pixelsPerPoint = fminf(pixelsPerPointX, pixelsPerPointY);
            float maskBezelPx = g_clockMaskBezelWidthPoints * pixelsPerPoint;
            // 取设置值和 mask 值的较大者，确保设置里的边缘比例调节对时钟也生效
            // mask 值是基础最小值（保证字形边缘有效果），设置值可以进一步加大
            lu.bezelWidth = fmaxf(lu.bezelWidth, fmaxf(1.0f, maskBezelPx));

            // [DIAG] 诊断日志：记录 mask/src/dest 尺寸和 UV 映射关键参数
            {
                static int sClockDiagCount = 0;
                if (sClockDiagCount < 30) {
                    sClockDiagCount++;
                    float srcAspect = (w > 0 && h > 0) ? (float)w / (float)h : 0.0f;
                    float maskAspect = (glyphMaskTexture.width > 0 && glyphMaskTexture.height > 0)
                        ? (float)glyphMaskTexture.width / (float)glyphMaskTexture.height : 0.0f;
                    float aspectDiff = fabsf(srcAspect - maskAspect);
                    bool aspectMismatch = aspectDiff > 0.01f;
                    lglog("[CLOCK DIAG] maskTex=%ux%u scale=%.2f pts=%.1fx%.1f | "
                          "src=%llux%llu aspect=%.4f | dest=? | "
                          "pps=(%.2f,%.2f) bezel=%.1f | "
                          "aspectMismatch=%d diff=%.4f frosted=%d",
                          (unsigned)glyphMaskTexture.width, (unsigned)glyphMaskTexture.height,
                          g_clockMaskImageScale, maskPointWidth, maskPointHeight,
                          w, h, srcAspect,
                          pixelsPerPointX, pixelsPerPointY,
                          lu.bezelWidth,
                          aspectMismatch ? 1 : 0, aspectDiff,
                          g_clockFrostedMode ? 1 : 0);
                }
            }
        }
    } else if (!strcmp(hp->prefPrefix, "CoverSheet")) {

        lu.useGlyphMask = -1.f;
        lu.radius = 78.0f;
        LGCoverSheetSharedState state = {};
        bool coverStateValid = LGCoverSheetReadSharedState(&state) && state.active;
        if (coverStateValid) {
            if (state.deviceOrientation == 2u) {

                lu.lensOrigin = simd_make_float2(0.0f, 0.0f);
                lu.useGlyphMask = -2.f;
            } else if (state.deviceOrientation == 3u) {

                lu.lensOrigin = simd_make_float2(0.0f, 0.0f);
                lu.useGlyphMask = -3.f;
            } else if (state.deviceOrientation == 4u) {

                lu.lensOrigin = simd_make_float2(
                    state.originXRatio * (float)h,
                    state.originYRatio * (float)w);
                lu.useGlyphMask = -4.f;
            } else {
                lu.lensOrigin = simd_make_float2(
                    state.originXRatio * (float)w,
                    state.originYRatio * (float)h);
            }
            float pixelsPerPoint = state.pixelsPerPoint;
            if (pixelsPerPoint >= 1.0f && pixelsPerPoint <= 4.0f) {
                lu.radius = 39.0f * pixelsPerPoint;
            }
        }
        static uint32_t sLastCoverOrientation = UINT32_MAX;
        static int sInitialCoverStateLogs = 0;
        uint32_t previousOrientation = __sync_lock_test_and_set(
            &sLastCoverOrientation,
            coverStateValid ? state.deviceOrientation : UINT32_MAX);
        int stateLogIndex = __sync_fetch_and_add(&sInitialCoverStateLogs, 1);
        if (previousOrientation != sLastCoverOrientation || stateLogIndex < 12) {
            lglog("coversheet-state-read valid=%d active=%u orientation=%u "
                  "ratio={%.4f,%.4f} ppp=%.2f tex=%llux%llu "
                  "aux=%.1f lens={%.2f,%.2f} radius=%.2f",
                  coverStateValid, state.active, state.deviceOrientation,
                  state.originXRatio, state.originYRatio, state.pixelsPerPoint,
                  w, h, lu.useGlyphMask, lu.lensOrigin.x, lu.lensOrigin.y,
                  lu.radius);
        }
    }

    // 灵动岛玻璃挂在 SBSystemApertureWindow 独立合成域：黑窗帘已隐藏、近黑底
    // 已剥光，同窗口玻璃下方没有不透明内容，液态效果全靠跨窗口 backdrop 捕获。
    // 若该窗口捕获域拿不到下方画面，着色器采样 alpha≈0 —— 旧逻辑直接输出全
    // 透明（"玻璃变纯透明、毫无液态效果"）。这里对灵动岛启用兜底：
    //   mode 1：空采样回退深色玻璃底色 + 边缘菲涅尔高光，保持玻璃质感；
    //   mode 2（DynamicIsland.EmptyCaptureDebug=1）：空采样渲染洋红，用于确诊。
    // 其它 host 捕获域始终有壁纸/内容，保持 mode 0 旧行为，零影响。
    lu.captureFallbackMode = 0.f;
    if (!strcmp(hp->prefPrefix, "DynamicIsland")) {
        lu.captureFallbackMode = g_diEmptyCaptureDebug ? 2.f : 1.f;
        static int sDIFallbackLog = 0;
        if (sDIFallbackLog < 3) {
            sDIFallbackLog++;
            lglog("[DI] capture fallback mode=%.0f atom=0x%x dims=%llux%llu",
                  lu.captureFallbackMode, ftype, w, h);
        }
    }

    if (g_radiusRoutes.find(ftype) != g_radiusRoutes.end()) {
        static int sPrefsGeometryLogs = 0;
        if (__sync_fetch_and_add(&sPrefsGeometryLogs, 1) < 20) {
            lglog("prefs render atom=0x%x tex=%llux%llu ratio=%.4f radius=%.2f bezel=%.2f",
                  ftype, w, h, radiusRatio, lu.radius, lu.bezelWidth);
        }
    }

    R13TRACE("R13[%llu] before g_origGaussR13(%p)", callN, (void *)g_origGaussR13);
    if (g_inLegacyRender && g_origGaussR14) {
        g_origGaussR14(self, filter, layer, ctx, opacity, surface,
                       scale, g_legacyRenderOffset, cm, shape, out);
    } else if (g_origGaussR13) {
        g_origGaussR13(self, filter, layer, ctx, opacity, surface,
                       scale, flag, cm, shape, out);
    }
    uint64_t t_afterGauss = mach_absolute_time();
    R13TRACE("R13[%llu] after g_origGaussR13", callN);

    rawCmdBuf = *(void **)(metalCtx + g_cmdBufOffset);
    cmdBuf = rawCmdBuf ? (__bridge id<MTLCommandBuffer>)rawCmdBuf : nil;
    uint8_t *destSurf = g_contextDestSurfaceOffset >= 0
        ? *(uint8_t **)(metalCtx + g_contextDestSurfaceOffset) : nullptr;

    bool plausibleDestSurf = (uintptr_t)destSurf >= 0x10000u;
    void *rawDestTex = (plausibleDestSurf && g_destinationTextureOffset >= 0)
        ? *(void **)(destSurf + g_destinationTextureOffset) : nullptr;
    __unsafe_unretained id<MTLTexture> destTex =
        rawDestTex ? (__bridge id<MTLTexture>)rawDestTex : nil;

    auto compatibleDimension = [](uint64_t destination, uint64_t source) {
        return destination >= source
            ? destination - source <= 64
            : source - destination <= 8;
    };
    bool compatibleDimensions =
        destTex &&
        compatibleDimension(destTex.width, w) &&
        compatibleDimension(destTex.height, h);
    if (!cmdBuf || !destTex || destTex.device != device ||
        !compatibleDimensions ||
        !(destTex.usage & MTLTextureUsageRenderTarget)) {
        static int sBadDestinationLogs = 0;
        if (__sync_fetch_and_add(&sBadDestinationLogs, 1) < 20) {
            lglog("ourCustomRender13: unusable CA destination atom=0x%x surf=%p tex=%p src=%llux%llu dst=%lux%lu usage=%lu; kept stock pass",
                  ftype, destSurf, rawDestTex, w, h,
                  (unsigned long)destTex.width, (unsigned long)destTex.height,
                  (unsigned long)destTex.usage);
        }
        return;
    }
    lu.outputResolution =
        simd_make_float2((float)destTex.width, (float)destTex.height);

    // [DIAG] Clock: 记录 resolution vs outputResolution 是否匹配
    if (!strcmp(hp->prefPrefix, "Clock")) {
        static int sClockResDiagCount = 0;
        if (sClockResDiagCount < 30) {
            sClockResDiagCount++;
            float resW = lu.resolution.x, resH = lu.resolution.y;
            float outW = lu.outputResolution.x, outH = lu.outputResolution.y;
            bool resMatch = (fabsf(resW - outW) < 1.0f && fabsf(resH - outH) < 1.0f);
            lglog("[CLOCK RES DIAG] src(res)=%.0fx%.0f dest(out)=%.0fx%.0f match=%d diff=(%.1f,%.1f)",
                  resW, resH, outW, outH, resMatch ? 1 : 0,
                  outW - resW, outH - resH);
        }
    }

    os_unfair_lock_lock(&g_loggedRenderAtomsLock);
    bool firstSuccessfulAtom = g_loggedRenderAtoms.insert(ftype).second;
    os_unfair_lock_unlock(&g_loggedRenderAtomsLock);
    if (firstSuccessfulAtom) {
        lglog("render destination ready atom=0x%x host=%s src=%llux%llu dst=%lux%lu radius=%.2f bezel=%.2f aux=%.1f",
              ftype, hp->prefPrefix, w, h,
              (unsigned long)destTex.width, (unsigned long)destTex.height, lu.radius,
              lu.bezelWidth, lu.useGlyphMask);
    }

    // [DIAG TEST 3] Clock 参数详细日志
    // 确认实际渲染时用的参数值，判断是否被偏好设置或降级逻辑覆盖
    if (!strcmp(hp->prefPrefix, "Clock")) {
        static int sClockParamLogCount = 0;
        if (sClockParamLogCount < 10) {
            sClockParamLogCount++;
            lglog("[CLOCK PARAMS] thickness=%.1f refrScale=%.2f refrIdx=%.2f "
                  "bezel=%.2f disp=%.3f fresnel=%.2f "
                  "tintRGB=(%.3f,%.3f,%.3f) tintA=%.3f dark=%d hostBlur=%.1f",
                  lu.glassThickness, lu.refractionScale, lu.refractiveIndex,
                  lu.bezelWidth, lu.dispersionStrength,
                  lu.fresnelGlareStrength,
                  lu.tintColor.x, lu.tintColor.y, lu.tintColor.z, lu.tintColor.w,
                  darkTint ? 1 : 0,
                  hp->blur);
        }
    }
    R13TRACE("R13[%llu] CA destination surf=%p tex=%p dims=%lux%lu",
             callN, destSurf, rawDestTex,
             (unsigned long)destTex.width, (unsigned long)destTex.height);

    if (!g_stopEncoders) { lglog("ourCustomRender13: null stopEncoders"); return; }
    R13TRACE("R13[%llu] before stopEncoders(%p)", callN, (void *)g_stopEncoders);
    g_stopEncoders(ctx);
    uint64_t t_afterStop = mach_absolute_time();
    R13TRACE("R13[%llu] after stopEncoders, before encoder", callN);

    rawCmdBuf = *(void **)(metalCtx + g_cmdBufOffset);
    cmdBuf = rawCmdBuf ? (__bridge id<MTLCommandBuffer>)rawCmdBuf : nil;
    if (!cmdBuf) {
        lglog("ourCustomRender13: command buffer unavailable after stopEncoders");
        return;
    }

    id<MTLRenderPipelineState> renderPipeline =
        renderPipelineForFormat(device, destTex.pixelFormat);
    if (!renderPipeline) {
        lglog("ourCustomRender13: no render pipeline, kept stock pass");
        return;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destTex;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
    if (!enc) { lglog("ourCustomRender13: nil render encoder"); return; }
    [enc setRenderPipelineState:renderPipeline];
    [enc setFragmentTexture:origTex atIndex:0];
    [enc setFragmentTexture:glyphMaskTexture atIndex:1];
    
    // [路线B] 为灵动岛 host 绑定壁纸 fallback 纹理（texture index 2）
    // 当 CABackdropLayer 跨窗口捕获失败时，shader 使用此纹理作为折射源
    lu.hasWallpaperTexture = 0.f;
    if (!strcmp(hp->prefPrefix, "DynamicIsland")) {
        // 通知到达或首帧时重新加载 plist（避免每帧读文件）
        if (__sync_bool_compare_and_swap(&g_wallpaperReloadFlag, 1, 0) ||
            !g_lastWallpaperSurfaceID) {
            LGDILoadWallpaperTexture(device);
        }
        id<MTLTexture> wpTex = LGDIGetWallpaperTexture(device);
        if (wpTex) {
            [enc setFragmentTexture:wpTex atIndex:2];
            lu.hasWallpaperTexture = 1.f;
        }
    }
    
    [enc setFragmentBytes:&lu length:sizeof(lu) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    uint64_t t_afterOurs = mach_absolute_time();
    R13TRACE("R13[%llu] after our compute dispatch", callN);

    R13TRACE("R13[%llu] DONE", callN);

    tsum_stop  += (t_afterStop  - t_afterGauss);
    tsum_ours  += (t_afterOurs  - t_afterStop);
    tsum_gauss += (t_afterGauss - t_start);
    tcount++;
    if (tcount >= 6000) {
        static mach_timebase_info_data_t tb = {0, 0};
        if (tb.denom == 0) mach_timebase_info(&tb);
        double scaleUs = (double)tb.numer / tb.denom / 1000.0;
        double avgStop  = (double)tsum_stop  / tcount * scaleUs;
        double avgOurs  = (double)tsum_ours  / tcount * scaleUs;
        double avgGauss = (double)tsum_gauss / tcount * scaleUs;
        double avgTotal = avgStop + avgOurs + avgGauss;
        lglog("timing (avg over %llu calls): stopEncoders=%.0fus  ourRender=%.0fus  gaussCall=%.0fus  total=%.0fus (%.2fms)",
              tcount, avgStop, avgOurs, avgGauss, avgTotal, avgTotal / 1000.0);
        tsum_stop = tsum_ours = tsum_gauss = 0;
        tcount = 0;
    }
#undef R13TRACE
}

// cloned descriptors must report non identity while hooked descriptors keep stock identity
static int ourIdentityStub(void *self, void *filter) {
    static bool identityLogged = false;
    if (!identityLogged) {
        identityLogged = true;
        lglog("ourIdentityStub: first call, CA is dispatching into our vtable (self=%p filter=%p)", self, filter);
    }
    return 0;
}

static bool lgIsCustomAtom(uint32_t atom) {
    os_unfair_lock_lock(&g_customAtomsLock);
    bool found = g_customAtoms.find(atom) != g_customAtoms.end();
    os_unfair_lock_unlock(&g_customAtomsLock);
    return found;
}

static uint64_t ourCustomEdgeInfo(void *self, void *filter, void *layer,
                                  void *ctx, void *bounds,
                                  simd_float2 *edge, bool *flag) {
    return g_origGaussEdgeInfo
        ? g_origGaussEdgeInfo(self, filter, layer, ctx, bounds, edge, flag)
        : 0;
}

static uint64_t ourGaussianEdgeInfoHook(void *self, void *filter, void *layer,
                                        void *ctx, void *bounds,
                                        simd_float2 *edge, bool *flag) {
    // [DIAG] QuickActions edgeInfo 诊断
    // 确认 QuickActions 的滤镜是否进入 edgeInfo hook
    // 如果连 edgeInfo 都没进，说明不走 gaussian 渲染路径
    {
        uint32_t atom = filter
            ? *(uint32_t *)((uint8_t *)filter + g_filterAtomOffset) : 0;
        static int sQAEdgeCount = 0;
        BOOL isQAEdge = NO;
        int qaIdx = -1;
        for (int i = 0; i < kHostCount; i++) {
            if (!strcmp(kHostDefaults[i].prefPrefix, "QuickActions")) { qaIdx = i; break; }
        }
        if (qaIdx >= 0) {
            if (g_hostParams[qaIdx].atom == atom || g_darkAtoms[qaIdx] == atom) {
                isQAEdge = YES;
            } else {
                auto route = g_radiusRoutes.find(atom);
                if (route != g_radiusRoutes.end() && route->second.host == qaIdx) {
                    isQAEdge = YES;
                } else {
                    auto refRoute = g_refreshRoutes.find(atom);
                    if (refRoute != g_refreshRoutes.end() && refRoute->second.host == qaIdx) {
                        isQAEdge = YES;
                    }
                }
            }
        }
        if (isQAEdge && sQAEdgeCount < 20) {
            sQAEdgeCount++;
            BOOL isCustom = lgIsCustomAtom(atom);
            lglog("[QA DIAG] edgeInfo #%d atom=0x%x isCustom=%d",
                  sQAEdgeCount, atom, isCustom);
        }
    }

    return g_origGaussEdgeInfo
        ? g_origGaussEdgeInfo(self, filter, layer, ctx, bounds, edge, flag)
        : 0;
}

static void ourGaussianRenderHook(void *self, void *filter, void *layer, void *ctx,
                                  float opacity, void *surface, float scale,
                                  bool flag, void *cm, void *shape, float *out) {
    uint32_t atom = filter
        ? *(uint32_t *)((uint8_t *)filter + g_filterAtomOffset) : 0;

    // [DIAG] QuickActions hook 层诊断
    // 确认 QuickActions 的 atom 有没有进入 gaussian render hook
    {
        static int sQAHookCount = 0;
        BOOL isQAHook = NO;
        int qaIdx = -1;
        for (int i = 0; i < kHostCount; i++) {
            if (!strcmp(kHostDefaults[i].prefPrefix, "QuickActions")) { qaIdx = i; break; }
        }
        if (qaIdx >= 0) {
            if (g_hostParams[qaIdx].atom == atom || g_darkAtoms[qaIdx] == atom) {
                isQAHook = YES;
            } else {
                auto route = g_radiusRoutes.find(atom);
                if (route != g_radiusRoutes.end() && route->second.host == qaIdx) {
                    isQAHook = YES;
                } else {
                    auto refRoute = g_refreshRoutes.find(atom);
                    if (refRoute != g_refreshRoutes.end() && refRoute->second.host == qaIdx) {
                        isQAHook = YES;
                    }
                }
            }
        }
        if (isQAHook && sQAHookCount < 20) {
            sQAHookCount++;
            BOOL isCustom = lgIsCustomAtom(atom);
            lglog("[QA DIAG] hook render #%d atom=0x%x isCustom=%d opacity=%.2f scale=%.2f",
                  sQAHookCount, atom, isCustom, opacity, scale);
        }
    }

    if (lgIsCustomAtom(atom)) {
        static int loggedCustomDispatch = 0;
        if (__sync_bool_compare_and_swap(&loggedCustomDispatch, 0, 1)) {
            lglog("hook: first custom render atom=0x%x self=%p filter=%p",
                  atom, self, filter);
        }
        ourCustomRender13(self, filter, layer, ctx, opacity, surface,
                          scale, flag, cm, shape, out);
        return;
    }
    static int loggedStockDispatch = 0;
    if (__sync_bool_compare_and_swap(&loggedStockDispatch, 0, 1)) {
        lglog("hook: first stock Gaussian forwarded atom=0x%x self=%p filter=%p",
              atom, self, filter);
    }
    if (g_origGaussR13) {
        g_origGaussR13(self, filter, layer, ctx, opacity, surface,
                       scale, flag, cm, shape, out);
    }
}

static void ourGaussianRender14Hook(void *self, void *filter, void *layer, void *ctx,
                                    float opacity, void *surface, float scale,
                                    simd_float2 offset, void *cm, void *shape,
                                    float *out) {
    uint32_t atom = filter
        ? *(uint32_t *)((uint8_t *)filter + g_filterAtomOffset) : 0;
    if (lgIsCustomAtom(atom)) {
        static int loggedCustomDispatch = 0;
        if (__sync_bool_compare_and_swap(&loggedCustomDispatch, 0, 1)) {
            lglog("hook: first iOS 14 custom render atom=0x%x self=%p filter=%p",
                  atom, self, filter);
        }
        g_inLegacyRender = true;
        g_legacyRenderOffset = offset;
        ourCustomRender13(self, filter, layer, ctx, opacity, surface,
                          scale, false, cm, shape, out);
        g_inLegacyRender = false;
        return;
    }
    if (g_origGaussR14) {
        g_origGaussR14(self, filter, layer, ctx, opacity, surface,
                       scale, offset, cm, shape, out);
    }
}

static int ourGaussianIdentityHook(void *self, void *filter) {
    uint32_t atom = filter
        ? *(uint32_t *)((uint8_t *)filter + g_filterAtomOffset) : 0;
    if (lgIsCustomAtom(atom)) {
        static int loggedCustomIdentity = 0;
        if (__sync_bool_compare_and_swap(&loggedCustomIdentity, 0, 1)) {
            lglog("hook: first custom identity forced nonidentity atom=0x%x self=%p filter=%p",
                  atom, self, filter);
        }
        return 0;
    }
    return g_origGaussIdentity
        ? g_origGaussIdentity(self, filter)
        : 0;
}

static MSHookFunctionFn lgResolveHookFunction(void) {
    lglog("hook: resolving MSHookFunction");
    MSHookFunctionFn hook =
        (MSHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (hook) {
        lglog("hook: resolved MSHookFunction from linked/default namespace");
        return hook;
    }

    static const char *candidates[] = {
        jbroot("/usr/lib/libellekit.dylib"),
        jbroot("/usr/lib/libsubstrate.dylib"),
        jbroot("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"),
        "libellekit.dylib",
        "libsubstrate.dylib",
    };
    for (const char *path : candidates) {
        lglog("hook: trying backend %s", path);
        void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            lglog("hook: backend load failed %s: %s", path,
                  dlerror() ?: "unknown loader error");
            continue;
        }
        hook = (MSHookFunctionFn)dlsym(handle, "MSHookFunction");
        if (hook) {
            lglog("hook: resolved MSHookFunction from %s", path);
            return hook;
        }
    }
    lglog("hook: MSHookFunction unavailable (%s)", dlerror() ?: "no loader error");
    return nullptr;
}

static bool lgInstallGaussianHooks(void *identityEntry, void *edgeInfoEntry,
                                   void *renderEntry) {
    g_hookFunction = lgResolveHookFunction();
    if (!g_hookFunction) return false;

    void *identityTrampoline = nullptr;
    void *identityTarget = LGSymStripCode(identityEntry);
    void *identityReplacement =
        LGSymStripCode((void *)&ourGaussianIdentityHook);
    lglog("hook: installing Gaussian identity target=%p replacement=%p",
          identityTarget, identityReplacement);
    g_hookFunction(identityTarget, identityReplacement, &identityTrampoline);
    g_origGaussIdentity =
        (IdentityFn)LGSymMakeCallable(identityTrampoline);
    if (!g_origGaussIdentity) {
        lglog("hook: Gaussian identity trampoline unavailable");
        return false;
    }

    void *edgeTrampoline = nullptr;
    void *edgeTarget = LGSymStripCode(edgeInfoEntry);
    void *edgeReplacement =
        LGSymStripCode((void *)&ourGaussianEdgeInfoHook);
    lglog("hook: installing Gaussian edge-info target=%p replacement=%p",
          edgeTarget, edgeReplacement);
    g_hookFunction(edgeTarget, edgeReplacement, &edgeTrampoline);
    g_origGaussEdgeInfo =
        (EdgeInfoFn)LGSymMakeCallable(edgeTrampoline);
    if (!g_origGaussEdgeInfo) {
        lglog("hook: Gaussian edge-info trampoline unavailable");
        return false;
    }

    void *trampoline = nullptr;
    void *target = LGSymStripCode(renderEntry);
    void *replacement = LGSymStripCode(g_legacyRenderABI
        ? (void *)&ourGaussianRender14Hook
        : (void *)&ourGaussianRenderHook);
    lglog("hook: installing Gaussian render target=%p replacement=%p",
          target, replacement);
    g_hookFunction(target, replacement, &trampoline);
    if (g_legacyRenderABI)
        g_origGaussR14 = (Render14Fn)LGSymMakeCallable(trampoline);
    else
        g_origGaussR13 = (Render13Fn)LGSymMakeCallable(trampoline);
    lglog("hook: Gaussian trampolines identity=%p edge=%p renderRaw=%p render=%p ABI=%s",
          (void *)g_origGaussIdentity, (void *)g_origGaussEdgeInfo,
          trampoline,
          g_legacyRenderABI ? (void *)g_origGaussR14 : (void *)g_origGaussR13,
          g_legacyRenderABI ? "Vec2" : "bool");
    return g_legacyRenderABI ? g_origGaussR14 != nullptr
                             : g_origGaussR13 != nullptr;
}

static void lgRegisterCustomAtom(uint32_t atom, void *descriptor) {
    if (!atom || !descriptor) return;
    os_unfair_lock_lock(&g_customAtomsLock);
    bool inserted = g_customAtoms.insert(atom).second;
    os_unfair_lock_unlock(&g_customAtomsLock);
    if (inserted) g_addFilter(atom, descriptor);
}

// registering before filter table exists breaks system blur
static bool registerCustomFilter(void) {
    void **filterTableSlot = (void **)LGResolve_FilterTableSlot();
    if (!filterTableSlot) {
        lglog("registerCustomFilter: could not resolve filter_table, aborting (no fallback)");
        return false;
    }
    if (!*filterTableSlot) {
        lglog("registerCustomFilter: filter_table null, retrying in 250ms");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                       ^{ registerCustomFilter(); });
        return false;
    }

    if (g_filterRegistered) return true; // idempotent

    void **gaussCtxSlot = (void **)LGResolve_GaussianCtxSlot();
    if (!gaussCtxSlot) {
        lglog("registerCustomFilter: could not resolve gaussian context, aborting (no fallback)");
        return false;
    }

    g_gaussCtxValue = LGSymStripData((void *)*gaussCtxSlot);
    lglog("registerCustomFilter: g_gaussCtxValue = %p (raw from %p)", g_gaussCtxValue, *gaussCtxSlot);
    void **gaussVtable = (void **)g_gaussCtxValue;
    if (!gaussVtable) {
        lglog("registerCustomFilter: gaussian vtable not found");
        return false;
    }
    lglog("registerCustomFilter: gaussian vtable @ %p", gaussVtable);

    int edgeInfoSlot =
        LGResolve_EdgeInfoVtableSlot((void * const *)gaussVtable,
                                     (int)kVtableSlots);
    if (edgeInfoSlot < 0 || edgeInfoSlot >= (int)kVtableSlots) {
        lglog("registerCustomFilter: could not resolve edge-info vtable slot (got %d), aborting",
              edgeInfoSlot);
        return false;
    }
    lglog("registerCustomFilter: edge-info vtable slot = %d", edgeInfoSlot);

    int renderSlot = LGResolve_RenderVtableSlot((void * const *)gaussVtable,
                                                (int)kVtableSlots);
    if (renderSlot < 0 && g_legacyRenderABI && edgeInfoSlot >= 3) {
        int candidate = edgeInfoSlot - 3;
        void *entry = LGSymStripCode(gaussVtable[candidate]);
        if (LGSymAddressInQuartzCoreImage(entry)) {
            renderSlot = candidate;
            lglog("registerCustomFilter: iOS 14 direct render fallback vtable[%d]=%p",
                  renderSlot, entry);
        }
    }
    if (renderSlot < 0 || renderSlot >= (int)kVtableSlots) {
        lglog("registerCustomFilter: could not resolve render vtable slot (got %d), aborting", renderSlot);
        return false;
    }
    lglog("registerCustomFilter: render vtable slot = %d", renderSlot);
    if (edgeInfoSlot == renderSlot) {
        lglog("registerCustomFilter: render and edge-info resolved to the same slot, aborting");
        return false;
    }

    if (!g_internAtom || !g_addFilter) {
        lglog("registerCustomFilter: internAtom=%p addFilter=%p, aborting",
              (void *)g_internAtom, (void *)g_addFilter);
        return false;
    }
    uint32_t atomId    = g_internAtom(kCustomFilterTypeName);
    uint32_t gaussAtom = g_internAtom("gaussianBlur");
    lglog("registerCustomFilter: atom('%s')=0x%x  gaussian=0x%x  collision=%s",
          kCustomFilterTypeName, atomId, gaussAtom,
          atomId == gaussAtom ? "YES-BAD" : "no");

    void *registrationDescriptor = nullptr;
    if (g_useHookPath) {

        if (!lgInstallGaussianHooks(gaussVtable[0],
                                    gaussVtable[edgeInfoSlot],
                                    gaussVtable[renderSlot])) {
            lglog("registerCustomFilter: Gaussian hooks install failed");
            return false;
        }
        registrationDescriptor = gaussCtxSlot;
    } else {
        g_origGaussR13 = (Render13Fn)LGSymMakeCallable(gaussVtable[renderSlot]);
        g_origGaussEdgeInfo =
            (EdgeInfoFn)LGSymMakeCallable(gaussVtable[edgeInfoSlot]);
        lglog("registerCustomFilter: g_origGaussR13 = %p", (void *)g_origGaussR13);
        lglog("registerCustomFilter: g_origGaussEdgeInfo = %p",
              (void *)g_origGaussEdgeInfo);
        if (!g_origGaussR13 || !g_origGaussEdgeInfo) {
            lglog("registerCustomFilter: Gaussian callable resolution failed");
            return false;
        }

        g_customVtable = (void **)mmap(NULL, kVtableSlots * sizeof(void *),
                                       PROT_READ | PROT_WRITE,
                                       MAP_ANON | MAP_PRIVATE, -1, 0);
        if (g_customVtable == MAP_FAILED) {
            lglog("registerCustomFilter: vtable mmap failed errno=%d", errno);
            g_customVtable = nullptr;
            return false;
        }
        memcpy(g_customVtable, gaussVtable, kVtableSlots * sizeof(void *));
        g_customVtable[0]          = LGSymStripCode((void *)&ourIdentityStub);
        g_customVtable[edgeInfoSlot] =
            LGSymStripCode((void *)&ourCustomEdgeInfo);
        g_customVtable[renderSlot] = LGSymStripCode((void *)&ourCustomRender13);

        g_customCtx = mmap(NULL, 256, PROT_READ | PROT_WRITE,
                           MAP_ANON | MAP_PRIVATE, -1, 0);
        if (g_customCtx == MAP_FAILED) {
            lglog("registerCustomFilter: ctx mmap failed errno=%d", errno);
            munmap(g_customVtable, kVtableSlots * sizeof(void *));
            g_customVtable = nullptr;
            g_customCtx    = nullptr;
            return false;
        }
        *(void **)g_customCtx = g_customVtable;
        registrationDescriptor = g_customCtx;
    }

    lgStartPrefsObserver();

    g_hostParams[0].atom = atomId;
    lgRegisterCustomAtom(atomId, registrationDescriptor);
    NSString *rootRefreshName = [[NSString stringWithUTF8String:kHostDefaults[0].typeName]
        stringByAppendingString:@".refresh"];
    uint32_t rootRefreshAtom = g_internAtom(rootRefreshName.UTF8String);
    if (rootRefreshAtom) {
        g_refreshRoutes[rootRefreshAtom] = { 0, false };
        lgRegisterCustomAtom(rootRefreshAtom, registrationDescriptor);
    }
    for (int i = 1; i < kHostCount; i++) {
        uint32_t a = g_internAtom(kHostDefaults[i].typeName);
        g_hostParams[i].atom = a;
        if (a && a != atomId) lgRegisterCustomAtom(a, registrationDescriptor);
        NSString *refreshName = [[NSString stringWithUTF8String:kHostDefaults[i].typeName]
            stringByAppendingString:@".refresh"];
        uint32_t refreshAtom = g_internAtom(refreshName.UTF8String);
        if (refreshAtom) {
            g_refreshRoutes[refreshAtom] = { i, false };
            lgRegisterCustomAtom(refreshAtom, registrationDescriptor);
        }
        NSString *darkName = [[NSString stringWithUTF8String:kHostDefaults[i].typeName] stringByAppendingString:@".dark"];
        uint32_t da = g_internAtom(darkName.UTF8String);
        g_darkAtoms[i] = da;
        if (da && da != a) lgRegisterCustomAtom(da, registrationDescriptor);
        NSString *darkRefreshName = [darkName stringByAppendingString:@".refresh"];
        uint32_t darkRefreshAtom = g_internAtom(darkRefreshName.UTF8String);
        if (darkRefreshAtom) {
            g_refreshRoutes[darkRefreshAtom] = { i, true };
            lgRegisterCustomAtom(darkRefreshAtom, registrationDescriptor);
        }
        if (lgUsesDynamicRadiusRoute(i)) {
            for (int step = 0; step <= kDynamicRadiusSteps / 2; step++) {
                NSString *radiusName = [[NSString stringWithUTF8String:kHostDefaults[i].typeName]
                    stringByAppendingFormat:@".r%d", step];
                uint32_t ra = g_internAtom(radiusName.UTF8String);
                if (ra) {
                    g_radiusRoutes[ra] = { i, (float)step / (float)kDynamicRadiusSteps, false };
                    lgRegisterCustomAtom(ra, registrationDescriptor);
                    NSString *radiusRefreshName = [radiusName stringByAppendingString:@".refresh"];
                    uint32_t radiusRefreshAtom = g_internAtom(radiusRefreshName.UTF8String);
                    if (radiusRefreshAtom) {
                        g_radiusRoutes[radiusRefreshAtom] =
                            { i, (float)step / (float)kDynamicRadiusSteps, false };
                        lgRegisterCustomAtom(radiusRefreshAtom, registrationDescriptor);
                    }
                }
                NSString *darkRadiusName = [radiusName stringByAppendingString:@".dark"];
                uint32_t rda = g_internAtom(darkRadiusName.UTF8String);
                if (rda) {
                    g_radiusRoutes[rda] = { i, (float)step / (float)kDynamicRadiusSteps, true };
                    lgRegisterCustomAtom(rda, registrationDescriptor);
                    NSString *darkRadiusRefreshName =
                        [darkRadiusName stringByAppendingString:@".refresh"];
                    uint32_t darkRadiusRefreshAtom =
                        g_internAtom(darkRadiusRefreshName.UTF8String);
                    if (darkRadiusRefreshAtom) {
                        g_radiusRoutes[darkRadiusRefreshAtom] =
                            { i, (float)step / (float)kDynamicRadiusSteps, true };
                        lgRegisterCustomAtom(darkRadiusRefreshAtom, registrationDescriptor);
                    }
                }
            }
        }
    }

    g_filterRegistered = true;
    lglog("registerCustomFilter: done mode=%s descriptor=%p renderSlot=%d atom=0x%x hosts=%d",
          g_useHookPath ? "hook" : "clone", registrationDescriptor,
          renderSlot, atomId, kHostCount);

    // [DIAG] QuickActions atom 注册诊断
    // 确认 QuickActions 的各种变体 atom 是否被正确注册
    {
        int qaIdx = -1;
        for (int i = 0; i < kHostCount; i++) {
            if (!strcmp(kHostDefaults[i].prefPrefix, "QuickActions")) { qaIdx = i; break; }
        }
        if (qaIdx >= 0) {
            uint32_t qaBase = g_hostParams[qaIdx].atom;
            uint32_t qaDark = g_darkAtoms[qaIdx];
            int qaRadiusCount = 0;
            for (auto &pair : g_radiusRoutes) {
                if (pair.second.host == qaIdx) qaRadiusCount++;
            }
            lglog("[QA DIAG] QuickActions registered: baseAtom=0x%x darkAtom=0x%x radiusVariants=%d (expected=%d)",
                  qaBase, qaDark, qaRadiusCount, (kDynamicRadiusSteps / 2 + 1) * 2);
        }
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kLGParametersReloadedNote, NULL, NULL, true);
    lglog("registerCustomFilter: registration-ready notification posted");
    return true;
}

__attribute__((constructor))
static void tweakInit(void) {
    @autoreleasepool {
#if LIQUIDASS_DEBUG
    { FILE *lf = fopen(LG_LOG_PATH, "w"); if (lf) fclose(lf); }
#endif

    NSOperatingSystemVersion osv = NSProcessInfo.processInfo.operatingSystemVersion;
    g_legacyRenderABI = osv.majorVersion <= 14;
    lglog("===== LiquidGlass (backboardd) on iOS %ld.%ld.%ld =====",
          (long)osv.majorVersion, (long)osv.minorVersion, (long)osv.patchVersion);

    g_filterAtomOffset = osv.majorVersion <= 14 ? 0x14 : 0x18;

    g_sourceTextureOffset = osv.majorVersion >= 17 ? 0x60 : 0x58;
    g_destinationTextureOffset = osv.majorVersion >= 17 ? 0x60 : 0x58;
    if (osv.majorVersion == 16)
        g_contextDestSurfaceOffset = 0x110;
    else if (osv.majorVersion == 15 || osv.majorVersion >= 18)
        g_contextDestSurfaceOffset = 0x108;
    else
        g_contextDestSurfaceOffset = 0xf8;
    lglog("init: QuartzCore layout filterAtom=%#lx sourceTexture=%#lx destinationTexture=%#lx contextDestination=%#lx",
          (long)g_filterAtomOffset,
          (long)g_sourceTextureOffset, (long)g_destinationTextureOffset,
          (long)g_contextDestSurfaceOffset);

    g_useHookPath = kIsPACSlice || g_legacyRenderABI || osv.majorVersion >= 17 ||
        access(kForceHookPath, F_OK) == 0;
    lglog("init: architecture=%s render registration=%s%s",
          kIsPACSlice ? "arm64e/PAC" : "arm64/non-PAC",
          g_useHookPath ? "genuine-descriptor hook" : "cloned descriptor",
          (!kIsPACSlice && g_useHookPath) ? " (forced by marker)" : "");

    if (!LGSymResolverInit()) {
        lglog("init: LGSymResolverInit failed, QuartzCore not loaded yet?");
        return;
    }

    void *stopEnc = logResolveResult("stop_encoders", LGResolve_StopEncoders());
    void *internA = logResolveResult("CAInternAtomWithCString", LGResolve_CAInternAtomWithCString());
    void *addF    = logResolveResult("add_filter", LGResolve_AddFilter());

    // scanned call targets need fresh pac signatures on arm64e
    g_stopEncoders = (StopEncodersFn)LGSymMakeCallable(stopEnc);
    g_internAtom   = (InternAtomFn)LGSymMakeCallable(internA);
    g_addFilter    = (AddFilterFn)LGSymMakeCallable(addF);

    lglog("init: stopEncoders=%p internAtom=%p addFilter=%p", stopEnc, internA, addF);

    if (!stopEnc || !internA || !addF) {
        lglog("init: required symbol(s) unresolved on this build, not activating (no fallback)");
        return;
    }

    g_cmdBufOffset = LGResolve_MetalCmdBufOffset();
    if (g_cmdBufOffset < 0)
        lglog("init: command-buffer offset unresolved, filter registers but custom render pass is skipped");
    else
        lglog("init: MetalContext command-buffer offset = %#lx", (long)g_cmdBufOffset);

    g_renderPipelines =
        new std::unordered_map<NSUInteger, id<MTLRenderPipelineState>>();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, lgClockMaskDidChange,
                                    kClockMaskReloadNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    lgReloadClockMask();

    // [路线B] 监听 SpringBoard 壁纸捕获就绪通知
    lgStartWallpaperObserver();

    registerCustomFilter();

    lglog("ready");
    }
}
