import 'dart:async';

import '../session/trusted_device.dart';

class DiscoveredServiceInfo {
  const DiscoveredServiceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.ip,
    required this.port,
    required this.protocolVersion,
    required this.discoveredAt,
  });

  final String deviceId;
  final String deviceName;
  final DevicePlatform platform;
  final String ip;
  final int port;
  final int protocolVersion;
  final DateTime discoveredAt;
}

class PublishedServiceInfo {
  const PublishedServiceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.port,
  });

  final String deviceId;
  final String deviceName;
  final DevicePlatform platform;
  final int port;
}

class DiscoveryService {
  DiscoveryService({this.discoveryTtl = const Duration(seconds: 30)});

  final Duration discoveryTtl;
  bool _isScanning = false;
  PublishedServiceInfo? _publishedService;
  final _devices = <String, _DiscoveredEntry>{};
  final _listeners = <void Function(DiscoveredServiceInfo device)>{};
  Timer? _cleanupTimer;

  bool get isScanning => _isScanning;

  PublishedServiceInfo? get publishedService => _publishedService;

  List<DiscoveredServiceInfo> get recentDevices {
    final now = DateTime.now();
    final active = <DiscoveredServiceInfo>[];
    for (final entry in _devices.values) {
      if (now.isBefore(entry.info.discoveredAt.add(discoveryTtl))) {
        active.add(entry.info);
      }
    }
    active.sort((a, b) => b.discoveredAt.compareTo(a.discoveredAt));
    return active;
  }

  void startScanning() {
    _isScanning = true;
    _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      _devices.removeWhere((ip, entry) {
        return !now.isBefore(entry.info.discoveredAt.add(discoveryTtl));
      });
    });
  }

  void stopScanning() {
    _isScanning = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _devices.clear();
  }

  void publishService({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int port,
  }) {
    _publishedService = PublishedServiceInfo(
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      port: port,
    );
  }

  void injectDiscoveredDevice({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required String ip,
    required int port,
  }) {
    if (!_isScanning) return;

    final normalizedIp = _normalizeIp(ip);
    if (normalizedIp.isEmpty) return;

    final existing = _devices[normalizedIp]?.info;
    final info = DiscoveredServiceInfo(
      deviceId: _preferDeviceId(deviceId, existing?.deviceId),
      deviceName: _preferDeviceName(deviceName, existing?.deviceName, normalizedIp),
      platform: platform,
      ip: normalizedIp,
      port: port > 0 ? port : (existing?.port ?? port),
      protocolVersion: 1,
      discoveredAt: DateTime.now(),
    );

    _devices[normalizedIp] = _DiscoveredEntry(info: info);

    for (final listener in _listeners) {
      listener(info);
    }
  }

  String _normalizeIp(String ip) {
    final trimmed = ip.trim();
    if (trimmed == 'localhost') return '127.0.0.1';
    return trimmed;
  }

  String _preferDeviceId(String incoming, String? existing) {
    if (existing == null || existing.startsWith('scanned-') || existing.startsWith('manual-')) {
      return incoming;
    }
    if (incoming.startsWith('scanned-') || incoming.startsWith('manual-')) {
      return existing;
    }
    return incoming;
  }

  String _preferDeviceName(String incoming, String? existing, String ip) {
    final cleanIncoming = incoming.trim();
    final cleanExisting = existing?.trim();

    if (_isUsefulDeviceName(cleanIncoming, ip)) return cleanIncoming;
    if (cleanExisting != null && _isUsefulDeviceName(cleanExisting, ip)) return cleanExisting;
    if (cleanIncoming.isNotEmpty) return cleanIncoming;
    return cleanExisting?.isNotEmpty == true ? cleanExisting! : '未知设备 ($ip)';
  }

  bool _isUsefulDeviceName(String name, String ip) {
    if (name.isEmpty) return false;
    final lower = name.toLowerCase();
    if (lower == 'localhost') return false;
    if (name == ip) return false;
    if (name == '未知设备 ($ip)') return false;
    if (name == '手动设备 ($ip)') return false;
    return true;
  }

  void addListener(void Function(DiscoveredServiceInfo device) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(DiscoveredServiceInfo device) listener) {
    _listeners.remove(listener);
  }
}

class _DiscoveredEntry {
  const _DiscoveredEntry({required this.info});
  final DiscoveredServiceInfo info;
}
