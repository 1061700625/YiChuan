import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/websocket_network_service.dart';
import 'package:local_mesh_transfer/core/protocol/binary_transfer_chunk.dart';
import 'package:local_mesh_transfer/core/transfer/file_integrity.dart';

void main() {
  test(
    'real sockets transfer MiB chunks in both directions without corrupting files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yichuan-socket-',
      );
      final first = WebSocketNetworkService();
      final second = WebSocketNetworkService();
      const total = 4 * 1024 * 1024 + 17;
      final original = File('${directory.path}/original');
      await original.writeAsBytes(List<int>.generate(total, (i) => i % 251));
      final firstFile = File('${directory.path}/first');
      final secondFile = File('${directory.path}/second');
      final firstOutput = await firstFile.open(mode: FileMode.write);
      final secondOutput = await secondFile.open(mode: FileMode.write);
      final receivedFirst = Completer<void>();
      final receivedSecond = Completer<void>();
      var firstBytes = 0;
      var secondBytes = 0;
      first.onBinaryReceived = (_, frame) async {
        final chunk = BinaryTransferChunk.decode(frame);
        expect(chunk.offset, firstBytes);
        await firstOutput.writeFrom(chunk.data);
        firstBytes += chunk.data.length;
        if (firstBytes == total) receivedFirst.complete();
      };
      second.onBinaryReceived = (_, frame) async {
        final chunk = BinaryTransferChunk.decode(frame);
        expect(chunk.offset, secondBytes);
        await secondOutput.writeFrom(chunk.data);
        secondBytes += chunk.data.length;
        if (secondBytes == total) receivedSecond.complete();
      };
      try {
        final port = await first.startServer(port: 0);
        final outgoing = await second.connect(host: '127.0.0.1', port: port);
        final incoming = first.connectedClients.single;
        final source = await original.readAsBytes();
        for (var offset = 0; offset < total; offset += 1024 * 1024) {
          final end = offset + 1024 * 1024 < total
              ? offset + 1024 * 1024
              : total;
          final frame = BinaryTransferChunk(
            taskId: 'file',
            offset: offset,
            data: Uint8List.sublistView(source, offset, end),
          ).encode();
          expect(await first.sendBinary(incoming, frame), isTrue);
          expect(await second.sendBinary(outgoing!, frame), isTrue);
        }
        await Future.wait([
          receivedFirst.future,
          receivedSecond.future,
        ]).timeout(const Duration(seconds: 10));
        await firstOutput.close();
        await secondOutput.close();
        final expected = await computeFileSha256(original.path);
        expect(await computeFileSha256(firstFile.path), expected);
        expect(await computeFileSha256(secondFile.path), expected);
      } finally {
        await first.stopServer();
        await second.stopServer();
        await directory.delete(recursive: true);
      }
    },
  );
}
