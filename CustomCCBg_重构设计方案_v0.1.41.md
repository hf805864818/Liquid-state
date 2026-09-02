# 控制中心背景（CustomCCBg）重构设计方案

| 项目 | 内容 |
|------|------|
| **版本号** | v0.1.41 |
| **基础版本** | v0.1.39b |
| **文档版本** | v1.1 |
| **更新日期** | 2026-09-02 |
| **变更类型** | 功能增强 + 界面重构 |

### 版本变更说明

| 版本 | 日期 | 变更内容 |
|------|------|----------|
| v0.1.41 | 2026-09-02 | 在 v0.1.40 基础上补充：视频静音处理（默认静音）、模块级视频降分辨率优化、性能参数表更新 |
| v0.1.40 | 2026-09-02 | 界面重构对齐对方样式；新增连接模块背景、播放控制模块背景、展开态模块背景；修复全屏背景层级问题；升级照片选择器为 PHPicker；新增缩略图预览和处理中 HUD；新增模块级视频降分辨率优化 |

---

## 一、目标

参照对方版本的界面样式和交互体验，重构我们的控制中心背景功能，实现：

1. **界面风格对齐**：页面布局、按钮样式、分组方式与对方一致
2. **缩略图预览**：选择背景按钮右侧显示当前背景的缩略图
3. **处理中 HUD**：图片/视频保存时显示"处理中..."加载弹窗
4. **现代照片选择器**：使用 `PHPickerViewController`（iOS 14+），支持同时选择图片和视频
5. **视频缩略图生成**：视频背景自动生成首帧缩略图
6. **文件路径跳转**：支持跳转到指定文件路径（Filza）
7. **全屏背景层级修复**：背景与控制中心同步显示/消失，不漏到桌面
8. **连接模块背景**：左上角连接模块单独显示背景（关闭全屏背景时生效）
9. **播放控制模块背景**：右上角媒体播放模块单独显示背景（关闭全屏背景时生效）
10. **展开态模块背景**：点击模块展开后，展开的大模块内部显示背景

---

## 二、三种背景模式总览

| 模式 | 说明 | 场景 |
|------|------|------|
| 全屏背景 | 背景铺满整个控制中心 | 默认模式，效果最炫 |
| 模块级背景 | 每个独立小模块都有背景 | 高级选项，精致效果 |
| 特定模块背景 | 只有连接/播放控制这2个模块有背景 | 新增，简约不花哨 |

**优先级**：全屏背景开关 > 特定模块背景

- 全屏背景开启 → 整个控制中心显示背景，特定模块背景设置不生效
- 全屏背景关闭 → 只有连接/播放控制模块显示背景（如果对应开关打开）

---

## 三、页面结构设计

### 3.1 页面布局（从上到下）

```
┌─────────────────────────────────────────┐
│  ← 控制中心    控制中心背景    注销    │  ← 导航栏
├─────────────────────────────────────────┤
│  全局开关                                │  ← 分组标题
│  ┌───────────────────────────────────┐  │
│  │ 开启自定义控制中心背景        [●] │  │  ← 总开关（全屏背景）
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  背景设置                                │  ← 分组标题
│  ┌───────────────────────────────────┐  │
│  │ 选择控制中心背景 (图片/视频) [🖼] │  │  ← 带缩略图的按钮
│  ├───────────────────────────────────┤  │
│  │ 清除背景                          │  │
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  背景模糊度调节                          │  ← 分组标题
│  ┌───────────────────────────────────┐  │
│  │ ──●────────────  0.30            │  │  ← 滑块 + 数值
│  └───────────────────────────────────┘  │
│  调整控制中心背景的毛玻璃强度           │  ← footer 说明
├─────────────────────────────────────────┤
│  特定模块背景                            │  ← 新增分组
│  ┌───────────────────────────────────┐  │
│  │ 连接模块背景                   [●]│  │  ← 开关
│  ├───────────────────────────────────┤  │
│  │ 播放控制模块背景                [ ]│  │  ← 开关
│  └───────────────────────────────────┘  │
│  关闭全屏背景时生效，仅在指定模块内显示背景 │  ← footer 说明
├─────────────────────────────────────────┤
│  高级选项                                │  ← 分组标题
│  ┌───────────────────────────────────┐  │
│  │ 背景模式选择                      │  │
│  ├───────────────────────────────────┤  │
│  │ 跳转 Filza 路径                   │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

### 3.2 与当前版本的差异

| 项目 | 当前 | 重构后 |
|------|------|--------|
| 背景模式选择 | 独立分组 | 移入高级选项 |
| 缩略图预览 | 无 | 选择背景按钮右侧显示 |
| 处理中 HUD | 无 | 保存图片/视频时显示 |
| 照片选择器 | UIImagePickerController + ActionSheet | PHPickerViewController（直接打开） |
| 视频缩略图 | 无 | 自动生成首帧 |
| 连接模块背景 | 无 | 新增 |
| 播放控制模块背景 | 无 | 新增 |
| 展开态模块背景 | 无 | 新增（模块展开时内部显示背景） |

---

## 四、核心功能模块设计

### 4.1 缩略图预览系统

**文件存储结构**：
```
/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media/
├── background.jpg      ← 图片背景原图
├── background.mp4      ← 视频背景原文件
└── thumb.jpg           ← 缩略图（图片/视频共用）
```

**缩略图生成规则**：
- 图片背景：将原图缩放到 120x120（正方形裁剪）
- 视频背景：用 `AVAssetImageGenerator` 提取第 0.5 秒首帧，缩放到 120x120
- 清除背景时一并删除缩略图

**UI 展示方式**：
- 自定义 cell（`PSButtonCell` + 自定义 `UIImageView`）
- 按钮文字左对齐，缩略图在右侧，圆形/圆角显示
- 没有背景时不显示缩略图

### 4.2 处理中 HUD

**触发时机**：
- 选择图片后，保存 + 生成缩略图期间
- 选择视频后，复制 + 生成首帧缩略图期间

**HUD 样式**：
- 毛玻璃圆角弹窗（`UIVisualEffectView`）
- 上方：`UIActivityIndicatorView` 菊花
- 下方：文字 "处理中..."
- 居中显示，不可交互

**实现方式**：
- 用一个 `CCBGProgressHUD` 工具类
- 类方法 `+ (void)showInView:(UIView *)view text:(NSString *)text`
- 类方法 `+ (void)dismissFromView:(UIView *)view`
- 处理完成后自动消失

### 4.3 现代照片选择器

**使用 PHPickerViewController 的原因**：
- iOS 14+ 官方推荐，不需要申请完整相册权限
- 用户可以只授权部分照片，隐私友好
- 支持同时选择图片和视频，不需要先弹窗选类型
- 对方版本也在用

**配置**：
```objc
PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
    [PHPickerFilter imagesFilter],
    [PHPickerFilter videosFilter]
]];
config.selectionLimit = 1; // 单选
```

**兼容性处理**：
- iOS 14 及以上：使用 `PHPickerViewController`
- iOS 13 及以下：降级使用 `UIImagePickerController`

### 4.4 文件路径跳转

**支持两种跳转**：

| 功能 | URL Scheme | 说明 |
|------|-----------|------|
| 跳转到媒体目录 | `filza:///var/mobile/Library/.../ccbg.media/` | 已有功能，保持 |
| 跳转到指定文件 | `filza://<path>` | 通用方法，支持传入任意路径 |

**实现**：
```objc
- (void)openFilzaWithPath:(NSString *)path {
    NSString *urlStr = [@"filza://" stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        // 提示未安装 Filza
    }
}
```

### 4.5 特定模块背景（新增）

#### 4.5.1 功能说明

当全屏背景关闭时，可以单独为以下模块开启背景：

| 模块 | 说明 | 对应类 |
|------|------|--------|
| 连接模块 | 左上角飞行模式/蜂窝/WiFi/蓝牙/隔空投送/热点 | `CCUINetworkTransportModule` 或类似 |
| 播放控制模块 | 右上角媒体播放控制 | `CCUIMediaControlsModule` 或类似 |

效果：只有这两个模块内部显示背景图/视频，其他模块还是系统默认毛玻璃。

#### 4.5.2 实现思路

```
控制中心布局：
┌───────────────────────────────────────────┐
│  [连接模块 □]         [播放控制模块 □]   │  ← 这2个模块内有背景
│  ┌──────────┐         ┌──────────┐       │
│  │ 背景图/视频│         │ 背景图/视频│      │
│  │ + 毛玻璃  │         │ + 毛玻璃  │      │
│  └──────────┘         └──────────┘       │
│                                           │
│  [锁定] [镜像] [亮度] [音量] ...          │  ← 其他模块正常
└───────────────────────────────────────────┘
```

**关键技术点**：
1. 找到对应的模块容器视图（`CCUIContentModuleContainerView` 或具体模块类）
2. 在模块内部插入背景层（模块层级，不是全屏）
3. 背景内容与模块 frame 一致，跟随模块大小变化
4. 共享同一个视频播放器（如果是视频背景），避免重复解码

#### 4.5.3 模块识别方式

通过以下方式识别目标模块：
- **类名匹配**：判断模块的类名是否包含关键词（如 "Network"、"Media"、"NowPlaying"）
- **子视图特征**：根据模块内的子视图结构判断（如是否有音量滑块、播放按钮等）
- **模块标识符**：通过 `moduleIdentifier` 或类似属性识别（如果可用）

### 4.6 展开态模块背景（新增）

#### 4.6.1 功能说明

当用户点击某个模块将其展开（变大）时，展开后的大模块**内部**显示背景图/视频。

效果示意：
```
点击前（小模块）：              点击后（展开态）：
┌──────────────┐               ┌──────────────────────┐
│ [连接模块]    │               │  背景图/视频          │
│              │    点击 →     │  + 毛玻璃            │
│  系统毛玻璃   │               │                      │
│              │               │  飞行模式 蜂窝 ...    │
└──────────────┘               │                      │
                               │  WiFi 蓝牙 ...        │
                               │                      │
                               └──────────────────────┘
```

#### 4.6.2 实现思路

1. **监听模块展开/收起**：hook 模块展开的方法（如 `willExpand`、`didExpand`、`setExpanded:` 等）
2. **展开时**：在展开的模块视图内部插入背景层
3. **收起时**：移除背景层（或隐藏）
4. **背景适配**：背景 frame 跟随展开后的模块大小，支持圆角裁剪

#### 4.6.3 展开态背景的层级

```
展开的模块视图：
┌──────────────────────────────────┐
│  模块内容（图标、文字、滑块等）   │  ← 最上层
├──────────────────────────────────┤
│  系统毛玻璃（MTMaterialView）    │  ← 隐藏或透明化
├──────────────────────────────────┤
│  我们的背景层（图片/视频）       │  ← 插入这里
├──────────────────────────────────┤
│  模块容器背景                    │  ← 最底层
└──────────────────────────────────┘
```

**方案**：在展开的模块视图中找到 `MTMaterialView`，隐藏它，然后在它下面插入我们的背景层。和全屏背景的思路一样，只是作用域从"整个控制中心"变成了"单个展开模块"。

#### 4.6.4 与全屏/特定模块背景的关系

| 全屏背景 | 特定模块背景 | 展开态背景 | 效果 |
|---------|------------|-----------|------|
| ✅ 开 | 任意 | 任意 | 全屏背景（优先级最高） |
| ❌ 关 | ✅ 连接模块 | 点击连接模块展开 | 展开态显示背景（和特定模块共用一套背景） |
| ❌ 关 | ✅ 播放控制 | 点击播放控制展开 | 展开态显示背景 |
| ❌ 关 | ❌ 都关 | 点击任意模块 | 不显示背景 |

**结论**：展开态背景不需要单独的开关，它是"特定模块背景"的自然延伸——哪个模块开了背景，展开后就继续显示背景。

---

## 五、全屏背景层级修复方案

### 5.1 问题根因

当前我们把背景插在 `CCUIModularControlCenterOverlayViewController.view` 的 `index:0`，但控制中心本身有一层系统毛玻璃背景（`MTMaterialView`）挡在前面，而且控制中心收起时我们的背景视图没有及时隐藏，导致背景留在桌面上。

### 5.2 修复方案

**方案：替换系统背景层**

```
控制中心视图层级（修复后）：
┌─────────────────────────────────┐
│ CCUIModularControlCenter...view │
├─────────────────────────────────┤
│  我们的背景视图                  │  ← 替换 MTMaterialView 的位置
│  (视频/图片 + 可选模糊)         │
├─────────────────────────────────┤
│  各个控制模块                    │  ← 模块自带毛玻璃，透出底下的背景
└─────────────────────────────────┘
```

**实现步骤**：
1. 在 `viewWillAppear:` 中遍历 `self.view.subviews`，找到 `MTMaterialView`（控制中心的毛玻璃背景层）
2. 将我们的 `bgContainerView` 插入到 `MTMaterialView` 的位置（同一层级，替换它的视觉作用）
3. 将 `MTMaterialView` 设为隐藏（`hidden = YES`）
4. 在 `viewWillDisappear:` 中恢复 `MTMaterialView` 可见，并隐藏我们的背景

### 5.3 同步显示/消失

```objc
// 控制中心出现时
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[CustomCCBgManager sharedInstance] attachAndShow];
}

// 控制中心消失时
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [[CustomCCBgManager sharedInstance] hideAndDetach];
}
```

---

## 六、重要参数配置表

> 所有可调参数集中在此，方便后期修改和排查问题。

### 6.1 基础参数

| 参数名 | 默认值 | 类型 | 说明 | 所在文件 |
|--------|--------|------|------|----------|
| `kCCBgPreferencesDomain` | `dylv.Deepliquid.ccbg` | NSString | 偏好设置域名 | Tweak.x / CCBGRootListController.m |
| `kCCBgEnabledKey` | `Enabled` | NSString | 总开关 key | Tweak.x |
| `kCCBgBlurAlphaKey` | `BlurAlpha` | NSString | 模糊度 key | Tweak.x |
| `kCCBgBackgroundModeKey` | `BackgroundMode` | NSString | 背景模式 key（0=全屏, 1=模块级） | Tweak.x |
| `kCCBgReloadNotification` | `dylv.Deepliquid.ccbg/ReloadPrefs` | NSString | 刷新通知名 | Tweak.x / CCBGRootListController.m |
| `kCCBgMediaDirectory` | `/var/mobile/Library/Preferences/dylv.Deepliquid.ccbg.media` | NSString | 媒体文件目录 | Tweak.x / CCBGMediaManager.m |
| `kCCBgImageFileName` | `background.jpg` | NSString | 图片背景文件名 | 同上 |
| `kCCBgVideoFileName` | `background.mp4` | NSString | 视频背景文件名 | 同上 |
| `kCCBgThumbFileName` | `thumb.jpg` | NSString | 缩略图文件名 | 同上 |

### 6.2 特定模块背景参数

| 参数名 | 默认值 | 类型 | 说明 | 所在文件 |
|--------|--------|------|------|----------|
| `kCCBgConnectModuleEnabledKey` | `ConnectModuleBgEnabled` | NSString | 连接模块背景开关 key | Tweak.x |
| `kCCBgMediaModuleEnabledKey` | `MediaModuleBgEnabled` | NSString | 播放控制模块背景开关 key | Tweak.x |

### 6.3 性能优化参数

| 参数名 | 默认值 | 类型 | 说明 | 所在文件 |
|--------|--------|------|------|----------|
| `kCCBgTargetVideoFPS` | `30` | NSInteger | 视频背景目标帧率 | Tweak.x |
| `kCCBgBlurDownscaleFactor` | `0.5` | CGFloat | 模糊降采样比例（0.5 = 缩放到 1/2 再模糊） | Tweak.x |
| `kCCBgMaxBlurRadius` | `20.0` | CGFloat | 最大模糊半径（blurAlpha=1 时对应的值） | Tweak.x |
| `kCCBgBlurRadiusTolerance` | `0.5` | CGFloat | 模糊半径缓存容差（小于此值不重新渲染） | Tweak.x |
| `kCCBgDeferredReleaseDelay` | `10.0` | NSTimeInterval | 控制中心关闭后延迟释放视频资源的时间（秒） | Tweak.x |
| `kCCBgVideoMuted` | `YES` | BOOL | 视频背景是否静音（默认静音，避免与系统音量冲突） | Tweak.x |
| `kCCBgModuleVideoDownscaleEnabled` | `YES` | BOOL | 模块级视频降分辨率开关（开启后模块视频以较低分辨率解码，省电） | Tweak.x |
| `kCCBgModuleVideoMaxWidth` | `480` | NSInteger | 模块级视频最大解码宽度（像素），超过则等比缩放到此宽度 | Tweak.x |
| `kCCBgImageQuality` | `0.85` | CGFloat | 图片保存的 JPEG 质量 | CCBGMediaManager.m |

### 6.4 UI 参数

| 参数名 | 默认值 | 类型 | 说明 | 所在文件 |
|--------|--------|------|------|----------|
| `kCCBgThumbSize` | `120.0` | CGFloat | 缩略图尺寸（正方形，像素） | CCBGMediaManager.m |
| `kCCBgThumbCornerRadius` | `60.0` | CGFloat | 缩略图圆角（= 尺寸/2 就是圆形） | CCBGRootListController.m |
| `kCCBgDefaultBlurAlpha` | `0.3` | CGFloat | 默认模糊度 | CCBGRootListController.m |
| `kCCBgMinBlurAlpha` | `0.0` | CGFloat | 最小模糊度 | 同上 |
| `kCCBgMaxBlurAlpha` | `1.0` | CGFloat | 最大模糊度 | 同上 |
| `kCCBgHUDShowDuration` | `0.25` | NSTimeInterval | HUD 出现动画时长 | CCBGProgressHUD.m |
| `kCCBgHUDDismissDuration` | `0.25` | NSTimeInterval | HUD 消失动画时长 | CCBGProgressHUD.m |

### 6.5 动画时序参数

| 参数名 | 默认值 | 类型 | 说明 | 所在文件 |
|--------|--------|------|------|----------|
| `kCCBgCCDismissAnimationDuration` | `0.35` | NSTimeInterval | 控制中心收起动画时长（用于延迟恢复系统背景） | Tweak.x |
| `kCCBgVideoThumbTime` | `0.5` | NSTimeInterval | 视频缩略图截取时间点（秒） | CCBGMediaManager.m |

### 6.6 模块识别参数

| 参数名 | 默认值 | 类型 | 说明 | 所在文件 |
|--------|--------|------|------|----------|
| `kCCBgConnectModuleKeywords` | `@[@"Network", @"Connect", @"WiFi"]` | NSArray | 连接模块类名关键词 | Tweak.x |
| `kCCBgMediaModuleKeywords` | `@[@"Media", @"NowPlaying", @"Playback"]` | NSArray | 播放控制模块类名关键词 | Tweak.x |
| `kCCBgExpandModuleMinSizeRatio` | `0.6` | CGFloat | 模块展开后最小宽高比阈值（用于判断是否展开态） | Tweak.x |

---

## 七、代码结构调整

### 7.1 文件清单

```
CustomCCBg/
├── Tweak.x                    ← 主 hook 逻辑（重构：全屏修复 + 特定模块 + 展开态）
├── CustomCCBg.plist
├── Makefile
└── icon*.png

CustomCCBgPrefs/
├── CCBGRootListController.h    ← 头文件
├── CCBGRootListController.m    ← 主控制器（重构：UI + 交互）
├── CCBGProgressHUD.h           ← 新增：处理中 HUD
├── CCBGProgressHUD.m
├── CCBGMediaManager.h          ← 新增：媒体文件管理
├── CCBGMediaManager.m
├── CCBGModuleDetector.h        ← 新增：模块识别工具
├── CCBGModuleDetector.m
└── Resources/
    ├── entry.plist
    ├── Info.plist
    └── icon*.png
```

### 7.2 新增类说明

#### CCBGMediaManager（媒体管理器）

**职责**：统一管理背景图片/视频的保存、读取、缩略图生成

```objc
@interface CCBGMediaManager : NSObject
@property (nonatomic, copy, readonly) NSString *mediaDirectory;
@property (nonatomic, copy, readonly) NSString *imagePath;
@property (nonatomic, copy, readonly) NSString *videoPath;
@property (nonatomic, copy, readonly) NSString *thumbPath;

+ (instancetype)sharedManager;

- (void)saveImage:(UIImage *)image
       completion:(void (^)(BOOL success))completion;

- (void)saveVideoFromURL:(NSURL *)videoURL
              completion:(void (^)(BOOL success))completion;

- (void)clearAllMedia;
- (UIImage *)currentThumbnail;
- (BOOL)hasImageBackground;
- (BOOL)hasVideoBackground;
@end
```

#### CCBGProgressHUD（处理中 HUD）

```objc
@interface CCBGProgressHUD : UIView
+ (void)showInView:(UIView *)view text:(NSString *)text;
+ (void)dismissFromView:(UIView *)view;
@end
```

#### CCBGModuleDetector（模块识别工具）

**职责**：根据类名/子视图特征识别控制中心的各个模块

```objc
@interface CCBGModuleDetector : NSObject

// 判断是否为连接模块
+ (BOOL)isConnectModule:(UIView *)view;

// 判断是否为播放控制模块
+ (BOOL)isMediaModule:(UIView *)view;

// 判断模块是否处于展开态
+ (BOOL)isModuleExpanded:(UIView *)moduleView;

// 获取模块的 MTMaterialView（用于隐藏系统毛玻璃）
+ (UIView *)findMaterialViewInView:(UIView *)view;

@end
```

### 7.3 CustomCCBgManager 新增方法

```objc
@interface CustomCCBgManager : NSObject
// ... 已有方法 ...

// 特定模块背景
- (void)attachBackgroundToConnectModule:(UIView *)moduleView;
- (void)attachBackgroundToMediaModule:(UIView *)moduleView;
- (void)detachBackgroundFromModule:(UIView *)moduleView;

// 展开态模块背景
- (void)attachBackgroundToExpandedModule:(UIView *)expandedModule;
- (void)detachBackgroundFromExpandedModule:(UIView *)expandedModule;

// 状态查询
@property (nonatomic, assign, readonly) BOOL connectModuleBgEnabled;
@property (nonatomic, assign, readonly) BOOL mediaModuleBgEnabled;
@end
```

### 7.4 CCBGRootListController specifiers 结构

```
分组1：全局开关
  └── 开启自定义控制中心背景 (PSSwitchCell)

分组2：背景设置
  ├── 选择控制中心背景 (图片/视频) (自定义 cell，带缩略图)
  └── 清除背景 (PSButtonCell)

分组3：背景模糊度调节
  └── BlurAlpha 滑块 (PSSliderCell) + 右侧数值显示
  Footer：调整控制中心背景的毛玻璃强度

分组4：特定模块背景
  ├── 连接模块背景 (PSSwitchCell)
  └── 播放控制模块背景 (PSSwitchCell)
  Footer：关闭全屏背景时生效，仅在指定模块内显示背景

分组5：高级选项
  ├── 背景模式选择 (PSButtonCell)
  └── 跳转 Filza 路径 (PSButtonCell)
```

---

## 八、Tweak.x Hook 清单

### 8.1 全屏背景相关

| Hook 类 | Hook 方法 | 用途 |
|---------|----------|------|
| `CCUIModularControlCenterOverlayViewController` | `viewWillAppear:` | 控制中心出现，显示全屏背景 |
| `CCUIModularControlCenterOverlayViewController` | `viewDidAppear:` | 确认可见状态 |
| `CCUIModularControlCenterOverlayViewController` | `viewWillDisappear:` | 控制中心消失，隐藏全屏背景 |
| `CCUIModularControlCenterOverlayViewController` | `viewDidDisappear:` | 确认不可见状态 |
| `CCUIModularControlCenterOverlayViewController` | `dealloc` | 清理资源 |

### 8.2 特定模块背景相关

| Hook 类 | Hook 方法 | 用途 |
|---------|----------|------|
| `CCUIContentModuleContainerView` | `layoutSubviews` | 模块布局更新，更新背景 frame |
| `CCUIContentModuleContainerView` | `didMoveToWindow` | 模块出现时挂载背景 |

### 8.3 展开态模块背景相关

| Hook 类 | Hook 方法 | 用途 |
|---------|----------|------|
| `CCUIContentModuleContainerView` 或具体模块类 | `setExpanded:` / `willExpand` / `didExpand` | 模块展开/收起时切换背景 |

> **注意**：展开态相关的具体 hook 方法名需要在实际设备上通过 class-dump 或调试确认，不同 iOS 版本可能有差异。

---

## 九、实施步骤

### Phase 1：界面重构（偏好设置）
1. 新增 `CCBGProgressHUD` 类
2. 新增 `CCBGMediaManager` 类
3. 重构 `CCBGRootListController`：
   - 调整分组顺序和内容（新增"特定模块背景"分组）
   - 添加缩略图显示
   - 集成 PHPickerViewController
   - 添加处理中 HUD
   - 背景模式移入高级选项

### Phase 2：全屏背景修复
1. 实现查找 `MTMaterialView` 的工具方法
2. 修改 `attachToHostView:` 插入到正确层级
3. 修改 `setControlCenterVisible:` 立即显示/隐藏背景
4. 恢复系统背景的时机处理

### Phase 3：特定模块背景
1. 新增 `CCBGModuleDetector` 工具类
2. 实现连接模块背景挂载逻辑
3. 实现播放控制模块背景挂载逻辑
4. 新增对应的偏好设置开关
5. 共享视频播放器，避免重复解码

### Phase 4：展开态模块背景
1. 确认展开/收起的 hook 方法
2. 实现展开态背景挂载/移除逻辑
3. 与特定模块背景联动（哪个模块开了背景，展开就显示）
4. 背景跟随模块尺寸变化

### Phase 5：联调测试
1. 全屏背景：显示/消失同步、模糊度调节
2. 特定模块背景：连接模块 + 播放控制模块分别测试
3. 展开态背景：展开显示、收起隐藏、尺寸适配
4. 图片/视频切换：缩略图、HUD、保存清除
5. 各开关组合测试（全开/全关/混合）
6. 性能测试：内存占用、CPU/GPU 使用率

---

## 十、保留的优化特性

对方版本没有的优化，我们继续保留：

| 优化项 | 状态 | 说明 |
|--------|------|------|
| 图片预渲染模糊 | 保留 | 比系统实时模糊更省电 |
| 视频 30fps 限制 | 保留 | 降低解码功耗 |
| **视频静音** | 保留 | 默认静音，避免与系统媒体音量冲突 |
| 模糊降采样 | 保留 | GPU 计算量减少 75% |
| 延迟释放资源 | 保留 | 控制中心关闭 10s 后释放视频 |
| **模块级视频降分辨率** | 新增 | 模块视频以 480p 解码，省电且不影响视觉 |
| 模块级背景模式 | 保留（高级选项） | 我们独有的功能 |
| 布局节流去重 | 保留 | 避免重复更新 |

---

## 十一、参考对方版本的类/方法

| 对方 | 我们对应 | 说明 |
|------|---------|------|
| `CustomCCBgRootListController` | `CCBGRootListController` | 主控制器 |
| `chooseGlobalMedia:` | `chooseMedia:` | 选择媒体 |
| `clearGlobalMedia:` | `clearMedia:` | 清除媒体 |
| `openFilzaPath:` | `openFilzaPath:` | 跳转 Filza |
| `global_bg.jpg` / `global_bg.mp4` | `background.jpg` / `background.mp4` | 媒体文件名 |
| `global_thumb.jpg` | `thumb.jpg` | 缩略图文件名 |
| `PHPickerViewController` | `PHPickerViewController` | 现代照片选择器 |
| `AVAssetImageGenerator` | `AVAssetImageGenerator` | 视频首帧生成 |
