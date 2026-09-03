#import "CCBGMediaManager.h"

static NSString * const kCCBgMediaDirectory = @"/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media";
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
        _mediaDirectory = [kCCBgMediaDirectory copy];
        _imagePath = [[kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgImageFileName] copy];
        _videoPath = [[kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgVideoFileName] copy];
        _thumbPath = [[kCCBgMediaDirectory stringByAppendingPathComponent:kCCBgThumbFileName] copy];
        [self ensureDirectoryExists];
    }
    return self;
}

- (void)ensureDirectoryExists {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_mediaDirectory]) {
        [fm createDirectoryAtPath:_mediaDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
}

#pragma mark - 保存图片

- (void)saveImage:(UIImage *)image completion:(void (^)(BOOL))completion {
    if (!image) {
        if (completion) completion(NO);
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *error = nil;
            BOOL success = YES;

            // 先清除旧视频
            if ([fm fileExistsAtPath:self.videoPath]) {
                [fm removeItemAtPath:self.videoPath error:&error];
            }

            // 保存原图
            NSData *imageData = UIImageJPEGRepresentation(image, kCCBgImageQuality);
            if (!imageData) {
                success = NO;
            } else {
                success = [imageData writeToFile:self.imagePath atomically:YES];
            }

            // 生成缩略图
            if (success) {
                UIImage *thumb = [self generateThumbnailFromImage:image];
                if (thumb) {
                    NSData *thumbData = UIImageJPEGRepresentation(thumb, kCCBgImageQuality);
                    [thumbData writeToFile:self.thumbPath atomically:YES];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(success);
            });
        }
    });
}

#pragma mark - 保存视频

- (void)saveVideoFromURL:(NSURL *)videoURL completion:(void (^)(BOOL))completion {
    if (!videoURL) {
        if (completion) completion(NO);
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *error = nil;
            BOOL success = YES;

            // 先清除旧图片
            if ([fm fileExistsAtPath:self.imagePath]) {
                [fm removeItemAtPath:self.imagePath error:&error];
            }

            // 复制视频
            if ([fm fileExistsAtPath:self.videoPath]) {
                [fm removeItemAtPath:self.videoPath error:nil];
            }
            success = [fm copyItemAtPath:videoURL.path toPath:self.videoPath error:&error];

            // 生成视频首帧缩略图
            if (success) {
                UIImage *thumb = [self generateThumbnailFromVideoURL:[NSURL fileURLWithPath:self.videoPath]];
                if (thumb) {
                    NSData *thumbData = UIImageJPEGRepresentation(thumb, kCCBgImageQuality);
                    [thumbData writeToFile:self.thumbPath atomically:YES];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(success);
            });
        }
    });
}

#pragma mark - 清除

- (void)clearAllMedia {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in @[self.imagePath, self.videoPath, self.thumbPath]) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
        }
    }
}

#pragma mark - 查询

- (UIImage *)currentThumbnail {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:_thumbPath]) {
        return [UIImage imageWithContentsOfFile:_thumbPath];
    }
    return nil;
}

- (BOOL)hasImageBackground {
    return [[NSFileManager defaultManager] fileExistsAtPath:_imagePath];
}

- (BOOL)hasVideoBackground {
    return [[NSFileManager defaultManager] fileExistsAtPath:_videoPath];
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
