import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';

void main() {
  group('TransferTask', () {
    test('tracks confirmed bytes without claiming integrity completion', () {
      final task = TransferTask.file(
        id: 'task-1',
        fileName: 'video.mp4',
        totalBytes: 100,
      );

      final received = task.markBytesCompleted(100);

      expect(received.completedBytes, 100);
      expect(received.progress, 1);
      expect(received.status, TransferTaskStatus.transferring);
      expect(received.markCompleted().status, TransferTaskStatus.completed);
    });

    test('handles an explicitly completed zero-byte file', () {
      final task = TransferTask.file(
        id: 'task-2',
        fileName: 'empty.txt',
        totalBytes: 0,
      ).markCompleted();

      expect(task.progress, 1);
      expect(task.status, TransferTaskStatus.completed);
    });

    test('creates a completed UTF-8 text task', () {
      final task = TransferTask.text(id: 'text-1', text: '你好');

      expect(task.kind, TransferTaskKind.text);
      expect(task.text, '你好');
      expect(task.totalBytes, 6);
      expect(task.status, TransferTaskStatus.completed);
    });
  });
}
