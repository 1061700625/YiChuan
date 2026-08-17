import 'dart:io';

enum DevicePlatform {
  android('android'),
  windows('windows'),
  macos('macos');

  const DevicePlatform(this.wireName);

  final String wireName;

  static DevicePlatform get current {
    if (Platform.isAndroid) return DevicePlatform.android;
    if (Platform.isWindows) return DevicePlatform.windows;
    return DevicePlatform.macos;
  }

  static DevicePlatform fromWireName(Object? value) {
    return DevicePlatform.values.firstWhere(
      (platform) => platform.wireName == value,
      orElse: () => DevicePlatform.macos,
    );
  }
}

class TrustedDevice {
  const TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
  });

  final String id;
  final String name;
  final DevicePlatform platform;
  Map<String, Object?> toJson() {
    return {'id': id, 'name': name, 'platform': platform.wireName};
  }

  factory TrustedDevice.fromJson(Map<String, Object?> json) {
    return TrustedDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      platform: DevicePlatform.fromWireName(json['platform']),
    );
  }
}
