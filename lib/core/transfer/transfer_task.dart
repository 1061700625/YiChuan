enum TransferTaskKind { text, file }

enum TransferTaskStatus { pending, transferring, paused, failed, completed, canceled }

class TransferTask {
  const TransferTask._({
    required this.id,
    required this.kind,
    required this.status,
    required this.totalBytes,
    required this.completedBytes,
    this.fileName,
    this.checksum,
    this.text,
  });

  factory TransferTask.file({
    required String id,
    required String fileName,
    required int totalBytes,
    required String checksum,
  }) {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'Must not be negative.');
    }

    return TransferTask._(
      id: id,
      kind: TransferTaskKind.file,
      status: TransferTaskStatus.pending,
      totalBytes: totalBytes,
      completedBytes: 0,
      fileName: fileName,
      checksum: checksum,
    );
  }

  factory TransferTask.text({required String id, required String text}) {
    return TransferTask._(
      id: id,
      kind: TransferTaskKind.text,
      status: TransferTaskStatus.pending,
      totalBytes: text.length,
      completedBytes: 0,
      text: text,
    );
  }

  final String id;
  final TransferTaskKind kind;
  final TransferTaskStatus status;
  final int totalBytes;
  final int completedBytes;
  final String? fileName;
  final String? checksum;
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
      status: bytes == totalBytes ? TransferTaskStatus.completed : TransferTaskStatus.transferring,
      completedBytes: bytes,
    );
  }

  TransferTask withStatus(TransferTaskStatus newStatus) {
    return _copyWith(status: newStatus);
  }

  TransferTask _copyWith({
    TransferTaskStatus? status,
    int? completedBytes,
  }) {
    return TransferTask._(
      id: id,
      kind: kind,
      status: status ?? this.status,
      totalBytes: totalBytes,
      completedBytes: completedBytes ?? this.completedBytes,
      fileName: fileName,
      checksum: checksum,
      text: text,
    );
  }
}
