import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/discovery/discovery_service.dart';
import 'package:local_mesh_transfer/core/session/trusted_device.dart';

void main() {
  group('DiscoveryService', () {
    late DiscoveryService service;
    final discoveredDevices = <DiscoveredServiceInfo>[];

    setUp(() {
      discoveredDevices.clear();
      service = DiscoveryService();
      service.addListener((device) => discoveredDevices.add(device));
    });

    test('starts and stops discovery', () {
      expect(service.isScanning, isFalse);

      service.startScanning();
      expect(service.isScanning, isTrue);

      service.stopScanning();
      expect(service.isScanning, isFalse);
    });

    test('injects discovered device and notifies listener', () {
      service.startScanning();
      service.injectDiscoveredDevice(
        deviceId: 'desktop-1',
        deviceName: 'Mac Studio',
        platform: DevicePlatform.macos,
        ip: '192.168.1.100',
        port: 45678,
      );

      expect(discoveredDevices, hasLength(1));
      expect(discoveredDevices.first.deviceId, 'desktop-1');
      expect(discoveredDevices.first.ip, '192.168.1.100');
    });

    test('does not notify listener when scanning is stopped', () {
      service.injectDiscoveredDevice(
        deviceId: 'desktop-1',
        deviceName: 'Mac Studio',
        platform: DevicePlatform.macos,
        ip: '192.168.1.100',
        port: 45678,
      );

      expect(discoveredDevices, isEmpty);
    });

    test('publishes and retrieves local service info', () {
      service.publishService(
        deviceId: 'my-desktop',
        deviceName: 'My Mac',
        platform: DevicePlatform.macos,
        port: 45678,
      );

      final published = service.publishedService;
      expect(published, isNotNull);
      expect(published!.deviceName, 'My Mac');
      expect(published.port, 45678);
    });

    test('returns list of recently discovered devices', () {
      service.startScanning();
      service.injectDiscoveredDevice(
        deviceId: 'd1', deviceName: 'M1', platform: DevicePlatform.macos,
        ip: '10.0.0.1', port: 45678,
      );
      service.injectDiscoveredDevice(
        deviceId: 'd2', deviceName: 'PC1', platform: DevicePlatform.windows,
        ip: '10.0.0.2', port: 45679,
      );

      final devices = service.recentDevices;
      expect(devices, hasLength(2));
    });

    test('deduplicates discovered devices by IP and keeps useful device name', () {
      service.startScanning();
      service.injectDiscoveredDevice(
        deviceId: 'scanned-10.0.0.5',
        deviceName: 'localhost',
        platform: DevicePlatform.macos,
        ip: '10.0.0.5',
        port: 45678,
      );
      service.injectDiscoveredDevice(
        deviceId: 'desktop-1',
        deviceName: 'Mac Studio',
        platform: DevicePlatform.macos,
        ip: '10.0.0.5',
        port: 45678,
      );

      final devices = service.recentDevices;
      expect(devices, hasLength(1));
      expect(devices.first.deviceId, 'desktop-1');
      expect(devices.first.deviceName, 'Mac Studio');
      expect(devices.first.ip, '10.0.0.5');
    });

    test('keeps existing useful name when later scan only has fallback name', () {
      service.startScanning();
      service.injectDiscoveredDevice(
        deviceId: 'desktop-1',
        deviceName: 'Mac Studio',
        platform: DevicePlatform.macos,
        ip: '10.0.0.5',
        port: 45678,
      );
      service.injectDiscoveredDevice(
        deviceId: 'scanned-10.0.0.5',
        deviceName: '未知设备 (10.0.0.5)',
        platform: DevicePlatform.macos,
        ip: '10.0.0.5',
        port: 45678,
      );

      final devices = service.recentDevices;
      expect(devices, hasLength(1));
      expect(devices.first.deviceId, 'desktop-1');
      expect(devices.first.deviceName, 'Mac Studio');
    });

    test('removes expired devices from recent list', () async {
      service = DiscoveryService(discoveryTtl: const Duration(milliseconds: 50));
      service.addListener((device) => discoveredDevices.add(device));
      service.startScanning();

      service.injectDiscoveredDevice(
        deviceId: 'd1', deviceName: 'Expired', platform: DevicePlatform.macos,
        ip: '10.0.0.1', port: 45678,
      );

      // Wait past TTL
      await Future.delayed(const Duration(milliseconds: 80));

      expect(service.recentDevices, isEmpty);
    });
  });
}
