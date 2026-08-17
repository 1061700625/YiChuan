import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/protocol_message.dart';
import 'network_service.dart';

class WebSocketNetworkService implements NetworkService {
  static const _pingInterval = Duration(seconds: 20);
  HttpServer? _server;
  final _clients = <String, WebSocket>{};
  int _nextId = 1;
  NetworkConnectionState _state = NetworkConnectionState.disconnected;
  int? _listeningPort;
  bool _isInitiator = false;
  MessageReceivedCallback? _onMessageReceived;
  BinaryReceivedCallback? _onBinaryReceived;
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
  MessageReceivedCallback? get onMessageReceived => _onMessageReceived;

  @override
  set onMessageReceived(MessageReceivedCallback? callback) {
    _onMessageReceived = callback;
  }

  @override
  BinaryReceivedCallback? get onBinaryReceived => _onBinaryReceived;

  @override
  set onBinaryReceived(BinaryReceivedCallback? callback) {
    _onBinaryReceived = callback;
  }

  @override
  void Function(String clientId)? get onClientDisconnected =>
      _onClientDisconnected;

  @override
  set onClientDisconnected(void Function(String clientId)? callback) {
    _onClientDisconnected = callback;
  }

  @override
  void Function(String clientId)? get onClientConnected => _onClientConnected;

  @override
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
        webSocket.pingInterval = _pingInterval;
        final id = 'client_${_nextId++}';
        _clients[id] = webSocket;
        _state = NetworkConnectionState.connected;

        // Notify server that a new client connected (for hello announcement)
        _onClientConnected?.call(id);

        unawaited(_listenToClient(id, webSocket));
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
      socket.pingInterval = _pingInterval;
      final id = 'client_${_nextId++}';
      _clients[id] = socket;
      _state = NetworkConnectionState.connected;
      _isInitiator = true;

      unawaited(_listenToClient(id, socket));

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
      client.add(jsonEncode(message.toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendBinary(String clientId, Uint8List data) async {
    final client = _clients[clientId];
    if (client == null) return false;

    try {
      client.add(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleIncomingData(String clientId, dynamic data) async {
    try {
      if (data is String) {
        final json = jsonDecode(data) as Map<String, Object?>;
        await _onMessageReceived?.call(
          clientId,
          ProtocolMessage.fromJson(json),
        );
      } else if (data is List<int>) {
        await _onBinaryReceived?.call(
          clientId,
          data is Uint8List ? data : Uint8List.fromList(data),
        );
      }
    } catch (_) {
      // Ignore malformed or unsupported frames.
    }
  }

  Future<void> _listenToClient(String clientId, WebSocket socket) async {
    try {
      await for (final data in socket) {
        await _handleIncomingData(clientId, data);
      }
    } catch (_) {
      // A closed or malformed connection is handled like a normal disconnect.
    } finally {
      if (_clients.remove(clientId) != null) {
        _onClientDisconnected?.call(clientId);
      }
      if (_clients.isEmpty) {
        _state = _server != null
            ? NetworkConnectionState.listening
            : NetworkConnectionState.disconnected;
      }
    }
  }

  @override
  Future<void> disconnect(String clientId) async {
    final client = _clients.remove(clientId);
    await client?.close();
    _onClientDisconnected?.call(clientId);
    if (_clients.isEmpty) {
      _state = _server != null
          ? NetworkConnectionState.listening
          : NetworkConnectionState.disconnected;
    }
  }

  @override
  Future<void> stopServer() async {
    for (final client in _clients.values) {
      await client.close();
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
