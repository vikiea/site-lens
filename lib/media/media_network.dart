import 'dart:io';

import 'package:flutter/services.dart';

import '../network/transport.dart';

/// Read current OS routing per URL, including redirects and network changes.
/// No proxy endpoints or browser credentials are persisted in task records.
class MediaNetwork {
  MediaNetwork({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/media_network');

  final MethodChannel _channel;

  Future<void> transferFile(
    Uri url,
    Uri document,
    File destination,
    int maxBytes,
    Cancellation cancel,
  ) async {
    if (!Platform.isAndroid) throw UnsupportedError('需要 Android 媒体传输');
    final jobId = 'tls_${DateTime.now().microsecondsSinceEpoch}';
    cancel.onCancel(() {
      _channel.invokeMethod<void>('cancelTransfer', {'jobId': jobId});
    });
    cancel.check();
    try {
      await _channel.invokeMethod<void>('transferFile', {
        'jobId': jobId,
        'url': url.toString(),
        'document': document.toString(),
        'path': destination.path,
        'maxBytes': maxBytes,
      });
    } on PlatformException catch (error) {
      cancel.check();
      if (error.code == 'media_authorization') {
        throw StateError('媒体下载需要重新授权 HTTP 403');
      }
      rethrow;
    }
    cancel.check();
  }

  Future<MediaNetworkRoute> route(Uri uri, {int attempt = 0}) async {
    if (!Platform.isAndroid) return const MediaNetworkRoute();
    final value = await _channel.invokeMapMethod<String, Object?>('route', {
      'url': uri.toString(),
      'attempt': attempt,
    });
    if (value == null) throw StateError('无法读取系统代理设置，请重试');
    return MediaNetworkRoute(
      proxy: value['proxy'] as String? ?? 'DIRECT',
      allowProxyFakeIp: value['vpn'] == true,
      userAgent:
          value['userAgent'] as String? ?? MediaNetworkRoute.defaultUserAgent,
      cookie: value['cookie'] as String?,
    );
  }
}
