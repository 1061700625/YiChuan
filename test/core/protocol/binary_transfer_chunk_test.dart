import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/protocol/binary_transfer_chunk.dart';

void main() {
  group('BinaryTransferChunk', () {
    test('round-trips task id, large offset, and raw bytes', () {
      final original = BinaryTransferChunk(
        taskId: 'send_测试_1',
        offset: 5 * 1024 * 1024 * 1024,
        data: Uint8List.fromList([0, 1, 127, 128, 255]),
      );

      final decoded = BinaryTransferChunk.decode(original.encode());

      expect(decoded.taskId, original.taskId);
      expect(decoded.offset, original.offset);
      expect(decoded.data, orderedEquals(original.data));
    });

    test('rejects malformed and unknown frames', () {
      expect(
        () => BinaryTransferChunk.decode(Uint8List(3)),
        throwsFormatException,
      );
      expect(
        () => BinaryTransferChunk.decode(Uint8List(14)),
        throwsFormatException,
      );
    });
  });
}
