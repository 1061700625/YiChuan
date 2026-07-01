import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/network/network_service.dart';
import 'package:local_mesh_transfer/core/protocol/protocol_message.dart';

void main() {
  group('InMemoryNetworkService', () {
    late InMemoryNetworkService service;

    setUp(() {
      service = InMemoryNetworkService();
    });

    test('starts as disconnected', () {
      expect(service.connectionState, NetworkConnectionState.disconnected);
    });

    test('opens server listener and transitions to listening', () async {
      await service.startServer(port: 45678);

      expect(service.connectionState, NetworkConnectionState.listening);
      expect(service.listeningPort, 45678);
    });

    test('connects to remote host and transitions to connected', () async {
      await service.startServer(port: 45678);
      final incoming = <ProtocolMessage>[];
      service.onMessageReceived = (msg) => incoming.add(msg);

      // Simulate a client connecting
      final clientId = await service.injectClientConnection(
        deviceId: 'phone-1',
        deviceName: 'Pixel',
        host: '192.168.1.50',
      );

      expect(clientId, isNotNull);
      expect(service.connectionState, NetworkConnectionState.connected);
    });

    test('sends message to connected client', () async {
      await service.startServer(port: 45678);
      final clientId = await service.injectClientConnection(
        deviceId: 'phone-1', deviceName: 'Pixel', host: '192.168.1.50',
      );

      final sent = await service.send(clientId!, ProtocolMessage.hello(
        messageId: 'msg-1', timestamp: DateTime.utc(2026, 1, 1),
        deviceId: 'desktop-1', deviceName: 'Mac', platform: 'macos', port: 45678,
      ));

      expect(sent, isTrue);
      expect(service.messageLog, hasLength(1));
    });

    test('receives message from client and notifies callback', () async {
      await service.startServer(port: 45678);
      final incoming = <ProtocolMessage>[];
      service.onMessageReceived = (msg) => incoming.add(msg);

      final clientId = await service.injectClientConnection(
        deviceId: 'phone-1', deviceName: 'Pixel', host: '192.168.1.50',
      );

      await service.injectMessageFrom(clientId!, ProtocolMessage.hello(
        messageId: 'msg-2', timestamp: DateTime.utc(2026, 1, 1),
        deviceId: 'phone-1', deviceName: 'Pixel', platform: 'android', port: 45678,
      ));

      expect(incoming, hasLength(1));
      expect(incoming.first.type, ProtocolMessageType.hello);
      expect(incoming.first.payload['deviceId'], 'phone-1');
    });

    test('disconnects and cleans up state', () async {
      await service.startServer(port: 45678);
      final clientId = await service.injectClientConnection(
        deviceId: 'phone-1', deviceName: 'Pixel', host: '192.168.1.50',
      );

      await service.disconnect(clientId!);

      expect(service.connectionState, NetworkConnectionState.disconnected);
      expect(service.connectedClients, isEmpty);
    });
  });
}
