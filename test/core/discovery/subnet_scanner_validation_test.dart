import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/discovery/subnet_scanner.dart';

void main() {
  final invalidGreetings = <String, Object>{
    'unrelated websocket': '{"type":"unrelated"}',
    'binary greeting': <int>[1, 2, 3],
    'invalid JSON': 'invalid',
    'unsupported version':
        '{"type":"hello","version":2,"payload":{"deviceId":"id","deviceName":"PC","platform":"windows"}}',
    'missing identity':
        '{"type":"hello","version":1,"payload":{"deviceName":"PC","platform":"windows"}}',
    'unknown platform':
        '{"type":"hello","version":1,"payload":{"deviceId":"id","deviceName":"PC","platform":"other"}}',
  };
  for (final entry in invalidGreetings.entries) {
    test('${entry.key} is ignored without uncaught errors', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        final ws = await WebSocketTransformer.upgrade(r);
        ws.listen((_) {});
        ws.add(entry.value);
      });
      final found = await SubnetScanner(
        scanPort: server.port,
        fallbackPort: null,
        connectionTimeout: const Duration(milliseconds: 100),
        maxConcurrent: 100,
      ).scan(ownIp: '127.0.0.2');
      expect(found, isEmpty);
    });
  }
}
