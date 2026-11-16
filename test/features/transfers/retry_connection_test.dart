import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_queue_service.dart';
import 'package:local_mesh_transfer/features/transfers/transfer_list_page.dart';

void main() {
  for (final scenario in ['disconnect', 'replace', 'changed']) {
    final changed = scenario == 'changed';
    testWidgets(
      changed
          ? 'same-size source changes require a new transfer'
          : '$scenario while negotiating resume immediately releases retry',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('yichuan-retry-');
        final file = File('${dir.path}/source.bin')
          ..writeAsBytesSync([1, 2, 3, 4]);
        addTearDown(() => dir.deleteSync(recursive: true));
        final queue = TransferQueueService();
        queue.addOffer(taskId: 'file', fileName: 'source.bin', fileSize: 4);
        queue.setSentFilePath('file', file.path);
        queue.setResumeToken('file', 'a' * 32);
        queue.setSentFileSha256(
          'file',
          sha256.convert([1, 2, 3, 4]).toString(),
        );
        queue.fail('file');
        if (changed) file.writeAsBytesSync([4, 3, 2, 1]);
        final network = InMemoryNetworkService();
        final session = SessionService(deviceRepo: DeviceRepository());
        final client = await network.connect(host: '127.0.0.1', port: 1234);
        Future<void> pair(String id) => session.acceptPairResult(
          clientId: id,
          sessionId: id,
          peerDeviceId: 'peer',
          peerDeviceName: 'Peer',
          peerPlatform: DevicePlatform.android,
        );
        await pair(client!);
        await tester.pumpWidget(
          MaterialApp(
            home: TransferListPage(
              transferQueue: queue,
              networkService: network,
              sessionService: session,
            ),
          ),
        );
        await tester.tap(find.text('重试'));
        for (
          var i = 0;
          i < 100 &&
              network.messageLog.isEmpty &&
              find.textContaining('源文件已改变').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        if (changed) {
          expect(find.textContaining('源文件已改变'), findsOneWidget);
          expect(network.messageLog, isEmpty);
          expect(network.binaryMessageLog, isEmpty);
        } else {
          expect(
            network.messageLog.last.type,
            ProtocolMessageType.transferResumeRequest,
          );
          if (scenario == 'disconnect') {
            await network.disconnect(client);
            session.disconnectClient(client);
          } else {
            await session.acceptPairResult(
              clientId: client,
              sessionId: 'replacement',
              peerDeviceId: 'peer',
              peerDeviceName: 'Peer',
              peerPlatform: DevicePlatform.android,
            );
          }
          await tester.pump();
          final next = await network.connect(host: '127.0.0.1', port: 1234);
          await pair(next!);
          await tester.pump();
          await tester.tap(find.text('重试'));
          for (var i = 0; i < 100 && network.messageLog.length < 2; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(
            network.messageLog.where(
              (m) => m.type == ProtocolMessageType.transferResumeRequest,
            ),
            hasLength(2),
          );
          session.disconnect();
          await tester.pump();
        }
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
}
