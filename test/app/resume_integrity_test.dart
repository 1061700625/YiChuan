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
  testWidgets('a resumed transfer lands every byte exactly once', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('yichuan-resume-');
    final network = InMemoryNetworkService();
    const bytes = [1, 2, 3, 4, 5, 6];
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
    final offer = <String, Object?>{
      'taskId': 'file',
      'fileName': 'sample.bin',
      'fileSize': bytes.length,
      'fileSha256': hash,
      'resumeToken': 'a' * 32,
    };

    await tester.runAsync(() async {
      await network.injectMessageFrom(
        client,
        message(ProtocolMessageType.transferOffer, offer),
      );
      await network.injectBinaryFrom(
        client,
        BinaryTransferChunk(
          taskId: 'file',
          offset: 0,
          data: Uint8List.fromList(bytes.sublist(0, 2)),
        ).encode(),
      );
      // The link drops with half a file on disk.
      await network.disconnect(client);
      client = await network.injectClientConnection(
        deviceId: 'peer',
        deviceName: 'Peer',
        host: '127.0.0.1',
      );
      await network.injectMessageFrom(
        client,
        ProtocolMessage(
          type: ProtocolMessageType.pairRequest,
          version: 1,
          messageId: 'pair2',
          timestamp: DateTime.now(),
          payload: {
            'deviceId': 'peer',
            'deviceName': 'Peer',
            'platform': 'android',
            'pairingCode': session.generatePairingCode(),
          },
        ),
      );
    });

    await tester.runAsync(
      () => network.injectMessageFrom(
        client,
        message(ProtocolMessageType.transferResumeRequest, offer),
      ),
    );

    final resumeResult = network.messageLog.reversed.firstWhere(
      (m) => m.type == ProtocolMessageType.transferResumeResult,
    );
    expect(resumeResult.payload['accepted'], isTrue);
    expect(resumeResult.payload['offset'], 2);

    await tester.runAsync(() async {
      await network.injectBinaryFrom(
        client,
        BinaryTransferChunk(
          taskId: 'file',
          offset: 2,
          data: Uint8List.fromList(bytes.sublist(2)),
        ).encode(),
      );
      await network.injectMessageFrom(
        client,
        message(ProtocolMessageType.transferDone, {
          'taskId': 'file',
          'sha256': hash,
        }),
      );
    });
    await tester.pump();

    final saved = File('${dir.path}/sample.bin');
    expect(saved.readAsBytesSync(), bytes);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(queue.findTask('file')!.status, TransferTaskStatus.completed);
  });
}
