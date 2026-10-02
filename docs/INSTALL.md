# 从源码构建、自签安装

本教程用于在自己的 Mac 上构建，并用自己的 Apple 账户安装到自己的 iPhone。普通安装不需要编辑 Swift 代码。

## 1. 准备环境

| 项目 | 要求 |
|---|---|
| Mac 与 Xcode | 使用相互兼容、并能支持目标 iPhone 系统的版本；本项目已使用 Xcode 16.4 编译 |
| iPhone | 工程部署目标 iOS 17.0；兼容性仍以实际设备测试为准 |
| Apple 账户 | 在 Xcode 登录，用于自己的开发签名 |
| 连接 | 首次建议使用可传输数据的 USB 线，手机解锁并完成信任 |
| 网络 | 能正常连接 YouTube，以及签名所需的 Apple 服务 |

新 iOS 设备若显示不支持、缺少设备支持或无法准备设备，请先确认 Xcode 与该 iOS 版本的兼容性。本教程不承诺旧 Xcode 支持所有新系统。

## 2. 获取工程

~~~bash
git clone https://github.com/maomaowuxian/YouTubeDesktop-iOS.git
cd YouTubeDesktop-iOS
open YouTubePoC.xcodeproj
~~~

若仓库仍是私有，需要 GitHub 账号拥有访问权限。请勿把访问令牌写进克隆地址、脚本或仓库文件。

## 3. 登录 Xcode 账户

在 Xcode 的 Settings → Accounts 中添加自己的 Apple 账户。Accounts 为空时，即使电脑残留旧证书，也可能无法为新设备生成签名。

选择工程的 `YouTubePoC` target，在 Signing & Capabilities 中确认使用 Automatic Signing。

## 4. 配置自己的签名

### 推荐：不入库的本地配置

在仓库根目录执行：

~~~bash
cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
~~~

编辑新文件，填写：

~~~xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.YouTubeDesktop
~~~

- `YOUR_TEAM_ID` 需替换为自己的实际 Team ID，不是 Apple 账户邮箱。
- Bundle ID 需换成自己的唯一反向域名标识，不要照抄 `com.yourname`。
- 可以从自己的开发者账号或 Xcode 签名信息查看 Team ID。
- 本地文件已被 Git 忽略，不应提交给其他人。
- Debug 和 Release 均先读取共享配置，再由该本地文件覆盖签名值。
- 原有安装更新时，沿用此前的 Team 与 Bundle ID；改变标识会成为另一份 App。

共享默认 Bundle ID 保留 `com.ray.YouTubeIOSPoC`，仅用于历史兼容，新使用者必须设置自己的唯一标识。公共工程的 Team 默认留空。

### 也可在 Xcode 图形界面配置

如果不方便填写 Team ID，在 Signing & Capabilities 中选择自己的 Team，并修改 Bundle Identifier。Xcode 会把这些值写进工程；这可能产生 `project.pbxproj` 改动，向上游提交代码前请排除个人签名设置。

如果本地配置填写错误或仍显示占位符，修正配置后重新构建。

## 5. 配对 iPhone 与开启开发者模式

1. 用数据线连接 Mac，解锁 iPhone；按系统提示信任电脑并输入手机密码。
2. 在 Xcode 的 Window → Devices and Simulators 中确认设备可见，等待配对和准备完成。较新 Xcode 的入口名称可能为 Device Hub。
3. 在 iPhone 的设置 → 隐私与安全性 → 开发者模式中开启，按提示重启并再次确认。
4. 如果尚未出现开发者模式，先完成 Xcode 配对、选择该设备并尝试运行，再检查手机设置。

开发者模式、信任电脑和信任开发者是不同步骤。仅靠重新插拔数据线不一定会显示所有提示。

参考：[Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)。

## 6. 构建和运行

1. 在 Xcode 顶部选择 `YouTubePoC` scheme。
2. 运行设备选择自己的 iPhone，而不是模拟器或通用设备。
3. 点击 Run（Command-R），等待构建、自动签名和安装。
4. 如手机提示“不受信任的开发者”，按系统提示到设置 → 通用 → VPN 与设备管理，找到自己账户对应的开发者 App 并完成信任，再打开 App。
5. 验证后台声音时，停止 Xcode 调试并从手机主屏幕正常启动 App，避免把附加调试器的结果当成正常后台行为。

首次测试建议：

- 打开一个自己选择的普通视频，确认网页有声。
- 等待原生“暂停／返回网页”按钮出现，再锁屏听至少一分钟。
- 耳机暂停约三分钟后，按一次播放，确认实际声音与播放进度。
- 回到 App，检查进度、暂停意图和“返回网页”。
- 原生接管前快速锁屏、广告和多音轨场景按 README 的已知限制处理。

这些步骤是建议测试流程，不代表所有设备和视频都已通过。

## 7. 免费签名的有效期

Apple 的 Personal Team 描述文件通常在签发 **7 天后到期**，需要重新构建、签名和安装。免费账户还有限制：最多3台设备、每台最多3个 App、最多10个 App ID，并存在相应有效期限制。

到期后建议保持原 Team 和 Bundle ID，重新连接手机并在 Xcode 运行。无需为了重新签名先删除 App；删除 App 可能丢失网页登录与本地数据。

新设备未包含在描述文件中时，需要 Xcode 当前账户能够登录并刷新签名。付费开发者计划也不是永久签名或免除设备注册。

参考：[Apple 开发者账户与 Personal Team 限制](https://developer.apple.com/help/account/basics/about-your-developer-account)。

## 8. 命令行构建（可选）

### 无签名检查

~~~bash
xcodebuild -project YouTubePoC.xcodeproj \
  -scheme YouTubePoC -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/Unsigned \
  CODE_SIGNING_ALLOWED=NO build
~~~

无签名构建仅用于编译检查，产物不能直接在 iPhone 上运行。

### 已配置本地签名后构建

先通过 Xcode 完成账户登录和设备配对，再查看可用目标：

~~~bash
xcodebuild -project YouTubePoC.xcodeproj -scheme YouTubePoC -showdestinations
~~~

使用列表中的 Xcode 设备 UDID：

~~~bash
xcodebuild -project YouTubePoC.xcodeproj \
  -scheme YouTubePoC -configuration Debug \
  -destination 'id=YOUR_XCODE_DEVICE_UDID' \
  -derivedDataPath build/Device \
  -allowProvisioningUpdates build
~~~

`YOUR_XCODE_DEVICE_UDID` 需要替换为实际值。CoreDevice Identifier 与 Xcode 的 destination UDID 不是同一种标识，不要直接把 `devicectl` 列表中的任意 UUID 当成构建目标。

新用户优先使用 Xcode Run 完成安装；本教程不提供通用签名 IPA 或公共安装证书。

## 9. 常见问题

| 现象 | 检查与处理 |
|---|---|
| Signing requires a development team | 填写本地 Team ID，或在 Xcode 选择自己的 Team |
| Bundle identifier cannot be registered | 在本地配置换成自己的唯一 Bundle ID |
| Provisioning profile 不包含当前设备 | 确认 Accounts 已登录，完成设备注册，使用自动签名重新构建 |
| 无法找到 destination | 使用 Xcode 的设备 UDID；检查配对、线缆及系统支持 |
| 手机没有开发者模式选项 | 先与 Xcode 配对并尝试运行，再检查隐私与安全性 |
| 不受信任的开发者／系统拒绝启动 | 在手机中按提示信任自己的开发者，并核对描述文件是否有效 |
| 若干天后无法打开 App | 检查 Personal Team 签名有效期，重新构建安装 |
| 没有原生按钮，锁屏后停止 | 来源尚未准备好；回前台等待，参阅 README 的限制 |
| 原生接管后语言变化 | 2.14 已验证中文保持；其他音轨和视频范围尚未完整覆盖。可返回网页确认所选音轨，并反馈版本、设备及交接步骤 |
| 模拟器正常而真机后台失败 | 模拟器不验证锁屏音频和耳机行为，需真机独立测试 |

不要提交自己的 `LocalSigning.xcconfig`、证书、描述文件、账号凭证或完整浏览器登录数据。
