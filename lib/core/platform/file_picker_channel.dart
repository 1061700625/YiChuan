import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.localmesh/filepicker');

/// Pick a single file using the platform's native file picker.
/// Returns the file path, name, and size, or null if cancelled.
Future<({String path, String name, int size})?> pickFile() async {
  final result = await _channel.invokeMapMethod<String, Object?>('pickFile');
  if (result == null) return null;
  final path = result['path'];
  final name = result['name'];
  final size = result['size'];
  if (path is! String ||
      path.isEmpty ||
      name is! String ||
      name.isEmpty ||
      size is! int ||
      size < 0) {
    throw const FormatException('Platform returned an invalid file.');
  }
  return (path: path, name: name, size: size);
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
    final uri = await _channel.invokeMethod<String>('moveToDownloads', {
      'tempPath': tempPath,
      'fileName': fileName,
    });
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

/// Open an HTTPS URL in the platform's default browser.
Future<bool> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  try {
    return await _channel.invokeMethod<bool>('openExternalUrl', {'url': url}) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Delete a received file. Android uses its MediaStore URI; desktop platforms
/// delete the local path directly.
Future<bool> deleteReceivedFile({String? uri, String? path}) async {
  try {
    if (uri != null) {
      return await _channel.invokeMethod<bool>('deleteFile', {'uri': uri}) ??
          false;
    }
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    return true;
  } catch (_) {
    return false;
  }
}
