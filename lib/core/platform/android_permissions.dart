import 'dart:io';

import 'package:flutter/services.dart';

const _permissionChannel = MethodChannel('com.localmesh/permissions');
const _networkChannel = MethodChannel('com.localmesh/network');

/// Request the NEARBY_WIFI_DEVICES permission on Android 13+.
/// Returns true if granted or not needed, false if denied.
Future<bool> requestNearbyDevicesPermission() async {
  if (!Platform.isAndroid) return true;

  try {
    final granted = await _permissionChannel.invokeMethod<bool>('requestNearbyDevices');
    return granted ?? false;
  } catch (_) {
    return true;
  }
}

/// Acquire WifiManager.MulticastLock on Android to enable receiving
/// UDP broadcast/multicast packets while the app is running.
Future<bool> acquireMulticastLock() async {
  if (!Platform.isAndroid) return true;

  try {
    final result = await _networkChannel.invokeMethod<bool>('acquireMulticastLock');
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Read the Android device name configured in system settings.
Future<String?> getAndroidDeviceName() async {
  if (!Platform.isAndroid) return null;

  try {
    final result = await _networkChannel.invokeMethod<String>('getDeviceName');
    final name = result?.trim();
    if (name == null || name.isEmpty || name.toLowerCase() == 'localhost') {
      return null;
    }
    return name;
  } catch (_) {
    return null;
  }
}

/// Release the MulticastLock.
Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;

  try {
    await _networkChannel.invokeMethod<void>('releaseMulticastLock');
  } catch (_) {
    // ignore
  }
}
