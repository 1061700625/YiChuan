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
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
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

    testWidgets('shows pairing code when generated', (tester) async {
      final code = sessionService.generatePairingCode();
      await tester.pumpWidget(_buildApp(
        PairingPage(
          sessionService: sessionService,
          discoveryService: discoveryService,
          networkService: networkService,
        ),
      ));

      expect(find.text(code), findsOneWidget);
    });

    testWidgets('shows connected badge when session is paired', (tester) async {
      final code = sessionService.generatePairingCode();
      await sessionService.handlePairRequest(
        deviceId: 'phone-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      await tester.pumpWidget(_buildApp(
        PairingPage(
          sessionService: sessionService,
          discoveryService: discoveryService,
          networkService: networkService,
        ),
      ));

      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('断开'), findsOneWidget);
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

      await tester.pumpWidget(_buildApp(
        PairingPage(
          sessionService: sessionService,
          discoveryService: discoveryService,
          networkService: networkService,
        ),
      ));

      expect(find.text('Windows PC'), findsOneWidget);
      expect(find.text('10.0.0.5:45678'), findsOneWidget);

      discoveryService.stopScanning();
    });

    testWidgets('does not show manual connection form', (tester) async {
      await tester.pumpWidget(_buildApp(
        PairingPage(
          sessionService: sessionService,
          discoveryService: discoveryService,
          networkService: networkService,
        ),
      ));
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pumpAndSettle();

      expect(find.text('手动连接'), findsNothing);
      expect(find.text('IP 地址'), findsNothing);
      expect(find.text('端口'), findsNothing);
    });
  });
}
