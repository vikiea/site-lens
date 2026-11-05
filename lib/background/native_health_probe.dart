import 'package:flutter/services.dart';

import '../discovery/health_checker.dart';

/// Available to both the Activity and WorkManager engine. Never reads cookies
/// or creates a WebView. Missing native support fails the run, not the site.
class NativeHealthProbe implements DetailedReachabilityProbe {
  NativeHealthProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/health_network');

  final MethodChannel _channel;

  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  @override
  Future<bool> reachable(Uri url) async => (await check(url)).reachable;

  @override
  Future<HealthProbeResult> check(Uri url) async {
    final result = await _channel.invokeMapMethod<String, Object?>('probe', {
      'url': url.toString(),
      'attempt': 0,
      'networkEpoch': 0,
    });
    if (result == null) throw StateError('后台网络探测未返回结果');
    return HealthProbeResult(
      reachable: result['status'] == 'reachable',
      failureCategory: result['failureCategory'] as String?,
      routeKind: result['routeKind'] as String?,
      networkEpoch: (result['networkEpoch'] as num?)?.toInt(),
    );
  }
}
