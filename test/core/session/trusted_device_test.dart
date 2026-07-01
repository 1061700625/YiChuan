import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

void main() {
  group('TrustedDevice', () {
    test('allows automatic receive when device is trusted and policy is enabled', () {
      final device = TrustedDevice(
        id: 'desktop-1',
        name: 'Mac Studio',
        platform: DevicePlatform.macos,
        trustedAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 2),
        autoAcceptTransfers: true,
      );

      expect(device.canAutoAccept, isTrue);
    });

    test('does not allow automatic receive when policy is disabled', () {
      final device = TrustedDevice(
        id: 'desktop-1',
        name: 'Mac Studio',
        platform: DevicePlatform.macos,
        trustedAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 2),
        autoAcceptTransfers: false,
      );

      expect(device.canAutoAccept, isFalse);
    });

    test('serializes to local storage friendly json', () {
      final device = TrustedDevice(
        id: 'android-1',
        name: 'Pixel',
        platform: DevicePlatform.android,
        trustedAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 2),
        autoAcceptTransfers: true,
      );

      expect(device.toJson(), {
        'id': 'android-1',
        'name': 'Pixel',
        'platform': 'android',
        'trustedAt': '2026-01-01T00:00:00.000Z',
        'lastSeenAt': '2026-01-02T00:00:00.000Z',
        'autoAcceptTransfers': true,
      });
    });
  });
}
