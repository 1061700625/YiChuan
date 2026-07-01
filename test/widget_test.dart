import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/features/pairing/pairing_page.dart';
import 'package:local_mesh_transfer/core/discovery/discovery_service.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
    home: child,
  );
}

void main() {
  testWidgets('pairing page shows pairing code', (WidgetTester tester) async {
    final sessionService = SessionService(deviceRepo: DeviceRepository());
    final code = sessionService.generatePairingCode();

    await tester.pumpWidget(_buildApp(
      PairingPage(
        sessionService: sessionService,
        discoveryService: DiscoveryService(),
        networkService: InMemoryNetworkService(),
      ),
    ));

    expect(find.text(code), findsOneWidget);
  });
}
