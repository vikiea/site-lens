import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../network/transport.dart';

/// Read current OS routing per URL, including redirects and network changes.
/// No proxy endpoints or browser credentials are persisted in task records.
class MediaNetwork {
  MediaNetwork({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/media_network'),
      _nativeAvailable = channel != null || Platform.isAndroid;

  final MethodChannel _channel;
  final bool _nativeAvailable;

  static final _progressByChannel =
      <(BinaryMessenger, String), Map<String, void Function(int)>>{};
  static int _nextJob = 0;

  (BinaryMessenger, String) get _channelKey =>
      (_channel.binaryMessenger, _channel.name);

  Map<String, void Function(int)> _progressHandlers() =>
      _progressByChannel.putIfAbsent(_channelKey, () {
        final callbacks = <String, void Function(int)>{};
        _channel.setMethodCallHandler((call) async {
          if (call.method != 'transferProgress' || call.arguments is! Map) {
            return null;
          }
          final args = call.arguments as Map;
          final jobId = args['jobId'];
          final bytes = args['bytesDownloaded'];
          if (jobId is String && bytes is int && bytes >= 0) {
            callbacks[jobId]?.call(bytes);
          }
          return null;
        });
        return callbacks;
      });

  Future<void> transferFile(
    Uri url,
    Uri document,
    File destination,
    int maxBytes,
    Cancellation cancel, {
    void Function(int bytesWritten)? onProgress,
  }) async {
    if (!_nativeAvailable) throw UnsupportedError('需要 Android 媒体传输');
    cancel.check();
    final jobId = 'tls_${DateTime.now().microsecondsSinceEpoch}_${_nextJob++}';
    final callbacks = _progressHandlers();
    var active = true;
    callbacks[jobId] = (bytes) {
      if (active && !cancel.cancelled) onProgress?.call(bytes);
    };
    cancel.onCancel(() {
      if (active) {
        unawaited(
          _channel
              .invokeMethod<void>('cancelTransfer', {'jobId': jobId})
              .catchError((Object _) {}),
        );
      }
    });
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
    } finally {
      active = false;
      callbacks.remove(jobId);
      if (callbacks.isEmpty) {
        _progressByChannel.remove(_channelKey);
        _channel.setMethodCallHandler(null);
      }
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
