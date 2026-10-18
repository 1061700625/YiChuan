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
