# 驿传 (YiChuan)

> 局域网文件高速传输工具 — Android ↔ Windows / macOS

驿传是一款基于 **WebSocket + UDP 广播** 的局域网文件传输应用，无需互联网、无需数据线，通过 6 位配对码一键连接，实现设备间高速文件传输。

## ✨ 特性

- **🔗 简单配对** — 6 位配对码连接，无需账号、无需扫码
- **🔒 安全传输** — 仅发起方可以发送文件，被连接方自动接收
- **🚀 局域网直连** — 不走互联网，利用 WiFi 局域网带宽极速传输
- **📂 一键打开** — 传输完成后可直接通过系统应用打开文件
- **🌙 深色模式** — 支持浅色/深色/跟随系统

## 📁 项目结构

```
test/                                  # 测试 (48 项)
android/                               # Android 平台配置
macos/                                 # macOS 平台配置
lib/
├── main.dart                          # 入口
├── app/
│   ├── app.dart                       # 应用主状态 + 消息路由
│   └── theme/app_theme.dart           # 浅色/深色主题
├── core/
│   ├── discovery/
│   │   ├── discovery_service.dart     # 设备发现服务
│   │   ├── udp_discovery_service.dart # UDP 广播发现
│   │   └── subnet_scanner.dart        # 子网扫描
│   ├── network/
│   │   ├── network_service.dart       # 网络接口 + 测试实现
│   │   └── websocket_network_service.dart  # WebSocket 实现
│   ├── platform/
│   │   ├── android_permissions.dart   # Android 权限通道
│   │   ├── file_picker_channel.dart   # 文件选择/打开/保存
│   │   └── network_info.dart          # 网络信息获取
│   ├── protocol/
│   │   └── protocol_message.dart      # 传输协议消息定义
│   ├── session/
│   │   ├── session_service.dart       # 配对码/会话管理
│   │   └── trusted_device.dart        # 可信设备模型
│   ├── storage/
│   │   └── device_repository.dart     # 设备存储
│   └── transfer/
│       ├── transfer_task.dart         # 传输任务模型
│       └── transfer_queue_service.dart # 传输队列管理
├── features/
│   ├── pairing/pairing_page.dart      # 配对页面
│   ├── transfers/transfer_list_page.dart  # 传输列表页面
│   └── settings/settings_page.dart    # 设置页面
```


## 📦 安装

### 下载安装包

从Release下载app安装即可。

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
