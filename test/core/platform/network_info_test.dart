import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/platform/network_info.dart';

void main() {
  group('lanInterfaceScore', () {
    test('ranks the WiFi/Ethernet radio above the cellular pipe', () {
      expect(
        NetworkInfo.lanInterfaceScore('wlan0', '10.168.1.159'),
        greaterThan(
          NetworkInfo.lanInterfaceScore('vgate0', '172.30.206.215'),
        ),
        reason: 'A phone that is on both WiFi and mobile data must pick the LAN.',
      );
    });

    test('scores the real device layout correctly', () {
      final scores = <String, int>{
        'wlan0': NetworkInfo.lanInterfaceScore(
          'wlan0',
          '10.168.1.159',
        ),
        'en0': NetworkInfo.lanInterfaceScore('en0', '10.168.1.120'),
        'vgate0': NetworkInfo.lanInterfaceScore(
          'vgate0',
          '172.30.206.215',
        ),
        'rmnet_data2': NetworkInfo.lanInterfaceScore(
          'rmnet_data2',
          '10.253.17.213',
        ),
      };
      expect(
        scores['wlan0'],
        greaterThan(scores['vgate0']!),
      );
      expect(scores['en0'], greaterThan(scores['rmnet_data2']!));
      expect(
        scores['rmnet_data2'],
        lessThan(scores['en0']!),
        reason:
            'A cellular point-to-point link must lose to a LAN radio even '
            'when its address is inside a private range.',
      );
    });

    test('treats mobile-data prefixes as non-LAN', () {
      for (final name in ['vgate0', 'rmnet_data0', 'ccp2_0', 'pdp_ip0', 'ccmni0']) {
        expect(
          NetworkInfo.lanInterfaceScore(name, '10.1.2.3'),
          0,
          reason: '$name is a cellular interface',
        );
      }
    });

    test('prefers a recognised LAN radio over a private-looking cellular address', () {
      final cellular = NetworkInfo.lanInterfaceScore(
        'rmnet_data2',
        '10.253.17.213',
      );
      final radio = NetworkInfo.lanInterfaceScore('wlan0', '10.168.1.159');
      expect(radio, greaterThan(cellular));
    });
  });

  group('isLanAddress', () {
    test('accepts the three RFC 1918 ranges', () {
      expect(NetworkInfo.isLanAddress('10.0.0.1'), isTrue);
      expect(NetworkInfo.isLanAddress('192.168.1.1'), isTrue);
      expect(NetworkInfo.isLanAddress('172.16.0.1'), isTrue);
      expect(NetworkInfo.isLanAddress('172.31.255.254'), isTrue);
    });

    test('rejects addresses outside the private ranges', () {
      expect(NetworkInfo.isLanAddress('172.15.0.1'), isFalse);
      expect(NetworkInfo.isLanAddress('172.32.0.1'), isFalse);
      expect(NetworkInfo.isLanAddress('169.254.1.1'), isFalse);
      expect(NetworkInfo.isLanAddress('8.8.8.8'), isFalse);
      expect(NetworkInfo.isLanAddress('127.0.0.1'), isFalse);
    });
  });
}
