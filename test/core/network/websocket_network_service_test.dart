import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/websocket_network_service.dart';

void main() {
  test(
    'shutdown tolerates peer closure while an async handler completes',
    () async {
      final server = WebSocketNetworkService();
      final gate = Completer<void>();
      final entered = Completer<void>();
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
      await closed.future.timeout(const Duration(seconds: 2));
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
}
