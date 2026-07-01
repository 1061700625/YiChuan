import 'transfer_task.dart';

class TransferQueueService {
  final _tasks = <TransferTask>[];
  final _listeners = <void Function(TransferTask task)>{};
  final _savedFileUris = <String, String>{};
  final _sentFilePaths = <String, String>{};

  List<TransferTask> get tasks => List.unmodifiable(_tasks.reversed);

  String? getSavedFileUri(String taskId) => _savedFileUris[taskId];
  void setSavedFileUri(String taskId, String uri) => _savedFileUris[taskId] = uri;
  String? getSentFilePath(String taskId) => _sentFilePaths[taskId];
  void setSentFilePath(String taskId, String path) => _sentFilePaths[taskId] = path;

  TransferTask? findTask(String id) {
    try {
      return _tasks.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  void addListener(void Function(TransferTask task) listener) => _listeners.add(listener);
  void removeListener(void Function(TransferTask task) listener) => _listeners.remove(listener);

  TransferTask addOffer({
    required String taskId,
    required String fileName,
    required int fileSize,
    required String checksum,
  }) {
    final task = TransferTask.file(
      id: taskId,
      fileName: fileName,
      totalBytes: fileSize,
      checksum: checksum,
    );
    _tasks.add(task);
    _notify(task);
    return task;
  }

  TransferTask addTextTask({required String id, required String text}) {
    final task = TransferTask.text(id: id, text: text);
    _tasks.add(task);
    _notify(task);
    return task;
  }

  void startTransfer(String taskId) {
    _updateTask(taskId, (t) => t.withStatus(TransferTaskStatus.transferring));
  }

  void recordChunkCompleted(String taskId, {required int chunkSize}) {
    _updateTask(taskId, (t) => t.markBytesCompleted(t.completedBytes + chunkSize));
  }

  void pause(String taskId) {
    _updateTask(taskId, (t) => t.withStatus(TransferTaskStatus.paused));
  }

  void resume(String taskId) {
    _updateTask(taskId, (t) => t.withStatus(TransferTaskStatus.transferring));
  }

  void remove(String taskId) {
    _tasks.removeWhere((t) => t.id == taskId);
  }

  void _updateTask(String taskId, TransferTask Function(TransferTask) transform) {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index < 0) return;
    final updated = transform(_tasks[index]);
    _tasks[index] = updated;
    _notify(updated);
  }

  void _notify(TransferTask task) {
    for (final listener in _listeners) {
      listener(task);
    }
  }
}
