import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/session/session_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';

void main() {
  test(
    'trusted connection requires proof and consumes challenge once',
    () async {
      final repo = DeviceRepository();
      final service = SessionService(deviceRepo: repo);
      const secret =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      await repo.save(
        const TrustedDevice(
          id: 'phone',
          name: 'Phone',
          platform: DevicePlatform.android,
          trustSecret: secret,
        ),
      );
      final challenge = service.createTrustChallenge('socket');
      final proof = SessionService.trustProof(secret, challenge, 'phone');
      final result = await service.handleTrustedPairRequest(
        clientId: 'socket',
        deviceId: 'phone',
        proof: proof,
      );
      expect(result.success, isTrue);
      expect(service.authorizes('socket', result.sessionId), isTrue);
      service.disconnect();
      expect(
        (await service.handleTrustedPairRequest(
          clientId: 'socket',
          deviceId: 'phone',
          proof: proof,
        )).success,
        isFalse,
      );
    },
  );

  test(
    'wrong proof consumes challenge and cannot authenticate another socket',
    () async {
      final repo = DeviceRepository();
      final service = SessionService(deviceRepo: repo);
      final secret = service.newTrustSecret();
      await repo.save(
        TrustedDevice(
          id: 'peer',
          name: 'Peer',
          platform: DevicePlatform.macos,
          trustSecret: secret,
        ),
      );
      final challenge = service.createTrustChallenge('socket');
      final proof = SessionService.trustProof(secret, challenge, 'peer');
      expect(
        (await service.handleTrustedPairRequest(
          clientId: 'other',
          deviceId: 'peer',
          proof: proof,
        )).success,
        isFalse,
      );
      expect(
        (await service.handleTrustedPairRequest(
          clientId: 'socket',
          deviceId: 'peer',
          proof: 'incorrect',
        )).success,
        isFalse,
      );
      expect(
        (await service.handleTrustedPairRequest(
          clientId: 'socket',
          deviceId: 'peer',
          proof: proof,
        )).success,
        isFalse,
      );
    },
  );

  test('trust is saved only for the currently authorized session', () async {
    final repo = DeviceRepository();
    final service = SessionService(deviceRepo: repo);
    final code = service.generatePairingCode();
    final result = await service.handlePairRequest(
      clientId: 'socket',
      deviceId: 'peer',
      deviceName: 'Peer',
      platform: DevicePlatform.macos,
      pairingCode: code,
    );
    final secret = service.newTrustSecret();
    await expectLater(
      service.trustPeer('other', result.sessionId!, secret),
      throwsStateError,
    );
    expect(await repo.findById('peer'), isNull);
    await service.trustPeer('socket', result.sessionId!, secret);
    final saved = await repo.findById('peer');
    expect(saved!.trustSecret, secret);
    expect(TrustedDevice.fromJson(saved.toJson()).canReconnect, isTrue);
  });

  test('legacy device and wrong proof cannot bypass pairing code', () async {
    final repo = DeviceRepository();
    final service = SessionService(deviceRepo: repo);
    await repo.save(
      const TrustedDevice(
        id: 'legacy',
        name: 'Old',
        platform: DevicePlatform.macos,
      ),
    );
    service.createTrustChallenge('socket');
    expect(
      (await service.handleTrustedPairRequest(
        clientId: 'socket',
        deviceId: 'legacy',
        proof: 'fake',
      )).success,
      isFalse,
    );
    expect(service.state, SessionState.waiting);
  });

  test(
    'removing trust prevents a previously valid proof from connecting',
    () async {
      final repo = DeviceRepository();
      final service = SessionService(deviceRepo: repo);
      const secret =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      await repo.save(
        const TrustedDevice(
          id: 'peer',
          name: 'Peer',
          platform: DevicePlatform.macos,
          trustSecret: secret,
        ),
      );
      final challenge = service.createTrustChallenge('socket');
      final proof = SessionService.trustProof(secret, challenge, 'peer');
      await repo.delete('peer');
      expect(
        (await service.handleTrustedPairRequest(
          clientId: 'socket',
          deviceId: 'peer',
          proof: proof,
        )).success,
        isFalse,
      );
    },
  );
}
