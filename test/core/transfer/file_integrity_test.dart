import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mesh_transfer/core/transfer/file_integrity.dart';

void main() {
  test(
    'worker hashes file bytes using SHA-256, including empty files',
    () async {
      final directory = await Directory.systemTemp.createTemp('yichuan-hash-');
      try {
        final file = File('${directory.path}/sample');
        await file.writeAsString('abc');
        expect(
          await computeFileSha256(file.path),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        );
        await file.writeAsBytes([]);
        expect(
          await computeFileSha256(file.path),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        );
        await file.delete();
        await expectLater(
          computeFileSha256(file.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
