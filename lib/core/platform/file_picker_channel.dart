import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.localmesh/filepicker');

typedef PickedFile = ({String path, String name, int size});

PickedFile _parsePickedFile(Object? value) {
  if (value is! Map)
    throw const FormatException('Platform returned an invalid file.');
  final path = value['path'];
  final name = value['name'];
  final size = value['size'];
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

/// Pick one or more files in the native picker. Cancellation returns an empty list.
Future<List<PickedFile>> pickFiles() async {
  final result = await _channel.invokeListMethod<Object?>('pickFiles');
  return result?.map(_parsePickedFile).toList(growable: false) ?? [];
}

/// Single-file compatibility API.
Future<PickedFile?> pickFile() async {
  final result = await _channel.invokeMapMethod<String, Object?>('pickFile');
  return result == null ? null : _parsePickedFile(result);
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

/// Delete a staged picker copy named by [path], or every staged copy when
/// [path] is null.
///
/// Refuses to touch anything outside the staging directory, so the user's real
/// file can never be removed this way. On macOS and Windows the picker returns
/// the original with no copy, so this is a no-op there.
Future<void> deletePickedFile(String? path) async {
  final root = await getPickerTempDir();
  if (root == null) return;
  await deleteStagedPickedFile(root, path);
}

/// Delete [path], or every staged copy in [root] when [path] is null.
///
/// Only removes regular files that live directly inside [root] and end in
/// `.tmp`, the shape the picker creates. Anything outside [root] is left
/// exactly as it was, which is what keeps the user's real file safe.
Future<void> deleteStagedPickedFile(String root, String? path) async {
  final prefix = '$root${Platform.pathSeparator}';
  Future<void> remove(File file) async {
    if (!file.path.startsWith(prefix) || !file.path.endsWith('.tmp')) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A copy may already be gone, or the platform may refuse the delete.
    }
  }

  if (path != null) {
    await remove(File(path));
    return;
  }

  try {
    final dir = Directory(root);
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        await remove(entity);
      }
    }
  } catch (_) {
    // The staging directory may be unreadable; leave stale copies alone.
  }
}

/// Directory where Android stages picker selections, or null elsewhere.
///
/// Only Android copies a selection into a local temp file (its content:// URI is
/// not readable by the sender after the dialog closes). On macOS and Windows the
/// picker returns the user's real file, so there is nothing to clean up and this
/// returns null.
Future<String?> getPickerTempDir() async {
  if (!Platform.isAndroid) return null;
  try {
    final dir = await _channel.invokeMethod<String>('getPickerTempDir');
    return (dir == null || dir.isEmpty) ? null : dir;
  } catch (_) {
    return null;
  }
}

/// Keep authentication credentials outside the received-files directory.
Future<String> getStateDir() async {
  if (Platform.isAndroid) {
    final path = await _channel.invokeMethod<String>('getStateDir');
    if (path == null || path.isEmpty) throw StateError('无法获取应用数据目录');
    return path;
  }
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  final base = Platform.isWindows
      ? Platform.environment['LOCALAPPDATA'] ?? home
      : '$home/Library/Application Support';
  final directory = Directory('$base/YiChuan');
  await directory.create(recursive: true);
  return directory.path;
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
Future<bool> openFile(String uri, {String? fileName}) async {
  try {
    return await _channel.invokeMethod<bool>('openFile', {
          'uri': uri,
          if (fileName != null) 'fileName': fileName,
        }) ??
        false;
  } catch (e) {
    return false;
  }
}

/// Open a local file (file system path) via the system's default app.
/// Uses FileProvider on Android to create a content:// URI.
Future<bool> openLocalFile(String path, {String? fileName}) async {
  try {
    return await _channel.invokeMethod<bool>('openLocalFile', {
          'path': path,
          if (fileName != null) 'fileName': fileName,
        }) ??
        false;
  } catch (e) {
    return false;
  }
}

/// Ask the native file manager to reveal a file or its containing location.
Future<bool> revealFile({String? uri, String? path}) async {
  if (uri == null && path == null) return false;
  try {
    return await _channel.invokeMethod<bool>('revealFile', {
          if (uri != null) 'uri': uri,
          if (path != null) 'path': path,
        }) ??
        false;
  } catch (_) {
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

Future<bool> verifySavedFile(String uri, String sha256) async {
  try {
    return await _channel.invokeMethod<bool>('verifySavedFile', {
          'uri': uri,
          'sha256': sha256,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}
