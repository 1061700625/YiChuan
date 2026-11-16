import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';
import 'package:local_mesh_transfer/core/storage/device_repository.dart';

void main() {
  group('DeviceRepository', () {
    test('stores and retrieves a trusted device', () async {
      final repo = DeviceRepository();
      const device = TrustedDevice(
        id: 'desktop-1',
        name: 'Mac Studio',
        platform: DevicePlatform.macos,
      );
      await repo.save(device);
      expect((await repo.findById(device.id))?.name, 'Mac Studio');
      await repo.delete(device.id);
      expect(await repo.findById(device.id), isNull);
    });

    test('concurrent changes persist the latest complete snapshot', () async {
      final dir = await Directory.systemTemp.createTemp('yichuan-concurrent-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');
      final repo = DeviceRepository();
      await repo.initialize(file);
      await repo.getOrCreateLocalDeviceId();
      await Future.wait(
        List.generate(
          40,
          (i) => repo.save(
            TrustedDevice(
              id: '$i',
              name: 'Device $i',
              platform: DevicePlatform.android,
            ),
          ),
        ),
      );
      final restored = DeviceRepository();
      await restored.initialize(file);
      expect(await restored.findAll(), hasLength(40));
    });

    test('failed temporary write leaves previous credentials intact', () async {
      final dir = await Directory.systemTemp.createTemp('yichuan-atomic-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');
      final repo = DeviceRepository();
      await repo.initialize(file);
      await repo.getOrCreateLocalDeviceId();
      final previous = await file.readAsString();
      await Directory('${file.path}.tmp').create();
      await expectLater(
        repo.save(
          const TrustedDevice(
            id: 'new',
            name: 'New',
            platform: DevicePlatform.android,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), previous);
      expect(await repo.findById('new'), isNull);
      await Directory('${file.path}.tmp').delete();
      await repo.save(
        const TrustedDevice(
          id: 'next',
          name: 'Next',
          platform: DevicePlatform.android,
        ),
      );
      final restored = DeviceRepository();
      await restored.initialize(file);
      expect(await restored.findById('next'), isNotNull);
    });

    test('persists the local ID and trusted devices', () async {
      final directory = await Directory.systemTemp.createTemp('yichuan_repo_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/state.json');
      final first = DeviceRepository();
      await first.initialize(file);
      final localId = await first.getOrCreateLocalDeviceId();
      await first.save(
        const TrustedDevice(
          id: 'phone-1',
          name: 'Pixel',
          platform: DevicePlatform.android,
        ),
      );

      final second = DeviceRepository();
      await second.initialize(file);

      expect(await second.getOrCreateLocalDeviceId(), localId);
      expect((await second.findById('phone-1'))?.name, 'Pixel');
      expect(jsonDecode(await file.readAsString()), isA<Map>());
    });
  });
}
