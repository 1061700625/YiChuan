import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/app/app.dart';
import 'package:local_mesh_transfer/core/discovery/udp_discovery_service.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/features/pairing/pairing_page.dart';

class _LocalDiscovery extends UdpDiscoveryService {
  @override
  void startScanning() {
    super.startScanning();
    injectDiscoveredDevice(
      deviceId: 'peer',
      deviceName: 'Peer',
      platform: DevicePlatform.android,
      ip: '127.0.0.1',
      port: 1234,
    );
  }

  @override
  Future<void> startBroadcasting({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int servicePort,
  }) async {}
}

ProtocolMessage _pair(String code) => ProtocolMessage(
  type: ProtocolMessageType.pairRequest,
  version: 1,
  messageId: 'pair',
  timestamp: DateTime.now(),
  payload: {
    'deviceId': 'peer',
    'deviceName': 'Peer',
    'platform': 'android',
    'pairingCode': code,
  },
);

void main() {
  testWidgets('receiver clears previous disconnect status on reconnection', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('yichuan-app-test-');
    });
    final network = InMemoryNetworkService();
    await tester.pumpWidget(
      LocalMeshTransferApp(
        networkService: network,
        discoveryService: _LocalDiscovery(),
        dataDirectory: dir,
      ),
    );
    for (
      var attempt = 0;
      attempt < 100 && network.onMessageReceived == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(
      network.onMessageReceived,
      isNotNull,
      reason: tester
          .widget<PairingPage>(find.byType(PairingPage))
          .statusMessage,
    );
    var session = tester
        .widget<PairingPage>(find.byType(PairingPage))
        .sessionService;
    final first = await network.injectClientConnection(
      deviceId: 'peer',
      deviceName: 'Peer',
      host: '127.0.0.1',
    );
    await tester.runAsync(
      () => network.injectMessageFrom(
        first,
        _pair(session.generatePairingCode()),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => network.disconnect(first));
    await tester.pump();
    final second = await network.injectClientConnection(
      deviceId: 'peer',
      deviceName: 'Peer',
      host: '127.0.0.1',
    );
    await tester.runAsync(
      () => network.injectMessageFrom(
        second,
        _pair(session.generatePairingCode()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
    final pairing = tester.widget<PairingPage>(find.byType(PairingPage));
    expect(pairing.statusMessage, isNot('对方已断开连接'));
    expect(session.pairedClientId, second);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets('trust confirmation does not block reading subsequent frames', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('yichuan-trust-test-');
    });
    final network = InMemoryNetworkService();
    await tester.pumpWidget(
      LocalMeshTransferApp(
        networkService: network,
        discoveryService: _LocalDiscovery(),
        dataDirectory: dir,
      ),
    );
    for (
      var attempt = 0;
      attempt < 100 && network.onMessageReceived == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(
      network.onMessageReceived,
      isNotNull,
      reason: tester
          .widget<PairingPage>(find.byType(PairingPage))
          .statusMessage,
    );
    final session = tester
        .widget<PairingPage>(find.byType(PairingPage))
        .sessionService;
    final client = await network.injectClientConnection(
      deviceId: 'peer',
      deviceName: 'Peer',
      host: '127.0.0.1',
    );
    await tester.runAsync(
      () => network.injectMessageFrom(
        client,
        _pair(session.generatePairingCode()),
      ),
    );
    await tester.pump();
    var released = false;
    final handling = network
        .injectMessageFrom(
          client,
          ProtocolMessage(
            type: ProtocolMessageType.trustRequest,
            version: 1,
            messageId: 'trust',
            sessionId: session.currentSessionId,
            timestamp: DateTime.now(),
            payload: {'secret': session.newTrustSecret()},
          ),
        )
        .then((_) => released = true);
    await tester.pump();
    expect(find.text('信任设备申请'), findsOneWidget);
    expect(
      released,
      isTrue,
      reason: 'The socket reader must resume before the user responds.',
    );
    await tester.tap(find.text('同意并信任'));
    await tester.pump();
    await tester.runAsync(() async {
      await handling;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 100 && !session.isPeerTrusted; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(session.isPeerTrusted, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
