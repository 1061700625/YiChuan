import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/discovery/subnet_scanner.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

void main() {
  test('default scan covers the server fallback port', () {
    final scanner = SubnetScanner();
    expect(scanner.scanPort, 45678);
    expect(scanner.fallbackPort, 45679);
  });
  for (final fallback in [false, true]) {
    test(
      'subnet discovery preserves identity on ${fallback ? 'fallback' : 'primary'} port',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((_) {});
          socket.add(
            jsonEncode({
              'type': 'hello',
              'version': 1,
              'payload': {
                'deviceId': 'real-peer-id',
                'deviceName': 'Windows Peer',
                'platform': 'windows',
                'port': server.port,
              },
            }),
          );
        });
        final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => primary.close(force: true));
        primary.listen((request) {
          request.response.statusCode = 400;
          request.response.close();
        });
        final results = await SubnetScanner(
          scanPort: fallback ? primary.port : server.port,
          fallbackPort: fallback ? server.port : null,
          connectionTimeout: const Duration(milliseconds: 100),
          maxConcurrent: 100,
        ).scan(ownIp: '127.0.0.2');
        final peer = results.singleWhere((d) => d.ip == '127.0.0.1');
        expect(peer.deviceName, 'Windows Peer');
        expect(peer.deviceId, 'real-peer-id');
        expect(peer.platform, DevicePlatform.windows);
      },
    );
  }
}
