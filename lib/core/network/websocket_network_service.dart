import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/protocol_message.dart';
import 'network_service.dart';

class WebSocketNetworkService implements NetworkService {
  HttpServer? _server;
  final _clients = <String, _WsClient>{};
  int _nextId = 1;
  NetworkConnectionState _state = NetworkConnectionState.disconnected;
  int? _listeningPort;
  bool _isInitiator = false;
  void Function(ProtocolMessage message)? _onMessageReceived;
  void Function(String clientId)? _onClientConnected;
  void Function(String clientId)? _onClientDisconnected;

  @override
  bool get isInitiator => _isInitiator;

  @override
  NetworkConnectionState get connectionState => _state;

  @override
  int? get listeningPort => _listeningPort;

  @override
  List<String> get connectedClients => _clients.keys.toList(growable: false);

  @override
  void Function(ProtocolMessage message)? get onMessageReceived => _onMessageReceived;

  @override
  set onMessageReceived(void Function(ProtocolMessage message)? callback) {
    _onMessageReceived = callback;
  }

  @override
  void Function(String clientId)? get onClientDisconnected => _onClientDisconnected;

  @override
  set onClientDisconnected(void Function(String clientId)? callback) {
    _onClientDisconnected = callback;
  }

  /// Callback invoked when a new client connects to this server.
  set onClientConnected(void Function(String clientId)? callback) {
    _onClientConnected = callback;
  }

  @override
  Future<int> startServer({required int port}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _listeningPort = _server!.port;
    _state = NetworkConnectionState.listening;

    _server!.listen((HttpRequest request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final webSocket = await WebSocketTransformer.upgrade(request);
        final id = 'client_${_nextId++}';
        final client = _WsClient(id: id, socket: webSocket);
        _clients[id] = client;
        _state = NetworkConnectionState.connected;

        // Notify server that a new client connected (for hello announcement)
        _onClientConnected?.call(id);

        webSocket.listen(
          (data) {
            try {
              final json = jsonDecode(data as String) as Map<String, Object?>;
              final message = ProtocolMessage.fromJson(json);
              _onMessageReceived?.call(message);
            } catch (_) {}
          },
          onDone: () {
            // Only fire callback if disconnect() hasn't already removed this client
            if (_clients.remove(id) != null) {
              _onClientDisconnected?.call(id);
            }
            if (_clients.isEmpty) {
              _state = _server != null ? NetworkConnectionState.listening : NetworkConnectionState.disconnected;
            }
          },
        );
      } else {
        request.response.statusCode = 400;
        request.response.close();
      }
    });

    return _listeningPort!;
  }

  @override
  Future<String?> connect({required String host, required int port}) async {
    try {
      final socket = await WebSocket.connect('ws://$host:$port');
      final id = 'client_${_nextId++}';
      final client = _WsClient(id: id, socket: socket);
      _clients[id] = client;
      _state = NetworkConnectionState.connected;
      _isInitiator = true;

      socket.listen(
        (data) {
          try {
            final json = jsonDecode(data as String) as Map<String, Object?>;
            final message = ProtocolMessage.fromJson(json);
            _onMessageReceived?.call(message);
          } catch (_) {}
        },
        onDone: () {
          // Only fire callback + update state if disconnect() hasn't already
          // removed this client. Avoids race between explicit disconnect and
          // the async onDone event (socket.close → onDone).
          if (_clients.remove(id) != null) {
            _onClientDisconnected?.call(id);
          }
          if (_clients.isEmpty) {
            _state = _server != null ? NetworkConnectionState.listening : NetworkConnectionState.disconnected;
          }
        },
      );

      return id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> send(String clientId, ProtocolMessage message) async {
    final client = _clients[clientId];
    if (client == null) return false;

    try {
      client.socket.add(jsonEncode(message.toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> disconnect(String clientId) async {
    final client = _clients.remove(clientId);
    await client?.socket.close();
    _onClientDisconnected?.call(clientId);
    if (_clients.isEmpty) {
      _state = _server != null ? NetworkConnectionState.listening : NetworkConnectionState.disconnected;
    }
  }

  @override
  Future<void> stopServer() async {
    for (final client in _clients.values) {
      await client.socket.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    _listeningPort = null;
    _state = NetworkConnectionState.disconnected;
    _isInitiator = false;
  }

  void dispose() {
    stopServer();
  }
}

class _WsClient {
  _WsClient({required this.id, required this.socket});
  final String id;
  final WebSocket socket;
}
