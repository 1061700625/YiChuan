# 驿传 (YiChuan)

> 局域网文件高速传输工具 — Android ↔ Windows / macOS

驿传是一款基于 **WebSocket + UDP 广播** 的局域网文件传输应用，无需互联网、无需数据线，通过 6 位配对码一键连接，实现设备间高速文件传输。

## ✨ 特性

- **🔗 简单配对** — 6 位配对码连接，无需账号、无需扫码
- **🔒 安全传输** — 仅发起方可以发送文件，被连接方自动接收
- **🚀 局域网直连** — 不走互联网，利用 WiFi 局域网带宽极速传输
- **📂 一键打开** — 传输完成后可直接通过系统应用打开文件
- **🌙 深色模式** — 支持浅色/深色/跟随系统

## 📦 安装

### Android

下载 APK 安装即可。

> ⚠️ 桌面端（Windows / macOS）需要自行编译，未来提供预编译版本。

### 从源码编译

```bash
# 克隆仓库
git clone https://github.com/1061700625/YiChuan.git
cd YiChuan

# Android APK
flutter build apk --release --target-platform android-arm64

# macOS（需要 macOS + Xcode）
flutter build macos
```

## 🕹️ 使用方式

1. **桌面端**启动应用 → 显示 6 位配对码
2. **手机端**打开应用 → 自动发现附近设备 → 点击设备 → 输入配对码
3. 配对成功后，手机端点击右下角 **发送文件**
4. 文件保存到 `Download/驿传/` 目录

## 🏗️ 技术栈

- **Flutter** 3.44 + Dart 3.12
- **WebSocket** — 文件数据传输通道
- **UDP 广播** — 局域网设备发现
- **MediaStore API** — 文件保存到公共下载目录
- **MethodChannel** — Android 原生平台通道（文件选择、权限请求等）

## 📄 开源协议

MIT License

---

**作者：小锋学长生活大爆炸**
