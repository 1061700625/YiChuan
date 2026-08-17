import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/platform/file_picker_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.localmesh/filepicker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('returns null only when file selection is cancelled', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    expect(await pickFile(), isNull);
  });

  test('does not hide platform file-picker errors', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'FILE_PICKER_ERROR'),
    );

    await expectLater(pickFile(), throwsA(isA<PlatformException>()));
  });
}
