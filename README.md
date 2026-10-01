# YouTube Desktop for iOS

一个基于 `WKWebView` 的 iPhone YouTube 桌面版封装项目。

当前版本：**2.9 / Build 31**。网页内播放由 WKWebView 负责，进入画中画后由原生 AVPlayer 接管。已在 iPhone 15 / iOS 18.7.8 上验证锁屏耳机暂停约 3 分钟后恢复，声音与进度正常。下方 2.3～2.8 记录为历史验证过程，当前实现以 2.9 为准。

## 2.0 基线功能

- YouTube 桌面版页面
- 视频页单列 / 手机宽度布局适配
- 画中画（PiP）
- iOS 原生全屏播放
- PiP 状态下稳定后台音频播放
- PiP 状态下使用系统媒体卡片 / 耳机控制
- 自定义 App 图标

## 2.1

- 修复 YouTube 频道 / 博主主页在 iPhone 上仍按桌面宽度排版导致的横向裁切。
- 频道资料区和 Tab 栏限制在手机视口内，Tab 可横向滚动。
- 频道视频列表在窄屏下改为两列自适应网格。

## 2.2

- 恢复左上角汉堡菜单：保留 YouTube 原生 guide drawer，仅隐藏常驻 mini-guide，手机端仍保持全宽布局。
- 自动跳过 YouTube 可跳过广告：检测到真实“跳过”按钮后，由 WKWebView 原生点击 SPI 触发用户交互点击。
- 真机日志已验证自动跳过事件链为 `mousedown -> mouseup -> click`，且 `isTrusted = true`，两次测试均返回 `success=true`。
- 自动跳过功能带本地持久日志 `Documents/adskip.log`，便于后续诊断。
- 自动跳广告依赖运行时可用的 WebKit 私有 SPI；不可用时会自动保持原有手工跳过行为，不影响正常播放。

## 2.3 / Build 16（已确认长暂停修复无效）

- 曾尝试在 PiP 存续期间将公开 API `WKPreferences.inactiveSchedulingPolicy` 设置为 `.none`，离开 PiP 后恢复原策略；180 秒真机复测证明该措施未解决恢复问题。
- 不接管 RemoteCommand、不伪装网页可见性、不添加后台自动播放或静音音轨。
- 音频会话在开始/恢复播放时激活，记录音频中断原因并处理媒体服务重置；用户暂停后不自动调用 `video.play()`。iOS 16 起不再依赖旧的 `wasSuspended` 中断通知。
- 新增可在锁屏期间写入的 `Documents/playback.log`，记录 PiP、暂停/播放、稀疏进度、音频路由和中断，单文件上限约 512 KiB 并保留一个历史文件。
- 本版本需在未连接调试器的 iPhone 15 / iOS 18.7.8 上完成长暂停复测后，才能标记为稳定基线。

复测步骤：播放视频 → 手动进入 PiP → 锁屏 → 耳机柄暂停 → 等待 90 秒后耳机柄播放；再分别测试暂停 3 分钟后用锁屏卡片播放、退出 PiP、普通暂停不自行恢复、蓝牙断开不强制外放。

## 2.4 / Build 17（已确认长暂停失败，命令未进入桥接）

- 用户真机复测确认 2.3：PiP 锁屏暂停 180 秒后，耳机不能恢复；锁屏卡片变成播放中仍无声。
- 2.3 日志确认 `.none` 设置生效，但 pause 之后没有任何 play/playing/progress；撤掉该无效策略及 App 主进程在网页播放时反复 `setActive(true)` 的逻辑。
- 仅在 PiP 存续期间注册耳机/锁屏 play、pause、toggle 命令，转给 WebKit iOS 18 原生媒体会话 SPI：`_playPredominantOrNowPlayingMediaSession:` / `_pauseNowPlayingMediaSession:`。
- 不调用 JS `video.play()`，不自行写入乐观的锁屏播放状态；退出 PiP 后撤销本版的命令处理。
- 每次用户命令最多使用 6 秒有界后台任务保护 IPC 与诊断，不长期保活暂停播放器。
- `playback.log` 的 REMOTE 记录分别包含命令入口、WebKit 接受结果、原生媒体状态与两次媒体时间采样。SPI 接受成功不代表已出声，进度不前进会明确记为未验证。
- SPI 运行时不可用时不安装本版命令处理，保留原有 PiP 行为。
- 尚待真实耳机和媒体卡 180 秒锁屏暂停复测；稳定基线仍为 2.2/15。

## 2.5 / Build 18（已确认短暂停失败，后台激活被拒绝）

- 2.4 真机复测仍失败。日志确认 PiP 处理器已安装，但暂停和后续播放没有任何 REMOTE 入口记录；尚未实际验证原生 SPI 能否恢复长暂停。
- 曾尝试在 PiP 视频实际暂停后激活 App 非混音音频会话再发布 NowPlaying；实测激活被 iOS 拒绝，导致发布流程提前返回，控制权交接没有发生。
- 开始恢复时先释放 App 的暂停控制会话，再通过 2.4 的 WebKit 原生媒体接口恢复，避免主进程在网页有声播放期间反复抢占音频。
- 退出 PiP 时撤销本版命令处理、清除 App 发布的媒体信息并释放控制会话。
- 新日志区分 `CONTROL audio session claimed`、`CONTROL paused NowPlaying published`、`REMOTE RECEIVED`、原生接口 accepted 和实际进度采样。
- 媒体信息只按真实暂停/playing/进度事件更新，不在收到播放命令时直接标记为播放中。
- 尚待短暂停命令路由及 180 秒锁屏恢复真机复测，稳定基线仍为 2.2/15。

## iOS 后台播放说明

在当前 iOS / WKWebView 实现中，稳定后台播放依赖系统 PiP 媒体会话。播放视频后先点击播放器中的 **“画中画 / 后台播放”** 按钮进入 PiP，再回到桌面即可持续播放。直接从普通 inline 播放状态退出 App，iOS 会暂停 WKWebView 视频。

2.0 已移除自动跳广告、后台强制续播、可见性伪装、程序化后台 PiP、RemoteCommand 播放桥等未形成稳定方案的实验代码。

## 2.6 / Build 19（短暂停通过、180 秒失败，命令仍未进入 App）

- 2.5 在 PiP → 锁屏 → 耳机暂停 → 等待 10 秒 → 耳机播放时仍无声。
- 日志确认暂停时 App 的 `setActive(true)` 返回 `560557684 / cannotInterruptOthers`；原代码因这一失败提前返回，完全没有发布 App 的 NowPlaying 信息，后续也没有 REMOTE 命令入口。
- 移除 App 主进程的暂停激活/恢复释放逻辑。在进入 PiP 时即发布原生 NowPlaying 信息，暂停更新不再依赖后台音频会话激活；实际声音仍由 WebKit/GPU 播放。
- 控制信息的播放速度来自实际媒体状态与进度证据，收到播放命令时不直接写入“正在播放”。日志新增发布事件、速度、进度和 App 前后台状态。
- 原生媒体 SPI 与命令进度诊断保留。发布成功仅表明控制信息已提交，不能据此认定系统命令路由或播放恢复成功。
- 先复测短暂停能否出声、进度前进；通过后再复测 180 秒。稳定基线仍为 2.2/15，未提交 Git。

## 2.7 / Build 20（短暂停通过，原生注册路线未成功）

- 2.6 用户实测 10 秒暂停恢复通过、180 秒失败。日志显示两种操作都没有任何 REMOTE 入口；短暂停由 WebKit 原路径恢复，不能视为 App 原生桥接成功。
- 长暂停后无播放/进度事件，回前台后集中出现播放/暂停事件。这与后台挂起和延迟处理相符；缺少系统进程状态证据，不能仅凭 App 日志断言具体哪个进程被挂起。
- 新增运行时守卫的 MediaRemote 客户端注册（系统 eligibility、实际 playback state、可见性），采用 WebKit 上游的函数签名，继续由 WebKit/GPU 播放实际音频。
- 在实际 PiP 播放状态改变后查询系统当前 NowPlaying 客户端 PID，与 App PID 对比；先核对是否真正选中 App，再验证耳机/锁屏命令入口和进度。
- 私有函数不存在时保留原路径；发布/注册返回值均不代表播放恢复成功。退出 PiP 后撤销本版注册，不添加静音音轨或长期后台任务。
- 尚待真机能力、控制权交接及 180 秒测试；稳定基线仍为 2.2/15，未提交 Git。

## 2.8 / Build 24（原生音频来源可行性验证，长暂停仍未修复）

- 2.7 用户短暂停出声、进度正常，但日志仍无 REMOTE；所有系统 playback state 调用返回 error=3，接收客户端查询为空。不能把 API 符号存在/注册 Boolean 返回1当成交接成功，已移除这组无效私有系统注册调用。
- 核对 Apple 文档后，MPRemoteCommandCenter 不要求成为 UIKit 第一响应者；不把旧 UIKit 事件入口当作已证实修复。
- 增加只读的原生音频来源验证：观察浏览器实际请求的 googlevideo 音视频地址，在 PiP 中由 AVURLAsset 读取可播放性、时长及音轨，与当前视频时长核对。
- 本版只读取元数据，不创建发声播放器，不接管音频、不静音网页；目标是确认后续由原生播放器承担后台音频是否可行。本版不是180秒恢复修复版。
- 地址只留在设备内存；日志不打印签名 URL。仅接受 HTTPS googlevideo /videoplayback，移除未参与签名的片段/传输参数，排除广告阶段，并防止将已观察的旧视频来源重新归到新视频。
- 每个视频最多4个候选；每个加载最多15秒；退出PiP、换视频、WebContent终止时取消读取。
- Build22用户测试：PiP视频进度正常，transport=SABR，网络候选数量0；没有AVFoundation加载成功证据。
- Build24补查播放器formats/adaptiveFormats已有直接URL，校验播放器response的视频ID以避免旧SPA数据；只记录格式/direct/cipher/audio计数与manifest/SABR布尔值。
- Debug诊断可用显式环境变量 `YOUTUBE_SOURCE_PROBE_VIDEO`（11字符视频ID）打开指定视频并在前台加载来源元数据；正常启动首页，Release不启用该入口。修正Debug配置缺少DEBUG编译条件。
- 构建及JS来源/格式归属合同检查通过；以真机NATIVE_SOURCE元数据结果判断原生播放器方案可行性。稳定基线仍2.2/15，无Git提交。

## 2.9 / Build 31（原生 PiP 接管，锁屏耳机长暂停恢复已验证）

- 网页使用 HLS 播放，并读取同一视频实际使用、已转换的 `currentSrc`。原始格式列表清单虽可读取元数据，实际播放器加载失败，不能直接用它接管。
- 来源须通过视频 ID、媒体 ID、有效期、时长及音视频轨道检查。签名地址仅保留在设备内存，日志不输出完整地址。
- 点击现有“画中画 / 后台播放”按钮后，先取得网页真实暂停位置，再由原生 AVPlayer 定位并播放，使用 AVPictureInPictureController 显示 PiP。
- MPNowPlayingSession 绑定实际 AVPlayer，耳机、锁屏播放/暂停及进度拖动直接操作原生播放器。移除未成功的 WebKit RemoteCommand 桥，关闭旧 WebKit PiP 入口。
- 返回 App 时同步网页播放位置；关闭小窗保持暂停；换视频、耳机断开、音频中断有暂停和清理处理。
- 日志包含 `REMOTE_NATIVE` 命令入口、原生播放器状态、真实进度及媒体会话激活结果。编译成功和短暂停正常均不能证明 180 秒故障已解决。
- iPhone 15 上的前台接管已确认：HLS 条目有音视频轨道、原生 PiP 启动、sessionActive=true，原生进度由 4.42 秒前进至 52 秒。该检查未连接调试器，不能代替真实锁屏长暂停测试。
- 2026-10-01 用户确认锁屏耳机暂停 180 秒后恢复，声音和进度均正常。真机日志确认 pause/play 均进入 REMOTE_NATIVE，实际间隔约 184.5 秒；恢复后 resume verified=true，进度继续从 13.56 秒前进至 60 秒，媒体会话保持激活。
- 已验证的范围为 iPhone 15 / iOS 18.7.8 的 PiP 锁屏耳机长暂停恢复；锁屏卡片长暂停恢复、长达数十分钟的暂停等场景尚未单独复测。
- Debug 可通过显式 `YOUTUBE_SOURCE_PROBE_VIDEO` 和 `YOUTUBE_NATIVE_PIP_SMOKE=1` 自动检查前台接管；正常启动首页，Release 不运行自动检查。

## 开发环境

- Xcode 16.4
- iOS Deployment Target 17.0
- Swift / UIKit / WebKit

## Bundle ID

`com.ray.YouTubeIOSPoC`

> 项目显示名称为 **YouTube Desktop**。工程 target / bundle identifier 保持原值，以避免影响现有签名和真机安装。
