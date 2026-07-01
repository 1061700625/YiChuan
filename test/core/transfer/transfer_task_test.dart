import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';

void main() {
  group('TransferTask', () {
    test('tracks file transfer progress by completed bytes', () {
      final task = TransferTask.file(
        id: 'task-1',
        fileName: 'video.mp4',
        totalBytes: 100,
        checksum: 'sha256-demo',
      );

      final updated = task.markBytesCompleted(25);

      expect(updated.status, TransferTaskStatus.transferring);
      expect(updated.completedBytes, 25);
      expect(updated.progress, 0.25);
    });

    test('marks task completed when completed bytes reach total bytes', () {
      final task = TransferTask.file(
        id: 'task-1',
        fileName: 'video.mp4',
        totalBytes: 100,
        checksum: 'sha256-demo',
      );

      final updated = task.markBytesCompleted(100);

      expect(updated.status, TransferTaskStatus.completed);
      expect(updated.progress, 1.0);
    });

    test('creates lightweight text transfer without file chunks', () {
      final task = TransferTask.text(id: 'task-2', text: 'hello');

      expect(task.kind, TransferTaskKind.text);
      expect(task.totalBytes, 5);
      expect(task.fileName, isNull);
    });
  });
}
