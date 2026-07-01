import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.localmesh/filepicker');

/// Pick a single file using the platform's native file picker.
/// Returns the file path, name, and size, or null if cancelled.
Future<({String path, String name, int size})?> pickFile() async {
  try {
    final result = await _channel.invokeMethod<String>('pickFile');
    if (result == null || result.isEmpty) return null;

    final parts = result.split('|');
    if (parts.length < 3) return null;

    final path = parts[0];
    final rawName = parts[1];
    // Strip any path-like segments to get just the basename
    final name = rawName.contains('/') ? rawName.split('/').last : rawName.contains('\\') ? rawName.split('\\').last : rawName;
    final size = int.tryParse(parts[2]) ?? 0;
    if (path.isEmpty) return null;

    return (path: path, name: name, size: size);
  } catch (_) {
    // Fallback: try using dart:io directly (desktop)
    return _fallbackPickFile();
  }
}

/// Get the download/received directory path from the platform.
Future<String> getDownloadDir() async {
  try {
    final dir = await _channel.invokeMethod<String>('getDownloadDir');
    if (dir != null && dir.isNotEmpty) return dir;
  } catch (_) {
    // Fall through
  }
  // Fallback: use a local directory
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  final receivedDir = Directory('$home/.local_mesh_transfer/received');
  if (!await receivedDir.exists()) {
    await receivedDir.create(recursive: true);
  }
  return receivedDir.path;
}

/// Move a completed file from temp storage to the public Downloads folder
/// via MediaStore API. Returns the content:// URI on success, or null on failure.
Future<String?> moveToDownloads(String tempPath, String fileName) async {
  try {
    final uri = await _channel.invokeMethod<String>(
      'moveToDownloads',
      {'tempPath': tempPath, 'fileName': fileName},
    );
    return uri;
  } catch (e) {
    return null;
  }
}

/// Open a file via the system's default app using the content:// URI.
Future<bool> openFile(String uri) async {
  try {
    await _channel.invokeMethod('openFile', {'uri': uri});
    return true;
  } catch (e) {
    return false;
  }
}

/// Open a local file (file system path) via the system's default app.
/// Uses FileProvider on Android to create a content:// URI.
Future<bool> openLocalFile(String path) async {
  try {
    await _channel.invokeMethod('openLocalFile', {'path': path});
    return true;
  } catch (e) {
    return false;
  }
}

/// Fallback file picker using stdin (for debug/test environments).
Future<({String path, String name, int size})?> _fallbackPickFile() async {
  // On desktop platforms, try reading from a hardcoded test path
  if (Platform.isMacOS || Platform.isLinux) {
    final home = Platform.environment['HOME'] ?? '';
    // List some files from Desktop as potential picks
    final desktop = Directory('$home/Desktop');
    if (await desktop.exists()) {
      final files = await desktop.list().where((e) => e is File).cast<File>().take(5).toList();
        if (files.isNotEmpty) {
          final f = files.first;
          final stat = await f.stat();
          return (path: f.path, name: f.uri.pathSegments.last, size: stat.size as int);
      }
    }
  }
  return null;
}
