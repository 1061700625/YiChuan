import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_queue_service.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';

void main() {
  group('TransferQueueService', () {
    late TransferQueueService queue;
    final events = <String>[];

    setUp(() {
      events.clear();
      queue = TransferQueueService()
        ..addListener((task) => events.add('${task.status.name}:${task.id}'));
    });

    test('starts with empty queue', () {
      expect(queue.tasks, isEmpty);
    });

    test('adds pending file task from offer', () {
      final task = queue.addOffer(
        taskId: 't1',
        fileName: 'doc.pdf',
        fileSize: 5000,
        checksum: 'sha256-x',
      );

      expect(task.id, 't1');
      expect(task.kind, TransferTaskKind.file);
      expect(task.fileName, 'doc.pdf');
      expect(task.status, TransferTaskStatus.pending);
      expect(queue.tasks, hasLength(1));
    });

    test('adds pending text task', () {
      final task = queue.addTextTask(id: 't1', text: 'Hello World');

      expect(task.id, 't1');
      expect(task.kind, TransferTaskKind.text);
      expect(task.status, TransferTaskStatus.pending);
    });

    test('starts transfer and updates task to transferring', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100, checksum: 'c');
      queue.startTransfer('t1');

      final task = queue.findTask('t1');
      expect(task!.status, TransferTaskStatus.transferring);
      expect(events.last, 'transferring:t1');
    });

    test('records chunk progress and notifies listener', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100, checksum: 'c');
      queue.startTransfer('t1');

      queue.recordChunkCompleted('t1', chunkSize: 50);
      final task = queue.findTask('t1');

      expect(task!.completedBytes, 50);
      expect(task.progress, 0.5);
    });

    test('marks task paused and resumed', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100, checksum: 'c');
      queue.startTransfer('t1');

      queue.pause('t1');
      expect(queue.findTask('t1')!.status, TransferTaskStatus.paused);

      queue.resume('t1');
      expect(queue.findTask('t1')!.status, TransferTaskStatus.transferring);
    });

    test('removes task from queue', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100, checksum: 'c');
      queue.remove('t1');

      expect(queue.tasks, isEmpty);
    });

    test('completes transfer when all bytes received', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 50, checksum: 'c');
      queue.startTransfer('t1');
      queue.recordChunkCompleted('t1', chunkSize: 50);

      expect(queue.findTask('t1')!.status, TransferTaskStatus.completed);
      expect(events.last, 'completed:t1');
    });

    test('sorts tasks by most recent first', () {
      queue.addOffer(taskId: 't1', fileName: 'a', fileSize: 1, checksum: 'c');
      queue.addTextTask(id: 't2', text: 'hi');
      queue.addOffer(taskId: 't3', fileName: 'b', fileSize: 1, checksum: 'c');

      expect(queue.tasks[0].id, 't3');
      expect(queue.tasks[1].id, 't2');
      expect(queue.tasks[2].id, 't1');
    });
  });
}
