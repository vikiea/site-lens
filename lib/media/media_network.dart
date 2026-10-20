import 'dart:io';

import 'package:flutter/services.dart';

import '../network/transport.dart';

/// Read current OS routing per URL, including redirects and network changes.
/// No proxy endpoints or browser credentials are persisted in task records.
class MediaNetwork {
  MediaNetwork({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/media_network');

  final MethodChannel _channel;

  Future<MediaNetworkRoute> route(Uri uri) async {
    if (!Platform.isAndroid) return const MediaNetworkRoute();
    final value = await _channel.invokeMapMethod<String, Object?>('route', {
      'url': uri.toString(),
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
