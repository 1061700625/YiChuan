import 'dart:async';
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
  for (final action in [
    'reconnect',
    'clear verifying',
    'remove completed',
    'stale validation',
  ]) {
    testWidgets('$action while hashing has controlled lifecycle', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('yichuan-lifecycle-');
      final network = InMemoryNetworkService();
      final hashing = Completer<void>();
      final release = Completer<void>();
      final validation = Completer<void>();
      final validating = Completer<void>();
      var calls = 0;
      const bytes = [1, 2, 3];
      final hash = sha256.convert(bytes).toString();
      await tester.pumpWidget(
        LocalMeshTransferApp(
          networkService: network,
          discoveryService: _Discovery(),
          dataDirectory: dir,
          fileHasher: (_) async {
            if (++calls == 2 && action == 'stale validation') {
              validating.complete();
              await validation.future;
              return '0' * 64;
            }
            if (!hashing.isCompleted) hashing.complete();
            await release.future;
            return hash;
          },
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        if (!validation.isCompleted) validation.complete();
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
          .widget<PairingPage>(find.byType(PairingPage))
          .sessionService;
      final queue = tester
          .widget<TransferListPage>(
            find.byType(TransferListPage, skipOffstage: false),
          )
          .transferQueue;
      Future<String> pair() async {
        final client = await network.injectClientConnection(
          deviceId: 'peer',
          deviceName: 'Peer',
          host: '127.0.0.1',
        );
        await network.injectMessageFrom(
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
        );
        return client;
      }

      late String client;
      await tester.runAsync(() async {
        client = await pair();
      });
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
            data: Uint8List.fromList(bytes),
          ).encode(),
        );
        await network.injectMessageFrom(
          client,
          message(ProtocolMessageType.transferDone, {
            'taskId': 'file',
            'sha256': hash,
          }),
        );
        // Flush the pending file-close I/O before waiting for the hash gate.
      });
      await tester.pump();
      for (var i = 0; i < 100 && !hashing.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        hashing.isCompleted,
        isTrue,
        reason: tester
            .widget<PairingPage>(find.byType(PairingPage, skipOffstage: false))
            .statusMessage,
      );
      expect(queue.findTask('file')!.status, TransferTaskStatus.verifying);
      if (action == 'clear verifying') {
        queue.clear();
      } else if (action == 'reconnect') {
        await tester.runAsync(() async {
          await network.disconnect(client);
          client = await pair();
          await network.injectMessageFrom(
            client,
            message(ProtocolMessageType.transferResumeRequest, offer),
          );
          expect(network.messageLog.last.payload['accepted'], isTrue);
          await network.injectMessageFrom(
            client,
            message(ProtocolMessageType.transferDone, {
              'taskId': 'file',
              'sha256': hash,
            }),
          );
        });
      }
      release.complete();
      await tester.runAsync(() async {
        await release.future;
      });
      for (
        var i = 0;
        i < 100 &&
            queue.findTask('file') != null &&
            queue.findTask('file')!.status != TransferTaskStatus.completed;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      if (action == 'clear verifying') {
        expect(queue.findTask('file'), isNull);
        expect(
          network.messageLog.where(
            (m) =>
                m.type == ProtocolMessageType.progress &&
                m.payload['complete'] == true,
          ),
          isEmpty,
        );
      } else {
        expect(queue.findTask('file')!.status, TransferTaskStatus.completed);
        expect(File('${dir.path}/sample.bin').readAsBytesSync(), bytes);
        if (action == 'stale validation') {
          await tester.runAsync(
            () => network.injectMessageFrom(
              client,
              message(ProtocolMessageType.transferDone, {
                'taskId': 'file',
                'sha256': hash,
              }),
            ),
          );
          await tester.pump();
          for (var i = 0; i < 100 && !validating.isCompleted; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(validating.isCompleted, isTrue);
          queue.remove('file');
          await tester.runAsync(
            () => network.injectMessageFrom(
              client,
              message(ProtocolMessageType.transferOffer, {
                ...offer,
                'fileName': 'new.bin',
              }),
            ),
          );
          expect(
            queue.findTask('file')!.status,
            TransferTaskStatus.transferring,
          );
          validation.complete();
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          expect(
            queue.findTask('file')!.status,
            TransferTaskStatus.transferring,
            reason: 'Old validation must not fail a replacement transfer',
          );
        }
        if (action == 'remove completed') {
          queue.remove('file');
          await tester.runAsync(() async {
            await network.injectMessageFrom(
              client,
              message(ProtocolMessageType.transferResumeRequest, offer),
            );
          });
          expect(network.messageLog.last.payload['accepted'], isFalse);
          expect(File('${dir.path}/sample.bin').readAsBytesSync(), bytes);
        }
      }
    });
  }
}
