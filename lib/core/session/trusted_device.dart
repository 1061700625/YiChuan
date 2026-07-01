enum DevicePlatform {
  android('android'),
  windows('windows'),
  macos('macos');

  const DevicePlatform(this.wireName);

  final String wireName;
}

class TrustedDevice {
  const TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.trustedAt,
    required this.lastSeenAt,
    required this.autoAcceptTransfers,
  });

  final String id;
  final String name;
  final DevicePlatform platform;
  final DateTime trustedAt;
  final DateTime lastSeenAt;
  final bool autoAcceptTransfers;

  bool get canAutoAccept => autoAcceptTransfers;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'platform': platform.wireName,
      'trustedAt': trustedAt.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
      'autoAcceptTransfers': autoAcceptTransfers,
    };
  }
}
