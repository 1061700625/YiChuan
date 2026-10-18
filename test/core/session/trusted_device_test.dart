import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

void main() {
  test('round-trips a trusted device through JSON', () {
    const device = TrustedDevice(
      id: 'android-1',
      name: 'Pixel',
      platform: DevicePlatform.android,
    );

    expect(TrustedDevice.fromJson(device.toJson()).toJson(), device.toJson());
  });

  test('parses platform wire names in one place', () {
    expect(DevicePlatform.fromWireName('android'), DevicePlatform.android);
    expect(DevicePlatform.fromWireName('windows'), DevicePlatform.windows);
    expect(DevicePlatform.fromWireName('macos'), DevicePlatform.macos);
    expect(DevicePlatform.fromWireName('unknown'), DevicePlatform.macos);
  });
}
