# YouTube Desktop for iOS

一个基于 `WKWebView` 的 iPhone YouTube 桌面版封装项目。

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

## iOS 后台播放说明

在当前 iOS / WKWebView 实现中，稳定后台播放依赖系统 PiP 媒体会话。播放视频后先点击播放器中的 **“画中画 / 后台播放”** 按钮进入 PiP，再回到桌面即可持续播放。直接从普通 inline 播放状态退出 App，iOS 会暂停 WKWebView 视频。

2.0 已移除自动跳广告、后台强制续播、可见性伪装、程序化后台 PiP、RemoteCommand 播放桥等未形成稳定方案的实验代码。

## 开发环境

- Xcode 16.4
- iOS Deployment Target 17.0
- Swift / UIKit / WebKit

## Bundle ID

`com.ray.YouTubeIOSPoC`

> 项目显示名称为 **YouTube Desktop**。工程 target / bundle identifier 保持原值，以避免影响现有签名和真机安装。
