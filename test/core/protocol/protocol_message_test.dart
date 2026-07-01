import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';

void main() {
  group('ProtocolMessage', () {
    test('serializes hello message with common envelope fields', () {
      final message = ProtocolMessage.hello(
        messageId: 'msg-1',
        timestamp: DateTime.utc(2026, 1, 1),
        deviceId: 'desktop-1',
        deviceName: 'Mac Studio',
        platform: 'macos',
        port: 45678,
      );

      expect(message.toJson(), {
        'type': 'hello',
        'version': 1,
        'messageId': 'msg-1',
        'sessionId': null,
        'timestamp': '2026-01-01T00:00:00.000Z',
        'payload': {
          'deviceId': 'desktop-1',
          'deviceName': 'Mac Studio',
          'platform': 'macos',
          'port': 45678,
        },
      });
    });

    test('parses pair request and exposes payload values', () {
      final message = ProtocolMessage.fromJson({
        'type': 'pair_request',
        'version': 1,
        'messageId': 'msg-2',
        'sessionId': null,
        'timestamp': '2026-01-01T00:00:00.000Z',
        'payload': {
          'deviceId': 'android-1',
          'pairingCode': '123456',
        },
      });

      expect(message.type, ProtocolMessageType.pairRequest);
      expect(message.payload['deviceId'], 'android-1');
      expect(message.payload['pairingCode'], '123456');
    });

    test('rejects unknown message type', () {
      expect(
        () => ProtocolMessage.fromJson({
          'type': 'unknown',
          'version': 1,
          'messageId': 'msg-3',
          'sessionId': null,
          'timestamp': '2026-01-01T00:00:00.000Z',
          'payload': <String, Object?>{},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
