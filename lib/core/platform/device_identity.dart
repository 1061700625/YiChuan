import 'dart:io';

import 'android_permissions.dart';
import 'network_info.dart';

Future<String> getLocalDeviceName() async {
  if (Platform.isAndroid) {
    final androidName = await getAndroidDeviceName();
    if (androidName != null) return androidName;
  }
  return NetworkInfo.getDeviceName();
}
