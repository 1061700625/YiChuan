import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'discovery_service.dart';
import '../session/trusted_device.dart';

/// Scans the local subnet for devices listening on a specific port
/// by attempting WebSocket connections. Used as a fallback when
/// UDP broadcast discovery is blocked by firewalls or WiFi settings.
class SubnetScanner {
  SubnetScanner({
    this.scanPort = 45678,
    this.fallbackPort = 45679,
    this.connectionTimeout = const Duration(seconds: 2),
    this.maxConcurrent = 20,
  });

  final int scanPort;
  final int? fallbackPort;
  final Duration connectionTimeout;
  final int maxConcurrent;

  bool _scanning = false;

  bool get isScanning => _scanning;

  /// Attempt to discover devices by scanning common LAN IPs.
  /// [ownIp] is the device's current WiFi IP (e.g. 192.168.1.5),
  /// used to determine which subnet to scan.
  Future<List<DiscoveredServiceInfo>> scan({required String ownIp}) async {
    if (_scanning) return [];
    _scanning = true;

    try {
      final ports = {scanPort, if (fallbackPort != null) fallbackPort!};
      final candidates = [
        for (final ip in _buildCandidates(ownIp))
          for (final port in ports) (ip: ip, port: port),
      ];
      final results = <DiscoveredServiceInfo>[];

      // Process in batches to avoid too many concurrent connections
      for (var i = 0; i < candidates.length; i += maxConcurrent) {
        final end = (i + maxConcurrent < candidates.length)
            ? i + maxConcurrent
            : candidates.length;
        final batch = candidates.sublist(i, end);
        final batchResults = await Future.wait(
          batch.map((candidate) => _tryConnect(candidate.ip, candidate.port)),
          eagerError: false,
        );
        results.addAll(batchResults.whereType<DiscoveredServiceInfo>());
      }

      return results;
    } finally {
      _scanning = false;
    }
  }

  List<String> _buildCandidates(String ownIp) {
    final candidates = <String>{};

    // Parse own IP to determine subnet
    final parts = ownIp.split('.');
    if (parts.length != 4) {
      candidates.addAll([
        '192.168.1.1',
        '192.168.1.100',
        '192.168.0.1',
        '192.168.0.100',
        '10.0.0.1',
        '10.0.0.100',
        '172.16.0.1',
      ]);
      return candidates.toList();
    }

    final a = parts[0];
    final b = parts[1];
    final c = parts[2];

    // Try .1 (gateway) and common hosts
    candidates.add('$a.$b.$c.1');
    candidates.add('$a.$b.$c.2');
    candidates.add('$a.$b.$c.100');
    candidates.add('$a.$b.$c.101');
    candidates.add('$a.$b.$c.200');
    candidates.add('$a.$b.$c.254');

    // Scan a wider range around our own IP
    final host = int.tryParse(parts[3]) ?? 0;
    for (var offset = -20; offset <= 20; offset++) {
      final candidate = host + offset;
      if (candidate > 0 && candidate < 255 && candidate != host) {
        candidates.add('$a.$b.$c.$candidate');
      }
    }

    // Also try adjacent C-class subnets
    final third = int.tryParse(c) ?? 0;
    for (var i = max(0, third - 1); i <= min(255, third + 1); i++) {
      if (i != third) {
        candidates.add('$a.$b.$i.1');
        candidates.add('$a.$b.$i.100');
      }
    }

    return candidates.toList();
  }

  Future<DiscoveredServiceInfo?> _tryConnect(String ip, int port) async {
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(
        'ws://$ip:$port',
      ).timeout(connectionTimeout);
      final data = await socket.first.timeout(const Duration(seconds: 1));
      if (data is! String) return null;
      final json = jsonDecode(data);
      if (json is! Map || json['type'] != 'hello' || json['version'] != 1) {
        return null;
      }
      final payload = json['payload'];
      if (payload is! Map) return null;
      final deviceId = payload['deviceId'];
      final deviceName = payload['deviceName'];
      final platform = payload['platform'];
      if (deviceId is! String ||
          deviceId.trim().isEmpty ||
          deviceName is! String ||
          deviceName.trim().isEmpty ||
          !DevicePlatform.values.any((value) => value.wireName == platform)) {
        return null;
      }
      return DiscoveredServiceInfo(
        deviceId: deviceId.trim(),
        deviceName: deviceName.trim(),
        platform: DevicePlatform.fromWireName(platform),
        ip: ip,
        port: port,
        protocolVersion: 1,
        discoveredAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    } finally {
      try {
        await socket?.close();
      } catch (_) {
        // A peer may close while its greeting is being validated.
      }
    }
  }
}
