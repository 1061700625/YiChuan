import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_queue_service.dart';
import 'package:local_mesh_transfer/features/transfers/transfer_list_page.dart';

void main() {
  const channel = MethodChannel('com.localmesh/filepicker');
  for (final contentUri in [false, true]) {
    for (final opens in [false, true]) {
      testWidgets(
        'completed APK opens with original name or reveals location (uri=$contentUri, opens=$opens)',
        (tester) async {
          final calls = <MethodCall>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'revealFile' || opens;
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          final queue = TransferQueueService();
          queue.addOffer(taskId: 'file', fileName: '驿传.apk', fileSize: 10);
          if (contentUri) {
            queue.markReceived('file');
            queue.setSavedFileUri(
              'file',
              'content://media/external/downloads/123',
            );
          } else {
            queue.setSentFilePath('file', '/tmp/picked_123.tmp');
          }
          queue.complete('file');
          await tester.pumpWidget(
            MaterialApp(
              home: TransferListPage(
                transferQueue: queue,
                networkService: InMemoryNetworkService(),
                sessionService: SessionService(deviceRepo: DeviceRepository()),
              ),
            ),
          );
          await tester.tap(find.text('驿传.apk'));
          await tester.pumpAndSettle();
          expect(calls.first.method, contentUri ? 'openFile' : 'openLocalFile');
          expect((calls.first.arguments as Map)['fileName'], '驿传.apk');
          expect(calls.map((c) => c.method), [
            contentUri ? 'openFile' : 'openLocalFile',
            if (!opens) 'revealFile',
          ]);
          calls.clear();
          await tester.tap(find.text('打开所在位置'));
          await tester.pumpAndSettle();
          expect(calls.single.method, 'revealFile');
          expect(
            (calls.single.arguments as Map)[contentUri ? 'uri' : 'path'],
            contentUri
                ? 'content://media/external/downloads/123'
                : '/tmp/picked_123.tmp',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'reports failure when no file app or file manager can handle a file',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final queue = TransferQueueService();
      queue.addOffer(taskId: 'file', fileName: 'unknown.bin', fileSize: 10);
      queue.markReceived('file');
      queue.setReceivedFilePath('file', '/tmp/unknown.bin');
      queue.complete('file');
      await tester.pumpWidget(
        MaterialApp(
          home: TransferListPage(
            transferQueue: queue,
            networkService: InMemoryNetworkService(),
            sessionService: SessionService(deviceRepo: DeviceRepository()),
          ),
        ),
      );
      await tester.tap(find.text('unknown.bin'));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法打开或定位文件'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
