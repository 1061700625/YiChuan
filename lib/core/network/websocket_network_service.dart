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
        final webSocket = await WebSocketTransformer.upgrade(
          request,
          compression: CompressionOptions.compressionOff,
        );
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
      final socket = await WebSocket.connect(
        'ws://$host:$port',
        compression: CompressionOptions.compressionOff,
      );
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

  void _removeClient(String clientId) {
    if (_clients.remove(clientId) == null) return;
    if (_clients.isEmpty) {
      _state = _server != null
          ? NetworkConnectionState.listening
          : NetworkConnectionState.disconnected;
    }
    _onClientDisconnected?.call(clientId);
  }

  Future<void> _listenToClient(String clientId, WebSocket socket) {
    const maxPendingBytes = 32 * 1024 * 1024;
    // Zero-byte frames carry no byte cost, so the byte cap alone cannot bound a
    // peer that floods empty frames. The sender emits 2 MiB chunks inside a
    // 16 MiB window, so 16 pending frames comfortably covers a healthy transfer
    // (and still 32 MiB of bytes). Keep this in sync with chunkSize/windowBytes
    // in _sendFileChunks.
    const maxPendingFrames = 16;
    var pendingBytes = 0;
    var pendingFrames = 0;
    var pending = Future<void>.value();
    final closed = Completer<void>();
    void finish() {
      _removeClient(clientId);
      if (!closed.isCompleted) closed.complete();
    }

    socket.listen(
      (dynamic data) {
        if (!identical(_clients[clientId], socket)) return;
        final bytes = data is String
            ? data.length * 2
            : (data as List<int>).length;
        if (bytes > maxPendingBytes - pendingBytes ||
            pendingFrames >= maxPendingFrames) {
          finish();
          unawaited(
            socket.close(WebSocketStatus.policyViolation, 'Receive queue full'),
          );
          return;
        }
        pendingBytes += bytes;
        pendingFrames++;
        // Keep reading transport events while serializing disk/protocol operations.
        pending = pending.then((_) async {
          try {
            if (identical(_clients[clientId], socket)) {
              await _handleIncomingData(clientId, data);
            }
          } finally {
            pendingBytes -= bytes;
            pendingFrames--;
          }
        });
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    return closed.future;
  }

  @override
  Future<void> disconnect(String clientId) async {
    final client = _clients[clientId];
    if (client == null) return;
    _removeClient(clientId);
    await client.close();
  }

  @override
  Future<void> stopServer() async {
    for (final client in List<WebSocket>.of(_clients.values)) {
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
