import 'dart:io';

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

  test(
    'returns selected files in order, including same names in different folders',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickFiles');
        return [
          {'path': '/a/file.txt', 'name': 'file.txt', 'size': 2},
          {'path': '/b/file.txt', 'name': 'file.txt', 'size': 3},
        ];
      });
      final files = await pickFiles();
      expect(files.map((f) => f.path), ['/a/file.txt', '/b/file.txt']);
      expect(files.map((f) => f.size), [2, 3]);
    },
  );

  test('multi-selection cancellation returns an empty list', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await pickFiles(), isEmpty);
  });

  test(
    'rejects malformed multi-selection and preserves picker errors',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          {'path': '/a/file.txt', 'name': 'file.txt', 'size': -1},
        ],
      );
      await expectLater(pickFiles(), throwsFormatException);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'FILE_PICKER_ERROR'),
      );
      await expectLater(pickFiles(), throwsA(isA<PlatformException>()));
    },
  );

  test(
    'picker cleanup only removes staged copies inside its directory',
    () async {
      final dir = await Directory.systemTemp.createTemp('yichuan-picker-test-');
      addTearDown(() => dir.delete(recursive: true));
      final outside = File('${dir.path}/outside.txt')
        ..writeAsStringSync('real file');
      final staged = File('${dir.path}/picked_1.tmp')
        ..writeAsStringSync('copy');
      final other = File('${dir.path}/unrelated.dat')
        ..writeAsStringSync('not ours');

      await deleteStagedPickedFile(dir.path, outside.path);
      expect(outside.existsSync(), isTrue,
          reason: 'A non-staged file must survive a named delete.');
      expect(staged.existsSync(), isTrue,
          reason: 'A different staged file must survive a named delete.');

      await deleteStagedPickedFile(dir.path, staged.path);
      expect(staged.existsSync(), isFalse,
          reason: 'A staged copy must be removed when named.');
      expect(outside.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);

      await deleteStagedPickedFile(dir.path, null);
      expect(outside.existsSync(), isTrue,
          reason: 'A sweep must leave non-staged files untouched.');
      expect(other.existsSync(), isTrue,
          reason: 'A sweep must not touch files the picker never created.');
    },
  );

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
  for (final platformResult in [false, null]) {
    test(
      'file opening respects platform failure result $platformResult',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => platformResult,
        );
        expect(await openFile('content://media/external/downloads/1'), isFalse);
        expect(await openLocalFile('/tmp/file'), isFalse);
      },
    );
  }
}
