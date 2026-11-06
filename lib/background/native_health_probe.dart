import 'dart:io';

import 'package:flutter/services.dart';

import '../discovery/health_checker.dart';
import '../network/transport.dart';

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
    if (isLocalTestPage(url)) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(url);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        await response.drain<void>();
        final reachable =
            response.statusCode >= 200 && response.statusCode < 400;
        return HealthProbeResult(
          reachable: reachable,
          failureCategory: reachable ? null : 'http_${response.statusCode}',
          routeKind: 'public_direct',
          networkEpoch: 0,
        );
      } catch (_) {
        return const HealthProbeResult(
          reachable: false,
          failureCategory: 'socket',
          routeKind: 'public_direct',
          networkEpoch: 0,
        );
      } finally {
        client.close(force: true);
      }
    }
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
