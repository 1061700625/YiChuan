import 'dart:async';
import 'dart:typed_data';

import '../protocol/protocol_message.dart';

enum NetworkConnectionState { disconnected, listening, connected }

typedef MessageReceivedCallback =
    FutureOr<void> Function(String clientId, ProtocolMessage message);
typedef BinaryReceivedCallback =
    FutureOr<void> Function(String clientId, Uint8List data);

abstract class NetworkService {
  NetworkConnectionState get connectionState;
  int? get listeningPort;
  List<String> get connectedClients;
  MessageReceivedCallback? get onMessageReceived;
  set onMessageReceived(MessageReceivedCallback? callback);
  BinaryReceivedCallback? get onBinaryReceived;
  set onBinaryReceived(BinaryReceivedCallback? callback);
  void Function(String clientId)? get onClientConnected;
  set onClientConnected(void Function(String clientId)? callback);
  void Function(String clientId)? get onClientDisconnected;
  set onClientDisconnected(void Function(String clientId)? callback);
  bool get isInitiator;

  Future<int> startServer({required int port});
  Future<String?> connect({required String host, required int port});
  Future<bool> send(String clientId, ProtocolMessage message);
  Future<bool> sendBinary(String clientId, Uint8List data);
  Future<void> disconnect(String clientId);
  Future<void> stopServer();
}

class InMemoryNetworkService implements NetworkService {
  NetworkConnectionState _state = NetworkConnectionState.disconnected;
  int? _listeningPort;
  MessageReceivedCallback? _onMessageReceived;
  BinaryReceivedCallback? _onBinaryReceived;
  void Function(String clientId)? _onClientConnected;
  void Function(String clientId)? _onClientDisconnected;
  final _clients = <String>{};
  int _nextId = 1;
  final _messageLog = <ProtocolMessage>[];
  final _binaryMessageLog = <Uint8List>[];

  @override
  NetworkConnectionState get connectionState => _state;

  @override
  int? get listeningPort => _listeningPort;

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
  void Function(String clientId)? get onClientConnected => _onClientConnected;

  @override
  set onClientConnected(void Function(String clientId)? callback) {
    _onClientConnected = callback;
  }

  @override
  void Function(String clientId)? get onClientDisconnected =>
      _onClientDisconnected;

  @override
  set onClientDisconnected(void Function(String clientId)? callback) {
    _onClientDisconnected = callback;
  }

  bool _isInitiator = false;

  @override
  bool get isInitiator => _isInitiator;

  List<ProtocolMessage> get messageLog => List.unmodifiable(_messageLog);
  List<Uint8List> get binaryMessageLog => List.unmodifiable(_binaryMessageLog);

  @override
  List<String> get connectedClients => _clients.toList(growable: false);

  @override
  Future<int> startServer({required int port}) async {
    _listeningPort = port;
    _state = NetworkConnectionState.listening;
    return port;
  }

  @override
  Future<String?> connect({required String host, required int port}) async {
    final id = 'client_${_nextId++}';
    _clients.add(id);
    _state = NetworkConnectionState.connected;
    _isInitiator = true;
    return id;
  }

  @override
  Future<bool> send(String clientId, ProtocolMessage message) async {
    if (!_clients.contains(clientId)) return false;
    _messageLog.add(message);
    return true;
  }

  @override
  Future<bool> sendBinary(String clientId, Uint8List data) async {
    if (!_clients.contains(clientId)) return false;
    _binaryMessageLog.add(Uint8List.fromList(data));
    return true;
  }

  Future<String> injectClientConnection({
    required String deviceId,
    required String deviceName,
    required String host,
  }) async {
    final id = 'client_${_nextId++}';
    _clients.add(id);
    _state = NetworkConnectionState.connected;
    _onClientConnected?.call(id);
    return id;
  }

  Future<void> injectMessageFrom(
    String clientId,
    ProtocolMessage message,
  ) async {
    _messageLog.add(message);
    await _onMessageReceived?.call(clientId, message);
  }

  Future<void> injectBinaryFrom(String clientId, Uint8List data) async {
    _binaryMessageLog.add(Uint8List.fromList(data));
    await _onBinaryReceived?.call(clientId, data);
  }

  @override
  Future<void> disconnect(String clientId) async {
    _clients.remove(clientId);
    _onClientDisconnected?.call(clientId);
    if (_clients.isEmpty) {
      _state = NetworkConnectionState.disconnected;
      _isInitiator = false;
    }
  }

  @override
  Future<void> stopServer() async {
    _clients.clear();
    _listeningPort = null;
    _state = NetworkConnectionState.disconnected;
    _isInitiator = false;
  }
}
