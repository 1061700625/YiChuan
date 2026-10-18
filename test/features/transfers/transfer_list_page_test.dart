import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:local_mesh_transfer/core/protocol/binary_transfer_chunk.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_queue_service.dart';
import 'package:local_mesh_transfer/features/transfers/transfer_list_page.dart';

class _AcknowledgingNetwork extends InMemoryNetworkService {
  _AcknowledgingNetwork(this.queue);
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

  @override
  Future<bool> send(String clientId, ProtocolMessage message) async {
    final sent = await super.send(clientId, message);
    if (sent && message.type == ProtocolMessageType.transferDone) {
      queue.complete(message.payload['taskId'] as String);
    }
    return sent;
  }
}

void main() {
  testWidgets('long pressing a received file can remove only its record', (
    tester,
  ) async {
    final queue = TransferQueueService();
    queue.addOffer(taskId: 'received-1', fileName: 'photo.jpg', fileSize: 10);
    queue.markReceived('received-1');
    queue.setReceivedFilePath('received-1', '/tmp/photo.jpg');
    queue.complete('received-1');

    await tester.pumpWidget(
      MaterialApp(
        home: TransferListPage(
          transferQueue: queue,
          networkService: InMemoryNetworkService(),
          sessionService: SessionService(deviceRepo: DeviceRepository()),
        ),
      ),
    );

    await tester.longPress(find.text('photo.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('是否同时删除已接收的文件？'), findsOneWidget);

    await tester.tap(find.text('仅删除记录'));
    await tester.pumpAndSettle();
    expect(queue.findTask('received-1'), isNull);
    expect(find.text('已删除记录'), findsOneWidget);
  });

  testWidgets('sends text and allows deleting the sent record', (tester) async {
    final queue = TransferQueueService();
    final network = InMemoryNetworkService();
    final clientId = await network.connect(host: '127.0.0.1', port: 45678);
    final session = SessionService(deviceRepo: DeviceRepository());
    await session.acceptPairResult(
      clientId: clientId!,
      sessionId: 'session-1',
      peerDeviceId: 'peer-1',
      peerDeviceName: 'Mac',
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

    await tester.tap(find.text('发送文字'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '你好，驿传');
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();

    expect(queue.tasks.single.text, '你好，驿传');
    expect(queue.isReceived(queue.tasks.single.id), isFalse);
    expect(network.messageLog.last.type, ProtocolMessageType.textMessage);
    expect(find.text('你好，驿传'), findsOneWidget);

    await tester.longPress(find.text('文字消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除这条发送记录？源文件不会被删除。'), findsOneWidget);

    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(queue.tasks, isEmpty);
  });

  testWidgets('accepting peer can send text while receiving a file', (
    tester,
  ) async {
    final queue = TransferQueueService();
    queue.addOffer(taskId: 'incoming', fileName: 'incoming.bin', fileSize: 100);
    queue.markReceived('incoming');
    queue.startTransfer('incoming');
    final network = InMemoryNetworkService();
    final client = await network.injectClientConnection(
      deviceId: 'phone',
      deviceName: 'Phone',
      host: '127.0.0.1',
    );
    expect(network.isInitiator, isFalse);
    final session = SessionService(deviceRepo: DeviceRepository());
    await session.acceptPairResult(
      clientId: client,
      sessionId: 'session',
      peerDeviceId: 'phone',
      peerDeviceName: 'Phone',
      peerPlatform: DevicePlatform.android,
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
    expect(find.text('发送文件'), findsOneWidget);
    await tester.tap(find.text('发送文字'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '来自接收端');
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();
    final sent = network.messageLog.last;
    expect(sent.type, ProtocolMessageType.textMessage);
    expect(sent.sessionId, 'session');
    expect(sent.payload['text'], '来自接收端');
    expect(queue.findTask('incoming')!.completedBytes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'accepting peer sends a file while an incoming transfer remains active',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'yichuan-send-test-',
      );
      final file = File('${directory.path}/sample.bin')
        ..writeAsBytesSync([1, 2, 3, 4]);
      const channel = MethodChannel('com.localmesh/filepicker');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pickFile')
          return {'path': file.path, 'name': 'sample.bin', 'size': 4};
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        directory.deleteSync(recursive: true);
      });
      final queue = TransferQueueService();
      queue.addOffer(taskId: 'incoming', fileName: 'other.bin', fileSize: 100);
      queue.markReceived('incoming');
      queue.startTransfer('incoming');
      final network = _AcknowledgingNetwork(queue);
      final client = await network.injectClientConnection(
        deviceId: 'phone',
        deviceName: 'Phone',
        host: '127.0.0.1',
      );
      final session = SessionService(deviceRepo: DeviceRepository());
      await session.acceptPairResult(
        clientId: client,
        sessionId: 'session',
        peerDeviceId: 'phone',
        peerDeviceName: 'Phone',
        peerPlatform: DevicePlatform.android,
      );
      expect(network.isInitiator, isFalse);
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
      for (
        var attempt = 0;
        attempt < 100 &&
            !queue.tasks.any(
              (task) =>
                  !queue.isReceived(task.id) &&
                  task.status == TransferTaskStatus.completed,
            );
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final sent = queue.tasks.singleWhere(
        (task) => !queue.isReceived(task.id),
      );
      expect(sent.status, TransferTaskStatus.completed);
      expect(sent.completedBytes, 4);
      final frame = BinaryTransferChunk.decode(network.binaryMessageLog.single);
      expect(frame.data, orderedEquals([1, 2, 3, 4]));
      expect(
        queue.findTask('incoming')!.status,
        TransferTaskStatus.transferring,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unpaired sockets cannot enable sending', (tester) async {
    final network = InMemoryNetworkService();
    await network.connect(host: '127.0.0.1', port: 45678);
    await tester.pumpWidget(
      MaterialApp(
        home: TransferListPage(
          transferQueue: TransferQueueService(),
          networkService: network,
          sessionService: SessionService(deviceRepo: DeviceRepository()),
        ),
      ),
    );
    expect(find.text('发送文件'), findsNothing);
    expect(find.text('发送文字'), findsNothing);
    expect(find.text('未连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clear records removes all history after confirmation', (
    tester,
  ) async {
    final queue = TransferQueueService();
    queue.addText(taskId: 'sent-text', text: '第一条', received: false);
    queue.addText(taskId: 'received-text', text: '第二条', received: true);

    await tester.pumpWidget(
      MaterialApp(
        home: TransferListPage(
          transferQueue: queue,
          networkService: InMemoryNetworkService(),
          sessionService: SessionService(deviceRepo: DeviceRepository()),
        ),
      ),
    );

    await tester.tap(find.byTooltip('清空记录'));
    await tester.pumpAndSettle();
    expect(find.text('确认清空全部传输记录？已接收文件和发送源文件都不会被删除。'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '清空记录'));
    await tester.pumpAndSettle();
    expect(queue.tasks, isEmpty);
    expect(find.text('已清空传输记录'), findsOneWidget);
  });

  testWidgets('failed sent files show a retry button', (tester) async {
    final queue = TransferQueueService();
    queue.addOffer(taskId: 'retry-1', fileName: 'resume.bin', fileSize: 4);
    queue.fail('retry-1');

    await tester.pumpWidget(
      MaterialApp(
        home: TransferListPage(
          transferQueue: queue,
          networkService: InMemoryNetworkService(),
          sessionService: SessionService(deviceRepo: DeviceRepository()),
        ),
      ),
    );

    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('opens long text details and copies the complete message', (
    tester,
  ) async {
    MethodCall? clipboardCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') clipboardCall = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final text = List.filled(100, '这是一段很长的文字').join('，');
    final queue = TransferQueueService();
    queue.addText(taskId: 'long-text', text: text, received: true);

    await tester.pumpWidget(
      MaterialApp(
        home: TransferListPage(
          transferQueue: queue,
          networkService: InMemoryNetworkService(),
          sessionService: SessionService(deviceRepo: DeviceRepository()),
        ),
      ),
    );

    expect(find.text('点击查看详情'), findsOneWidget);
    await tester.tap(find.text('文字消息'));
    await tester.pumpAndSettle();
    expect(find.text('文字详情'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);

    await tester.tap(find.text('复制全部'));
    await tester.pump();
    expect(clipboardCall?.method, 'Clipboard.setData');
    expect(clipboardCall?.arguments, {'text': text});
    expect(find.text('文字已复制'), findsOneWidget);
  });
}
