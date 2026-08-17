import 'transfer_task.dart';

class TransferResumeDecision {
  const TransferResumeDecision({required this.accepted, required this.offset});

  final bool accepted;
  final int offset;
}

class TransferQueueService {
  final _tasks = <TransferTask>[];
  final _listeners = <void Function(TransferTask task)>{};
  final _savedFileUris = <String, String>{};
  final _receivedFilePaths = <String, String>{};
  final _sentFilePaths = <String, String>{};
  final _receivedTaskIds = <String>{};
  final _resumeTokens = <String, String>{};
  final _resumeDecisions = <String, TransferResumeDecision>{};

  List<TransferTask> get tasks => List.unmodifiable(_tasks.reversed);

  String? getSavedFileUri(String taskId) => _savedFileUris[taskId];
  void setSavedFileUri(String taskId, String uri) =>
      _savedFileUris[taskId] = uri;
  String? getReceivedFilePath(String taskId) => _receivedFilePaths[taskId];
  void setReceivedFilePath(String taskId, String path) =>
      _receivedFilePaths[taskId] = path;
  String? getSentFilePath(String taskId) => _sentFilePaths[taskId];
  void setSentFilePath(String taskId, String path) =>
      _sentFilePaths[taskId] = path;
  bool isReceived(String taskId) => _receivedTaskIds.contains(taskId);
  void markReceived(String taskId) => _receivedTaskIds.add(taskId);
  String? getResumeToken(String taskId) => _resumeTokens[taskId];
  void setResumeToken(String taskId, String token) =>
      _resumeTokens[taskId] = token;

  TransferTask? findTask(String id) {
    try {
      return _tasks.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  void addListener(void Function(TransferTask task) listener) =>
      _listeners.add(listener);
  void removeListener(void Function(TransferTask task) listener) =>
      _listeners.remove(listener);

  TransferTask addOffer({
    required String taskId,
    required String fileName,
    required int fileSize,
  }) {
    final task = TransferTask.file(
      id: taskId,
      fileName: fileName,
      totalBytes: fileSize,
    );
    _tasks.add(task);
    _notify(task);
    return task;
  }

  TransferTask addText({
    required String taskId,
    required String text,
    required bool received,
  }) {
    final task = TransferTask.text(id: taskId, text: text);
    _tasks.add(task);
    if (received) _receivedTaskIds.add(taskId);
    _notify(task);
    return task;
  }

  void startTransfer(String taskId) {
    _updateTask(taskId, (t) => t.withStatus(TransferTaskStatus.transferring));
  }

  /// Update transfer progress with the receiver-confirmed byte count.
  ///
  /// Progress messages can be duplicated or arrive after a newer one, so only
  /// move the task forward and clamp malformed values to the advertised size.
  void recordProgress(String taskId, {required int completedBytes}) {
    _updateTask(taskId, (task) {
      final confirmed = completedBytes.clamp(0, task.totalBytes).toInt();
      if (confirmed <= task.completedBytes) return task;
      return task.markBytesCompleted(confirmed);
    });
  }

  void pause(String taskId) {
    _updateTask(taskId, (t) => t.withStatus(TransferTaskStatus.paused));
  }

  void fail(String taskId) {
    _updateTask(taskId, (t) => t.withStatus(TransferTaskStatus.failed));
  }

  void complete(String taskId) {
    _updateTask(taskId, (t) => t.markCompleted());
  }

  void restart(String taskId, {required int completedBytes}) {
    _updateTask(taskId, (task) => task.restart(completedBytes: completedBytes));
  }

  void setResumeDecision(
    String taskId, {
    required bool accepted,
    required int offset,
  }) {
    final task = findTask(taskId);
    if (task == null) return;
    _resumeDecisions[taskId] = TransferResumeDecision(
      accepted: accepted,
      offset: offset,
    );
    _notify(task);
  }

  TransferResumeDecision? takeResumeDecision(String taskId) =>
      _resumeDecisions.remove(taskId);

  void remove(String taskId) {
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) return;
    final removed = _tasks.removeAt(index);
    _savedFileUris.remove(taskId);
    _receivedFilePaths.remove(taskId);
    _sentFilePaths.remove(taskId);
    _receivedTaskIds.remove(taskId);
    _resumeTokens.remove(taskId);
    _resumeDecisions.remove(taskId);
    _notify(removed);
  }

  void clear() {
    if (_tasks.isEmpty) return;
    final removed = List<TransferTask>.from(_tasks);
    _tasks.clear();
    _savedFileUris.clear();
    _receivedFilePaths.clear();
    _sentFilePaths.clear();
    _receivedTaskIds.clear();
    _resumeTokens.clear();
    _resumeDecisions.clear();
    for (final task in removed) {
      _notify(task);
    }
  }

  void _updateTask(
    String taskId,
    TransferTask Function(TransferTask) transform,
  ) {
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
