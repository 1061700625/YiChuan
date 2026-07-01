import 'dart:math';

import 'trusted_device.dart';
import '../storage/device_repository.dart';

enum SessionState { waiting, paired, disconnected }

class PairResult {
  const PairResult({
    required this.success,
    this.sessionId,
    this.error,
  });
  final bool success;
  final String? sessionId;
  final String? error;
}

class SessionService {
  SessionService({required DeviceRepository deviceRepo})
      : _deviceRepo = deviceRepo,
        _rng = Random.secure();

  final DeviceRepository _deviceRepo;
  final Random _rng;
  String? _currentCode;
  DateTime? _codeCreatedAt;
  String? _currentSessionId;
  SessionState _state = SessionState.waiting;

  static const _ttl = Duration(minutes: 5);
  static const _validCodeRegex = r'^\d{6}$';

  SessionState get state => _state;

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
    required String deviceId,
    required String deviceName,
    required DevicePlatform platform,
    required String pairingCode,
  }) async {
    if (_currentCode == null || _isCodeExpired()) {
      return const PairResult(
        success: false,
        error: '配对码已过期，请刷新后重试。',
      );
    }

    if (!RegExp(_validCodeRegex).hasMatch(pairingCode)) {
      return const PairResult(
        success: false,
        error: '配对码格式错误。',
      );
    }

    if (pairingCode != _currentCode) {
      return const PairResult(
        success: false,
        error: '配对码不匹配。',
      );
    }

    _currentSessionId = _generateSessionId();
    _state = SessionState.paired;

    await _deviceRepo.save(TrustedDevice(
      id: deviceId,
      name: deviceName,
      platform: platform,
      trustedAt: DateTime.now(),
      lastSeenAt: DateTime.now(),
      autoAcceptTransfers: true,
    ));

    return PairResult(success: true, sessionId: _currentSessionId);
  }

  void disconnect() {
    _state = SessionState.disconnected;
    _currentSessionId = null;
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
