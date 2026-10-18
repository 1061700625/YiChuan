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

### 文件传输与完整性校验

文件采用 1 MiB 二进制分块，最多保留 8 MiB 未确认数据。发送端随接收进度补充窗口，避免每批数据全部确认后才继续发送。接收端逐块按序写入并确认，界面中的字节进度最多每 200 毫秒刷新一次，状态变化立即显示。文件连接关闭 WebSocket 压缩，避免对视频、APK、ZIP 等已压缩内容重复压缩。

文件收齐后双方显示“校验中”。接收端关闭写入句柄，在工作 isolate 中重新读取文件计算 SHA-256；与发送前公布的摘要一致且保存成功后，才显示“已完成”。损坏文件会判定失败并删除，发送端等待最终确认最多 5 分钟。空文件和续传至末尾也必须经过校验。

诊断日志 `yichuan.transfer.send` 记录读取、发送入队、等待确认和总耗时；`yichuan.transfer.receive` 记录写入耗时，`yichuan.transfer.sha256` 记录摘要计算耗时。发送入队耗时不等同于网络传输耗时。

可用 `dart tool/websocket_compression_benchmark.dart` 对比本机 WebSocket 压缩开销；该测试不包含磁盘、Wi-Fi 和完整性校验，不能代表手机与电脑间的实际文件传输速度。

### 一次发送多个文件

点击“发送文件”后可在系统选择器中多选。所选文件会全部进入列表并逐个发送；当前文件校验结束后才发送下一项。单项读取或校验失败不影响后续文件，连接中断则暂停剩余项，可重连后分别点击“重试”。发送队列期间仍可收发文字和接收对方文件。

Android 会将选中文件复制到独立缓存路径，复制在后台线程执行；macOS 和 Windows 使用原始文件路径。文件选择或摘要计算期间若连接改变，未发送项不会自动发给新连接的设备。

### 打开已完成的文件

点击已完成的文件可交给系统应用打开。Android 使用原始文件名判断类型，APK 会调起系统安装界面，首次使用可能需要允许驿传安装应用。

已完成文件提供“打开所在位置”按钮，打开文件失败时也会自动尝试定位。macOS 和 Windows 在文件管理器中选中文件；Android 尝试打开 `Download/驿传`，不支持目录跳转的系统会退回下载列表。应用私有缓存无法由外部文件管理器浏览，无法打开或定位时会显示提示。
