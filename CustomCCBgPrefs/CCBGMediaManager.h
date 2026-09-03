#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, CCBgMediaType) {
    CCBgMediaTypeFullscreen = 0,   // 全屏背景
    CCBgMediaTypeConnect    = 1,   // 连接模块背景
    CCBgMediaTypeMedia      = 2,   // 播放控制模块背景
};

@interface CCBGMediaManager : NSObject

@property (nonatomic, copy, readonly) NSString *baseMediaDirectory;

+ (instancetype)sharedManager;

// 获取指定类型的目录和文件路径
- (NSString *)mediaDirectoryForType:(CCBgMediaType)type;
- (NSString *)imagePathForType:(CCBgMediaType)type;
- (NSString *)videoPathForType:(CCBgMediaType)type;
- (NSString *)thumbPathForType:(CCBgMediaType)type;
- (NSString *)typeNameForType:(CCBgMediaType)type;

// 保存图片 + 生成缩略图（异步）
- (void)saveImage:(UIImage *)image
           forType:(CCBgMediaType)type
       completion:(void (^)(BOOL success))completion;

// 保存视频 + 生成首帧缩略图（异步）
- (void)saveVideoFromURL:(NSURL *)videoURL
                 forType:(CCBgMediaType)type
              completion:(void (^)(BOOL success))completion;

// 清除指定类型的媒体
- (void)clearMediaForType:(CCBgMediaType)type;

// 清除所有媒体
- (void)clearAllMedia;

// 获取指定类型的缩略图
- (UIImage *)thumbnailForType:(CCBgMediaType)type;

// 是否有图片/视频背景
- (BOOL)hasImageForType:(CCBgMediaType)type;
- (BOOL)hasVideoForType:(CCBgMediaType)type;

@end
