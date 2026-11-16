import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'discovery_service.dart';
import '../session/trusted_device.dart';
import '../platform/network_info.dart';

class UdpDiscoveryService extends DiscoveryService {
  UdpDiscoveryService({
    super.discoveryTtl,
    Duration listenRetryDelay = const Duration(seconds: 1),
    Future<RawDatagramSocket> Function(InternetAddress, int)?
    receiveSocketBinder,
  }) : _listenRetryDelay = listenRetryDelay,
       _receiveSocketBinder = receiveSocketBinder ?? RawDatagramSocket.bind;

  final Duration _listenRetryDelay;
  final Future<RawDatagramSocket> Function(InternetAddress, int)
  _receiveSocketBinder;

  int _generation = 0;
  bool _disposed = false;
  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _receiveSocket;
  Timer? _broadcastTimer;
  Timer? _listenRetryTimer;
  StreamSubscription<RawSocketEvent>? _receiveSubscription;

  static const _broadcastPort = 45677;
  static const _discoveryTag = 'LOCAL_MESH_DISCOVER';

  /// Start broadcasting local service info via UDP.
  /// Called on the desktop (server) side.
  ///
  /// The send socket is pinned to the LAN address. A phone that is on both
  /// WiFi and mobile data otherwise picks its outgoing interface from the
  /// default route (cellular), so a 255.255.255.255 datagram never reaches the
  /// desktop. A wildcard send socket also picks the wrong interface.
  Future<void> startBroadcasting({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int servicePort,
  }) async {
    if (_disposed) return;
    final generation = _generation;
    publishService(
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      port: servicePort,
    );

    final localAddress = await NetworkInfo.getLocalIp();
    final boundAddress = localAddress == null || localAddress.isEmpty
        ? InternetAddress.anyIPv4
        : (InternetAddress.tryParse(localAddress) ?? InternetAddress.anyIPv4);
    final socket = await RawDatagramSocket.bind(boundAddress, 0);
    if (_disposed || generation != _generation) {
      socket.close();
      return;
    }
    _sendSocket = socket;
    _sendSocket!.broadcastEnabled = true;

    // Send discovery broadcast every 5 seconds
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _sendPublishedService(),
    );

    // Also immediately send one
    _sendPublishedService();
  }

  void _sendPublishedService() {
    final socket = _sendSocket;
    final service = publishedService;
    if (socket == null || service == null) return;
    final message =
        '$_discoveryTag|${service.deviceId}|${service.deviceName}|'
        '${service.platform.wireName}|${service.port}';
    socket.send(
      utf8.encode(message),
      InternetAddress('255.255.255.255'),
      _broadcastPort,
    );
  }

  @override
  void startScanning() {
    if (_disposed || isScanning) return;
    super.startScanning(); // starts cleanup timer
    _startListening();
  }

  Future<void> _startListening() async {
    if (_receiveSocket != null || _disposed) return; // already listening

    final generation = _generation;
    try {
      final socket = await _receiveSocketBinder(
        InternetAddress.anyIPv4,
        _broadcastPort,
      );
      if (_disposed || generation != _generation) {
        socket.close();
        return;
      }
      _receiveSocket = socket;
      _listenRetryTimer?.cancel();
      _listenRetryTimer = null;
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

          final platform = DevicePlatform.fromWireName(platformStr);

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
      _receiveSocket = null;
      if (_disposed || generation != _generation || !isScanning) return;
      _listenRetryTimer?.cancel();
      _listenRetryTimer = Timer(_listenRetryDelay, () {
        _listenRetryTimer = null;
        unawaited(_startListening());
      });
    }
  }

  @override
  void stopScanning() {
    _generation++;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _listenRetryTimer?.cancel();
    _listenRetryTimer = null;

    _receiveSubscription?.cancel();
    _receiveSubscription = null;

    _sendSocket?.close();
    _sendSocket = null;

    _receiveSocket?.close();
    _receiveSocket = null;

    super.stopScanning();
  }

  void dispose() {
    _disposed = true;
    stopScanning();
  }
}
