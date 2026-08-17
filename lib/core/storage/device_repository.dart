import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../session/trusted_device.dart';

class DeviceRepository {
  final _store = <String, TrustedDevice>{};
  final _listeners = <void Function()>{};
  File? _storageFile;
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

  Future<String> getOrCreateLocalDeviceId() async {
    if (_localDeviceId != null) return _localDeviceId!;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    _localDeviceId = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    await _persist();
    return _localDeviceId!;
  }

  Future<TrustedDevice?> findById(String id) async {
    return _store[id];
  }

  Future<List<TrustedDevice>> findAll() async {
    return _store.values.toList(growable: false);
  }

  Future<void> save(TrustedDevice device) async {
    _store[device.id] = device;
    await _persist();
    _notify();
  }

  Future<void> delete(String id) async {
    _store.remove(id);
    await _persist();
    _notify();
  }

  Future<void> _persist() async {
    final file = _storageFile;
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'localDeviceId': _localDeviceId,
        'trustedDevices': _store.values
            .map((device) => device.toJson())
            .toList(),
      }),
      flush: true,
    );
  }

  void _notify() {
    for (final listener in _listeners) {
      listener();
    }
  }
}
