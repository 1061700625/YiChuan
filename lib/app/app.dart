import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../core/discovery/subnet_scanner.dart';
import '../core/discovery/udp_discovery_service.dart';
import '../core/network/websocket_network_service.dart';
import '../core/platform/android_permissions.dart';
import '../core/platform/device_identity.dart';
import '../core/platform/file_picker_channel.dart'
    show getDownloadDir, moveToDownloads;
import '../core/platform/network_info.dart';
import '../core/protocol/binary_transfer_chunk.dart';
import '../core/protocol/protocol_message.dart';
import '../core/session/session_service.dart';
import '../core/session/trusted_device.dart';
import '../core/storage/device_repository.dart';
import '../core/transfer/transfer_queue_service.dart';
import '../core/transfer/transfer_task.dart';
import '../features/pairing/pairing_page.dart';
import '../features/settings/settings_page.dart';
import '../features/transfers/transfer_list_page.dart';
import 'theme/app_theme.dart';

class LocalMeshTransferApp extends StatefulWidget {
  const LocalMeshTransferApp({super.key});

  @override
  State<LocalMeshTransferApp> createState() => _LocalMeshTransferAppState();
}

class _LocalMeshTransferAppState extends State<LocalMeshTransferApp>
    with WidgetsBindingObserver {
  int _currentTab = 0;

  late final DeviceRepository _deviceRepo;
  late final SessionService _sessionService;
  late final UdpDiscoveryService _discoveryService;
  late final WebSocketNetworkService _networkService;
  late final TransferQueueService _transferQueue;
  final _incomingFiles = <String, _IncomingFile>{};

  String _statusMessage = '';
  String? _localIp;
  String _localDeviceId = '';
  bool _connectionServiceRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deviceRepo = DeviceRepository();
    _sessionService = SessionService(deviceRepo: _deviceRepo);
    _discoveryService = UdpDiscoveryService();
    _networkService = WebSocketNetworkService();
    _transferQueue = TransferQueueService();
    unawaited(_initializeServices());
  }

  Future<void> _initializeServices() async {
    try {
      final downloadDir = await getDownloadDir();
      await _deviceRepo.initialize(
        File('$downloadDir${Platform.pathSeparator}.yichuan_state.json'),
      );
      _localDeviceId = await _deviceRepo.getOrCreateLocalDeviceId();
      final deviceName = await getLocalDeviceName();

      var wsPort = 45678;
      try {
        wsPort = await _networkService.startServer(port: wsPort);
      } catch (_) {
        wsPort = await _networkService.startServer(port: 45679);
      }

      _sessionService.generatePairingCode();
      _localIp = await NetworkInfo.getLocalIp();

      if (Platform.isAndroid) {
        final granted = await requestNearbyDevicesPermission();
        if (!granted) _statusMessage = '请在系统设置中授予"附近设备"权限';
        final notificationsGranted = await requestNotificationPermission();
        if (!notificationsGranted) {
          _statusMessage = '请允许通知，以便在后台保持设备连接';
        }
        await acquireMulticastLock();
      }

      _discoveryService.startScanning();
      _discoveryService.startBroadcasting(
        deviceId: _localDeviceId,
        deviceName: deviceName,
        platform: DevicePlatform.current,
        servicePort: wsPort,
      );

      _networkService.onClientConnected = (clientId) {
        unawaited(
          _networkService.send(
            clientId,
            ProtocolMessage(
              type: ProtocolMessageType.hello,
              version: 1,
              messageId: 'hello_${DateTime.now().millisecondsSinceEpoch}',
              timestamp: DateTime.now(),
              payload: {
                'deviceId': _localDeviceId,
                'deviceName': deviceName,
                'platform': DevicePlatform.current.wireName,
                'host': _localIp ?? 'localhost',
                'port': wsPort,
              },
            ),
          ),
        );
      };

      _networkService.onClientDisconnected = (clientId) {
        final wasPaired = _sessionService.pairedClientId == clientId;
        _sessionService.disconnectClient(clientId);
        unawaited(_suspendIncomingForClient(clientId));
        if (!wasPaired) return;
        unawaited(_stopBackgroundConnectionService());
        for (final task in _transferQueue.tasks) {
          if (task.status == TransferTaskStatus.transferring) {
            _transferQueue.pause(task.id);
          }
        }
        if (mounted) {
          setState(() => _statusMessage = '对方已断开连接');
        }
      };

      _networkService.onBinaryReceived = _handleBinaryChunk;
      _networkService.onMessageReceived = (clientId, message) =>
          _handleMessage(clientId, message, downloadDir);

      unawaited(_autoSubnetScan());
      if (mounted) {
        setState(() => _statusMessage = '服务已启动 (端口 $wsPort)');
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = '启动失败: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_stopBackgroundConnectionService());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_sessionService.state == SessionState.paired &&
            _networkService.connectedClients.isNotEmpty) {
          unawaited(_startBackgroundConnectionService());
        }
      case AppLifecycleState.detached:
        unawaited(_stopBackgroundConnectionService());
    }
  }

  Future<void> _startBackgroundConnectionService() async {
    if (_connectionServiceRequested) return;
    _connectionServiceRequested = true;
    final started = await startConnectionForegroundService();
    if (!started) _connectionServiceRequested = false;
  }

  Future<void> _stopBackgroundConnectionService() async {
    _connectionServiceRequested = false;
    await stopConnectionForegroundService();
  }

  Future<void> _handleMessage(
    String clientId,
    ProtocolMessage message,
    String downloadDir,
  ) async {
    try {
      if (message.version != 1) return;
      switch (message.type) {
        case ProtocolMessageType.hello:
          if (_statusMessage == '对方已断开连接' && mounted) {
            setState(() => _statusMessage = '');
          }
          _discoveryService.injectDiscoveredDevice(
            deviceId: message.payload['deviceId'] as String,
            deviceName: message.payload['deviceName'] as String? ?? '未知设备',
            platform: DevicePlatform.fromWireName(message.payload['platform']),
            ip: '${message.payload['host'] ?? _localIp ?? 'local'}',
            port: (message.payload['port'] as num?)?.toInt() ?? 45678,
          );

        case ProtocolMessageType.pairRequest:
          final result = await _sessionService.handlePairRequest(
            clientId: clientId,
            deviceId: message.payload['deviceId'] as String,
            deviceName: message.payload['deviceName'] as String,
            platform: DevicePlatform.fromWireName(message.payload['platform']),
            pairingCode: message.payload['pairingCode'] as String,
          );
          await _networkService.send(
            clientId,
            ProtocolMessage(
              type: ProtocolMessageType.pairResult,
              version: 1,
              messageId: 'resp_${message.messageId}',
              sessionId: result.sessionId,
              timestamp: DateTime.now(),
              payload: {
                'success': result.success,
                if (result.error != null) 'error': result.error,
              },
            ),
          );
          if (result.success) {
            for (final other in List<String>.from(
              _networkService.connectedClients,
            )) {
              if (other != clientId) await _networkService.disconnect(other);
            }
          }
          if (mounted) {
            setState(() {
              if (result.success) _currentTab = 1;
            });
          }

        case ProtocolMessageType.pairResult:
          break;

        case ProtocolMessageType.transferOffer:
          if (_sessionService.authorizes(clientId, message.sessionId)) {
            await _handleTransferOffer(clientId, message, downloadDir);
          }

        case ProtocolMessageType.transferResumeRequest:
          if (_sessionService.authorizes(clientId, message.sessionId)) {
            await _handleTransferResumeRequest(clientId, message);
          }

        case ProtocolMessageType.transferResumeResult:
          if (_sessionService.authorizes(clientId, message.sessionId)) {
            _handleTransferResumeResult(message);
          }

        case ProtocolMessageType.textMessage:
          if (_sessionService.authorizes(clientId, message.sessionId)) {
            _handleTextMessage(message);
          }

        case ProtocolMessageType.progress:
          if (!_sessionService.authorizes(clientId, message.sessionId)) return;
          final taskId = message.payload['taskId'] as String?;
          final receivedBytes = (message.payload['receivedBytes'] as num?)
              ?.toInt();
          if (taskId != null && receivedBytes != null) {
            if (message.payload['failed'] == true) {
              _transferQueue.fail(taskId);
              return;
            }
            _transferQueue.recordProgress(
              taskId,
              completedBytes: receivedBytes,
            );
            if (message.payload['complete'] == true) {
              _transferQueue.complete(taskId);
            }
          }

        case ProtocolMessageType.transferDone:
          if (_sessionService.authorizes(clientId, message.sessionId)) {
            await _handleTransferDone(clientId, message);
          }
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = '协议消息无效: $e');
    }
  }

  Future<void> _handleTransferOffer(
    String clientId,
    ProtocolMessage message,
    String downloadDir,
  ) async {
    final taskId = message.payload['taskId'] as String;
    final fileName = _validateFileName(message.payload['fileName']);
    final fileSize = (message.payload['fileSize'] as num?)?.toInt() ?? -1;
    final fileSha256 = message.payload['fileSha256'] as String?;
    final resumeToken = message.payload['resumeToken'] as String?;
    final restart = message.payload['restart'] == true;
    if (taskId.isEmpty ||
        fileSize < 0 ||
        fileSha256 == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fileSha256) ||
        resumeToken == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(resumeToken)) {
      throw const FormatException('Invalid or duplicate transfer offer.');
    }

    final existing = _incomingFiles[taskId];
    if (restart) {
      if (existing != null) {
        if (existing.resumeToken != resumeToken) {
          throw const FormatException('Invalid restart token.');
        }
        try {
          await existing.raf?.close();
        } catch (_) {}
        try {
          await File(existing.savePath).delete();
        } catch (_) {}
        _incomingFiles.remove(taskId);
        _transferQueue.remove(taskId);
      } else {
        final existingTask = _transferQueue.findTask(taskId);
        if (existingTask != null) {
          if (existingTask.status == TransferTaskStatus.completed ||
              _transferQueue.getResumeToken(taskId) != resumeToken) {
            throw const FormatException('Cannot restart this transfer.');
          }
          _transferQueue.remove(taskId);
        }
      }
    } else if (existing != null || _transferQueue.findTask(taskId) != null) {
      throw const FormatException('Invalid or duplicate transfer offer.');
    }

    final savePath = _availableSavePath(downloadDir, fileName);
    final file = File(savePath);
    file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    _incomingFiles[taskId] = _IncomingFile(
      clientId: clientId,
      savePath: savePath,
      raf: raf,
      totalBytes: fileSize,
      fileName: fileName,
      expectedSha256: fileSha256,
      resumeToken: resumeToken,
    );
    _transferQueue.addOffer(
      taskId: taskId,
      fileName: fileName,
      fileSize: fileSize,
    );
    _transferQueue.markReceived(taskId);
    _transferQueue.setResumeToken(taskId, resumeToken);
    _transferQueue.startTransfer(taskId);
    if (mounted) setState(() {});
  }

  Future<void> _handleTransferResumeRequest(
    String clientId,
    ProtocolMessage message,
  ) async {
    final taskId = message.payload['taskId'] as String?;
    final fileName = message.payload['fileName'] as String?;
    final fileSize = (message.payload['fileSize'] as num?)?.toInt();
    final fileSha256 = message.payload['fileSha256'] as String?;
    final resumeToken = message.payload['resumeToken'] as String?;
    final incoming = taskId == null ? null : _incomingFiles[taskId];
    var accepted = false;
    var offset = 0;

    if (incoming != null &&
        incoming.raf == null &&
        incoming.fileName == fileName &&
        incoming.totalBytes == fileSize &&
        incoming.expectedSha256 == fileSha256 &&
        incoming.resumeToken == resumeToken) {
      final partial = File(incoming.savePath);
      if (await partial.exists() &&
          await partial.length() == incoming.receivedBytes) {
        incoming.clientId = clientId;
        incoming.raf = await partial.open(mode: FileMode.append);
        offset = incoming.receivedBytes;
        accepted = true;
        _transferQueue.restart(taskId!, completedBytes: offset);
      }
    }

    await _networkService.send(
      clientId,
      ProtocolMessage(
        type: ProtocolMessageType.transferResumeResult,
        version: 1,
        messageId: 'resp_${message.messageId}',
        sessionId: _sessionService.currentSessionId,
        timestamp: DateTime.now(),
        payload: {
          'taskId': taskId ?? '',
          'accepted': accepted,
          'offset': offset,
        },
      ),
    );
  }

  void _handleTransferResumeResult(ProtocolMessage message) {
    final taskId = message.payload['taskId'] as String?;
    final offset = (message.payload['offset'] as num?)?.toInt();
    if (taskId == null || taskId.isEmpty || offset == null || offset < 0) {
      throw const FormatException('Invalid transfer resume result.');
    }
    _transferQueue.setResumeDecision(
      taskId,
      accepted: message.payload['accepted'] == true,
      offset: offset,
    );
  }

  void _handleTextMessage(ProtocolMessage message) {
    final taskId = message.payload['taskId'] as String?;
    final text = message.payload['text'] as String?;
    if (taskId == null ||
        taskId.isEmpty ||
        text == null ||
        text.trim().isEmpty ||
        utf8.encode(text).length > 64 * 1024 ||
        _transferQueue.findTask(taskId) != null) {
      throw const FormatException('Invalid text message.');
    }
    _transferQueue.addText(taskId: taskId, text: text, received: true);
    if (mounted) setState(() => _currentTab = 1);
  }

  Future<void> _handleBinaryChunk(String clientId, Uint8List frame) async {
    BinaryTransferChunk? chunk;
    try {
      if (_sessionService.pairedClientId != clientId) return;
      chunk = BinaryTransferChunk.decode(frame);
      final incoming = _incomingFiles[chunk.taskId];
      final raf = incoming?.raf;
      if (incoming == null) return;
      if (incoming.clientId != clientId ||
          raf == null ||
          chunk.offset != incoming.receivedBytes ||
          chunk.data.isEmpty ||
          chunk.data.length > incoming.totalBytes - chunk.offset) {
        throw const FormatException('File chunk is out of sequence.');
      }
      await raf.writeFrom(chunk.data);
      incoming.receivedBytes += chunk.data.length;
      _transferQueue.recordProgress(
        chunk.taskId,
        completedBytes: incoming.receivedBytes,
      );
      await _sendTransferProgress(
        clientId,
        chunk.taskId,
        incoming.receivedBytes,
      );
    } catch (e) {
      if (chunk != null) {
        await _failIncoming(chunk.taskId, '接收文件失败: $e');
      } else if (mounted) {
        setState(() => _statusMessage = '解析文件分块失败: $e');
      }
    }
  }

  Future<void> _sendTransferProgress(
    String clientId,
    String taskId,
    int receivedBytes, {
    bool complete = false,
    bool failed = false,
  }) async {
    await _networkService.send(
      clientId,
      ProtocolMessage(
        type: ProtocolMessageType.progress,
        version: 1,
        messageId: 'progress_${taskId}_$receivedBytes',
        sessionId: _sessionService.currentSessionId,
        timestamp: DateTime.now(),
        payload: {
          'taskId': taskId,
          'receivedBytes': receivedBytes,
          if (complete) 'complete': true,
          if (failed) 'failed': true,
        },
      ),
    );
  }

  Future<void> _handleTransferDone(
    String clientId,
    ProtocolMessage message,
  ) async {
    final taskId = message.payload['taskId'] as String;
    final incoming = _incomingFiles[taskId];
    if (incoming == null || incoming.clientId != clientId) return;
    _incomingFiles.remove(taskId);

    try {
      await incoming.raf?.close();
      incoming.raf = null;
      if (incoming.receivedBytes != incoming.totalBytes) {
        throw const FormatException(
          'File ended before all bytes were received.',
        );
      }
      final expectedSha256 = message.payload['sha256'] as String?;
      if (expectedSha256 == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256) ||
          expectedSha256 != incoming.expectedSha256) {
        throw const FormatException('Missing or invalid SHA-256.');
      }
      final digest = await sha256
          .bind(File(incoming.savePath).openRead())
          .first;
      if (digest.toString() != expectedSha256) {
        throw const FormatException('SHA-256 mismatch.');
      }

      final fileName = incoming.savePath.split(Platform.pathSeparator).last;
      if (Platform.isAndroid) {
        final uri = await moveToDownloads(incoming.savePath, fileName);
        if (uri != null) {
          _transferQueue.setSavedFileUri(taskId, uri);
          _statusMessage = '文件已保存到 Download/驿传/$fileName';
        } else {
          _transferQueue.setReceivedFilePath(taskId, incoming.savePath);
          _statusMessage = '文件已保存(私有目录): $fileName';
        }
      } else {
        _transferQueue.setReceivedFilePath(taskId, incoming.savePath);
        _statusMessage = '文件已保存: ${incoming.savePath}';
      }
      _transferQueue.complete(taskId);
      await _sendTransferProgress(
        clientId,
        taskId,
        incoming.totalBytes,
        complete: true,
      );
    } catch (e) {
      try {
        await incoming.raf?.close();
      } catch (_) {}
      try {
        await File(incoming.savePath).delete();
      } catch (_) {}
      _transferQueue.fail(taskId);
      _statusMessage = '保存文件失败: $e';
      await _sendTransferProgress(
        clientId,
        taskId,
        incoming.receivedBytes,
        failed: true,
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _failIncoming(String taskId, String message) async {
    final incoming = _incomingFiles.remove(taskId);
    if (incoming == null) return;
    try {
      await incoming.raf?.close();
    } catch (_) {}
    try {
      await File(incoming.savePath).delete();
    } catch (_) {}
    _transferQueue.fail(taskId);
    if (_sessionService.pairedClientId == incoming.clientId) {
      await _sendTransferProgress(
        incoming.clientId,
        taskId,
        incoming.receivedBytes,
        failed: true,
      );
    }
    _statusMessage = message;
    if (mounted) setState(() {});
  }

  Future<void> _suspendIncomingForClient(String clientId) async {
    final incomingFiles = _incomingFiles.entries
        .where((entry) => entry.value.clientId == clientId)
        .toList();
    for (final entry in incomingFiles) {
      try {
        await entry.value.raf?.close();
      } catch (_) {}
      entry.value.raf = null;
      _transferQueue.pause(entry.key);
    }
    if (incomingFiles.isNotEmpty) _statusMessage = '连接中断，已保留未完成文件等待续传';
    if (mounted) setState(() {});
  }

  String _validateFileName(Object? value) {
    if (value is! String || value.isEmpty || value.contains('\u0000')) {
      throw const FormatException('Invalid file name.');
    }
    final normalized = value.replaceAll('\\', '/');
    if (normalized.contains('/') || normalized == '.' || normalized == '..') {
      throw const FormatException('File name must not contain a path.');
    }
    return value;
  }

  String _availableSavePath(String directory, String fileName) {
    final separator = Platform.pathSeparator;
    var candidate = '$directory$separator$fileName';
    if (!File(candidate).existsSync()) return candidate;
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final extension = dot > 0 ? fileName.substring(dot) : '';
    var suffix = 1;
    do {
      candidate = '$directory$separator$stem ($suffix)$extension';
      suffix++;
    } while (File(candidate).existsSync());
    return candidate;
  }

  Future<void> _autoSubnetScan() async {
    await Future<void>.delayed(const Duration(seconds: 5));
    final ownIp = await NetworkInfo.getLocalIp();
    if (ownIp == null ||
        !mounted ||
        _discoveryService.recentDevices.isNotEmpty) {
      return;
    }
    final found = await SubnetScanner().scan(ownIp: ownIp);
    for (final device in found.where((device) => device.ip != ownIp)) {
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopBackgroundConnectionService());
    for (final incoming in _incomingFiles.values) {
      try {
        incoming.raf?.closeSync();
      } catch (_) {}
      try {
        File(incoming.savePath).deleteSync();
      } catch (_) {}
    }
    _incomingFiles.clear();
    _networkService.dispose();
    _discoveryService.dispose();
    unawaited(releaseMulticastLock());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '驿传',
      themeMode: ThemeMode.system,
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
              localDeviceId: _localDeviceId,
              statusMessage: _statusMessage,
            ),
            TransferListPage(
              transferQueue: _transferQueue,
              networkService: _networkService,
              sessionService: _sessionService,
            ),
            SettingsPage(deviceRepo: _deviceRepo),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentTab,
          onDestinationSelected: (index) => setState(() => _currentTab = index),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.cast_rounded), label: '配对'),
            NavigationDestination(
              icon: Icon(Icons.cloud_upload_outlined),
              label: '传输',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingFile {
  _IncomingFile({
    required this.clientId,
    required this.savePath,
    required this.raf,
    required this.totalBytes,
    required this.fileName,
    required this.expectedSha256,
    required this.resumeToken,
  });

  String clientId;
  final String savePath;
  RandomAccessFile? raf;
  final int totalBytes;
  final String fileName;
  final String expectedSha256;
  final String resumeToken;
  int receivedBytes = 0;
}
