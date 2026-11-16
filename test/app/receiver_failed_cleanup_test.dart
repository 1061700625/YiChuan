import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/app/app.dart';
import 'package:local_mesh_transfer/core/discovery/udp_discovery_service.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/binary_transfer_chunk.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';
import 'package:local_mesh_transfer/features/pairing/pairing_page.dart';
import 'package:local_mesh_transfer/features/transfers/transfer_list_page.dart';

class _Discovery extends UdpDiscoveryService {
  @override
  void startScanning() {}

  @override
  Future<void> startBroadcasting({
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required int servicePort,
  }) async {}
}

void main() {
  testWidgets(
    'a failed transfer removes the receiver-side partial file',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('yichuan-failed-');
      final network = InMemoryNetworkService();
      const bytes = [1, 2, 3];
      final hash = sha256.convert(bytes).toString();

      await tester.pumpWidget(
        LocalMeshTransferApp(
          networkService: network,
          discoveryService: _Discovery(),
          dataDirectory: dir,
          fileHasher: (path) async => hash,
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => dir.delete(recursive: true));
      });

      for (var i = 0; i < 100 && network.onMessageReceived == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(network.onMessageReceived, isNotNull);

      final session = tester
          .widget<PairingPage>(find.byType(PairingPage, skipOffstage: false))
          .sessionService;
      final queue = tester
          .widget<TransferListPage>(
            find.byType(TransferListPage, skipOffstage: false),
          )
          .transferQueue;

      late String client;
      await tester.runAsync(() async {
        client = await network.injectClientConnection(
          deviceId: 'peer',
          deviceName: 'Peer',
          host: '127.0.0.1',
        );
      });
      await tester.runAsync(
        () => network.injectMessageFrom(
          client,
          ProtocolMessage(
            type: ProtocolMessageType.pairRequest,
            version: 1,
            messageId: 'pair',
            timestamp: DateTime.now(),
            payload: {
              'deviceId': 'peer',
              'deviceName': 'Peer',
              'platform': 'android',
              'pairingCode': session.generatePairingCode(),
            },
          ),
        ),
      );

      ProtocolMessage message(
        ProtocolMessageType type,
        Map<String, Object?> payload,
      ) => ProtocolMessage(
        type: type,
        version: 1,
        messageId: type.name,
        timestamp: DateTime.now(),
        sessionId: session.currentSessionId,
        payload: payload,
      );

      await tester.runAsync(() async {
        await network.injectMessageFrom(
          client,
          message(ProtocolMessageType.transferOffer, {
            'taskId': 'file',
            'fileName': 'sample.bin',
            'fileSize': bytes.length,
            'fileSha256': hash,
            'resumeToken': 'a' * 32,
          }),
        );
        await network.injectBinaryFrom(
          client,
          BinaryTransferChunk(
            taskId: 'file',
            offset: 0,
            data: Uint8List.fromList(bytes.sublist(0, 2)),
          ).encode(),
        );
      });
      await tester.pump();

      expect(queue.findTask('file')!.status, TransferTaskStatus.transferring);
      final partial = File('${dir.path}/sample.bin');
      expect(partial.existsSync(), isTrue);

      await tester.runAsync(() async {
        await network.injectMessageFrom(
          client,
          message(ProtocolMessageType.progress, {
            'taskId': 'file',
            'receivedBytes': 2,
            'failed': true,
          }),
        );
      });
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      expect(queue.findTask('file')!.status, TransferTaskStatus.failed);
      expect(
        partial.existsSync(),
        isFalse,
        reason: 'A failed transfer must not keep its partial file on disk.',
      );
    },
  );
}
