import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

void main() {
  group('DeviceRepository', () {
    late DeviceRepository repo;

    setUp(() {
      repo = DeviceRepository();
    });

    test('stores and retrieves a trusted device by id', () async {
      final device = TrustedDevice(
        id: 'desktop-1',
        name: 'Mac Studio',
        platform: DevicePlatform.macos,
        trustedAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 2),
        autoAcceptTransfers: true,
      );

      await repo.save(device);
      final found = await repo.findById('desktop-1');

      expect(found, isNotNull);
      expect(found!.name, 'Mac Studio');
      expect(found.canAutoAccept, isTrue);
    });

    test('returns null for unknown device id', () async {
      final found = await repo.findById('unknown');
      expect(found, isNull);
    });

    test('lists all trusted devices', () async {
      await repo.save(TrustedDevice(
        id: 'd1', name: 'Mac', platform: DevicePlatform.macos,
        trustedAt: DateTime.utc(2026, 1, 1), lastSeenAt: DateTime.utc(2026, 1, 2),
        autoAcceptTransfers: true,
      ));
      await repo.save(TrustedDevice(
        id: 'd2', name: 'PC', platform: DevicePlatform.windows,
        trustedAt: DateTime.utc(2026, 1, 2), lastSeenAt: DateTime.utc(2026, 1, 3),
        autoAcceptTransfers: false,
      ));

      final all = await repo.findAll();
      expect(all, hasLength(2));
    });

    test('deletes a trusted device by id', () async {
      await repo.save(TrustedDevice(
        id: 'd1', name: 'Mac', platform: DevicePlatform.macos,
        trustedAt: DateTime.utc(2026, 1, 1), lastSeenAt: DateTime.utc(2026, 1, 2),
        autoAcceptTransfers: true,
      ));

      await repo.delete('d1');
      final found = await repo.findById('d1');
      expect(found, isNull);
    });
  });
}
