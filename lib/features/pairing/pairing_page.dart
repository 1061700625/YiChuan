import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/session/session_service.dart';
import '../../core/session/trusted_device.dart';
import '../../core/discovery/discovery_service.dart';
import '../../core/discovery/subnet_scanner.dart';
import '../../core/network/network_service.dart';
import '../../core/protocol/protocol_message.dart';
import '../../core/platform/android_permissions.dart';
import '../../core/platform/network_info.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    required this.sessionService,
    required this.discoveryService,
    required this.networkService,
    this.statusMessage = '',
    super.key,
  });

  final SessionService sessionService;
  final DiscoveryService discoveryService;
  final NetworkService networkService;
  final String statusMessage;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  String _pairingCode = '';
  final _inputController = TextEditingController();
  bool _connecting = false;
  bool _scanningNetwork = false;
  String _ownIp = '';

  final _subnetScanner = SubnetScanner();

  @override
  void initState() {
    super.initState();
    _pairingCode = widget.sessionService.generatePairingCode();

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
    widget.discoveryService.removeListener(_onDeviceDiscovered);
    _inputController.dispose();
    super.dispose();
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
      appBar: AppBar(
        title: const Text('配对'),
        centerTitle: true,
      ),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(widget.statusMessage,
                        style: TextStyle(fontSize: 13, color: scheme.onSurface)),
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
                Text('在手机上输入此 6 位验证码', style: Theme.of(context).textTheme.bodyMedium),
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
            child: Text('正在搜索附近设备…', style: Theme.of(context).textTheme.bodyMedium),
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
            trailing: FilledButton(
              onPressed: () => _showPairDialog(device),
              child: const Text('连接'),
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
                Text('本机 IP：${_ownIp.isEmpty ? "获取中…" : _ownIp}',
                  style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _scanningNetwork ? null : _startSubnetScan,
                icon: _scanningNetwork
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find),
                label: Text(_scanningNetwork
                    ? '正在扫描局域网…'
                    : '扫描局域网设备'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法获取本机 IP，请确认已连接 WiFi')),
        );
      }
      return;
    }

    setState(() => _scanningNetwork = true);

    try {
      final found = await _subnetScanner.scan(ownIp: _ownIp);

      if (found.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未扫描到设备，请检查：\n1. 桌面端已启动\n2. 手机和电脑在同一 WiFi\n3. macOS 防火墙未阻止端口 45678')),
        );
      } else {
        for (final device in found) {
          // Inject into discovery service so they appear in the nearby list
          (widget.discoveryService as dynamic).injectDiscoveredDevice(
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('扫描出错: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanningNetwork = false);
    }
  }

  Future<String> _localDeviceName() async {
    final androidName = await getAndroidDeviceName();
    return androidName ?? NetworkInfo.getDeviceName();
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _connectToDevice(
                host: device.ip,
                port: device.port,
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                platform: device.platform,
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
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required String pairingCode,
  }) async {
    if (pairingCode.length != 6) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('配对码必须为 6 位数字')),
        );
      }
      return;
    }

    setState(() => _connecting = true);

    try {
      final clientId = await widget.networkService.connect(host: host, port: port);
      if (clientId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('无法连接到 $host:$port\n• 桌面端是否已启动？\n• 防火墙是否阻止了连接？')),
          );
        }
        return;
      }

      final localDeviceName = await _localDeviceName();
      final request = ProtocolMessage(
        type: ProtocolMessageType.pairRequest,
        version: 1,
        messageId: 'pair_req_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        payload: {
          'deviceId': deviceId,
          'deviceName': localDeviceName,
          'pairingCode': pairingCode,
        },
      );

      final completer = Completer<PairResult>();
      final originalCallback = widget.networkService.onMessageReceived;

      widget.networkService.onMessageReceived = (message) {
        if (message.type == ProtocolMessageType.pairResult) {
          final success = message.payload['success'] == true;
          completer.complete(PairResult(
            success: success,
            sessionId: message.sessionId,
            error: success ? null : (message.payload['error'] as String? ?? '配对失败'),
          ));
        }
        originalCallback?.call(message);
      };

      await widget.networkService.send(clientId, request);

      final result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => const PairResult(success: false, error: '连接超时'),
      );

      widget.networkService.onMessageReceived = originalCallback;

      if (mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('配对成功！'), backgroundColor: Colors.green),
          );
          setState(() {}); // will show connected state
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.error ?? '配对失败')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接出错: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }
}
