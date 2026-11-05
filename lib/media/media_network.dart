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
  static int _networkEpoch = 0;

  /// Invalidates transport context after Wi-Fi, cellular, VPN, or proxy
  /// changes. The epoch is process-local and is never part of media identity.
  static void networkChanged() => _networkEpoch++;

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
    Map<String, String>? headers,
    String? requestContextId,
  }) async {
    await transferFileWithPolicy(
      url,
      document,
      destination,
      maxBytes,
      cancel,
      onProgress: onProgress,
      headers: headers,
      requestContextId: requestContextId,
      maxAttempts: 5,
      startAttempt: 0,
    );
  }

  Future<MediaTransferResult> transferFileWithPolicy(
    Uri url,
    Uri document,
    File destination,
    int maxBytes,
    Cancellation cancel, {
    void Function(int bytesWritten)? onProgress,
    Map<String, String>? headers,
    String? requestContextId,
    required int maxAttempts,
    required int startAttempt,
    String resourceKind = 'file',
  }) async {
    if (!_nativeAvailable) throw UnsupportedError('需要 Android 媒体传输');
    if (maxAttempts < 1 || startAttempt < 0) {
      throw RangeError('媒体传输重试预算无效');
    }
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
      var contextId = requestContextId;
      try {
        contextId ??= (await _route(
          url,
          attempt: startAttempt,
          media: true,
          document: document,
        )).requestContextId;
      } catch (_) {
        // The transfer channel performs its own route selection. Context
        // discovery is best effort so a page without observed auth headers
        // keeps the existing transport behavior.
      }
      cancel.check();
      final result = await _channel.invokeMapMethod<String, Object?>(
        'transferFile',
        {
          'jobId': jobId,
          'url': url.toString(),
          'document': document.toString(),
          'networkEpoch': _networkEpoch,
          ...?contextId == null ? null : {'requestContextId': contextId},
          'path': destination.path,
          'maxBytes': maxBytes,
          'maxAttempts': maxAttempts,
          'startAttempt': startAttempt,
          'resourceKind': resourceKind,
          if (headers != null && headers.isNotEmpty) 'headers': headers,
        },
      );
      final used = result?['attemptsUsed'];
      final finalUrl = result?['finalUrl'];
      cancel.check();
      return MediaTransferResult(
        attemptsUsed: used is int && used >= 1 && used <= maxAttempts
            ? used
            : maxAttempts,
        finalUrl: finalUrl is String ? Uri.tryParse(finalUrl) : null,
      );
    } finally {
      active = false;
      callbacks.remove(jobId);
      if (callbacks.isEmpty) {
        _progressByChannel.remove(_channelKey);
        _channel.setMethodCallHandler(null);
      }
    }
  }

  Future<MediaNetworkRoute> route(
    Uri uri, {
    int attempt = 0,
    Uri? document,
  }) async {
    return _route(uri, attempt: attempt, media: true, document: document);
  }

  /// Site probes share OS proxy/VPN policy without reading browser cookies.
  Future<MediaNetworkRoute> probeRoute(Uri uri, {int attempt = 0}) async {
    return _route(uri, attempt: attempt, media: false);
  }

  /// Android returns Java Socket.localAddress; Dart Socket.address retains the
  /// address passed to connect and therefore cannot identify the local route.
  Future<String> relayAddress(Uri receiver) async {
    final String? value;
    try {
      value = await _channel.invokeMethod<String>('relayAddress', {
        'url': receiver.toString(),
      });
    } on PlatformException catch (error) {
      throw MediaRelayRouteException(error);
    }
    if (value == null || value.trim().isEmpty) {
      throw StateError('无法读取本机投屏地址');
    }
    return value;
  }

  Future<MediaNetworkRoute> _route(
    Uri uri, {
    required int attempt,
    required bool media,
    Uri? document,
  }) async {
    if (!_nativeAvailable) return const MediaNetworkRoute();
    final value = await _channel.invokeMapMethod<String, Object?>(
      media ? 'route' : 'probeRoute',
      {
        'url': uri.toString(),
        'attempt': attempt,
        'networkEpoch': _networkEpoch,
        if (document != null) 'document': document.toString(),
      },
    );
    if (value == null) throw StateError('无法读取系统代理设置，请重试');
    return MediaNetworkRoute(
      proxy: value['proxy'] as String? ?? 'DIRECT',
      allowProxyFakeIp:
          value['fakeIpAllowed'] == true || value['routeAllowsFakeIp'] == true,
      routeKind: value['routeKind'] as String? ?? 'unknown',
      dnsOwner: value['dnsOwner'] as String? ?? 'unknown',
      targetDnsMode: value['targetDnsMode'] as String? ?? 'unknown',
      fakeIpAllowed:
          value['fakeIpAllowed'] == true || value['routeAllowsFakeIp'] == true,
      proxyConfigured: value['proxyConfigured'] == true,
      preferVpnTun: value['preferVpnTun'] == true,
      directAllowed: value['directAllowed'] != false,
      networkEpoch: (value['networkEpoch'] as num?)?.toInt() ?? _networkEpoch,
      requestContextId: value['requestContextId'] as String?,
      userAgent:
          value['userAgent'] as String? ?? MediaNetworkRoute.defaultUserAgent,
    );
  }
}

class MediaRelayRouteException extends StateError {
  MediaRelayRouteException(this.cause) : super('无法确定本机投屏地址，请检查与接收设备的网络连接');

  final Object cause;

  @override
  String toString() => '${super.toString()}\n原因：$cause';
}
