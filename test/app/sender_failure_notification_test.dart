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

/// Receives the sender's chunks and stops acknowledging the first one, which
/// forces the sender down its failure path without a real network.
class _FailingReceiver extends InMemoryNetworkService {
  _FailingReceiver(this.queue);
  final TransferQueueService queue;
  final _dropped = Completer<void>();
  int _chunk = 0;

  @override
  Future<bool> sendBinary(String clientId, Uint8List data) async {
    final chunk = BinaryTransferChunk.decode(data);
    _chunk++;
    if (_chunk == 1) {
      queue.recordProgress(
        chunk.taskId,
        completedBytes: chunk.offset + chunk.data.length,
      );
      return true;
    }
    if (!_dropped.isCompleted) _dropped.complete();
    return false;
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets('a failed send tells the receiver to clean up', (tester) async {
    final dir = Directory.systemTemp.createTempSync('yichuan-sendfail-');
    final file = File('${dir.path}/source.bin')
      ..writeAsBytesSync(List.filled(3 * 1024 * 1024, 7));
    const channel = MethodChannel('com.localmesh/filepicker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pickFiles') {
        return [
          {
            'path': file.path,
            'name': 'source.bin',
            'size': file.lengthSync(),
          },
        ];
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });

    final queue = TransferQueueService();
    final network = _FailingReceiver(queue);
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
      () => queue.findTask(queue.tasks.first.id)?.status ==
              TransferTaskStatus.failed,
    );

    expect(queue.findTask(queue.tasks.first.id)!.status, TransferTaskStatus.failed);
    expect(
      network.messageLog.where(
        (m) => m.type == ProtocolMessageType.progress && m.payload['failed'] == true,
      ),
      isNotEmpty,
      reason: 'The sender must tell the peer that the transfer stopped.',
    );
  });
}
