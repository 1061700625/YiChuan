import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../session/trusted_device.dart';

class DeviceRepository {
  final _store = <String, TrustedDevice>{};
  final _listeners = <void Function()>{};
  File? _storageFile;
  Future<void> _pendingWrite = Future<void>.value();
  String? _localDeviceId;

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<void> initialize(File storageFile) async {
    _storageFile = storageFile;
    if (await storageFile.exists()) {
      try {
        final json = jsonDecode(await storageFile.readAsString());
        if (json is Map<String, Object?>) {
          _localDeviceId = json['localDeviceId'] as String?;
          final devices = json['trustedDevices'];
          if (devices is List) {
            for (final item in devices) {
              if (item is Map) {
                final device = TrustedDevice.fromJson(
                  Map<String, Object?>.from(item),
                );
                _store[device.id] = device;
              }
            }
          }
        }
      } catch (_) {
        _store.clear();
        _localDeviceId = null;
      }
    }
    _notify();
  }

  Future<String> getOrCreateLocalDeviceId() => _enqueue(() async {
    if (_localDeviceId != null) return _localDeviceId!;
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _writeSnapshot(_store, localDeviceId: id);
    _localDeviceId = id;
    return id;
  });

  Future<TrustedDevice?> findById(String id) async {
    return _store[id];
  }

  Future<List<TrustedDevice>> findAll() async {
    return _store.values.toList(growable: false);
  }

  Future<void> save(TrustedDevice device) => _enqueue(() async {
    final next = Map<String, TrustedDevice>.of(_store)..[device.id] = device;
    await _writeSnapshot(next);
    _store[device.id] = device;
    _notify();
  });

  Future<void> delete(String id) => _enqueue(() async {
    final next = Map<String, TrustedDevice>.of(_store)..remove(id);
    await _writeSnapshot(next);
    _store.remove(id);
    _notify();
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_storageFile == null) return action();
    final operation = _pendingWrite.then((_) => action());
    _pendingWrite = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _writeSnapshot(
    Map<String, TrustedDevice> devices, {
    String? localDeviceId,
  }) async {
    final file = _storageFile;
    if (file == null) return;
    final snapshot = jsonEncode({
      'localDeviceId': localDeviceId ?? _localDeviceId,
      'trustedDevices': devices.values
          .map((device) => device.toJson())
          .toList(),
    });
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _notify() {
    for (final listener in _listeners) {
      listener();
    }
  }
}
