import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/transfer/file_integrity.dart';

import '../../core/transfer/transfer_task.dart';
import '../../core/transfer/transfer_queue_service.dart';
import '../../core/network/network_service.dart';
import '../../core/protocol/binary_transfer_chunk.dart';
import '../../core/protocol/protocol_message.dart';
import '../../core/platform/file_picker_channel.dart';
import '../../core/session/session_service.dart';

class TransferListPage extends StatefulWidget {
  const TransferListPage({
    required this.transferQueue,
    required this.networkService,
    required this.sessionService,
    super.key,
  });

  final TransferQueueService transferQueue;
  final NetworkService networkService;
  final SessionService sessionService;

  @override
  State<TransferListPage> createState() => _TransferListPageState();
}

class _TransferListPageState extends State<TransferListPage> {
  bool _picking = false;
  bool _sendingBatch = false;
  Timer? _progressRefreshTimer;
  final _progressWaiters = <String, _ProgressWaiter>{};
  final _resumeWaiters = <String, Completer<TransferResumeDecision>>{};
  final _retryingTaskIds = <String>{};
  final _secureRandom = Random.secure();

  @override
  void initState() {
    super.initState();
    widget.transferQueue.addListener(_onTaskChanged);
    widget.sessionService.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _progressRefreshTimer?.cancel();
    widget.sessionService.removeListener(_onSessionChanged);
    widget.transferQueue.removeListener(_onTaskChanged);
    for (final waiter in _progressWaiters.values) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(
          StateError('Transfer page was disposed.'),
        );
      }
    }
    _progressWaiters.clear();
    for (final waiter in _resumeWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Transfer page was disposed.'));
      }
    }
    _resumeWaiters.clear();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  bool get _canSend =>
      widget.sessionService.state == SessionState.paired &&
      widget.networkService.connectedClients.contains(
        widget.sessionService.pairedClientId,
      );

  bool get _sendingFile => _tasks.any(
    (task) =>
        !widget.transferQueue.isReceived(task.id) &&
        task.kind == TransferTaskKind.file &&
        (task.status == TransferTaskStatus.transferring ||
            task.status == TransferTaskStatus.verifying),
  );

  void _onTaskChanged(TransferTask task) {
    final resumeWaiter = _resumeWaiters[task.id];
    final resumeDecision = widget.transferQueue.takeResumeDecision(task.id);
    if (resumeWaiter != null && resumeDecision != null) {
      _resumeWaiters.remove(task.id);
      if (!resumeWaiter.isCompleted) resumeWaiter.complete(resumeDecision);
    }
    final waiter = _progressWaiters[task.id];
    if (waiter != null &&
        (task.status == TransferTaskStatus.failed ||
            task.status == TransferTaskStatus.paused)) {
      _progressWaiters.remove(task.id);
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(StateError('Transfer was interrupted.'));
      }
      if (mounted) setState(() {});
      return;
    }
    if (waiter != null &&
        task.completedBytes >= waiter.targetBytes &&
        (!waiter.requireCompletion ||
            task.status == TransferTaskStatus.completed)) {
      _progressWaiters.remove(task.id);
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    if (task.status == TransferTaskStatus.transferring) {
      _progressRefreshTimer ??= Timer(const Duration(milliseconds: 200), () {
        _progressRefreshTimer = null;
        if (mounted) setState(() {});
      });
    } else {
      _progressRefreshTimer?.cancel();
      _progressRefreshTimer = null;
      if (mounted) setState(() {});
    }
  }

  List<TransferTask> get _tasks => widget.transferQueue.tasks;

  String get _connectionStatus => _canSend ? '已连接 1 台设备' : '未连接';

  bool _sameConnection(String clientId, String sessionId) =>
      mounted &&
      _canSend &&
      widget.sessionService.pairedClientId == clientId &&
      widget.sessionService.currentSessionId == sessionId;

  Future<void> _pickAndSendFile() async {
    if (_picking ||
        _sendingBatch ||
        _sendingFile ||
        _retryingTaskIds.isNotEmpty)
      return;
    final clientId = widget.sessionService.pairedClientId;
    final sessionId = widget.sessionService.currentSessionId;
    if (clientId == null || sessionId == null || !_canSend) return;
    setState(() => _picking = true);
    final batch = <({String id, PickedFile file})>[];
    try {
      final selected = await pickFiles();
      if (!mounted || selected.isEmpty) return;
      if (!_sameConnection(clientId, sessionId)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('连接已改变，请重新选择文件')));
        return;
      }
      for (final picked in selected) {
        final taskId = 'send_${_newResumeToken()}';
        widget.transferQueue.addOffer(
          taskId: taskId,
          fileName: picked.name,
          fileSize: picked.size,
        );
        widget.transferQueue.setSentFilePath(taskId, picked.path);
        widget.transferQueue.setResumeToken(taskId, _newResumeToken());
        batch.add((id: taskId, file: picked));
      }
      setState(() {
        _picking = false;
        _sendingBatch = true;
      });
      for (final item in batch) {
        if (!_sameConnection(clientId, sessionId)) break;
        try {
          final file = File(item.file.path);
          if (await file.length() != item.file.size)
            throw StateError('文件大小已改变');
          final hash = await computeFileSha256(file.path);
          // A picker or hash can outlive a session; never send to a different peer.
          if (!_sameConnection(clientId, sessionId)) break;
          final sent = await widget.networkService.send(
            clientId,
            ProtocolMessage(
              type: ProtocolMessageType.transferOffer,
              version: 1,
              messageId: 'offer_${item.id}',
              sessionId: sessionId,
              timestamp: DateTime.now(),
              payload: {
                'taskId': item.id,
                'fileName': item.file.name,
                'fileSize': item.file.size,
                'fileSha256': hash,
                'resumeToken': widget.transferQueue.getResumeToken(item.id),
              },
            ),
          );
          if (!sent) throw StateError('连接已断开');
          widget.transferQueue.startTransfer(item.id);
          await _sendFileChunks(
            clientId,
            sessionId,
            item.id,
            file,
            item.file.size,
            expectedSha256: hash,
          );
        } catch (error) {
          widget.transferQueue.fail(item.id);
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${item.file.name} 发送失败: $error')),
            );
        }
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件出错: $error')));
    } finally {
      // Retain paths/tokens so interrupted queued files can be retried individually.
      for (final item in batch) {
        if (widget.transferQueue.findTask(item.id)?.status ==
            TransferTaskStatus.pending) {
          widget.transferQueue.pause(item.id);
        }
      }
      if (mounted)
        setState(() {
          _picking = false;
          _sendingBatch = false;
        });
    }
  }

  Future<void> _composeAndSendText() async {
    var draft = '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('发送文字'),
        content: TextField(
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          maxLength: 5000,
          onChanged: (value) => draft = value,
          decoration: const InputDecoration(
            hintText: '输入要发送的文字',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = draft.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (text == null || !mounted) return;

    final clientId = widget.sessionService.pairedClientId;
    final sessionId = widget.sessionService.currentSessionId;
    if (clientId == null || sessionId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连接已断开，请重新配对')));
      return;
    }
    final taskId = 'text_${_newResumeToken()}';
    final sent = await widget.networkService.send(
      clientId,
      ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 1,
        messageId: 'message_$taskId',
        sessionId: sessionId,
        timestamp: DateTime.now(),
        payload: {'taskId': taskId, 'text': text},
      ),
    );
    if (!mounted) return;
    if (!sent) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('文字发送失败')));
      return;
    }
    widget.transferQueue.addText(taskId: taskId, text: text, received: false);
  }

  String _newResumeToken() => List.generate(
    16,
    (_) => _secureRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> _retryFile(TransferTask task) async {
    if (_retryingTaskIds.contains(task.id)) return;
    if (_sendingBatch ||
        _sendingFile ||
        _picking ||
        _retryingTaskIds.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请等待当前文件队列完成后重试')));
      return;
    }
    final clientId = widget.sessionService.pairedClientId;
    final sessionId = widget.sessionService.currentSessionId;
    if (clientId == null || sessionId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先重新配对，再重试传输')));
      return;
    }

    final path = widget.transferQueue.getSentFilePath(task.id);
    final resumeToken = widget.transferQueue.getResumeToken(task.id);
    if (path == null || resumeToken == null || task.fileName == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('缺少原文件或续传信息，无法重试')));
      return;
    }

    setState(() => _retryingTaskIds.add(task.id));
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() != task.totalBytes) {
        throw StateError('发送源文件不存在或大小已改变');
      }
      final fileHash = await computeFileSha256(file.path);
      widget.transferQueue.takeResumeDecision(task.id);
      final resumeCompleter = Completer<TransferResumeDecision>();
      _resumeWaiters[task.id] = resumeCompleter;

      final requestSent = await widget.networkService.send(
        clientId,
        ProtocolMessage(
          type: ProtocolMessageType.transferResumeRequest,
          version: 1,
          messageId:
              'resume_${task.id}_${DateTime.now().microsecondsSinceEpoch}',
          sessionId: sessionId,
          timestamp: DateTime.now(),
          payload: {
            'taskId': task.id,
            'fileName': task.fileName,
            'fileSize': task.totalBytes,
            'fileSha256': fileHash,
            'resumeToken': resumeToken,
          },
        ),
      );
      if (!requestSent) throw StateError('连接已断开');

      TransferResumeDecision decision;
      try {
        decision = await resumeCompleter.future.timeout(
          const Duration(seconds: 5),
        );
      } on TimeoutException {
        decision = const TransferResumeDecision(accepted: false, offset: 0);
      }

      var startOffset = 0;
      if (decision.accepted &&
          decision.offset >= 0 &&
          decision.offset <= task.totalBytes) {
        startOffset = decision.offset;
      } else {
        final restartSent = await widget.networkService.send(
          clientId,
          ProtocolMessage(
            type: ProtocolMessageType.transferOffer,
            version: 1,
            messageId:
                'restart_${task.id}_${DateTime.now().microsecondsSinceEpoch}',
            sessionId: sessionId,
            timestamp: DateTime.now(),
            payload: {
              'taskId': task.id,
              'fileName': task.fileName,
              'fileSize': task.totalBytes,
              'fileSha256': fileHash,
              'resumeToken': resumeToken,
              'restart': true,
            },
          ),
        );
        if (!restartSent) throw StateError('无法重新发起传输');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('接收端无法续传，已从头重新传输')));
        }
      }

      widget.transferQueue.restart(task.id, completedBytes: startOffset);
      unawaited(
        _sendFileChunks(
          clientId,
          sessionId,
          task.id,
          file,
          task.totalBytes,
          expectedSha256: fileHash,
          startOffset: startOffset,
        ),
      );
    } catch (e) {
      widget.transferQueue.fail(task.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重试失败: $e')));
      }
    } finally {
      _resumeWaiters.remove(task.id);
      if (mounted) setState(() => _retryingTaskIds.remove(task.id));
    }
  }

  Future<void> _sendFileChunks(
    String clientId,
    String sessionId,
    String taskId,
    File file,
    int fileSize, {
    required String expectedSha256,
    int startOffset = 0,
  }) async {
    // Bound queued data while refilling as soon as individual chunks are
    // acknowledged, rather than draining the entire window between batches.
    const chunkSize = 1024 * 1024;
    const windowBytes = 8 * 1024 * 1024;
    RandomAccessFile? raf;
    int offset = startOffset;
    final buffer = Uint8List(chunkSize);
    final totalTime = Stopwatch()..start();
    final readTime = Stopwatch();
    final enqueueTime = Stopwatch();
    final acknowledgmentTime = Stopwatch();

    try {
      raf = await file.open(mode: FileMode.read);
      await raf.setPosition(startOffset);
      while (offset < fileSize) {
        final nextBytes = min(chunkSize, fileSize - offset);
        acknowledgmentTime.start();
        await _waitForReceiverProgress(
          taskId,
          max(startOffset, offset + nextBytes - windowBytes),
        );
        acknowledgmentTime.stop();
        readTime.start();
        final bytesRead = await raf.readInto(
          buffer,
          0,
          min(chunkSize, fileSize - offset),
        );
        readTime.stop();
        if (bytesRead == 0) break;

        final chunk = Uint8List.sublistView(buffer, 0, bytesRead);

        final chunkFrame = BinaryTransferChunk(
          taskId: taskId,
          offset: offset,
          data: chunk,
        ).encode();

        enqueueTime.start();
        final sent = await widget.networkService.sendBinary(
          clientId,
          chunkFrame,
        );
        enqueueTime.stop();
        if (!sent) {
          throw StateError('WebSocket connection was lost.');
        }

        offset += bytesRead;
      }
      acknowledgmentTime.start();
      await _waitForReceiverProgress(taskId, offset);
      acknowledgmentTime.stop();
      if (offset != fileSize) {
        throw StateError('The selected file changed while it was being sent.');
      }
    } on TimeoutException {
      widget.transferQueue.fail(taskId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('接收端长时间未确认进度，传输已暂停')));
      }
      return;
    } catch (e) {
      widget.transferQueue.fail(taskId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('文件发送失败: $e')));
      }
      return;
    } finally {
      await raf?.close();
      totalTime.stop();
      developer.log(
        'bytes=${offset - startOffset} readMs=${readTime.elapsedMilliseconds} '
        'enqueueMs=${enqueueTime.elapsedMilliseconds} '
        'ackWaitMs=${acknowledgmentTime.elapsedMilliseconds} '
        'totalMs=${totalTime.elapsedMilliseconds}',
        name: 'yichuan.transfer.send',
      );
      _progressWaiters.remove(taskId);
    }

    // Send done notification
    final doneMsg = ProtocolMessage(
      type: ProtocolMessageType.transferDone,
      version: 1,
      messageId: 'done_$taskId',
      sessionId: sessionId,
      timestamp: DateTime.now(),
      payload: {'taskId': taskId, 'sha256': expectedSha256},
    );

    if (!await widget.networkService.send(clientId, doneMsg)) {
      widget.transferQueue.fail(taskId);
      return;
    }
    try {
      await _waitForReceiverCompletion(taskId, fileSize);
    } catch (_) {
      widget.transferQueue.fail(taskId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('接收端未确认文件完整性，传输失败')));
      }
    }
  }

  Future<void> _waitForReceiverProgress(String taskId, int targetBytes) {
    final task = widget.transferQueue.findTask(taskId);
    if (task?.status == TransferTaskStatus.failed ||
        task?.status == TransferTaskStatus.paused) {
      return Future.error(StateError('Receiver rejected the file.'));
    }
    if (task == null || task.completedBytes >= targetBytes) {
      return Future.value();
    }

    final completer = Completer<void>();
    _progressWaiters[taskId] = _ProgressWaiter(
      targetBytes: targetBytes,
      completer: completer,
      requireCompletion: false,
    );
    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> _waitForReceiverCompletion(String taskId, int totalBytes) {
    final task = widget.transferQueue.findTask(taskId);
    if (task?.status == TransferTaskStatus.completed) return Future.value();
    if (task?.status == TransferTaskStatus.failed ||
        task?.status == TransferTaskStatus.paused) {
      return Future.error(StateError('Receiver rejected the file.'));
    }
    final completer = Completer<void>();
    _progressWaiters[taskId] = _ProgressWaiter(
      targetBytes: totalBytes,
      completer: completer,
      requireCompletion: true,
    );
    return completer.future.timeout(const Duration(minutes: 5));
  }

  Future<void> _showDeleteMenu(TransferTask task) async {
    final selected = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListTile(
          leading: Icon(
            Icons.delete_outline,
            color: Theme.of(sheetContext).colorScheme.error,
          ),
          title: Text(
            '删除',
            style: TextStyle(color: Theme.of(sheetContext).colorScheme.error),
          ),
          onTap: () => Navigator.pop(sheetContext, true),
        ),
      ),
    );
    if (selected != true || !mounted) return;

    final isReceived = widget.transferQueue.isReceived(task.id);
    if (!isReceived || task.kind == TransferTaskKind.text) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(isReceived ? '删除接收记录' : '删除发送记录'),
          content: Text(isReceived ? '确认删除这条接收记录？' : '确认删除这条发送记录？源文件不会被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除记录'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        widget.transferQueue.remove(task.id);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已删除记录')));
      }
      return;
    }

    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除接收记录'),
        content: const Text('是否同时删除已接收的文件？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _DeleteChoice.recordOnly),
            child: const Text('仅删除记录'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _DeleteChoice.recordAndFile),
            child: const Text('同时删除文件'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == _DeleteChoice.recordAndFile) {
      final deleted = await deleteReceivedFile(
        uri: widget.transferQueue.getSavedFileUri(task.id),
        path: widget.transferQueue.getReceivedFilePath(task.id),
      );
      if (!deleted) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('文件删除失败，记录已保留')));
        }
        return;
      }
    }

    widget.transferQueue.remove(task.id);
    if (mounted) {
      final message = choice == _DeleteChoice.recordAndFile
          ? '已删除记录和文件'
          : '已删除记录';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _clearRecords() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空传输记录'),
        content: const Text('确认清空全部传输记录？已接收文件和发送源文件都不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.transferQueue.clear();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已清空传输记录')));
  }

  Future<void> _showTextDetails(String text) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('文字详情'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.6,
          ),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('文字已复制')));
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制全部'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '清空记录',
            onPressed:
                _tasks.isEmpty ||
                    _tasks.any(
                      (task) =>
                          task.status == TransferTaskStatus.pending ||
                          task.status == TransferTaskStatus.transferring ||
                          task.status == TransferTaskStatus.verifying ||
                          task.status == TransferTaskStatus.paused,
                    )
                ? null
                : _clearRecords,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _canSend
                        ? const Color(0xFF4CAF50) // green dot
                        : scheme.outline,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _connectionStatus,
                  style: textTheme.labelSmall?.copyWith(color: scheme.outline),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: !_canSend
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'send-text',
                  onPressed: _composeAndSendText,
                  icon: const Icon(Icons.text_fields),
                  label: const Text('发送文字'),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'send-file',
                  onPressed:
                      _picking ||
                          _sendingBatch ||
                          _sendingFile ||
                          _retryingTaskIds.isNotEmpty
                      ? null
                      : _pickAndSendFile,
                  icon: _picking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.file_upload),
                  label: Text(
                    _picking
                        ? '选择中…'
                        : _sendingBatch
                        ? '发送队列中…'
                        : '发送文件',
                  ),
                ),
              ],
            ),
      body: _tasks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_upload_outlined,
                    size: 64,
                    color: scheme.outlineVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '暂无传输任务',
                    style: textTheme.bodyLarge?.copyWith(color: scheme.outline),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    !_canSend ? '请先在"配对"页面连接设备' : '双方均可发送文件或文字',
                    style: textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _tasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final task = _tasks[index];
                // Receiver: use content:// URI from MediaStore
                // Sender: use local file path (starts with /, no scheme)
                String? fileUri;
                String? localPath;
                final isReceived = widget.transferQueue.isReceived(task.id);
                if (task.status == TransferTaskStatus.completed) {
                  fileUri = widget.transferQueue.getSavedFileUri(task.id);
                  localPath = isReceived
                      ? widget.transferQueue.getReceivedFilePath(task.id)
                      : widget.transferQueue.getSentFilePath(task.id);
                }
                return _TransferTaskCard(
                  task: task,
                  scheme: scheme,
                  textTheme: textTheme,
                  fileUri: fileUri,
                  localPath: localPath,
                  onLongPress: task.status == TransferTaskStatus.completed
                      ? () => _showDeleteMenu(task)
                      : null,
                  onRetry:
                      !isReceived &&
                          task.kind == TransferTaskKind.file &&
                          (task.status == TransferTaskStatus.paused ||
                              task.status == TransferTaskStatus.failed)
                      ? () => _retryFile(task)
                      : null,
                  onTextTap: task.kind == TransferTaskKind.text
                      ? () => _showTextDetails(task.text!)
                      : null,
                  retrying: _retryingTaskIds.contains(task.id),
                );
              },
            ),
    );
  }
}

class _ProgressWaiter {
  const _ProgressWaiter({
    required this.targetBytes,
    required this.completer,
    required this.requireCompletion,
  });

  final int targetBytes;
  final Completer<void> completer;
  final bool requireCompletion;
}

enum _DeleteChoice { recordOnly, recordAndFile }

class _TransferTaskCard extends StatelessWidget {
  const _TransferTaskCard({
    required this.task,
    required this.scheme,
    required this.textTheme,
    this.fileUri,
    this.localPath,
    this.onLongPress,
    this.onRetry,
    this.onTextTap,
    this.retrying = false,
  });

  final TransferTask task;
  final ColorScheme scheme;
  final TextTheme textTheme;
  final String? fileUri;
  final String? localPath;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;
  final VoidCallback? onTextTap;
  final bool retrying;

  bool get _canOpen => fileUri != null || localPath != null;
  bool get _isInteractive =>
      _canOpen || onLongPress != null || onRetry != null || onTextTap != null;

  Future<void> _openWithFallback(BuildContext context) async {
    final opened = fileUri != null
        ? await openFile(fileUri!, fileName: task.fileName)
        : localPath != null &&
              await openLocalFile(localPath!, fileName: task.fileName);
    if (!opened && context.mounted) await _revealLocation(context);
  }

  Future<void> _revealLocation(BuildContext context) async {
    final revealed = await revealFile(uri: fileUri, path: localPath);
    if (!revealed && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '无法打开或定位文件，请在文件管理器中查找：${fileUri != null ? 'Download/驿传/${task.fileName}' : localPath}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (task.status) {
      TransferTaskStatus.completed => scheme.primary,
      TransferTaskStatus.failed => scheme.error,
      TransferTaskStatus.transferring ||
      TransferTaskStatus.verifying => scheme.tertiary,
      TransferTaskStatus.paused => scheme.outline,
      _ => scheme.outlineVariant,
    };

    final statusLabel = switch (task.status) {
      TransferTaskStatus.pending => '等待中',
      TransferTaskStatus.transferring => '传输中',
      TransferTaskStatus.verifying => '校验中',
      TransferTaskStatus.paused => '已暂停',
      TransferTaskStatus.failed => '失败',
      TransferTaskStatus.completed => '已完成',
    };

    final icon = task.kind == TransferTaskKind.text
        ? Icons.text_fields
        : Icons.insert_drive_file;

    return Card(
      clipBehavior: _isInteractive ? Clip.antiAlias : Clip.none,
      child: _isInteractive
          ? InkWell(
              onTap:
                  onTextTap ??
                  (_canOpen ? () => _openWithFallback(context) : null),
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _cardBody(
                  context,
                  scheme,
                  textTheme,
                  statusColor,
                  statusLabel,
                  icon,
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: _cardBody(
                context,
                scheme,
                textTheme,
                statusColor,
                statusLabel,
                icon,
              ),
            ),
    );
  }

  Widget _cardBody(
    BuildContext context,
    ColorScheme scheme,
    TextTheme textTheme,
    Color statusColor,
    String statusLabel,
    IconData icon,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                task.fileName ?? '文字消息',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(30),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (task.kind == TransferTaskKind.text) ...[
          Text(
            task.text!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatBytes(task.totalBytes)} 文字消息',
            style: textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 4),
          Text(
            '点击查看详情',
            style: textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ] else ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: task.status == TransferTaskStatus.verifying
                  ? null
                  : task.progress,
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_formatBytes(task.completedBytes)} / ${_formatBytes(task.totalBytes)}',
            style: textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
          if (_canOpen) ...[
            const SizedBox(height: 4),
            Text(
              '点击打开文件',
              style: textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                fontStyle: FontStyle.italic,
              ),
            ),
            TextButton.icon(
              onPressed: () => _revealLocation(context),
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('打开所在位置'),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: retrying ? null : onRetry,
                icon: retrying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(retrying ? '协商中…' : '重试'),
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
