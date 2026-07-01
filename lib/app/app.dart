import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'theme/app_theme.dart';
import '../features/pairing/pairing_page.dart';
import '../features/transfers/transfer_list_page.dart';
import '../features/settings/settings_page.dart';
import '../core/session/session_service.dart';
import '../core/session/trusted_device.dart';
import '../core/discovery/udp_discovery_service.dart';
import '../core/network/websocket_network_service.dart';
import '../core/storage/device_repository.dart';
import '../core/transfer/transfer_queue_service.dart';
import '../core/transfer/transfer_task.dart';
import '../core/protocol/protocol_message.dart';
import '../core/platform/android_permissions.dart';
import '../core/platform/network_info.dart';
import '../core/platform/file_picker_channel.dart' show getDownloadDir, moveToDownloads;
import '../core/discovery/subnet_scanner.dart';

class LocalMeshTransferApp extends StatefulWidget {
  const LocalMeshTransferApp({super.key});

  @override
  State<LocalMeshTransferApp> createState() => _LocalMeshTransferAppState();
}

class _LocalMeshTransferAppState extends State<LocalMeshTransferApp> {
  ThemeMode _themeMode = ThemeMode.system;
  int _currentTab = 0;

  late final DeviceRepository _deviceRepo;
  late final SessionService _sessionService;
  late final UdpDiscoveryService _discoveryService;
  late final WebSocketNetworkService _networkService;
  late final TransferQueueService _transferQueue;
  String _statusMessage = '';
  String? _localIp;

  // Receiving file state: taskId → accumulated bytes
  final _incomingFiles = <String, _IncomingFile>{};

  @override
  void initState() {
    super.initState();
    _deviceRepo = DeviceRepository();
    _sessionService = SessionService(deviceRepo: _deviceRepo);
    _discoveryService = UdpDiscoveryService();
    _networkService = WebSocketNetworkService();
    _transferQueue = TransferQueueService();
    _initializeServices();
  }

  Future<String> _getDownloadDir() async {
    return await getDownloadDir();
  }

  Future<void> _initializeServices() async {
    try {
      // --- Start WebSocket server on ALL platforms ---
      int wsPort = 45678;
      try {
        wsPort = await _networkService.startServer(port: wsPort);
      } catch (_) {
        wsPort = await _networkService.startServer(port: 45679);
      }

      final deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
      final deviceName = await _localDeviceName();
      final downloadDir = await _getDownloadDir();
      _sessionService.generatePairingCode();
      _localIp = await NetworkInfo.getLocalIp();

      // --- Request permissions on Android ---
      if (Platform.isAndroid) {
        final granted = await requestNearbyDevicesPermission();
        if (!granted && mounted) {
          _statusMessage = '请在系统设置中授予"附近设备"权限';
        }
        await acquireMulticastLock();
      }

      // --- Start discovery ---
      _discoveryService.startScanning();
      _discoveryService.startBroadcasting(
        deviceId: deviceId,
        deviceName: deviceName,
        platform: Platform.isAndroid
            ? DevicePlatform.android
            : Platform.isMacOS
                ? DevicePlatform.macos
                : Platform.isWindows
                    ? DevicePlatform.windows
                    : DevicePlatform.macos,
        servicePort: wsPort,
      );

      // When a new WebSocket client connects, announce ourselves
      _networkService.onClientConnected = (clientId) {
        _networkService.send(clientId, ProtocolMessage(
          type: ProtocolMessageType.hello,
          version: 1,
          messageId: 'hello_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: DateTime.now(),
          payload: {
            'deviceId': deviceId,
            'deviceName': deviceName,
            'platform': Platform.isAndroid ? 'android' : 'desktop',
            'host': _localIp ?? 'localhost',
            'port': wsPort,
          },
        ));
      };

      // When a client disconnects, notify the user and pause active transfers
      _networkService.onClientDisconnected = (clientId) {
        if (mounted) {
          setState(() {
            _statusMessage = '对方已断开连接';
          });
        }
        // Pause any active transfers (sender side won't have connectedClients)
        for (final task in _transferQueue.tasks) {
          if (task.status == TransferTaskStatus.transferring) {
            _transferQueue.pause(task.id);
          }
        }
      };

      // Auto subnet scan after 5s
      _autoSubnetScan(deviceId, wsPort);

      // --- Handle incoming messages ---
      _networkService.onMessageReceived = (message) async {
        switch (message.type) {
          case ProtocolMessageType.hello:
            // Clear stale disconnect message when device reconnects
            if (_statusMessage == '对方已断开连接') {
              if (mounted) setState(() => _statusMessage = '');
            }
            _discoveryService.injectDiscoveredDevice(
              deviceId: message.payload['deviceId'] as String,
              deviceName: message.payload['deviceName'] as String? ?? '未知设备',
              platform: (message.payload['platform'] as String?) == 'android'
                  ? DevicePlatform.android
                  : DevicePlatform.macos,
              ip: '${message.payload['host'] ?? _localIp ?? 'local'}',
              port: (message.payload['port'] as num?)?.toInt() ?? 45678,
            );
            break;

          case ProtocolMessageType.pairRequest:
            final result = await _sessionService.handlePairRequest(
              deviceId: message.payload['deviceId'] as String,
              deviceName: message.payload['deviceName'] as String,
              platform: DevicePlatform.android,
              pairingCode: message.payload['pairingCode'] as String,
            );

            final response = ProtocolMessage(
              type: ProtocolMessageType.pairResult,
              version: 1,
              messageId: 'resp_${message.messageId}',
              sessionId: result.sessionId,
              timestamp: DateTime.now(),
              payload: {
                'success': result.success,
                if (result.error != null) 'error': result.error,
              },
            );
            for (final clientId in _networkService.connectedClients) {
              await _networkService.send(clientId, response);
            }
            if (mounted) setState(() {});
            break;

          case ProtocolMessageType.pairResult:
            break;

          case ProtocolMessageType.transferOffer:
            _handleTransferOffer(message, downloadDir);
            break;

          case ProtocolMessageType.chunk:
            _handleChunk(message);
            break;

          case ProtocolMessageType.transferDone:
            await _handleTransferDone(message);
            break;

          default:
            break;
        }
      };

      if (mounted) {
        setState(() {
          _statusMessage = '服务已启动 (端口 $wsPort)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '启动失败: $e';
        });
      }
    }
  }

  void _handleTransferOffer(ProtocolMessage message, String downloadDir) {
    final taskId = message.payload['taskId'] as String;
    final fileName = message.payload['fileName'] as String? ?? 'unknown.bin';
    final fileSize = (message.payload['fileSize'] as num?)?.toInt() ?? 0;
    final checksum = message.payload['checksum'] as String? ?? '';

    _transferQueue.addOffer(
      taskId: taskId,
      fileName: fileName,
      fileSize: fileSize,
      checksum: checksum,
    );

    final savePath = '$downloadDir/$fileName';
    try {
      final tempFile = File(savePath);
      tempFile.parent.createSync(recursive: true);
      final raf = tempFile.openSync(mode: FileMode.write);
      _incomingFiles[taskId] = _IncomingFile(savePath: savePath, raf: raf);
    } catch (e) {
      _statusMessage = '接收文件失败: $e';
      if (mounted) setState(() {});
      return;
    }

    // Send accept
    final acceptMsg = ProtocolMessage(
      type: ProtocolMessageType.transferAccept,
      version: 1,
      messageId: 'accept_$taskId',
      timestamp: DateTime.now(),
      payload: {'taskId': taskId, 'accepted': true},
    );
    for (final clientId in _networkService.connectedClients) {
      _networkService.send(clientId, acceptMsg);
    }

    _transferQueue.startTransfer(taskId);
    if (mounted) setState(() {});
  }

  void _handleChunk(ProtocolMessage message) {
    final taskId = message.payload['taskId'] as String;
    final offset = (message.payload['offset'] as num?)?.toInt() ?? 0;
    final dataStr = message.payload['data'] as String?;
    final chunkSize = (message.payload['size'] as num?)?.toInt() ?? 0;

    if (dataStr == null) return;

    final incoming = _incomingFiles[taskId];
    if (incoming == null) return;

    try {
      final decoded = base64Decode(dataStr);
      incoming.raf.setPositionSync(offset);
      incoming.raf.writeFromSync(decoded);
    } catch (e) {
      _statusMessage = '写入分块失败: $e';
      if (mounted) setState(() {});
      return;
    }

    _transferQueue.recordChunkCompleted(taskId, chunkSize: chunkSize);
    if (mounted) setState(() {});
  }

  Future<void> _handleTransferDone(ProtocolMessage message) async {
    final taskId = message.payload['taskId'] as String;
    final incoming = _incomingFiles.remove(taskId);
    if (incoming == null) return;

    try {
      await incoming.raf.close();
      final fileName = incoming.savePath.split('/').last;

      // Move file from private temp dir to public Downloads via MediaStore
      if (Platform.isAndroid) {
        final uri = await moveToDownloads(incoming.savePath, fileName);
        if (uri != null) {
          _transferQueue.setSavedFileUri(taskId, uri);
          _statusMessage = '文件已保存到 Download/驿传/$fileName';
        } else {
          // Fallback: file stays in private dir
          _statusMessage = '文件已保存(私有目录): $fileName';
        }
      } else {
        _statusMessage = '文件已保存: ${incoming.savePath}';
      }
    } catch (e) {
      _transferQueue.pause(taskId);
      _statusMessage = '保存文件失败: $e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _autoSubnetScan(String deviceId, int wsPort) async {
    await Future.delayed(const Duration(seconds: 5));

    final ownIp = await NetworkInfo.getLocalIp();
    if (ownIp == null || !mounted) return;

    if (_discoveryService.recentDevices.isNotEmpty) return;

    final scanner = SubnetScanner();
    final found = await scanner.scan(ownIp: ownIp);

    final external = found.where((d) => d.ip != ownIp).toList();

    for (final device in external) {
      _discoveryService.injectDiscoveredDevice(
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        platform: device.platform,
        ip: device.ip,
        port: device.port,
      );
    }
    if (found.isNotEmpty && mounted) setState(() {});
  }

  Future<String> _localDeviceName() async {
    if (Platform.isAndroid) {
      final androidName = await getAndroidDeviceName();
      if (androidName != null) return androidName;
    }
    return NetworkInfo.getDeviceName();
  }

  @override
  void dispose() {
    _networkService.dispose();
    _discoveryService.dispose();
    releaseMulticastLock();
    super.dispose();
  }

  void _setThemeMode(ThemeMode mode) => setState(() => _themeMode = mode);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '驿传',
      themeMode: _themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: IndexedStack(
          index: _currentTab,
          children: [
            PairingPage(
              sessionService: _sessionService,
              discoveryService: _discoveryService,
              networkService: _networkService,
              statusMessage: _statusMessage,
            ),
            TransferListPage(
              transferQueue: _transferQueue,
              networkService: _networkService,
            ),
            SettingsPage(deviceRepo: _deviceRepo),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentTab,
          onDestinationSelected: (i) => setState(() => _currentTab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.cast_rounded), label: '配对'),
            NavigationDestination(icon: Icon(Icons.cloud_upload_outlined), label: '传输'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
          ],
        ),
      ),
    );
  }
}

class _IncomingFile {
  _IncomingFile({required this.savePath, required this.raf});
  final String savePath;
  final RandomAccessFile raf;
}
