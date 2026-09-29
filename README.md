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
