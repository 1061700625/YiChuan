import 'dart:io';

/// Utility to retrieve the device's local network information.
class NetworkInfo {
  /// Rank one network interface as a source of LAN discovery traffic.
  ///
  /// A higher score wins. Interface names tell us what a network stack did with
  /// the link, which addresses cannot: `wlan0`/`en0` is a LAN radio while
  /// `vgate0`/`rmnet*` is the cellular pipe that a phone also carries at the
  /// same time. The address checks below only run once no interface matched by
  /// name, because a cellular carrier can hand out an address that looks like a
  /// private one (`10.253.17.213` on this device).
  static int lanInterfaceScore(String name, String ipv4) {
    final lower = name.toLowerCase();
    if (lower.startsWith('wlan') || lower.startsWith('wifi')) return 100;
    if (lower.startsWith('en') ||
        lower.startsWith('eth') ||
        lower.startsWith('docker')) {
      return 90;
    }
    // Tethered hotspot bridges stay reachable on the LAN.
    if (lower.startsWith('ap') ||
        lower.startsWith('br-') ||
        lower.startsWith('vmnet') ||
        lower.startsWith('host')) {
      return 60;
    }
    if (lower.contains('vgate') ||
        lower.contains('rmnet') ||
        lower.contains('ccp2') ||
        lower.startsWith('pdp_') ||
        lower.startsWith('ccmni')) {
      return 0;
    }
    if (isLanAddress(ipv4)) return 40;
    return 20;
  }

  /// RFC 1918 ranges are the only IPv4 space where a 255.255.255.255
  /// broadcast can reach another device on this machine's LAN.
  static bool isLanAddress(String ipv4) {
    if (ipv4.startsWith('10.') || ipv4.startsWith('192.168.')) return true;
    if (!ipv4.startsWith('172.')) return false;
    final second = int.tryParse(ipv4.substring(4).split('.').first);
    return second != null && second >= 16 && second <= 31;
  }

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

      // Every candidate, best interface first, so a cellular address that merely
      // looks LAN-like never shadows the real radio address.
      final candidates = <(int, String)>[];
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final ip = addr.address;
          if (ip.startsWith('169.254.')) continue; // link-local / APIPA
          if (ip.startsWith('127.')) continue;
          candidates.add((
            lanInterfaceScore(interface.name, ip),
            ip,
          ));
        }
      }
      candidates.sort((a, b) => b.$1.compareTo(a.$1));

      // Prefer an interface that is recognisably a LAN radio when the device
      // has one; only fall back to address heuristics otherwise.
      for (final (score, ip) in candidates) {
        if (score >= 60) return ip;
      }
      for (final (score, ip) in candidates) {
        if (score > 0) return ip;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
