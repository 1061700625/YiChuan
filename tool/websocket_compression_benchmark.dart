// Run with dart tool/websocket_compression_benchmark.dart.
// Loopback-only compression probe: excludes disk I/O, Wi-Fi and file verification.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

Future<void> main() async {
  final random = Random(42);
  final data = Uint8List.fromList(
    List.generate(1024 * 1024, (_) => random.nextInt(256)),
  );
  for (final compression in [
    CompressionOptions.compressionDefault,
    CompressionOptions.compressionOff,
  ]) {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      final peer = await WebSocketTransformer.upgrade(
        request,
        compression: compression,
      );
      peer.listen((frame) {
        peer.add((frame as List<int>).length.toString());
      });
    });
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}',
      compression: compression,
    );
    var sent = 0;
    var received = 0;
    final done = Completer<void>();
    final clock = Stopwatch()..start();
    socket.listen((ack) {
      received++;
      if (sent < 64) {
        socket.add(data);
        sent++;
      }
      if (received == 64) done.complete();
    });
    for (var i = 0; i < 8; i++) {
      socket.add(data);
      sent++;
    }
    await done.future;
    clock.stop();
    print(
      'compression=${compression.enabled} bytes=${64 * data.length} milliseconds=${clock.elapsedMilliseconds} MiB/s=${(64 / (clock.elapsedMicroseconds / 1000000)).toStringAsFixed(1)}',
    );
    await socket.close();
    await server.close(force: true);
  }
}
