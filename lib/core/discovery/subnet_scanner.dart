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
    this.connectionTimeout = const Duration(seconds: 2),
    this.maxConcurrent = 20,
  });

  final int scanPort;
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
      final ips = _buildCandidates(ownIp);
      final results = <DiscoveredServiceInfo>[];

      // Process in batches to avoid too many concurrent connections
      for (var i = 0; i < ips.length; i += maxConcurrent) {
        final end = (i + maxConcurrent < ips.length) ? i + maxConcurrent : ips.length;
        final batch = ips.sublist(i, end);
        final batchResults = await Future.wait(
          batch.map((ip) => _tryConnect(ip, scanPort)),
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
        '192.168.1.1', '192.168.1.100',
        '192.168.0.1', '192.168.0.100',
        '10.0.0.1', '10.0.0.100',
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
    try {
      final socket = await WebSocket.connect(
        'ws://$ip:$port',
      ).timeout(connectionTimeout);

      // Try to read the first message (should be a hello announcement)
      String deviceName = '未知设备 ($ip)';
      try {
        // Use a completer to get the first message from the stream
        final completer = Completer<String>();
        final sub = socket.listen(
          (data) {
            if (!completer.isCompleted) completer.complete(data as String);
          },
          onError: (e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
        );
        final data = await completer.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => '',
        );
        await sub.cancel();
        if (data.isNotEmpty) {
          final json = jsonDecode(data) as Map<String, Object?>;
          if (json['type'] == 'hello') {
            final payload = json['payload'] as Map<String, Object?>?;
            if (payload != null) {
              final announcedName = (payload['deviceName'] as String?)?.trim();
              if (announcedName != null &&
                  announcedName.isNotEmpty &&
                  announcedName.toLowerCase() != 'localhost') {
                deviceName = announcedName;
              }
            }
          }
        }
      } catch (_) {
        // No hello message received, use default name
      }

      final info = DiscoveredServiceInfo(
        deviceId: 'scanned-$ip',
        deviceName: deviceName,
        platform: DevicePlatform.macos,
        ip: ip,
        port: port,
        protocolVersion: 1,
        discoveredAt: DateTime.now(),
      );

      await socket.close();
      return info;
    } catch (_) {
      return null;
    }
  }
}
