import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/transfer/incoming_transfer.dart';

class _BlockedWriter implements RandomAccessFile {
  final closed = Completer<void>();
  int closes = 0;
  final written = Completer<RandomAccessFile>();
  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) => written.future;
  @override
  Future<void> close() {
    closes++;
    return closed.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

IncomingTransfer transfer(RandomAccessFile writer) => IncomingTransfer(
  clientId: 'old',
  savePath: '/unused',
  raf: writer,
  totalBytes: 1,
  fileName: 'f',
  expectedSha256: 'hash',
  resumeToken: 'token',
);

void main() {
  test('pause waits for an active write before closing the file', () async {
    final writer = _BlockedWriter();
    final incoming = transfer(writer);
    final writing = incoming.write([1]);
    final pausing = incoming.pause();
    await Future<void>.delayed(Duration.zero);
    expect(writer.closes, 0);
    writer.written.complete(writer);
    await writing;
    await Future<void>.delayed(Duration.zero);
    expect(writer.closes, 1);
    writer.closed.complete();
    await pausing;
    expect(incoming.state, IncomingTransferState.paused);
  });
  test(
    'verification owns the writer before asynchronous close finishes',
    () async {
      final writer = _BlockedWriter();
      final incoming = transfer(writer)..receivedBytes = 1;
      incoming.beginVerification();
      final close = incoming.closeWriter();
      expect(incoming.state, IncomingTransferState.verifying);
      expect(incoming.canResume, isTrue);
      expect(incoming.acceptsChunks, isFalse);
      await incoming.pause();
      expect(incoming.state, IncomingTransferState.verifying);
      await Future<void>.delayed(Duration.zero);
      expect(writer.closes, 1);
      writer.closed.complete();
      await close;
      incoming.complete();
      await incoming.finalized.future;
      expect(incoming.state, IncomingTransferState.completed);
      expect(() => incoming.beginVerification(), throwsStateError);
    },
  );

  test('pause and cancellation share an in-flight close', () async {
    final writer = _BlockedWriter();
    final incoming = transfer(writer);
    final pausing = incoming.pause();
    expect(incoming.state, IncomingTransferState.paused);
    final canceling = incoming.cancel();
    expect(incoming.state, IncomingTransferState.canceled);
    expect(incoming.acceptsChunks, isFalse);
    expect(incoming.canResume, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(writer.closes, 1);
    writer.closed.complete();
    await Future.wait([pausing, canceling]);
    expect(() => incoming.complete(), throwsStateError);
  });
}
