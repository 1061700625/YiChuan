import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/websocket_network_service.dart';

void main() {
  test(
    'slow handlers have a bounded receive queue and discard queued frames on close',
    () async {
      final service = WebSocketNetworkService();
      final gate = Completer<void>();
      final entered = Completer<void>();
      final disconnected = Completer<void>();
      var notifications = 0;
      var binaryCalls = 0;
      service.onMessageReceived = (_, _) async {
        entered.complete();
        await gate.future;
      };
      service.onBinaryReceived = (_, _) {
        binaryCalls++;
      };
      service.onClientDisconnected = (_) {
        notifications++;
        if (!disconnected.isCompleted) disconnected.complete();
      };
      final port = await service.startServer(port: 0);
      final peer = await WebSocket.connect('ws://127.0.0.1:$port');
      peer.listen((_) {});
      try {
        peer.add(
          jsonEncode({
            'type': 'hello',
            'version': 1,
            'messageId': 'm',
            'timestamp': DateTime.now().toIso8601String(),
            'payload': {},
          }),
        );
        await entered.future;
        peer.add(Uint8List(17 * 1024 * 1024));
        peer.add(Uint8List(17 * 1024 * 1024));
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(service.connectedClients, isEmpty);
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        expect(binaryCalls, 0);
        await peer.close();
        await service.stopServer();
        expect(notifications, 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await peer.close();
        await service.stopServer();
      }
    },
  );
  test('slow ordered handlers do not block WebSocket heartbeats', () async {
    final service = WebSocketNetworkService();
    final gate = Completer<void>();
    final first = Completer<void>();
    final second = Completer<void>();
    final order = <String>[];
    service.onMessageReceived = (_, message) async {
      order.add(message.messageId);
      if (message.messageId == 'first') {
        first.complete();
        await gate.future;
      } else {
        second.complete();
      }
    };
    final port = await service.startServer(port: 0);
    final peer = await WebSocket.connect('ws://127.0.0.1:$port');
    peer.pingInterval = const Duration(milliseconds: 50);
    peer.listen((_) {});
    try {
      for (final id in ['first', 'second']) {
        peer.add(
          jsonEncode({
            'type': 'hello',
            'version': 1,
            'messageId': id,
            'timestamp': DateTime.now().toIso8601String(),
            'payload': {},
          }),
        );
      }
      await first.future;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(peer.readyState, WebSocket.open);
      expect(order, ['first']);
      gate.complete();
      await second.future.timeout(const Duration(seconds: 2));
      expect(order, ['first', 'second']);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await peer.close();
      await service.stopServer();
    }
  });
  test(
    'file sockets do not negotiate compression in either connection direction',
    () async {
      final service = WebSocketNetworkService();
      final port = await service.startServer(port: 0);
      final http = HttpClient();
      final request = await http.getUrl(Uri.parse('http://127.0.0.1:$port'));
      request.headers.set('Connection', 'Upgrade');
      request.headers.set('Upgrade', 'websocket');
      request.headers.set('Sec-WebSocket-Version', '13');
      request.headers.set('Sec-WebSocket-Key', 'MDEyMzQ1Njc4OWFiY2RlZg==');
      request.headers.set(
        'Sec-WebSocket-Extensions',
        'permessage-deflate; client_max_window_bits',
      );
      final response = await request.close();
      expect(response.statusCode, 101);
      expect(response.headers.value('Sec-WebSocket-Extensions'), isNull);
      (await response.detachSocket()).destroy();
      http.close(force: true);
      await service.stopServer();

      final raw = await HttpServer.bind('127.0.0.1', 0);
      final accepted = Completer<WebSocket>();
      String? requestedCompression;
      raw.listen((request) async {
        requestedCompression = request.headers.value(
          'Sec-WebSocket-Extensions',
        );
        accepted.complete(await WebSocketTransformer.upgrade(request));
      });
      final id = await service.connect(host: '127.0.0.1', port: raw.port);
      expect(id, isNotNull);
      final peer = await accepted.future;
      peer.listen((_) {});
      expect(requestedCompression, isNull);
      await service.stopServer();
      await peer.close();
      await raw.close(force: true);
    },
  );

  test(
    'shutdown tolerates peer closure while an async handler completes',
    () async {
      final server = WebSocketNetworkService();
      final gate = Completer<void>();
      final entered = Completer<void>();
      final disconnected = Completer<void>();
      server.onClientDisconnected = (_) {
        if (!disconnected.isCompleted) disconnected.complete();
      };
      server.onMessageReceived = (_, _) async {
        entered.complete();
        await gate.future;
      };
      final port = await server.startServer(port: 0);
      final socket = await WebSocket.connect('ws://127.0.0.1:$port');
      socket.pingInterval = const Duration(milliseconds: 50);
      final closed = Completer<void>();
      socket.listen((_) {}, onDone: () => closed.complete());
      socket.add(
        jsonEncode({
          'type': 'hello',
          'version': 1,
          'messageId': 'message',
          'timestamp': DateTime.now().toIso8601String(),
          'payload': {},
        }),
      );
      await entered.future;
      await socket.close();
      await closed.future.timeout(const Duration(seconds: 2));
      await disconnected.future.timeout(const Duration(seconds: 2));
      expect(server.connectedClients, isEmpty);
      gate.complete();
      await socket.close();
      await server.stopServer();
      expect(server.connectedClients, isEmpty);
    },
  );

  test(
    'stopping a server with live peers closes connections without concurrent mutation',
    () async {
      final server = WebSocketNetworkService();
      final port = await server.startServer(port: 0);
      final first = await WebSocket.connect('ws://127.0.0.1:$port');
      final second = await WebSocket.connect('ws://127.0.0.1:$port');
      first.listen((_) {});
      second.listen((_) {});
      await server.stopServer();
      expect(server.connectedClients, isEmpty);
      await first.close();
      await second.close();
    },
  );
  test(
    'empty binary frames cannot exhaust an unbounded pending frame count',
    () async {
      final service = WebSocketNetworkService();
      final gate = Completer<void>();
      final entered = Completer<void>();
      final disconnected = Completer<void>();
      var notifications = 0;
      var binaryCalls = 0;
      service.onMessageReceived = (_, _) async {
        entered.complete();
        await gate.future;
      };
      service.onBinaryReceived = (_, _) {
        binaryCalls++;
      };
      service.onClientDisconnected = (_) {
        notifications++;
        if (!disconnected.isCompleted) disconnected.complete();
      };
      final port = await service.startServer(port: 0);
      final peer = await WebSocket.connect('ws://127.0.0.1:$port');
      peer.listen((_) {});
      try {
        peer.add(
          jsonEncode({
            'type': 'hello',
            'version': 1,
            'messageId': 'blocking',
            'timestamp': DateTime.now().toIso8601String(),
            'payload': {},
          }),
        );
        await entered.future;
        // Zero-byte frames carry no byte cost, so a hostile or buggy peer can
        // enqueue as many of them as the socket buffer admits.
        for (var i = 0; i < 20000; i++) {
          peer.add(Uint8List(0));
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(service.connectedClients, isEmpty);
        gate.complete();
        // Frames already queued behind the disconnect must be dropped, not
        // dispatched to business callbacks.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(binaryCalls, 0);
        await peer.close();
        await service.stopServer();
        expect(notifications, 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await peer.close();
        await service.stopServer();
      }
    },
  );
}
