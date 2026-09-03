#import "CCBGMediaManager.h"

static NSString * const kCCBgBaseMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
static NSString * const kCCBgImageFileName = @"background.jpg";
static NSString * const kCCBgVideoFileName = @"background.mp4";
static NSString * const kCCBgThumbFileName = @"thumb.jpg";

static const CGFloat kCCBgThumbSize = 120.0;
static const CGFloat kCCBgImageQuality = 0.85;
static const NSTimeInterval kCCBgVideoThumbTime = 0.5;

@implementation CCBGMediaManager

+ (instancetype)sharedManager {
    static CCBGMediaManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CCBGMediaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _baseMediaDirectory = [kCCBgBaseMediaDirectory copy];
        [self ensureBaseDirectoryExists];
    }
    return self;
}

- (void)ensureBaseDirectoryExists {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_baseMediaDirectory]) {
        NSError *error = nil;
        [fm createDirectoryAtPath:_baseMediaDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];
        if (error) {
            NSLog(@"[CCBg] ERROR: Failed to create base media directory '%@': %@", _baseMediaDirectory, error);
        }
    }
    // 确保三个子目录都存在
    for (NSInteger i = 0; i <= 2; i++) {
        [self ensureDirectoryExistsForType:(CCBgMediaType)i];
    }
}

- (void)ensureDirectoryExistsForType:(CCBgMediaType)type {
    NSString *dir = [self mediaDirectoryForType:type];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        NSError *error = nil;
        [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];
        if (error) {
            NSLog(@"[CCBg] ERROR: Failed to create media directory '%@': %@", dir, error);
        }
    }
}

- (NSString *)typeNameForType:(CCBgMediaType)type {
    switch (type) {
        case CCBgMediaTypeFullscreen: return @"fullscreen";
        case CCBgMediaTypeConnect:    return @"connect";
        case CCBgMediaTypeMedia:      return @"media";
    }
    return @"unknown";
}

- (NSString *)mediaDirectoryForType:(CCBgMediaType)type {
    return [_baseMediaDirectory stringByAppendingPathComponent:[self typeNameForType:type]];
}

- (NSString *)imagePathForType:(CCBgMediaType)type {
    return [[self mediaDirectoryForType:type] stringByAppendingPathComponent:kCCBgImageFileName];
}

- (NSString *)videoPathForType:(CCBgMediaType)type {
    return [[self mediaDirectoryForType:type] stringByAppendingPathComponent:kCCBgVideoFileName];
}

- (NSString *)thumbPathForType:(CCBgMediaType)type {
    return [[self mediaDirectoryForType:type] stringByAppendingPathComponent:kCCBgThumbFileName];
}

#pragma mark - 保存图片

- (void)saveImage:(UIImage *)image forType:(CCBgMediaType)type completion:(void (^)(BOOL))completion {
    if (!image) {
        if (completion) completion(NO);
        return;
    }

    NSString *imagePath = [self imagePathForType:type];
    NSString *videoPath = [self videoPathForType:type];
    NSString *thumbPath = [self thumbPathForType:type];
    [self ensureDirectoryExistsForType:type];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *error = nil;
            BOOL success = YES;

            // 先清除旧视频
            if ([fm fileExistsAtPath:videoPath]) {
                [fm removeItemAtPath:videoPath error:&error];
            }

            // 保存原图
            NSData *imageData = UIImageJPEGRepresentation(image, kCCBgImageQuality);
            if (!imageData) {
                NSLog(@"[CCBg] ERROR: UIImageJPEGRepresentation returned nil");
                success = NO;
            } else {
                NSError *writeError = nil;
                success = [imageData writeToFile:imagePath options:NSDataWritingAtomic error:&writeError];
                if (writeError) {
                    NSLog(@"[CCBg] ERROR: Failed to write image to '%@': %@", imagePath, writeError);
                }
            }

            // 生成缩略图
            if (success) {
                UIImage *thumb = [self generateThumbnailFromImage:image];
                if (thumb) {
                    NSData *thumbData = UIImageJPEGRepresentation(thumb, kCCBgImageQuality);
                    [thumbData writeToFile:thumbPath atomically:YES];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(success);
            });
        }
    });
}

#pragma mark - 保存视频

- (void)saveVideoFromURL:(NSURL *)videoURL forType:(CCBgMediaType)type completion:(void (^)(BOOL))completion {
    if (!videoURL) {
        if (completion) completion(NO);
        return;
    }

    NSString *imagePath = [self imagePathForType:type];
    NSString *videoPath = [self videoPathForType:type];
    NSString *thumbPath = [self thumbPathForType:type];
    [self ensureDirectoryExistsForType:type];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *error = nil;
            BOOL success = YES;

            // 先清除旧图片
            if ([fm fileExistsAtPath:imagePath]) {
                [fm removeItemAtPath:imagePath error:&error];
            }

            // 复制视频
            if ([fm fileExistsAtPath:videoPath]) {
                [fm removeItemAtPath:videoPath error:nil];
            }
            success = [fm copyItemAtPath:videoURL.path toPath:videoPath error:&error];
            if (!success && error) {
                NSLog(@"[CCBg] ERROR: Failed to copy video from '%@' to '%@': %@", videoURL.path, videoPath, error);
            }

            // 生成视频首帧缩略图
            if (success) {
                UIImage *thumb = [self generateThumbnailFromVideoURL:[NSURL fileURLWithPath:videoPath]];
                if (thumb) {
                    NSData *thumbData = UIImageJPEGRepresentation(thumb, kCCBgImageQuality);
                    [thumbData writeToFile:thumbPath atomically:YES];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(success);
            });
        }
    });
}

#pragma mark - 清除

- (void)clearMediaForType:(CCBgMediaType)type {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        [self imagePathForType:type],
        [self videoPathForType:type],
        [self thumbPathForType:type]
    ];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
        }
    }
}

- (void)clearAllMedia {
    for (NSInteger i = 0; i <= 2; i++) {
        [self clearMediaForType:(CCBgMediaType)i];
    }
}

#pragma mark - 查询

- (UIImage *)thumbnailForType:(CCBgMediaType)type {
    NSString *thumbPath = [self thumbPathForType:type];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:thumbPath]) {
        return [UIImage imageWithContentsOfFile:thumbPath];
    }
    return nil;
}

- (BOOL)hasImageForType:(CCBgMediaType)type {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self imagePathForType:type]];
}

- (BOOL)hasVideoForType:(CCBgMediaType)type {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self videoPathForType:type]];
}

#pragma mark - 缩略图生成

- (UIImage *)generateThumbnailFromImage:(UIImage *)image {
    if (!image) return nil;

    CGSize originalSize = image.size;
    CGFloat scale = 1.0;

    // 按短边裁剪成正方形
    CGFloat minDim = fmin(originalSize.width, originalSize.height);
    CGRect cropRect = CGRectMake((originalSize.width - minDim) / 2,
                                  (originalSize.height - minDim) / 2,
                                  minDim, minDim);

    // 如果尺寸小于目标尺寸，直接用原尺寸
    if (minDim > kCCBgThumbSize) {
        scale = kCCBgThumbSize / minDim;
    }

    CGSize targetSize = CGSizeMake(kCCBgThumbSize, kCCBgThumbSize);

    UIGraphicsBeginImageContextWithOptions(targetSize, YES, [UIScreen mainScreen].scale);

    // 裁剪并缩放
    CGRect drawRect = CGRectMake(-cropRect.origin.x * scale,
                                  -cropRect.origin.y * scale,
                                  originalSize.width * scale,
                                  originalSize.height * scale);
    [image drawInRect:drawRect];

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return result;
}

- (UIImage *)generateThumbnailFromVideoURL:(NSURL *)videoURL {
    if (!videoURL) return nil;

    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(kCCBgThumbSize * 2, kCCBgThumbSize * 2);

    CMTime time = CMTimeMakeWithSeconds(kCCBgVideoThumbTime, 600);
    NSError *error = nil;
    CGImageRef cgImage = [generator copyCGImageAtTime:time actualTime:nil error:&error];

    if (!cgImage) return nil;

    UIImage *frameImage = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);

    // 裁剪成正方形缩略图
    return [self generateThumbnailFromImage:frameImage];
}

@end
