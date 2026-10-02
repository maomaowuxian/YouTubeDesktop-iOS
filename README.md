# YouTube Desktop for iOS

基于 Swift、UIKit 和 WKWebView 的 iPhone YouTube 桌面网页客户端，提供窄屏适配、原生媒体接管、后台音频与画中画。

**当前已提交并验证的基线：2.13 / Build 35。** 本项目按源码构建、自签安装方式使用，是独立的个人实验项目，与 YouTube、Google、Apple 无隶属或认可关系。

- [安装与签名教程](docs/INSTALL.md)
- [详细版本与实验记录](CHANGELOG.md)
- [MIT 许可证](LICENSE)

## 当前功能

| 功能 | 实现与范围 |
|---|---|
| 桌面网页与手机布局 | 桌面 User-Agent；视频页单列；频道页宽度、Tab 和网格适配 |
| 原生后台音频 | 当前视频来源准备好后，在前台由 AVPlayer 接管；锁屏继续使用同一播放器 |
| 耳机与锁屏控制 | 原生媒体会话处理播放、暂停和进度；2.13 验证了约五分钟暂停后的单次耳机恢复 |
| 画中画 | 手动入口使用原生 AVPictureInPictureController |
| 返回网页 | 原生画面提供“返回网页”，同步播放位置及暂停意图 |
| 可跳过广告的自动点击 | 实验功能，只检测已显示的真实跳过按钮；依赖 WebKit 私有 SPI |

## 快速开始

需要 Mac、兼容的 Xcode、Apple 账户和一台 iPhone。工程最低部署目标是 iOS 17.0。

~~~bash
git clone https://github.com/maomaowuxian/YouTubeDesktop-iOS.git
cd YouTubeDesktop-iOS
cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
open YouTubePoC.xcodeproj
~~~

1. 编辑 `Config/LocalSigning.xcconfig`，填入自己的 Team ID 和唯一的 Bundle ID。
2. 在 Xcode 的 Accounts 中登录自己的 Apple 账户。
3. 用数据线连接 iPhone，完成配对、信任和开发者模式设置。
4. 选择 `YouTubePoC` scheme 与自己的 iPhone，点击 Run。

详细操作、图形界面配置方式、免费签名有效期和常见错误见 [安装教程](docs/INSTALL.md)。仓库尚为私有时，克隆需要账号具有访问权限。

## 使用方法

1. 打开 App，选择视频并开始播放。
2. 来源准备好后，播放器出现原生“暂停／返回网页”按钮，即表示原生接管已完成。
3. 此时可锁屏或回桌面继续听音频，耳机和锁屏卡片控制同一个原生播放器。
4. 点击“返回网页”后恢复网页控制；同一视频不会立即重复自动接管。
5. 需要小窗时，在网页播放器使用画中画入口。

原生接管尚未完成时，直接锁屏可能停止网页声音。不要用控制中心卡片存在或按钮变成播放状态来判断是否真的出声。

## 兼容性与已知问题

- 已验证的主要设备是 **iPhone 15 / iOS 18.7.8**，使用 Xcode 16.4 编译。最低部署目标不等于所有 iOS 17 及以上设备都已验证。
- iPhone SE（第二代）已有安装与启动记录；完整播放回归尚未覆盖。
- **2.13 的多音轨交接存在缺口**：部分视频从网页转到原生播放器后可能改用默认音轨。发生时可返回网页播放；后续修复需要独立真机验证。
- 广告阶段、来源未准备好前快速锁屏、复杂换视频、锁屏卡片长暂停恢复和更长暂停未充分验证。
- 网页结构、媒体来源和私有接口可能随 YouTube、iOS 或 WebKit 更新而变化，无法保证长期兼容。
- 模拟器和无签名构建不能替代真机声音、锁屏与蓝牙耳机验证。

## 构建与本地签名

公共工程不固定开发者 Team。Debug 和 Release 都读取 `Config/Signing.xcconfig`，再可选读取不入库的 `Config/LocalSigning.xcconfig`。

默认 Bundle ID 保留历史值 `com.ray.YouTubeIOSPoC`，方便已有安装保持连续；新使用者应在本地配置中填写自己的唯一标识。已有安装更新时，保持原 Team 和 Bundle ID。

不签名的设备构建检查：

~~~bash
xcodebuild -project YouTubePoC.xcodeproj \
  -scheme YouTubePoC -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/Unsigned \
  CODE_SIGNING_ALLOWED=NO build
~~~

这个产物不能直接在 iPhone 上运行。真机安装仍须使用自己的有效签名，具体步骤见 [安装教程](docs/INSTALL.md)。

## 项目结构

| 路径 | 内容 |
|---|---|
| `YouTubePoC/AppDelegate.swift` | 来源验证、原生播放、恢复逻辑、音频会话和生命周期 |
| `YouTubePoC/ViewController.swift` | WKWebView、页面脚本、布局与网页／原生交接 |
| `YouTubePoC/Info.plist` | App 信息和后台音频声明 |
| `Config/` | 共享签名配置、本地配置示例 |
| `docs/INSTALL.md` | 构建、签名、安装与排错 |
| `CHANGELOG.md` | 版本历史及成功、失败实验记录 |

## 更新摘要

| 版本 | 主要变化 |
|---|---|
| 开源准备（未改变 App 版本） | 增加 MIT、安装教程和本地签名配置；整理 README；测试记录不指向具体创作者 |
| 2.13 / 35 | 原生恢复时激活音频会话；零进度时最多重试一次；约299秒暂停后单次耳机恢复通过 |
| 2.12 / 34 | 前台自动接管、来源准备重试、跨解锁保留原生播放器；长暂停曾需双按 |
| 2.11 / 33 | 失活时自动交接实验；真实锁屏测试失败，已被替换 |
| 2.10 / 32 | 前台手动无 PiP 后台音频；约168秒暂停恢复通过 |
| 2.9 / 31 | 原生 AVPlayer 与 PiP 接管；约184.5秒锁屏暂停恢复通过 |
| 2.8 | 原生媒体来源可行性检查，尚未接管声音 |
| 2.7 | 私有媒体客户端注册实验，未成功 |
| 2.6 | 短暂停可恢复，但长暂停失败 |
| 2.5 | 暂停时音频激活被拒绝，控制权未交接 |
| 2.4 | WebKit 媒体命令桥实验，未解决长暂停 |
| 2.3 | 后台调度策略实验，长暂停修复无效 |
| 2.2 | 恢复菜单并实现可跳过广告的自动点击 |
| 2.1 | 修复频道主页窄屏布局 |
| 2.0 | 手动 PiP 后台播放基线 |

完整证据与限制见 [CHANGELOG](CHANGELOG.md)。历史实验中的候选状态不代表当前功能或保证。

## 数据与反馈

App 网页会直接连接 YouTube／Google 及其媒体服务。网页登录状态由 WKWebView 管理；本项目没有自己的账号服务器或分析 SDK。

App 会在设备本地写入 `playback.log` 和 `adskip.log`，用于播放及广告按钮诊断。日志可能包含视频标识、播放进度和音频路由名称；播放日志有大小轮转，广告日志目前没有大小上限。媒体签名地址不应被写入日志。反馈前请自行检查并删除不希望公开的信息，勿上传完整登录状态或凭证。

提交 Issue 时请写明 App 版本、设备、iOS、操作步骤和实际声音／进度表现。请勿把具体创作者、频道或账号作为默认测试示例。

## 许可与项目边界

项目自有代码按 [MIT](LICENSE) 授权，版权署名为 Ray（maomaowuxian）。第三方内容、商标、素材和 Apple SDK 的权利仍归各自权利人，MIT 不授予访问第三方服务的额外权限。

当前保留 WebKit 私有 SPI，包括自动点击及 MediaSource 配置。这是实验实现，**本项目不以 App Store 上架为目标**。源码许可不代表获得 YouTube 服务授权，使用时仍需考虑相关平台条款。

相关说明：[YouTube 服务条款](https://www.youtube.com/static?template=terms)、[YouTube API 开发者政策](https://developers.google.com/youtube/terms/developer-policies)。
