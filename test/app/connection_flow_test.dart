import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:local_mesh_transfer/core/protocol/binary_transfer_chunk.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';
import 'package:local_mesh_transfer/features/transfers/transfer_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/app/app.dart';
import 'package:local_mesh_transfer/core/discovery/udp_discovery_service.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/features/pairing/pairing_page.dart';

class _LocalDiscovery extends UdpDiscoveryService {
  @override
  void startScanning() {
    super.startScanning();
    injectDiscoveredDevice(
      deviceId: 'peer',
      deviceName: 'Peer',
      platform: DevicePlatform.android,
      ip: '127.0.0.1',
      port: 1234,
    );
  }

  @override
  Future<void> startBroadcasting({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int servicePort,
  }) async {}
}

ProtocolMessage _pair(String code) => ProtocolMessage(
  type: ProtocolMessageType.pairRequest,
  version: 1,
  messageId: 'pair',
  timestamp: DateTime.now(),
  payload: {
    'deviceId': 'peer',
    'deviceName': 'Peer',
    'platform': 'android',
    'pairingCode': code,
  },
);

void main() {
  testWidgets('receiver clears previous disconnect status on reconnection', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('yichuan-app-test-');
    });
    final network = InMemoryNetworkService();
    await tester.pumpWidget(
      LocalMeshTransferApp(
        networkService: network,
        discoveryService: _LocalDiscovery(),
        dataDirectory: dir,
      ),
    );
    for (
      var attempt = 0;
      attempt < 100 && network.onMessageReceived == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(
      network.onMessageReceived,
      isNotNull,
      reason: tester
          .widget<PairingPage>(find.byType(PairingPage))
          .statusMessage,
    );
    var session = tester
        .widget<PairingPage>(find.byType(PairingPage))
        .sessionService;
    final first = await network.injectClientConnection(
      deviceId: 'peer',
      deviceName: 'Peer',
      host: '127.0.0.1',
    );
    await tester.runAsync(
      () => network.injectMessageFrom(
        first,
        _pair(session.generatePairingCode()),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => network.disconnect(first));
    await tester.pump();
    final second = await network.injectClientConnection(
      deviceId: 'peer',
      deviceName: 'Peer',
      host: '127.0.0.1',
    );
    await tester.runAsync(
      () => network.injectMessageFrom(
        second,
        _pair(session.generatePairingCode()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
    final pairing = tester.widget<PairingPage>(find.byType(PairingPage));
    expect(pairing.statusMessage, isNot('对方已断开连接'));
    expect(session.pairedClientId, second);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets('trust confirmation does not block reading subsequent frames', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('yichuan-trust-test-');
    });
    final network = InMemoryNetworkService();
    await tester.pumpWidget(
      LocalMeshTransferApp(
        networkService: network,
        discoveryService: _LocalDiscovery(),
        dataDirectory: dir,
      ),
    );
    for (
      var attempt = 0;
      attempt < 100 && network.onMessageReceived == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(
      network.onMessageReceived,
      isNotNull,
      reason: tester
          .widget<PairingPage>(find.byType(PairingPage))
          .statusMessage,
    );
    final session = tester
        .widget<PairingPage>(find.byType(PairingPage))
        .sessionService;
    final client = await network.injectClientConnection(
      deviceId: 'peer',
      deviceName: 'Peer',
      host: '127.0.0.1',
    );
    await tester.runAsync(
      () => network.injectMessageFrom(
        client,
        _pair(session.generatePairingCode()),
      ),
    );
    await tester.pump();
    var released = false;
    final handling = network
        .injectMessageFrom(
          client,
          ProtocolMessage(
            type: ProtocolMessageType.trustRequest,
            version: 1,
            messageId: 'trust',
            sessionId: session.currentSessionId,
            timestamp: DateTime.now(),
            payload: {'secret': session.newTrustSecret()},
          ),
        )
        .then((_) => released = true);
    await tester.pump();
    expect(find.text('信任设备申请'), findsOneWidget);
    expect(
      released,
      isTrue,
      reason: 'The socket reader must resume before the user responds.',
    );
    await tester.tap(find.text('同意并信任'));
    await tester.pump();
    await tester.runAsync(() async {
      await handling;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 100 && !session.isPeerTrusted; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(session.isPeerTrusted, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  for (final variant in ['valid', 'corrupted', 'empty']) {
    testWidgets(
      'receiver verifies $variant file without blocking socket dispatch',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync(
          'yichuan-integrity-test-',
        );
        final network = InMemoryNetworkService();
        await tester.pumpWidget(
          LocalMeshTransferApp(
            networkService: network,
            discoveryService: _LocalDiscovery(),
            dataDirectory: dir,
          ),
        );
        for (var i = 0; i < 100 && network.onMessageReceived == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        final session = tester
            .widget<PairingPage>(find.byType(PairingPage))
            .sessionService;
        final client = await network.injectClientConnection(
          deviceId: 'peer',
          deviceName: 'Peer',
          host: '127.0.0.1',
        );
        await tester.runAsync(
          () => network.injectMessageFrom(
            client,
            _pair(session.generatePairingCode()),
          ),
        );
        await tester.pump();
        final queue = tester
            .widget<TransferListPage>(find.byType(TransferListPage))
            .transferQueue;
        final bytes = variant == 'empty' ? <int>[] : [1, 2, 3, 4];
        final hash = sha256.convert(bytes).toString();
        ProtocolMessage message(
          ProtocolMessageType type,
          Map<String, Object?> payload,
        ) => ProtocolMessage(
          type: type,
          version: 1,
          messageId: type.name,
          sessionId: session.currentSessionId,
          timestamp: DateTime.now(),
          payload: payload,
        );
        await tester.runAsync(
          () => network.injectMessageFrom(
            client,
            message(ProtocolMessageType.transferOffer, {
              'taskId': 'file',
              'fileName': 'sample.bin',
              'fileSize': bytes.length,
              'fileSha256': hash,
              'resumeToken': 'a' * 32,
            }),
          ),
        );
        if (bytes.isNotEmpty) {
          await tester.runAsync(
            () => network.injectBinaryFrom(
              client,
              BinaryTransferChunk(
                taskId: 'file',
                offset: 0,
                data: Uint8List.fromList(
                  variant == 'corrupted' ? [1, 2, 3, 5] : bytes,
                ),
              ).encode(),
            ),
          );
        }
        await tester.pump();
        expect(find.text('校验中'), findsOneWidget);
        expect(queue.findTask('file')!.status, TransferTaskStatus.verifying);
        await tester.runAsync(
          () => network.injectMessageFrom(
            client,
            message(ProtocolMessageType.transferDone, {
              'taskId': 'file',
              'sha256': hash,
            }),
          ),
        );
        // Dispatch returns while the file is being closed and hashed.
        expect(queue.findTask('file')!.status, TransferTaskStatus.verifying);
        await tester.runAsync(
          () => network.injectMessageFrom(
            client,
            message(ProtocolMessageType.textMessage, {
              'taskId': 'text',
              'text': 'still connected',
            }),
          ),
        );
        for (
          var i = 0;
          i < 100 &&
              queue.findTask('file')!.status == TransferTaskStatus.verifying;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        final progress = network.messageLog.lastWhere(
          (m) => m.type == ProtocolMessageType.progress,
        );
        if (variant == 'corrupted') {
          expect(queue.findTask('file')!.status, TransferTaskStatus.failed);
          expect(progress.payload['failed'], isTrue);
          expect(queue.getReceivedFilePath('file'), isNull);
        } else {
          expect(queue.findTask('file')!.status, TransferTaskStatus.completed);
          expect(progress.payload['complete'], isTrue);
          expect(
            File(queue.getReceivedFilePath('file')!).readAsBytesSync(),
            bytes,
          );
        }
        if (variant != 'corrupted') {
          await tester.runAsync(() => network.disconnect(client));
          final reconnected = await network.injectClientConnection(
            deviceId: 'peer',
            deviceName: 'Peer',
            host: '127.0.0.1',
          );
          await tester.runAsync(
            () => network.injectMessageFrom(
              reconnected,
              _pair(session.generatePairingCode()),
            ),
          );
          await tester.runAsync(
            () => network.injectMessageFrom(
              reconnected,
              message(ProtocolMessageType.transferResumeRequest, {
                'taskId': 'file',
                'fileName': 'sample.bin',
                'fileSize': bytes.length,
                'fileSha256': hash,
                'resumeToken': 'a' * 32,
              }),
            ),
          );
          final decision = network.messageLog.lastWhere(
            (m) => m.type == ProtocolMessageType.transferResumeResult,
          );
          expect(decision.payload['accepted'], isTrue);
          expect(decision.payload['offset'], bytes.length);
          await tester.runAsync(
            () => network.injectMessageFrom(
              reconnected,
              message(ProtocolMessageType.transferDone, {
                'taskId': 'file',
                'sha256': hash,
              }),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          expect(
            network.messageLog
                .lastWhere((m) => m.type == ProtocolMessageType.progress)
                .payload['complete'],
            isTrue,
          );
          expect(queue.findTask('file')!.status, TransferTaskStatus.completed);
          expect(
            File(queue.getReceivedFilePath('file')!).readAsBytesSync(),
            bytes,
          );
        }
        if (variant == 'valid') {
          final savedPath = queue.getReceivedFilePath('file')!;
          await tester.runAsync(
            () => network.injectBinaryFrom(
              session.pairedClientId!,
              BinaryTransferChunk(
                taskId: 'file',
                offset: 0,
                data: Uint8List.fromList(bytes),
              ).encode(),
            ),
          );
          expect(
            File(savedPath).existsSync(),
            isTrue,
            reason: 'A late chunk must not delete a verified file',
          );
        }
        if (variant != 'corrupted') {
          final saved = File(queue.getReceivedFilePath('file')!);
          if (variant == 'valid') {
            saved.writeAsBytesSync([4, 3, 2, 1]);
          } else {
            saved.deleteSync();
          }
          await tester.runAsync(
            () => network.injectMessageFrom(
              session.pairedClientId!,
              message(ProtocolMessageType.transferResumeRequest, {
                'taskId': 'file',
                'fileName': 'sample.bin',
                'fileSize': bytes.length,
                'fileSha256': hash,
                'resumeToken': 'a' * 32,
              }),
            ),
          );
          expect(
            network.messageLog
                .lastWhere(
                  (m) => m.type == ProtocolMessageType.transferResumeResult,
                )
                .payload['accepted'],
            isFalse,
          );
        }
        expect(queue.tasks.any((t) => t.text == 'still connected'), isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => dir.delete(recursive: true));
      },
    );
  }
}
