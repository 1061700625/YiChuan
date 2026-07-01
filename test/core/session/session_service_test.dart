import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';

void main() {
  group('SessionService', () {
    late SessionService service;
    late DeviceRepository repo;

    setUp(() {
      repo = DeviceRepository();
      service = SessionService(deviceRepo: repo);
    });

    test('generates a 6 digit numeric pairing code', () {
      final code = service.generatePairingCode();

      expect(code.length, 6);
      expect(int.tryParse(code), isNotNull);
    });

    test('caches same code on successive calls until expired', () {
      final code1 = service.generatePairingCode();
      final code2 = service.generatePairingCode();

      expect(code1, code2);
    });

    test('accepts pair request with correct code and creates session', () async {
      final code = service.generatePairingCode();

      final result = await service.handlePairRequest(
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      expect(result.success, isTrue);
      expect(result.sessionId, isNotNull);
      expect(result.sessionId!.length, greaterThan(0));
    });

    test('rejects pair request with wrong code', () async {
      service.generatePairingCode();

      final result = await service.handlePairRequest(
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: '000000',
      );

      expect(result.success, isFalse);
      expect(result.sessionId, isNull);
      expect(result.error, isNotNull);
    });

    test('saves device as trusted on successful pairing', () async {
      final code = service.generatePairingCode();

      await service.handlePairRequest(
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      final saved = await repo.findById('android-1');
      expect(saved, isNotNull);
      expect(saved!.name, 'Pixel');
      expect(saved.canAutoAccept, isTrue);
    });

    test('creates new code after expiry', () {
      final initial = service.generatePairingCode();

      service.forceExpire();
      final newCode = service.generatePairingCode();

      expect(newCode, isNot(initial));
    });

    test('tracks connection state', () async {
      expect(service.state, SessionState.waiting);

      final code = service.generatePairingCode();
      await service.handlePairRequest(
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      expect(service.state, SessionState.paired);

      service.disconnect();
      expect(service.state, SessionState.disconnected);
    });
  });
}
