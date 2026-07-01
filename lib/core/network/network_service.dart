import '../protocol/protocol_message.dart';

enum NetworkConnectionState { disconnected, listening, connected }

abstract class NetworkService {
  NetworkConnectionState get connectionState;
  int? get listeningPort;
  List<String> get connectedClients;
  void Function(ProtocolMessage message)? get onMessageReceived;
  set onMessageReceived(void Function(ProtocolMessage message)? callback);
  void Function(String clientId)? get onClientDisconnected;
  set onClientDisconnected(void Function(String clientId)? callback);
  bool get isInitiator;

  Future<int> startServer({required int port});
  Future<String?> connect({required String host, required int port});
  Future<bool> send(String clientId, ProtocolMessage message);
  Future<void> disconnect(String clientId);
  Future<void> stopServer();
}

class InMemoryNetworkService implements NetworkService {
  NetworkConnectionState _state = NetworkConnectionState.disconnected;
  int? _listeningPort;
  void Function(ProtocolMessage message)? _onMessageReceived;
  void Function(String clientId)? _onClientDisconnected;
  final _clients = <String, _ClientConnection>{};
  int _nextId = 1;
  final _messageLog = <ProtocolMessage>[];
  final _pendingIncoming = <String, List<ProtocolMessage>>{};

  @override
  NetworkConnectionState get connectionState => _state;

  @override
  int? get listeningPort => _listeningPort;

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

  bool _isInitiator = false;

  @override
  bool get isInitiator => _isInitiator;

  List<ProtocolMessage> get messageLog => List.unmodifiable(_messageLog);

  @override
  List<String> get connectedClients => _clients.keys.toList(growable: false);

  @override
  Future<int> startServer({required int port}) async {
    _listeningPort = port;
    _state = NetworkConnectionState.listening;
    return port;
  }

  @override
  Future<String?> connect({required String host, required int port}) async {
    final id = 'client_${_nextId++}';
    _clients[id] = _ClientConnection(host: host, port: port);
    _state = NetworkConnectionState.connected;
    _isInitiator = true;
    return id;
  }

  @override
  Future<bool> send(String clientId, ProtocolMessage message) async {
    if (!_clients.containsKey(clientId) && _state != NetworkConnectionState.connected) {
      return false;
    }
    _messageLog.add(message);
    return true;
  }

  Future<String> injectClientConnection({
    required String deviceId,
    required String deviceName,
    required String host,
  }) async {
    final id = 'client_${_nextId++}';
    _clients[id] = _ClientConnection(host: host, port: 0, deviceId: deviceId, deviceName: deviceName);
    _state = NetworkConnectionState.connected;
    return id;
  }

  Future<void> injectMessageFrom(String clientId, ProtocolMessage message) async {
    _messageLog.add(message);
    _onMessageReceived?.call(message);
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

class _ClientConnection {
  const _ClientConnection({
    required this.host,
    required this.port,
    this.deviceId,
    this.deviceName,
  });

  final String host;
  final int port;
  final String? deviceId;
  final String? deviceName;
}
