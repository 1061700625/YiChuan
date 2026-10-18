import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/features/settings/settings_page.dart';

void main() {
  testWidgets('about card opens the project GitHub page', (tester) async {
    String? openedUrl;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          deviceRepo: DeviceRepository(),
          openUrl: (url) async {
            openedUrl = url;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('驿传 v1.0.3'));
    await tester.pump();

    expect(openedUrl, projectGitHubUrl);
  });
}
