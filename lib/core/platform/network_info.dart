import 'dart:io';

/// Utility to retrieve the device's local network information.
class NetworkInfo {
  /// Get a user-friendly device name for LAN discovery.
  ///
  /// Some Android builds expose [Platform.localHostname] as "localhost", which
  /// is technically true but useless in a nearby-device list. Prefer the OS
  /// host name only when it is meaningful, then fall back to platform labels.
  static String getDeviceName() {
    try {
      final hostName = Platform.localHostname.trim();
      if (hostName.isNotEmpty && hostName.toLowerCase() != 'localhost') {
        return hostName;
      }
    } catch (_) {
      // Fall through to platform defaults.
    }

    if (Platform.isAndroid) return 'Android 设备';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    return '本机设备';
  }

  /// Get the device's own local IP address on the WiFi/LAN interface.
  /// Returns null if unable to determine.
  static Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      );

      // Sort: prefer en0/en1 (WiFi/Ethernet) over other interfaces
      interfaces.sort((a, b) {
        final aScore = a.name.startsWith('en') ? 1 : 0;
        final bScore = b.name.startsWith('en') ? 1 : 0;
        return bScore.compareTo(aScore);
      });

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            final ip = addr.address;
            // Skip link-local and APIPA addresses
            if (ip.startsWith('169.254.')) continue;
            if (ip.startsWith('127.')) continue;
            return ip;
          }
        }
      }

      return null;
    } catch (_) {
      return null;
    }
  }
}
