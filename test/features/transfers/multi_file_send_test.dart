import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/binary_transfer_chunk.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_queue_service.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';
import 'package:local_mesh_transfer/features/transfers/transfer_list_page.dart';

class _Receiver extends InMemoryNetworkService {
  _Receiver(this.queue);
  final TransferQueueService queue;
  @override
  Future<bool> sendBinary(String clientId, Uint8List data) async {
    final sent = await super.sendBinary(clientId, data);
    final chunk = BinaryTransferChunk.decode(data);
    if (sent)
      queue.recordProgress(
        chunk.taskId,
        completedBytes: chunk.offset + chunk.data.length,
      );
    return sent;
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  for (final outcome in [
    'complete',
    'reject',
    'disconnect',
    'reconnect',
    'missing',
  ]) {
    testWidgets(
      'multi-selection queues files and handles $outcome independently',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('yichuan-batch-');
        final files = List.generate(
          3,
          (i) => File('${dir.path}/file$i.bin')..writeAsBytesSync([i, i + 1]),
        );
        if (outcome == 'missing') files.first.deleteSync();
        const channel = MethodChannel('com.localmesh/filepicker');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'pickFiles')
            return [
              for (var i = 0; i < files.length; i++)
                {'path': files[i].path, 'name': 'file$i.bin', 'size': 2},
            ];
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          dir.deleteSync(recursive: true);
        });
        final queue = TransferQueueService();
        final network = _Receiver(queue);
        final client = await network.connect(host: '127.0.0.1', port: 45678);
        final session = SessionService(deviceRepo: DeviceRepository());
        await session.acceptPairResult(
          clientId: client!,
          sessionId: 'session',
          peerDeviceId: 'peer',
          peerDeviceName: 'Peer',
          peerPlatform: DevicePlatform.macos,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: TransferListPage(
              transferQueue: queue,
              networkService: network,
              sessionService: session,
            ),
          ),
        );
        await tester.tap(find.text('发送文件'));
        await _until(
          tester,
          () =>
              queue.tasks.length == 3 &&
              network.messageLog.any(
                (m) => m.type == ProtocolMessageType.transferDone,
              ),
        );
        List<ProtocolMessage> offers() => network.messageLog
            .where((m) => m.type == ProtocolMessageType.transferOffer)
            .toList();
        expect(
          offers().length,
          1,
          reason: 'Next file must wait for integrity confirmation.',
        );
        final first = offers().first.payload['taskId'] as String;
        expect(
          offers().first.payload['fileName'],
          outcome == 'missing' ? 'file1.bin' : 'file0.bin',
        );
        expect(queue.findTask(first)!.status, TransferTaskStatus.verifying);
        expect(
          queue.tasks
              .where((t) => t.status == TransferTaskStatus.pending)
              .length,
          outcome == 'missing' ? 1 : 2,
        );
        if (outcome == 'disconnect' || outcome == 'reconnect') {
          await network.disconnect(client);
          session.disconnect();
          queue.pause(first);
          await _until(
            tester,
            () =>
                !queue.tasks.any((t) => t.status == TransferTaskStatus.pending),
          );
          expect(offers().length, 1);
          expect(
            queue.tasks
                .where((t) => t.id != first)
                .every((t) => t.status == TransferTaskStatus.paused),
            isTrue,
          );
          for (final task in queue.tasks)
            expect(queue.getSentFilePath(task.id), isNotNull);
        } else {
          if (outcome == 'reject') {
            queue.fail(first);
          } else {
            queue.complete(first);
          }
          final count = outcome == 'missing' ? 2 : 3;
          for (var i = 1; i < count; i++) {
            await _until(
              tester,
              () =>
                  offers().length == i + 1 &&
                  network.messageLog
                          .where(
                            (m) => m.type == ProtocolMessageType.transferDone,
                          )
                          .length ==
                      i + 1,
            );
            final id = offers().last.payload['taskId'] as String;
            expect(queue.findTask(id)!.status, TransferTaskStatus.verifying);
            queue.complete(id);
          }
          await _until(
            tester,
            () => !queue.tasks.any(
              (t) =>
                  t.status == TransferTaskStatus.pending ||
                  t.status == TransferTaskStatus.verifying,
            ),
          );
          expect(
            queue.tasks
                .where((t) => t.status == TransferTaskStatus.failed)
                .length,
            ['missing', 'reject'].contains(outcome) ? 1 : 0,
          );
          final chunks = network.binaryMessageLog
              .map(BinaryTransferChunk.decode)
              .toList();
          expect(
            chunks.map((c) => c.data.toList()),
            outcome == 'missing'
                ? [
                    [1, 2],
                    [2, 3],
                  ]
                : [
                    [0, 1],
                    [1, 2],
                    [2, 3],
                  ],
          );
        }
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
  for (final changedPeer in [false, true]) {
    testWidgets(
      'selection cancellation or changed peer sends nothing ($changedPeer)',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('yichuan-picker-');
        final file = File('${dir.path}/secret.txt')
          ..writeAsStringSync('secret');
        const channel = MethodChannel('com.localmesh/filepicker');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final selection = Completer<Object?>();
        var opened = false;
        messenger.setMockMethodCallHandler(channel, (call) {
          if (call.method != 'pickFiles') return Future.value(null);
          opened = true;
          return selection.future;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          dir.deleteSync(recursive: true);
        });
        final queue = TransferQueueService();
        final network = _Receiver(queue);
        final client = await network.connect(host: '127.0.0.1', port: 45678);
        final session = SessionService(deviceRepo: DeviceRepository());
        await session.acceptPairResult(
          clientId: client!,
          sessionId: 'session',
          peerDeviceId: 'peer',
          peerDeviceName: 'Peer',
          peerPlatform: DevicePlatform.macos,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: TransferListPage(
              transferQueue: queue,
              networkService: network,
              sessionService: session,
            ),
          ),
        );
        await tester.tap(find.text('发送文件'));
        await tester.pump();
        expect(opened, isTrue);
        if (changedPeer) {
          final other = await network.connect(host: '127.0.0.2', port: 45678);
          await session.acceptPairResult(
            clientId: other!,
            sessionId: 'new-session',
            peerDeviceId: 'other',
            peerDeviceName: 'Other',
            peerPlatform: DevicePlatform.macos,
          );
        }
        selection.complete(
          changedPeer
              ? [
                  {'path': file.path, 'name': 'secret.txt', 'size': 6},
                ]
              : [],
        );
        await tester.pump();
        expect(queue.tasks, isEmpty);
        expect(network.messageLog, isEmpty);
        if (changedPeer) expect(find.text('连接已改变，请重新选择文件'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
}
