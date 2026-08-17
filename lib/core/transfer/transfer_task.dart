import 'dart:convert';

enum TransferTaskKind { file, text }

enum TransferTaskStatus { pending, transferring, paused, failed, completed }

class TransferTask {
  const TransferTask._({
    required this.id,
    required this.status,
    required this.totalBytes,
    required this.completedBytes,
    required this.kind,
    this.fileName,
    this.text,
  });

  factory TransferTask.file({
    required String id,
    required String fileName,
    required int totalBytes,
  }) {
    if (totalBytes < 0) {
      throw ArgumentError.value(
        totalBytes,
        'totalBytes',
        'Must not be negative.',
      );
    }

    return TransferTask._(
      id: id,
      status: TransferTaskStatus.pending,
      totalBytes: totalBytes,
      completedBytes: 0,
      kind: TransferTaskKind.file,
      fileName: fileName,
    );
  }

  factory TransferTask.text({required String id, required String text}) {
    final size = utf8.encode(text).length;
    return TransferTask._(
      id: id,
      status: TransferTaskStatus.completed,
      totalBytes: size,
      completedBytes: size,
      kind: TransferTaskKind.text,
      text: text,
    );
  }

  final String id;
  final TransferTaskStatus status;
  final int totalBytes;
  final int completedBytes;
  final TransferTaskKind kind;
  final String? fileName;
  final String? text;

  double get progress {
    if (totalBytes == 0) {
      return 1;
    }
    return completedBytes / totalBytes;
  }

  TransferTask markBytesCompleted(int bytes) {
    if (bytes < 0 || bytes > totalBytes) {
      throw RangeError.range(bytes, 0, totalBytes, 'bytes');
    }

    return _copyWith(
      status: TransferTaskStatus.transferring,
      completedBytes: bytes,
    );
  }

  TransferTask markCompleted() {
    return _copyWith(
      status: TransferTaskStatus.completed,
      completedBytes: totalBytes,
    );
  }

  TransferTask withStatus(TransferTaskStatus newStatus) {
    return _copyWith(status: newStatus);
  }

  TransferTask restart({required int completedBytes}) {
    if (completedBytes < 0 || completedBytes > totalBytes) {
      throw RangeError.range(completedBytes, 0, totalBytes, 'completedBytes');
    }
    return _copyWith(
      status: TransferTaskStatus.transferring,
      completedBytes: completedBytes,
    );
  }

  TransferTask _copyWith({TransferTaskStatus? status, int? completedBytes}) {
    return TransferTask._(
      id: id,
      status: status ?? this.status,
      totalBytes: totalBytes,
      completedBytes: completedBytes ?? this.completedBytes,
      kind: kind,
      fileName: fileName,
      text: text,
    );
  }
}
