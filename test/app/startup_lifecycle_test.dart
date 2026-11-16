import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/app/app.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/discovery/udp_discovery_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

class DelayedNetwork extends InMemoryNetworkService {
  final gate = Completer<void>();
  bool entered = false;
  @override
  Future<int> startServer({required int port}) async {
    entered = true;
    await gate.future;
    return super.startServer(port: port);
  }
}

class Discovery extends UdpDiscoveryService {
  bool closed = false;
  bool restartedAfterDispose = false;
  @override
  void dispose() {
    closed = true;
    super.dispose();
  }

  @override
  void startScanning() {
    if (closed) restartedAfterDispose = true;
  }

  @override
  Future<void> startBroadcasting({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int servicePort,
  }) async {
    if (closed) restartedAfterDispose = true;
  }
}

void main() {
  testWidgets('disposing during startup must not restart services', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('yichuan-startup-review-');
    final network = DelayedNetwork();
    final discovery = Discovery();
    await tester.pumpWidget(
      LocalMeshTransferApp(
        networkService: network,
        discoveryService: discovery,
        dataDirectory: dir,
      ),
    );
    for (var i = 0; i < 100 && !network.entered; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(network.entered, isTrue);
    await tester.pumpWidget(const SizedBox());
    network.gate.complete();
    for (var i = 0; i < 100 && !discovery.restartedAfterDispose; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 6));
    await tester.runAsync(() => dir.delete(recursive: true));
    expect(discovery.restartedAfterDispose, isFalse);
    expect(network.listeningPort, isNull);
  });
}
