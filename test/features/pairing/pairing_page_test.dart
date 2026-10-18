import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/features/pairing/pairing_page.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/discovery/discovery_service.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    ),
    home: child,
  );
}

void main() {
  group('PairingPage', () {
    late SessionService sessionService;
    late DeviceRepository deviceRepo;
    late DiscoveryService discoveryService;
    late InMemoryNetworkService networkService;

    setUp(() {
      deviceRepo = DeviceRepository();
      sessionService = SessionService(deviceRepo: deviceRepo);
      discoveryService = DiscoveryService();
      networkService = InMemoryNetworkService();
    });

    tearDown(() {
      discoveryService.stopScanning();
      networkService.stopServer();
    });

    Future<void> openConnection(WidgetTester tester) async {
      discoveryService.startScanning();
      discoveryService.injectDiscoveredDevice(
        deviceId: 'pc',
        deviceName: 'Peer',
        platform: DevicePlatform.macos,
        ip: '10.0.0.5',
        port: 45678,
      );
      await tester.pumpWidget(
        _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local',
          ),
        ),
      );
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.widgetWithText(FilledButton, '连接').last);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'disables another connection while pairing and cleans timeout',
      (tester) async {
        await openConnection(tester);
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '连接'),
        );
        expect(button.onPressed, isNull);
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(networkService.connectedClients, isEmpty);
        discoveryService.stopScanning();
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('closes rejected connection and restores message handler', (
      tester,
    ) async {
      MessageReceivedCallback original = (_, _) {};
      networkService.onMessageReceived = original;
      await openConnection(tester);
      final client = networkService.connectedClients.single;
      await networkService.injectMessageFrom(
        client,
        ProtocolMessage(
          type: ProtocolMessageType.pairResult,
          version: 1,
          messageId: 'response',
          timestamp: DateTime.now(),
          payload: {'success': false, 'error': 'wrong code'},
        ),
      );
      await tester.pumpAndSettle();
      expect(networkService.connectedClients, isEmpty);
      expect(networkService.onMessageReceived, same(original));
      discoveryService.stopScanning();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('replaces consumed code after disconnect', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local',
          ),
        ),
      );
      final oldCode = sessionService.generatePairingCode();
      await sessionService.handlePairRequest(
        clientId: 'peer',
        deviceId: 'peer',
        deviceName: 'Peer',
        platform: DevicePlatform.macos,
        pairingCode: oldCode,
      );
      sessionService.disconnect();
      await tester.pump(const Duration(seconds: 1));
      final code = sessionService.generatePairingCode();
      expect(find.text(code), findsOneWidget);
      final result = await sessionService.handlePairRequest(
        clientId: 'next',
        deviceId: 'next',
        deviceName: 'Next',
        platform: DevicePlatform.macos,
        pairingCode: code,
      );
      expect(result.success, isTrue);
      discoveryService.stopScanning();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'paired device can request trust and pending request is disabled',
      (tester) async {
        await sessionService.acceptPairResult(
          clientId: 'peer',
          sessionId: 'session',
          peerDeviceId: 'pc',
          peerDeviceName: 'Peer',
          peerPlatform: DevicePlatform.macos,
        );
        var requests = 0;
        Widget page(bool pending) => _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local',
            trustPending: pending,
            onRequestTrust: () async {
              requests++;
            },
          ),
        );
        await tester.pumpWidget(page(false));
        await tester.tap(find.text('申请互相信任'));
        await tester.pump();
        expect(requests, 1);
        await tester.pumpWidget(page(true));
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '等待对方确认信任…'),
        );
        expect(button.onPressed, isNull);
        discoveryService.stopScanning();
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'trust action disappears immediately after acceptance and returns after revocation',
      (tester) async {
        await sessionService.acceptPairResult(
          clientId: 'peer',
          sessionId: 'session',
          peerDeviceId: 'pc',
          peerDeviceName: 'Peer',
          peerPlatform: DevicePlatform.macos,
        );
        await tester.pumpWidget(
          _buildApp(
            PairingPage(
              sessionService: sessionService,
              discoveryService: discoveryService,
              networkService: networkService,
              localDeviceId: 'local',
              onRequestTrust: () async {},
            ),
          ),
        );
        expect(find.text('申请互相信任'), findsOneWidget);
        await sessionService.trustPeer(
          'peer',
          'session',
          sessionService.newTrustSecret(),
        );
        await tester.pump();
        expect(find.text('申请互相信任'), findsNothing);
        expect(find.text('已互相信任'), findsOneWidget);
        await deviceRepo.delete('pc');
        await tester.pump();
        await tester.pump();
        expect(find.text('申请互相信任'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final validServer in [true, false]) {
      testWidgets('trusted reconnect verifies server proof ($validServer)', (
        tester,
      ) async {
        final secret = sessionService.newTrustSecret();
        await deviceRepo.save(
          TrustedDevice(
            id: 'pc',
            name: 'Peer',
            platform: DevicePlatform.macos,
            trustSecret: secret,
          ),
        );
        discoveryService.startScanning();
        discoveryService.injectDiscoveredDevice(
          deviceId: 'pc',
          deviceName: 'Peer',
          platform: DevicePlatform.macos,
          ip: '10.0.0.5',
          port: 45678,
        );
        await tester.pumpWidget(
          _buildApp(
            PairingPage(
              sessionService: sessionService,
              discoveryService: discoveryService,
              networkService: networkService,
              localDeviceId: 'local',
            ),
          ),
        );
        await tester.tap(find.widgetWithText(FilledButton, '连接'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        final client = networkService.connectedClients.single;
        await networkService.injectMessageFrom(
          client,
          ProtocolMessage(
            type: ProtocolMessageType.trustedChallenge,
            version: 1,
            messageId: 'challenge',
            timestamp: DateTime.now(),
            payload: {'challenge': 'fresh-nonce'},
          ),
        );
        await tester.pumpAndSettle();
        final request = networkService.messageLog.lastWhere(
          (message) => message.type == ProtocolMessageType.pairRequest,
        );
        expect(request.payload.containsKey('pairingCode'), isFalse);
        expect(
          request.payload['proof'],
          SessionService.trustProof(secret, 'fresh-nonce', 'local'),
        );
        await networkService.injectMessageFrom(
          client,
          ProtocolMessage(
            type: ProtocolMessageType.pairResult,
            version: 1,
            sessionId: 'session',
            messageId: 'result',
            timestamp: DateTime.now(),
            payload: {
              'success': true,
              'serverProof': validServer
                  ? SessionService.trustProof(
                      secret,
                      'fresh-nonce:session',
                      'pc',
                    )
                  : 'forged',
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(sessionService.state == SessionState.paired, validServer);
        expect(networkService.connectedClients.isNotEmpty, validServer);
        discoveryService.stopScanning();
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('shows pairing code when generated', (tester) async {
      final code = sessionService.generatePairingCode();
      await tester.pumpWidget(
        _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local-1',
          ),
        ),
      );

      expect(find.text(code), findsOneWidget);
      discoveryService.stopScanning();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows connected badge when session is paired', (tester) async {
      final code = sessionService.generatePairingCode();
      await sessionService.handlePairRequest(
        clientId: 'client-1',
        deviceId: 'phone-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      await tester.pumpWidget(
        _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local-1',
          ),
        ),
      );

      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('断开'), findsOneWidget);
      discoveryService.stopScanning();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows discovered devices when scanning', (tester) async {
      discoveryService.startScanning();
      discoveryService.injectDiscoveredDevice(
        deviceId: 'pc-1',
        deviceName: 'Windows PC',
        platform: DevicePlatform.windows,
        ip: '10.0.0.5',
        port: 45678,
      );

      await tester.pumpWidget(
        _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local-1',
          ),
        ),
      );

      expect(find.text('Windows PC'), findsOneWidget);
      expect(find.text('10.0.0.5:45678'), findsOneWidget);

      discoveryService.stopScanning();
      discoveryService.stopScanning();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('does not show manual connection form', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          PairingPage(
            sessionService: sessionService,
            discoveryService: discoveryService,
            networkService: networkService,
            localDeviceId: 'local-1',
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pumpAndSettle();

      expect(find.text('手动连接'), findsNothing);
      expect(find.text('IP 地址'), findsNothing);
      expect(find.text('端口'), findsNothing);
      discoveryService.stopScanning();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
