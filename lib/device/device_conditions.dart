import 'package:flutter/services.dart';

import '../discovery/health_checker.dart';
import '../network/transport.dart';

/// Reads the device conditions the background survival check depends on.
/// Charging comes from the platform (BatteryManager) over a tiny channel; the
/// network class reuses connectivity_plus.
class DeviceConditions {
  const DeviceConditions();
  static const MethodChannel _channel = MethodChannel('site_lens/device');

  Future<bool> isCharging() async {
    try {
      return await _channel.invokeMethod<bool>('isCharging') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Posts a system notification. Used to surface a notice recorded by the
  /// background isolate once the app is back in the foreground.
  Future<bool> notify(String title, String body) async {
    try {
      return await _channel.invokeMethod<bool>('notify', {
            'title': title,
            'body': body,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<HealthConditions> read() async {
    final charging = await isCharging();
    final network = await detectNetworkClass();
    return HealthConditions(
      charging: charging,
      wifi: network == NetworkClass.wifi,
    );
  }
}
