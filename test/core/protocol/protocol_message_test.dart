import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';

void main() {
  group('ProtocolMessage', () {
    test('serializes the common envelope', () {
      final message = ProtocolMessage(
        type: ProtocolMessageType.hello,
        version: 1,
        messageId: 'msg-1',
        timestamp: DateTime.utc(2026),
        payload: {'deviceId': 'desktop-1'},
      );

      expect(message.toJson(), {
        'type': 'hello',
        'version': 1,
        'messageId': 'msg-1',
        'sessionId': null,
        'timestamp': '2026-01-01T00:00:00.000Z',
        'payload': {'deviceId': 'desktop-1'},
      });
    });

    test('parses a session-bound transfer message', () {
      final message = ProtocolMessage.fromJson({
        'type': 'transfer_offer',
        'version': 1,
        'messageId': 'msg-2',
        'sessionId': 'session-1',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'payload': {'taskId': 'task-1'},
      });

      expect(message.type, ProtocolMessageType.transferOffer);
      expect(message.sessionId, 'session-1');
    });

    test('rejects an unknown message type', () {
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

    test('parses a session-bound text message', () {
      final message = ProtocolMessage.fromJson({
        'type': 'text_message',
        'version': 1,
        'messageId': 'msg-text',
        'sessionId': 'session-1',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'payload': {'taskId': 'text-1', 'text': 'hello'},
      });

      expect(message.type, ProtocolMessageType.textMessage);
      expect(message.payload['text'], 'hello');
    });

    test('parses transfer resume negotiation messages', () {
      expect(
        ProtocolMessageType.fromWireName('transfer_resume_request'),
        ProtocolMessageType.transferResumeRequest,
      );
      expect(
        ProtocolMessageType.fromWireName('transfer_resume_result'),
        ProtocolMessageType.transferResumeResult,
      );
    });
  });
}
