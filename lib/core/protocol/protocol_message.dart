enum ProtocolMessageType {
  hello('hello'),
  pairRequest('pair_request'),
  pairResult('pair_result'),
  transferOffer('transfer_offer'),
  transferResumeRequest('transfer_resume_request'),
  transferResumeResult('transfer_resume_result'),
  textMessage('text_message'),
  progress('progress'),
  transferDone('transfer_done');

  const ProtocolMessageType(this.wireName);

  final String wireName;

  static ProtocolMessageType fromWireName(String value) {
    for (final type in values) {
      if (type.wireName == value) {
        return type;
      }
    }
    throw FormatException('Unknown protocol message type.', value);
  }
}

class ProtocolMessage {
  const ProtocolMessage({
    required this.type,
    required this.version,
    required this.messageId,
    required this.timestamp,
    required this.payload,
    this.sessionId,
  });

  factory ProtocolMessage.fromJson(Map<String, Object?> json) {
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException(
        'Protocol message payload must be an object.',
      );
    }

    return ProtocolMessage(
      type: ProtocolMessageType.fromWireName(json['type'] as String),
      version: json['version'] as int,
      messageId: json['messageId'] as String,
      sessionId: json['sessionId'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      payload: Map<String, Object?>.from(payload),
    );
  }

  final ProtocolMessageType type;
  final int version;
  final String messageId;
  final String? sessionId;
  final DateTime timestamp;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() {
    return {
      'type': type.wireName,
      'version': version,
      'messageId': messageId,
      'sessionId': sessionId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'payload': payload,
    };
  }
}
