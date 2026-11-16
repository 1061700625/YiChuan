import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/discovery/discovery_service.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/features/pairing/pairing_page.dart';

void main() {
  testWidgets('the pairing code renders on one line on a high-density phone', (
    tester,
  ) async {
    // RMX3706: 1240 x 2772 physical pixels at 560dpi => 2.8 device pixel ratio.
    tester.view.physicalSize = const Size(1240, 2772);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = DeviceRepository();
    final session = SessionService(deviceRepo: repo);
    final code = session.generatePairingCode();
    await tester.pumpWidget(
      MaterialApp(
        home: PairingPage(
          sessionService: session,
          discoveryService: DiscoveryService(),
          networkService: InMemoryNetworkService(),
          localDeviceId: 'local',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final finder = find.text(code, findRichText: true);
    expect(finder, findsOneWidget);

    final paragraph = tester.renderObject<RenderParagraph>(finder);
    // RenderParagraph exposes the laid-out line height but not the line count.
    // One laid-out line occupies one preferredLineHeight; a wrap occupies two.
    expect(
      paragraph.size.height,
      lessThan(paragraph.preferredLineHeight * 1.5),
      reason: 'The six-digit pairing code must stay on one line.',
    );

    // The fitted widget must still scale the fixed displayLarge style down to
    // the card's available width rather than clipping or wrapping it.
    final fitted = tester.widget<FittedBox>(
      find.ancestor(of: finder, matching: find.byType(FittedBox)),
    );
    expect(fitted.fit, BoxFit.scaleDown);
  });
}
