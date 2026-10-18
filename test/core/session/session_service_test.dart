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

    test(
      'accepts pair request with correct code and creates session',
      () async {
        final code = service.generatePairingCode();

        final result = await service.handlePairRequest(
          clientId: 'client-1',
          deviceId: 'android-1',
          deviceName: 'Pixel',
          platform: DevicePlatform.android,
          pairingCode: code,
        );

        expect(result.success, isTrue);
        expect(result.sessionId, isNotNull);
        expect(result.sessionId!.length, greaterThan(0));
      },
    );

    test('only one concurrent request can consume a pairing code', () async {
      final code = service.generatePairingCode();
      Future<PairResult> pair(String client) => service.handlePairRequest(
        clientId: client,
        deviceId: client,
        deviceName: client,
        platform: DevicePlatform.android,
        pairingCode: code,
      );
      final results = await Future.wait([pair('first'), pair('second')]);
      expect(results.where((result) => result.success), hasLength(1));
      expect(service.authorizes('first', results.first.sessionId), isTrue);
      expect(service.authorizes('second', results.first.sessionId), isFalse);
    });

    test('rejects pair request with wrong code', () async {
      service.generatePairingCode();

      final result = await service.handlePairRequest(
        clientId: 'client-1',
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: '000000',
      );

      expect(result.success, isFalse);
      expect(result.sessionId, isNull);
      expect(result.error, isNotNull);
    });

    test('ordinary pairing does not automatically grant trust', () async {
      final code = service.generatePairingCode();

      await service.handlePairRequest(
        clientId: 'client-1',
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      final saved = await repo.findById('android-1');
      expect(saved, isNull);
      expect(service.peer!.name, 'Pixel');
      expect(service.authorizes('client-1', service.currentSessionId), isTrue);
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
        clientId: 'client-1',
        deviceId: 'android-1',
        deviceName: 'Pixel',
        platform: DevicePlatform.android,
        pairingCode: code,
      );

      expect(service.state, SessionState.paired);

      service.disconnect();
      expect(service.state, SessionState.disconnected);
    });

    test('initiator binds the pair result to one client and session', () async {
      await service.acceptPairResult(
        clientId: 'client-1',
        sessionId: 'session-1',
        peerDeviceId: 'desktop-1',
        peerDeviceName: 'Mac',
        peerPlatform: DevicePlatform.macos,
      );

      expect(service.state, SessionState.paired);
      expect(service.authorizes('client-1', 'session-1'), isTrue);
      expect(service.authorizes('client-2', 'session-1'), isFalse);
      expect(service.authorizes('client-1', 'session-2'), isFalse);
      expect(await repo.findById('desktop-1'), isNull);
    });
  });
}
