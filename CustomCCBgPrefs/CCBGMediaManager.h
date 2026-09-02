#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface CCBGMediaManager : NSObject

@property (nonatomic, copy, readonly) NSString *mediaDirectory;
@property (nonatomic, copy, readonly) NSString *imagePath;
@property (nonatomic, copy, readonly) NSString *videoPath;
@property (nonatomic, copy, readonly) NSString *thumbPath;

+ (instancetype)sharedManager;

// 保存图片 + 生成缩略图（异步）
- (void)saveImage:(UIImage *)image
       completion:(void (^)(BOOL success))completion;

// 保存视频 + 生成首帧缩略图（异步）
- (void)saveVideoFromURL:(NSURL *)videoURL
              completion:(void (^)(BOOL success))completion;

// 清除所有媒体
- (void)clearAllMedia;

// 获取当前缩略图
- (UIImage *)currentThumbnail;

// 是否有图片/视频背景
- (BOOL)hasImageBackground;
- (BOOL)hasVideoBackground;

@end
