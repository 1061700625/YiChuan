import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/session/session_service.dart';
import '../../core/session/trusted_device.dart';
import '../../core/discovery/discovery_service.dart';
import '../../core/discovery/subnet_scanner.dart';
import '../../core/network/network_service.dart';
import '../../core/protocol/protocol_message.dart';
import '../../core/platform/device_identity.dart';
import '../../core/platform/network_info.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    required this.sessionService,
    required this.discoveryService,
    required this.networkService,
    required this.localDeviceId,
    this.statusMessage = '',
    this.onRequestTrust,
    this.trustPending = false,
    super.key,
  });

  final SessionService sessionService;
  final DiscoveryService discoveryService;
  final NetworkService networkService;
  final String localDeviceId;
  final String statusMessage;
  final Future<void> Function()? onRequestTrust;
  final bool trustPending;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  String _pairingCode = '';
  Timer? _codeTimer;
  bool _connecting = false;
  final _inputController = TextEditingController();
  bool _scanningNetwork = false;
  String _ownIp = '';

  final _subnetScanner = SubnetScanner();

  @override
  void initState() {
    super.initState();
    _pairingCode = widget.sessionService.generatePairingCode();

    _codeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.sessionService.state == SessionState.paired) return;
      final code = widget.sessionService.generatePairingCode();
      if (code != _pairingCode && mounted) {
        setState(() => _pairingCode = code);
      }
    });

    widget.sessionService.addListener(_onSessionChanged);

    // Listen for new discovered devices → refresh UI
    widget.discoveryService.addListener(_onDeviceDiscovered);

    // Get own IP for diagnostics and subnet scanning
    _initNetworkInfo();
  }

  Future<void> _initNetworkInfo() async {
    final ip = await NetworkInfo.getLocalIp();
    if (ip != null && mounted) {
      setState(() => _ownIp = ip);
    }
  }

  @override
  void dispose() {
    widget.sessionService.removeListener(_onSessionChanged);
    _codeTimer?.cancel();
    widget.discoveryService.removeListener(_onDeviceDiscovered);
    _inputController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _onDeviceDiscovered(DiscoveredServiceInfo _) {
    if (mounted) setState(() {});
  }

  void _refreshCode() {
    setState(() {
      widget.sessionService.forceExpire();
      _pairingCode = widget.sessionService.generatePairingCode();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.sessionService.state;

    return Scaffold(
      appBar: AppBar(title: const Text('配对'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: state == SessionState.paired
            ? _buildConnectedView(scheme)
            : _buildPairingView(scheme),
      ),
    );
  }

  Widget _buildConnectedView(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 64, color: scheme.primary),
          const SizedBox(height: 16),
          Text('已连接', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (widget.statusMessage.isNotEmpty &&
              widget.statusMessage != '已互相信任')
            Text(widget.statusMessage),
          if (widget.sessionService.isPeerTrusted) const Text('已互相信任'),
          if (widget.onRequestTrust != null &&
              !widget.sessionService.isPeerTrusted)
            FilledButton.tonal(
              onPressed: widget.trustPending ? null : widget.onRequestTrust,
              child: Text(widget.trustPending ? '等待对方确认信任…' : '申请互相信任'),
            ),
          const SizedBox(height: 32),
          FilledButton.tonal(
            onPressed: () async {
              // Disconnect all WebSocket connections
              for (final clientId in widget.networkService.connectedClients) {
                await widget.networkService.disconnect(clientId);
              }
              if (mounted) {
                setState(() {
                  widget.sessionService.disconnect();
                  _pairingCode = widget.sessionService.generatePairingCode();
                });
              }
            },
            child: const Text('断开'),
          ),
        ],
      ),
    );
  }

  Widget _buildPairingView(ColorScheme scheme) {
    return ListView(
      children: [
        if (widget.statusMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              color: scheme.primaryContainer.withAlpha(100),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.statusMessage,
                        style: TextStyle(fontSize: 13, color: scheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Desktop mode: show pairing code
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text('配对码', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                Text(
                  _pairingCode,
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 8,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '在手机上输入此 6 位验证码（5 分钟内有效，过期自动刷新）',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: _refreshCode,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Discovered devices
        Text('附近设备', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _buildDeviceListView(scheme),
        const SizedBox(height: 24),
        // Subnet scan
        _buildScanSection(scheme),
      ],
    );
  }

  Widget _buildDeviceListView(ColorScheme scheme) {
    final devices = widget.discoveryService.recentDevices;

    if (devices.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              '正在搜索附近设备…',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    return Column(
      children: devices.map((device) {
        return Card(
          child: ListTile(
            leading: Icon(
              device.platform == DevicePlatform.macos
                  ? Icons.desktop_mac
                  : device.platform == DevicePlatform.windows
                  ? Icons.desktop_windows
                  : Icons.phone_android,
            ),
            title: Text(device.deviceName),
            subtitle: Text('${device.ip}:${device.port}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _connecting ? null : () => _showPairDialog(device),
                  child: const Text('配对码'),
                ),
                FilledButton(
                  onPressed: _connecting ? null : () => _connectOrPair(device),
                  child: const Text('连接'),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildScanSection(ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi, size: 16, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  '本机 IP：${_ownIp.isEmpty ? "获取中…" : _ownIp}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _scanningNetwork ? null : _startSubnetScan,
                icon: _scanningNetwork
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find),
                label: Text(_scanningNetwork ? '正在扫描局域网…' : '扫描局域网设备'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startSubnetScan() async {
    if (_ownIp.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法获取本机 IP，请确认已连接 WiFi')));
      }
      return;
    }

    setState(() => _scanningNetwork = true);

    try {
      final found = await _subnetScanner.scan(ownIp: _ownIp);

      if (found.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '未扫描到设备，请检查：\n1. 桌面端已启动\n2. 手机和电脑在同一 WiFi\n3. macOS 防火墙未阻止端口 45678',
            ),
          ),
        );
      } else {
        for (final device in found) {
          // Inject into discovery service so they appear in the nearby list
          widget.discoveryService.injectDiscoveredDevice(
            deviceId: device.deviceId,
            deviceName: device.deviceName,
            platform: device.platform,
            ip: device.ip,
            port: device.port,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫描出错: $e')));
      }
    } finally {
      if (mounted) setState(() => _scanningNetwork = false);
    }
  }

  Future<void> _connectOrPair(DiscoveredServiceInfo device) async {
    final trusted = await widget.sessionService.trustedDevice(device.deviceId);
    if (!mounted || _connecting) return;
    if (trusted?.canReconnect == true) {
      await _connectToDevice(
        host: device.ip,
        port: device.port,
        peerDeviceId: device.deviceId,
        peerDeviceName: device.deviceName,
        peerPlatform: device.platform,
        pairingCode: '',
        trustSecret: trusted!.trustSecret,
      );
    } else {
      _showPairDialog(device);
    }
  }

  void _showPairDialog(DiscoveredServiceInfo device) {
    _inputController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('连接 ${device.deviceName}'),
        content: TextField(
          controller: _inputController,
          decoration: const InputDecoration(
            labelText: '6 位配对码',
            hintText: '输入桌面显示的配对码',
          ),
          maxLength: 6,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _connectToDevice(
                host: device.ip,
                port: device.port,
                peerDeviceId: device.deviceId,
                peerDeviceName: device.deviceName,
                peerPlatform: device.platform,
                pairingCode: _inputController.text.trim(),
              );
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectToDevice({
    required String host,
    required int port,
    required String peerDeviceId,
    required String peerDeviceName,
    required DevicePlatform peerPlatform,
    required String pairingCode,
    String? trustSecret,
  }) async {
    if (_connecting || widget.sessionService.state == SessionState.paired)
      return;
    if (trustSecret == null && pairingCode.length != 6) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('配对码必须为 6 位数字')));
      }
      return;
    }
    if (widget.localDeviceId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本机服务仍在初始化，请稍后重试')));
      }
      return;
    }

    setState(() => _connecting = true);
    String? pendingClientId;
    var paired = false;
    MessageReceivedCallback? pairingCallback;
    MessageReceivedCallback? originalCallback;
    var callbackInstalled = false;
    try {
      final clientId = await widget.networkService.connect(
        host: host,
        port: port,
      );
      pendingClientId = clientId;
      if (clientId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('无法连接到 $host:$port\n• 桌面端是否已启动？\n• 防火墙是否阻止了连接？'),
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      final localDeviceName = await getLocalDeviceName();
      var challenge = '';
      final challengeCompleter = Completer<String>();
      final request = ProtocolMessage(
        type: ProtocolMessageType.pairRequest,
        version: 1,
        messageId: 'pair_req_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        payload: {
          'deviceId': widget.localDeviceId,
          'deviceName': localDeviceName,
          'platform': DevicePlatform.current.wireName,
          'pairingCode': pairingCode,
        },
      );

      final completer = Completer<PairResult>();
      originalCallback = widget.networkService.onMessageReceived;

      pairingCallback = (sourceClientId, message) {
        if (sourceClientId == clientId &&
            message.version == 1 &&
            message.type == ProtocolMessageType.pairResult &&
            !completer.isCompleted) {
          final serverProof = message.payload['serverProof'];
          final verified =
              trustSecret == null ||
              (challenge.isNotEmpty &&
                  message.sessionId != null &&
                  serverProof ==
                      SessionService.trustProof(
                        trustSecret,
                        '$challenge:${message.sessionId}',
                        peerDeviceId,
                      ));
          final success = message.payload['success'] == true && verified;
          completer.complete(
            PairResult(
              success: success,
              sessionId: message.sessionId,
              error: success
                  ? null
                  : (message.payload['error'] as String? ??
                        '信任验证失败，请使用配对码重新连接'),
            ),
          );
        }
        if (sourceClientId == clientId &&
            message.version == 1 &&
            message.type == ProtocolMessageType.trustedChallenge &&
            message.payload['challenge'] is String &&
            !challengeCompleter.isCompleted) {
          challengeCompleter.complete(message.payload['challenge'] as String);
        }
        return originalCallback?.call(sourceClientId, message);
      };
      widget.networkService.onMessageReceived = pairingCallback;
      callbackInstalled = true;

      var outgoingRequest = request;
      if (trustSecret != null) {
        if (!await widget.networkService.send(
          clientId,
          ProtocolMessage(
            type: ProtocolMessageType.trustedChallengeRequest,
            version: 1,
            messageId: 'challenge_${request.messageId}',
            timestamp: DateTime.now(),
            payload: {},
          ),
        ))
          throw StateError('连接已断开');
        challenge = await challengeCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        final payload = Map<String, Object?>.from(request.payload)
          ..remove('pairingCode')
          ..addAll({
            'challenge': challenge,
            'proof': SessionService.trustProof(
              trustSecret,
              challenge,
              widget.localDeviceId,
            ),
          });
        outgoingRequest = ProtocolMessage(
          type: request.type,
          version: 1,
          messageId: request.messageId,
          timestamp: request.timestamp,
          payload: payload,
        );
      }
      if (!await widget.networkService.send(clientId, outgoingRequest)) {
        throw StateError('连接已断开');
      }

      final result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => const PairResult(success: false, error: '连接超时'),
      );

      if (!mounted) return;
      if (result.success) {
        await widget.sessionService.acceptPairResult(
          clientId: clientId,
          sessionId: result.sessionId!,
          peerDeviceId: peerDeviceId,
          peerDeviceName: peerDeviceName,
          peerPlatform: peerPlatform,
        );
        paired = true;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('配对成功！'),
              backgroundColor: Colors.green,
            ),
          );
          setState(() {});
        }
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.error ?? '配对失败')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('连接出错: $e')));
      }
    } finally {
      if (callbackInstalled &&
          identical(widget.networkService.onMessageReceived, pairingCallback)) {
        widget.networkService.onMessageReceived = originalCallback;
      }
      try {
        if (!paired && pendingClientId != null) {
          await widget.networkService.disconnect(pendingClientId);
        }
      } finally {
        if (mounted) setState(() => _connecting = false);
      }
    }
  }
}
