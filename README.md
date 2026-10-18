# 驿传 (YiChuan)

> 局域网文件高速传输工具 — Android ↔ Windows / macOS

驿传是一款基于 **WebSocket + UDP 广播** 的局域网文件传输应用，无需互联网、无需数据线，通过 6 位配对码一键连接，实现设备间高速文件传输。

## ✨ 特性

- **🔗 简单配对** — 6 位配对码连接，无需账号、无需扫码
- **🔒 安全传输** — 配对后双方均可发送文件和文字，接收文件期间也可向对方发送
- **🚀 局域网直连** — 不走互联网，利用 WiFi 局域网带宽极速传输
- **📂 一键打开** — 传输完成后可直接通过系统应用打开文件
- **🌙 深色模式** — 支持浅色/深色/跟随系统

## 📁 项目结构

```
test/                                  # 单元测试与组件测试
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
│   │   ├── protocol_message.dart      # JSON 控制消息定义
│   │   └── binary_transfer_chunk.dart # 文件二进制帧编解码
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
5. 配对页点击 **申请互相信任**，对方选择 **同意并信任** 后保存双方的认证凭据
6. 之后在附近设备中点击 **连接**，已信任设备会自动验证，无需输入配对码；也可点击 **配对码** 重新配对

信任申请只能在已配对会话内发起，30 秒未确认会超时。设置页可删除信任；任意一端删除后，免码连接会失败，需要重新配对并申请信任。旧版本的可信设备记录没有认证凭据，需重新申请一次。

免码认证使用每次连接新生成、限时且只能使用一次的随机挑战及 HMAC-SHA256，并校验服务端响应。认证状态保存在应用数据目录，旧记录在首次启动时迁移。当前传输仍使用未加密的 `ws://`，首次配对和信任凭据交换应在可信局域网中进行；此功能不提供传输加密。

## 🏗️ 技术栈

- **Flutter** 3.44 + Dart 3.12
- **WebSocket** — JSON 控制消息 + 二进制文件分块传输
- **UDP 广播** — 局域网设备发现
- **MediaStore API** — 文件保存到公共下载目录
- **MethodChannel** — Android 原生平台通道（文件选择、权限请求等）

## 📄 开源协议

MIT License

---

**作者：小锋学长生活大爆炸**
