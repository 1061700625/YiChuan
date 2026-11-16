import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/discovery/udp_discovery_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

void main() {
  testWidgets('disposing during UDP bind does not restart discovery', (
    tester,
  ) async {
    final discovery = UdpDiscoveryService();
    await tester.runAsync(() async {
      final starting = discovery.startBroadcasting(
        deviceId: 'local',
        deviceName: 'Local',
        platform: DevicePlatform.macos,
        servicePort: 45678,
      );
      discovery.dispose();
      await starting;
    });
    discovery.startScanning();
    expect(discovery.isScanning, isFalse);
    discovery.dispose();
  });

  testWidgets('receive bind failure retries while scanning', (tester) async {
    var bindAttempts = 0;
    final discovery = UdpDiscoveryService(
      listenRetryDelay: const Duration(milliseconds: 10),
      receiveSocketBinder: (address, port) async {
        bindAttempts++;
        if (bindAttempts == 1) {
          throw const SocketException('port temporarily unavailable');
        }
        return RawDatagramSocket.bind(address, 0);
      },
    );

    await tester.runAsync(() async {
      discovery.startScanning();
      final bindDeadline = DateTime.now().add(const Duration(seconds: 1));
      while (bindAttempts < 2 && DateTime.now().isBefore(bindDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    expect(bindAttempts, greaterThanOrEqualTo(2));
    discovery.dispose();
  });
}
