import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'discovery_service.dart';
import '../session/trusted_device.dart';

class UdpDiscoveryService extends DiscoveryService {
  UdpDiscoveryService({super.discoveryTtl});

  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _receiveSocket;
  Timer? _broadcastTimer;
  StreamSubscription<RawSocketEvent>? _receiveSubscription;

  static const _broadcastPort = 45677;
  static const _discoveryTag = 'LOCAL_MESH_DISCOVER';

  /// Start broadcasting local service info via UDP.
  /// Called on the desktop (server) side.
  Future<void> startBroadcasting({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int servicePort,
  }) async {
    publishService(
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      port: servicePort,
    );

    // Bind send socket to a random ephemeral port
    _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sendSocket!.broadcastEnabled = true;

    // Send discovery broadcast every 5 seconds
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_sendSocket == null) return;
      final message = '$_discoveryTag|$deviceId|$deviceName|${platform.name}|$servicePort';
      final data = utf8.encode(message);
      _sendSocket!.send(
        data,
        InternetAddress('255.255.255.255'),
        _broadcastPort,
      );
    });

    // Also immediately send one
    final msg = '$_discoveryTag|$deviceId|$deviceName|${platform.name}|$servicePort';
    _sendSocket!.send(
      utf8.encode(msg),
      InternetAddress('255.255.255.255'),
      _broadcastPort,
    );
  }

  @override
  void startScanning() {
    super.startScanning(); // starts cleanup timer
    _startListening();
  }

  Future<void> _startListening() async {
    if (_receiveSocket != null) return; // already listening

    try {
      _receiveSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _broadcastPort,
      );
      _receiveSocket!.broadcastEnabled = true;

      _receiveSubscription = _receiveSocket!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = _receiveSocket!.receive();
        if (datagram == null) return;

        try {
          final message = utf8.decode(datagram.data);
          final parts = message.split('|');
          if (parts.length < 5 || parts[0] != _discoveryTag) return;

          final deviceId = parts[1];
          final deviceName = parts[2];
          final platformStr = parts[3];
          final port = int.tryParse(parts[4]) ?? 0;
          final ip = datagram.address.address;

          // Don't add ourselves
          final self = publishedService;
          if (self != null && deviceId == self.deviceId) return;

          final platform = switch (platformStr) {
            'macos' => DevicePlatform.macos,
            'windows' => DevicePlatform.windows,
            'android' => DevicePlatform.android,
            _ => DevicePlatform.macos,
          };

          injectDiscoveredDevice(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            ip: ip,
            port: port,
          );
        } catch (_) {
          // ignore malformed packets
        }
      });
    } catch (_) {
      // Binding failed (e.g., port in use) — discovery will work via retry
      _receiveSocket = null;
    }
  }

  @override
  void stopScanning() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _receiveSubscription?.cancel();
    _receiveSubscription = null;

    _sendSocket?.close();
    _sendSocket = null;

    _receiveSocket?.close();
    _receiveSocket = null;

    super.stopScanning();
  }

  void dispose() {
    stopScanning();
  }
}
