import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_queue_service.dart';
import 'package:local_mesh_transfer/core/transfer/transfer_task.dart';

void main() {
  group('TransferQueueService', () {
    late TransferQueueService queue;

    setUp(() => queue = TransferQueueService());

    test('adds and starts a file task', () {
      final task = queue.addOffer(
        taskId: 't1',
        fileName: 'doc.pdf',
        fileSize: 5000,
      );
      expect(task.status, TransferTaskStatus.pending);

      queue.startTransfer('t1');
      expect(queue.findTask('t1')!.status, TransferTaskStatus.transferring);
    });

    test('keeps receiver-confirmed progress monotonic and bounded', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100);
      queue.startTransfer('t1');
      queue.recordProgress('t1', completedBytes: 60);
      queue.recordProgress('t1', completedBytes: 40);
      queue.recordProgress('t1', completedBytes: 120);

      final task = queue.findTask('t1')!;
      expect(task.completedBytes, 100);
      expect(task.status, TransferTaskStatus.transferring);
    });

    test('completes only after explicit integrity confirmation', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100);
      queue.startTransfer('t1');
      queue.recordProgress('t1', completedBytes: 100);
      queue.complete('t1');
      expect(queue.findTask('t1')!.status, TransferTaskStatus.completed);
    });

    test('marks a transfer failed', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100);
      queue.fail('t1');
      expect(queue.findTask('t1')!.status, TransferTaskStatus.failed);
    });

    test('restarts a paused transfer from a negotiated offset', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100);
      queue.startTransfer('t1');
      queue.recordProgress('t1', completedBytes: 80);
      queue.pause('t1');

      queue.restart('t1', completedBytes: 48);

      expect(queue.findTask('t1')!.completedBytes, 48);
      expect(queue.findTask('t1')!.status, TransferTaskStatus.transferring);
    });

    test('delivers a resume decision once', () {
      queue.addOffer(taskId: 't1', fileName: 'f.bin', fileSize: 100);
      queue.setResumeDecision('t1', accepted: true, offset: 64);

      final decision = queue.takeResumeDecision('t1');
      expect(decision?.accepted, isTrue);
      expect(decision?.offset, 64);
      expect(queue.takeResumeDecision('t1'), isNull);
    });

    test('sorts tasks by most recent first', () {
      queue.addOffer(taskId: 't1', fileName: 'a', fileSize: 1);
      queue.addOffer(taskId: 't2', fileName: 'b', fileSize: 1);
      expect(queue.tasks.map((task) => task.id), ['t2', 't1']);
    });

    test('removes a received record and its file metadata', () {
      queue.addOffer(taskId: 't1', fileName: 'a.bin', fileSize: 1);
      queue.markReceived('t1');
      queue.setReceivedFilePath('t1', '/tmp/a.bin');

      queue.remove('t1');

      expect(queue.findTask('t1'), isNull);
      expect(queue.isReceived('t1'), isFalse);
      expect(queue.getReceivedFilePath('t1'), isNull);
    });

    test('adds a received text record', () {
      final task = queue.addText(
        taskId: 'text-1',
        text: 'hello',
        received: true,
      );

      expect(task.kind, TransferTaskKind.text);
      expect(task.status, TransferTaskStatus.completed);
      expect(queue.isReceived(task.id), isTrue);
    });

    test('clears all records and associated file metadata', () {
      queue.addOffer(taskId: 'received', fileName: 'a.bin', fileSize: 1);
      queue.markReceived('received');
      queue.setReceivedFilePath('received', '/tmp/a.bin');
      queue.addText(taskId: 'sent', text: 'hello', received: false);

      queue.clear();

      expect(queue.tasks, isEmpty);
      expect(queue.isReceived('received'), isFalse);
      expect(queue.getReceivedFilePath('received'), isNull);
    });
  });
}
