import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';

ProtocolMessage _hello(String deviceId) => ProtocolMessage(
  type: ProtocolMessageType.hello,
  version: 1,
  messageId: 'hello-$deviceId',
  timestamp: DateTime.utc(2026),
  payload: {'deviceId': deviceId},
);

void main() {
  group('InMemoryNetworkService', () {
    late InMemoryNetworkService service;

    setUp(() => service = InMemoryNetworkService());

    test('opens server listener', () async {
      await service.startServer(port: 45678);
      expect(service.connectionState, NetworkConnectionState.listening);
      expect(service.listeningPort, 45678);
    });

    test('routes a message with its source client ID', () async {
      await service.startServer(port: 45678);
      final received = <(String, ProtocolMessage)>[];
      service.onMessageReceived = (clientId, message) =>
          received.add((clientId, message));
      final clientId = await service.injectClientConnection(
        deviceId: 'phone-1',
        deviceName: 'Pixel',
        host: '192.168.1.50',
      );

      await service.injectMessageFrom(clientId, _hello('phone-1'));

      expect(received.single.$1, clientId);
      expect(received.single.$2.payload['deviceId'], 'phone-1');
    });

    test('rejects sends to a different client ID', () async {
      await service.connect(host: '127.0.0.1', port: 45678);
      expect(await service.send('missing', _hello('desktop-1')), isFalse);
      expect(
        await service.sendBinary('missing', Uint8List.fromList([1])),
        isFalse,
      );
    });

    test('routes a binary frame with its source client ID', () async {
      final received = <(String, Uint8List)>[];
      service.onBinaryReceived = (clientId, data) =>
          received.add((clientId, data));
      final clientId = await service.injectClientConnection(
        deviceId: 'phone-1',
        deviceName: 'Pixel',
        host: '192.168.1.50',
      );
      final frame = Uint8List.fromList([1, 2, 3, 4]);

      await service.injectBinaryFrom(clientId, frame);

      expect(received.single.$1, clientId);
      expect(received.single.$2, orderedEquals(frame));
    });

    test('disconnects and cleans up state', () async {
      final clientId = await service.connect(host: '127.0.0.1', port: 45678);
      await service.disconnect(clientId!);
      expect(service.connectionState, NetworkConnectionState.disconnected);
      expect(service.connectedClients, isEmpty);
    });
  });
}
