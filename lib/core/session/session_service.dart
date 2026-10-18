import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'trusted_device.dart';
import '../storage/device_repository.dart';

enum SessionState { waiting, paired, disconnected }

class PairResult {
  const PairResult({required this.success, this.sessionId, this.error});
  final bool success;
  final String? sessionId;
  final String? error;
}

class SessionService {
  SessionService({required DeviceRepository deviceRepo})
    : _deviceRepo = deviceRepo,
      _rng = Random.secure() {
    _deviceRepo.addListener(_onTrustChanged);
  }

  final DeviceRepository _deviceRepo;
  final Random _rng;
  final _listeners = <void Function()>{};
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _onTrustChanged() => unawaited(_refreshPeerTrust());

  Future<void> _refreshPeerTrust() async {
    final peer = _peer;
    final session = _currentSessionId;
    if (peer == null) return;
    final saved = await _deviceRepo.findById(peer.id);
    if (_peer?.id != peer.id || _currentSessionId != session) return;
    _peer = TrustedDevice(
      id: peer.id,
      name: peer.name,
      platform: peer.platform,
      trustSecret: saved?.trustSecret,
    );
    _notify();
  }

  void dispose() {
    _deviceRepo.removeListener(_onTrustChanged);
    _listeners.clear();
  }

  bool _pairing = false;
  TrustedDevice? _peer;
  final _challenges = <String, ({String nonce, DateTime created})>{};
  TrustedDevice? get peer => _peer;
  bool get isPeerTrusted =>
      _state == SessionState.paired && _peer?.canReconnect == true;

  Future<TrustedDevice?> trustedDevice(String id) => _deviceRepo.findById(id);

  String newTrustSecret() => List.generate(
    32,
    (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static String trustProof(String secret, String challenge, String deviceId) =>
      Hmac(sha256, utf8.encode(secret))
          .convert(
            utf8.encode(jsonEncode(['yichuan-trust-v1', challenge, deviceId])),
          )
          .toString();

  String createTrustChallenge(String clientId) {
    final nonce = newTrustSecret();
    _challenges[clientId] = (nonce: nonce, created: DateTime.now());
    return nonce;
  }

  Future<PairResult> handleTrustedPairRequest({
    required String clientId,
    required String deviceId,
    required String proof,
  }) async {
    if (_pairing || _state == SessionState.paired) {
      return const PairResult(success: false, error: '设备正在配对或已连接。');
    }
    _pairing = true;
    try {
      final challenge = _challenges.remove(clientId);
      final device = await _deviceRepo.findById(deviceId);
      if (challenge == null ||
          DateTime.now().difference(challenge.created) >=
              const Duration(seconds: 30) ||
          device == null ||
          !device.canReconnect ||
          trustProof(device.trustSecret!, challenge.nonce, deviceId) != proof) {
        return const PairResult(success: false, error: '信任验证失败，请重新使用配对码连接。');
      }
      _peer = device;
      _pairedClientId = clientId;
      _currentSessionId = _generateSessionId();
      _state = SessionState.paired;
      forceExpire();
      _notify();
      return PairResult(success: true, sessionId: _currentSessionId);
    } finally {
      _pairing = false;
    }
  }

  Future<void> trustPeer(
    String clientId,
    String sessionId,
    String secret,
  ) async {
    if (!authorizes(clientId, sessionId) ||
        _peer == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      throw StateError('信任申请已失效');
    }
    final device = TrustedDevice(
      id: _peer!.id,
      name: _peer!.name,
      platform: _peer!.platform,
      trustSecret: secret,
    );
    await _deviceRepo.save(device);
    if (authorizes(clientId, sessionId)) {
      _peer = device;
      _notify();
    }
  }

  String? _currentCode;
  DateTime? _codeCreatedAt;
  String? _currentSessionId;
  String? _pairedClientId;
  SessionState _state = SessionState.waiting;

  static const _ttl = Duration(minutes: 5);
  static const _validCodeRegex = r'^\d{6}$';

  SessionState get state => _state;
  String? get currentSessionId => _currentSessionId;
  String? get pairedClientId => _pairedClientId;

  String generatePairingCode() {
    if (_currentCode != null && !_isCodeExpired()) {
      // Return existing valid code
      return _currentCode!;
    }
    _currentCode = _rng.nextInt(900000).toString().padLeft(6, '0');
    _codeCreatedAt = DateTime.now();
    return _currentCode!;
  }

  Future<PairResult> handlePairRequest({
    required String clientId,
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required String pairingCode,
  }) async {
    if (_pairing || _state == SessionState.paired) {
      return const PairResult(success: false, error: '设备正在配对或已连接。');
    }
    if (_currentCode == null || _isCodeExpired()) {
      return const PairResult(success: false, error: '配对码已过期，请刷新后重试。');
    }

    if (!RegExp(_validCodeRegex).hasMatch(pairingCode)) {
      return const PairResult(success: false, error: '配对码格式错误。');
    }

    if (pairingCode != _currentCode) {
      return const PairResult(success: false, error: '配对码不匹配。');
    }

    // Consume the code before persistence yields to another request.
    _pairing = true;
    forceExpire();
    final sessionId = _generateSessionId();
    try {
      _peer = TrustedDevice(id: deviceId, name: deviceName, platform: platform);
      _currentSessionId = sessionId;
      _pairedClientId = clientId;
      _state = SessionState.paired;
      await _refreshPeerTrust();
      _notify();
      return PairResult(success: true, sessionId: sessionId);
    } finally {
      _pairing = false;
    }
  }

  Future<void> acceptPairResult({
    required String clientId,
    required String sessionId,
    required String peerDeviceId,
    required String peerDeviceName,
    required DevicePlatform peerPlatform,
  }) async {
    if (sessionId.isEmpty) {
      throw const FormatException('Pair result has no session ID.');
    }
    _pairedClientId = clientId;
    _currentSessionId = sessionId;
    _state = SessionState.paired;
    _peer = TrustedDevice(
      id: peerDeviceId,
      name: peerDeviceName,
      platform: peerPlatform,
    );
    await _refreshPeerTrust();
    _notify();
  }

  bool authorizes(String clientId, String? sessionId) {
    return _state == SessionState.paired &&
        clientId == _pairedClientId &&
        sessionId != null &&
        sessionId == _currentSessionId;
  }

  void disconnectClient(String clientId) {
    _challenges.remove(clientId);
    if (clientId == _pairedClientId) disconnect();
  }

  void disconnect() {
    _peer = null;
    _state = SessionState.disconnected;
    _currentSessionId = null;
    _pairedClientId = null;
    _notify();
  }

  void forceExpire() {
    _currentCode = null;
    _codeCreatedAt = null;
  }

  bool _isCodeExpired() {
    if (_codeCreatedAt == null) return true;
    return DateTime.now().difference(_codeCreatedAt!) >= _ttl;
  }

  String _generateSessionId() {
    final random = _rng.nextInt(1 << 30);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'sess_${timestamp}_$random';
  }
}
