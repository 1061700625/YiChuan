import 'dart:async';
import 'dart:io';

enum IncomingTransferState {
  receiving,
  paused,
  verifying,
  completed,
  failed,
  canceled,
}

class IncomingTransfer {
  IncomingTransfer({
    required this.clientId,
    required this.savePath,
    required RandomAccessFile raf,
    required this.totalBytes,
    required this.fileName,
    required this.expectedSha256,
    required this.resumeToken,
  }) : _raf = raf;

  String clientId;
  final String savePath;
  RandomAccessFile? _raf;
  RandomAccessFile? get raf => _raf;
  final int totalBytes;
  final String fileName;
  final String expectedSha256;
  final String resumeToken;
  int receivedBytes = 0;
  final writeTime = Stopwatch();
  final receiveTime = Stopwatch();
  final finalized = Completer<void>();
  IncomingTransferState _state = IncomingTransferState.receiving;
  IncomingTransferState get state => _state;
  bool get finalizing => _state == IncomingTransferState.verifying;
  bool get completed => _state == IncomingTransferState.completed;
  bool get acceptsChunks => _state == IncomingTransferState.receiving;
  bool get canResume =>
      _state == IncomingTransferState.paused || finalizing || completed;
  Future<void>? _closing;
  Future<void>? _writing;

  Future<void> write(List<int> bytes) {
    final writer = _raf;
    if (!acceptsChunks || writer == null)
      throw StateError('Transfer is not writable');
    return _writing = writer.writeFrom(bytes).then<void>((_) {});
  }

  Future<void> closeWriter() {
    if (_closing != null) return _closing!;
    final writer = raf;
    _raf = null;
    return _closing = (_writing ?? Future<void>.value()).whenComplete(() async {
      await writer?.close();
    });
  }

  Future<void> pause() {
    if (_state != IncomingTransferState.receiving) return Future<void>.value();
    _state = IncomingTransferState.paused;
    return closeWriter();
  }

  Future<void> resume() async {
    if (_state != IncomingTransferState.paused) throw StateError('Not paused');
    await closeWriter();
    final writer = await File(savePath).open(mode: FileMode.append);
    if (_state != IncomingTransferState.paused) {
      await writer.close();
      throw StateError('Transfer canceled');
    }
    _raf = writer;
    _closing = null;
    _state = IncomingTransferState.receiving;
  }

  void beginVerification() {
    if (!acceptsChunks && _state != IncomingTransferState.paused) {
      throw StateError('Cannot verify $_state');
    }
    _state = IncomingTransferState.verifying;
  }

  void complete() {
    if (!finalizing) throw StateError('Cannot complete $_state');
    _state = IncomingTransferState.completed;
    _finish();
  }

  void fail() {
    if (completed || _state == IncomingTransferState.canceled) return;
    _state = IncomingTransferState.failed;
    _finish();
  }

  Future<void> cancel() {
    _state = IncomingTransferState.canceled;
    _finish();
    return closeWriter();
  }

  void _finish() {
    if (!finalized.isCompleted) finalized.complete();
  }
}
