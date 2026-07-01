import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/transfer/transfer_task.dart';
import '../../core/transfer/transfer_queue_service.dart';
import '../../core/network/network_service.dart';
import '../../core/protocol/protocol_message.dart';
import '../../core/platform/file_picker_channel.dart';

/// Safe file picker wrapper.
Future<({String path, String name, int size})?> pickSingleFile() async {
  try {
    return await pickFile();
  } catch (_) {
    return null;
  }
}

class TransferListPage extends StatefulWidget {
  const TransferListPage({
    required this.transferQueue,
    required this.networkService,
    super.key,
  });

  final TransferQueueService transferQueue;
  final NetworkService networkService;

  @override
  State<TransferListPage> createState() => _TransferListPageState();
}

class _TransferListPageState extends State<TransferListPage> {
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    widget.transferQueue.addListener(_onTaskChanged);
  }

  @override
  void dispose() {
    widget.transferQueue.removeListener(_onTaskChanged);
    super.dispose();
  }

  void _onTaskChanged(TransferTask _) {
    if (mounted) setState(() {});
  }

  List<TransferTask> get _tasks => widget.transferQueue.tasks;

  String get _connectionStatus {
    final count = widget.networkService.connectedClients.length;
    if (count == 0) return '未连接';
    if (count == 1) return '已连接 1 台设备';
    return '已连接 $count 台设备';
  }

  Future<void> _pickAndSendFile() async {
    if (_picking) return;
    setState(() => _picking = true);

    try {
      final picked = await pickSingleFile();
      if (picked == null) return;

      final file = File(picked.path);
      final fileSize = picked.size;
      final fileName = picked.name;

      if (widget.networkService.connectedClients.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有已连接的设备，请先配对')),
          );
        }
        return;
      }

      final taskId = 'send_${DateTime.now().millisecondsSinceEpoch}';
      final task = widget.transferQueue.addOffer(
        taskId: taskId,
        fileName: fileName,
        fileSize: fileSize,
        checksum: fileSize.toString(),
      );

      // Send offer to all connected clients
      final offerMsg = ProtocolMessage(
        type: ProtocolMessageType.transferOffer,
        version: 1,
        messageId: 'offer_$taskId',
        timestamp: DateTime.now(),
        payload: {
          'taskId': taskId,
          'fileName': fileName,
          'fileSize': fileSize,
          'checksum': fileSize.toString(),
        },
      );

      for (final clientId in widget.networkService.connectedClients) {
        await widget.networkService.send(clientId, offerMsg);
      }

      widget.transferQueue.startTransfer(taskId);
      // Store the file path so the sender can tap to open it later
      widget.transferQueue.setSentFilePath(taskId, picked.path);

      // Read and send chunks in the background
      _sendFileChunks(taskId, file, fileSize);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件出错: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _sendFileChunks(String taskId, File file, int fileSize) async {
    const chunkSize = 64 * 1024; // 64 KB
    final raf = await file.open(mode: FileMode.read);
    int offset = 0;
    int chunkIndex = 0;
    final buffer = Uint8List(chunkSize);

    try {
      while (offset < fileSize) {
        final bytesRead = await raf.readInto(buffer, 0, chunkSize);
        if (bytesRead == 0) break;

        final chunk = buffer.sublist(0, bytesRead);

        final chunkMsg = ProtocolMessage(
          type: ProtocolMessageType.chunk,
          version: 1,
          messageId: 'chunk_${taskId}_$chunkIndex',
          timestamp: DateTime.now(),
          payload: {
            'taskId': taskId,
            'chunkIndex': chunkIndex,
            'offset': offset,
            'size': chunk.length,
            'data': base64Encode(chunk),
          },
        );

        for (final clientId in widget.networkService.connectedClients) {
          await widget.networkService.send(clientId, chunkMsg);
        }

        widget.transferQueue.recordChunkCompleted(taskId, chunkSize: chunk.length);
        offset += bytesRead;
        chunkIndex++;

        // Small delay to not flood the socket
        await Future.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      await raf.close();
    }

    // Send done notification
    final doneMsg = ProtocolMessage(
      type: ProtocolMessageType.transferDone,
      version: 1,
      messageId: 'done_$taskId',
      timestamp: DateTime.now(),
      payload: {'taskId': taskId, 'checksum': fileSize.toString()},
    );

    for (final clientId in widget.networkService.connectedClients) {
      await widget.networkService.send(clientId, doneMsg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.networkService.connectedClients.isNotEmpty
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
      floatingActionButton: (_tasks.any((t) => t.status == TransferTaskStatus.transferring) || !widget.networkService.isInitiator)
          ? null
          : FloatingActionButton.extended(
              onPressed: _picking ? null : _pickAndSendFile,
              icon: _picking
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.file_upload),
              label: Text(_picking ? '选择中…' : '发送文件'),
            ),
      body: _tasks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_upload_outlined, size: 64, color: scheme.outlineVariant),
                  const SizedBox(height: 16),
                  Text('暂无传输任务', style: textTheme.bodyLarge?.copyWith(color: scheme.outline)),
                  const SizedBox(height: 8),
                  Text(
                    widget.networkService.connectedClients.isEmpty
                        ? '请先在"配对"页面连接设备'
                        : widget.networkService.isInitiator
                            ? '配对完成后，点击右下角按钮发送文件'
                            : '等待对方发送文件…',
                    style: textTheme.bodySmall?.copyWith(color: scheme.outline)),
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
                if (task.status == TransferTaskStatus.completed && task.kind == TransferTaskKind.file) {
                  fileUri = widget.transferQueue.getSavedFileUri(task.id);
                  localPath = widget.transferQueue.getSentFilePath(task.id);
                }
                return _TransferTaskCard(
                  task: task,
                  scheme: scheme,
                  textTheme: textTheme,
                  fileUri: fileUri,
                  localPath: localPath,
                );
              },
            ),
    );
  }
}

class _TransferTaskCard extends StatelessWidget {
  const _TransferTaskCard({
    required this.task,
    required this.scheme,
    required this.textTheme,
    this.fileUri,
    this.localPath,
  });

  final TransferTask task;
  final ColorScheme scheme;
  final TextTheme textTheme;
  final String? fileUri;
  final String? localPath;

  bool get _canOpen => fileUri != null || localPath != null;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (task.status) {
      TransferTaskStatus.completed => scheme.primary,
      TransferTaskStatus.failed => scheme.error,
      TransferTaskStatus.transferring => scheme.tertiary,
      TransferTaskStatus.paused => scheme.outline,
      _ => scheme.outlineVariant,
    };

    final statusLabel = switch (task.status) {
      TransferTaskStatus.pending => '等待中',
      TransferTaskStatus.transferring => '传输中',
      TransferTaskStatus.paused => '已暂停',
      TransferTaskStatus.failed => '失败',
      TransferTaskStatus.completed => '已完成',
      TransferTaskStatus.canceled => '已取消',
    };

    final icon = switch (task.kind) {
      TransferTaskKind.text => Icons.text_fields,
      TransferTaskKind.file => Icons.insert_drive_file,
    };

    return Card(
      clipBehavior: _canOpen ? Clip.antiAlias : Clip.none,
      child: _canOpen
          ? InkWell(
              onTap: () {
                if (fileUri != null) {
                  openFile(fileUri!);
                } else if (localPath != null) {
                  openLocalFile(localPath!);
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _cardBody(scheme, textTheme, statusColor, statusLabel, icon),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: _cardBody(scheme, textTheme, statusColor, statusLabel, icon),
            ),
    );
  }

  Widget _cardBody(ColorScheme scheme, TextTheme textTheme, Color statusColor, String statusLabel, IconData icon) {
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
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(30),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(statusLabel,
                  style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: task.progress,
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
          Text('点击打开文件', style: textTheme.labelSmall?.copyWith(
            color: scheme.primary,
            fontStyle: FontStyle.italic,
          )),
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
