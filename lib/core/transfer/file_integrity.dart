import 'dart:io';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Stream the file in a worker isolate so hashing cannot stall the UI or pongs.
Future<String> computeFileSha256(String path) async {
  final clock = Stopwatch()..start();
  try {
    return await Isolate.run(() async {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString();
    });
  } finally {
    developer.log(
      'elapsedMs=${clock.elapsedMilliseconds}',
      name: 'yichuan.transfer.sha256',
    );
  }
}
