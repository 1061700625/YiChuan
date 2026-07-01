import '../session/trusted_device.dart';

class DeviceRepository {
  final _store = <String, TrustedDevice>{};

  Future<TrustedDevice?> findById(String id) async {
    return _store[id];
  }

  Future<List<TrustedDevice>> findAll() async {
    return _store.values.toList(growable: false);
  }

  Future<void> save(TrustedDevice device) async {
    _store[device.id] = device;
  }

  Future<void> delete(String id) async {
    _store.remove(id);
  }
}
