import 'dart:convert';
import 'dart:typed_data';

/// Compact binary frame used for file data over WebSocket.
///
/// Layout (big endian): 4-byte magic/version (`YCT1`), 2-byte UTF-8 task id
/// length, 8-byte absolute file offset, task id, then the raw file bytes.
class BinaryTransferChunk {
  const BinaryTransferChunk({
    required this.taskId,
    required this.offset,
    required this.data,
  });

  static const _fixedHeaderLength = 14;
  static const _magic = <int>[0x59, 0x43, 0x54, 0x31]; // YCT1

  final String taskId;
  final int offset;
  final Uint8List data;

  Uint8List encode() {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Must not be negative.');
    }

    final taskIdBytes = utf8.encode(taskId);
    if (taskIdBytes.isEmpty || taskIdBytes.length > 0xffff) {
      throw ArgumentError.value(
        taskId,
        'taskId',
        'UTF-8 task id must contain between 1 and 65535 bytes.',
      );
    }

    final result = Uint8List(
      _fixedHeaderLength + taskIdBytes.length + data.length,
    );
    result.setRange(0, _magic.length, _magic);

    final header = ByteData.view(result.buffer);
    header.setUint16(4, taskIdBytes.length, Endian.big);
    header.setUint64(6, offset, Endian.big);
    result.setRange(
      _fixedHeaderLength,
      _fixedHeaderLength + taskIdBytes.length,
      taskIdBytes,
    );
    result.setRange(
      _fixedHeaderLength + taskIdBytes.length,
      result.length,
      data,
    );
    return result;
  }

  factory BinaryTransferChunk.decode(Uint8List frame) {
    if (frame.length < _fixedHeaderLength) {
      throw const FormatException('Binary transfer frame is too short.');
    }

    for (var i = 0; i < _magic.length; i++) {
      if (frame[i] != _magic[i]) {
        throw const FormatException('Unknown binary transfer frame.');
      }
    }

    final header = ByteData.sublistView(frame);
    final taskIdLength = header.getUint16(4, Endian.big);
    final payloadOffset = _fixedHeaderLength + taskIdLength;
    if (taskIdLength == 0 || payloadOffset > frame.length) {
      throw const FormatException('Invalid binary transfer task id.');
    }

    final taskId = utf8.decode(
      frame.sublist(_fixedHeaderLength, payloadOffset),
    );
    return BinaryTransferChunk(
      taskId: taskId,
      offset: header.getUint64(6, Endian.big),
      data: Uint8List.sublistView(frame, payloadOffset),
    );
  }
}
