import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../network/transport.dart';

/// Resumable native media transfer and LAN relay adapter.
///
/// Routing, PAC, DNS and proxy ownership stay in Android's system client. Task
/// records store only media identity and bytes; proxy endpoints are never
/// persisted.
class MediaNetwork {
  MediaNetwork({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/media_network'),
      _nativeAvailable = channel != null || Platform.isAndroid;

  final MethodChannel _channel;
  final bool _nativeAvailable;

  static final _progressByChannel =
      <(BinaryMessenger, String), Map<String, void Function(int)>>{};
  static final _networkByChannel =
      <(BinaryMessenger, String), Map<int, void Function()>>{};
  static final _registeredHandlers = <(BinaryMessenger, String)>{};
  static int _nextJob = 0;
  static int _nextNetworkListener = 0;
  static int _networkEpoch = 0;

  /// Invalidates transport context after Wi-Fi, cellular, VPN, or proxy
  /// changes. The epoch is process-local and is never part of media identity.
  static void networkChanged() => _networkEpoch++;

  (BinaryMessenger, String) get _channelKey =>
      (_channel.binaryMessenger, _channel.name);

  Map<String, void Function(int)> _progressHandlers() =>
      _progressByChannel.putIfAbsent(_channelKey, () {
        final callbacks = <String, void Function(int)>{};
        _ensureChannelHandler();
        return callbacks;
      });

  /// One Android network epoch owns both cancellation and media recovery.
  /// Consumers must not start a second recovery from connectivity_plus.
  VoidCallback onNetworkChanged(void Function() callback) {
    final key = _channelKey;
    final id = _nextNetworkListener++;
    final listeners = _networkByChannel.putIfAbsent(key, () {
      final value = <int, void Function()>{};
      _ensureChannelHandler();
      return value;
    });
    listeners[id] = callback;
    return () {
      listeners.remove(id);
      _retireChannelHandler();
    };
  }

  void _ensureChannelHandler() {
    final key = _channelKey;
    if (!_registeredHandlers.add(key)) return;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      if (call.method == 'transferProgress') {
        final jobId = args['jobId'];
        final bytes = args['bytesDownloaded'];
        if (jobId is String && bytes is int && bytes >= 0) {
          _progressByChannel[key]?[jobId]?.call(bytes);
        }
        return null;
      }
      if (call.method == 'networkChanged') {
        MediaNetwork.networkChanged();
        for (final listener in List.of(
          _networkByChannel[key]?.values ?? const <void Function()>[],
        )) {
          listener();
        }
      }
      return null;
    });
  }

  void _retireChannelHandler() {
    final key = _channelKey;
    if ((_progressByChannel[key]?.isEmpty ?? true) &&
        (_networkByChannel[key]?.isEmpty ?? true)) {
      _progressByChannel.remove(key);
      _networkByChannel.remove(key);
      if (_registeredHandlers.remove(key)) {
        _channel.setMethodCallHandler(null);
      }
    }
  }

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
      cancel.check();
      final result = await _channel.invokeMapMethod<String, Object?>(
        'transferFile',
        {
          'jobId': jobId,
          'url': url.toString(),
          'document': document.toString(),
          'networkEpoch': _networkEpoch,
          ...?requestContextId == null
              ? null
              : {'requestContextId': requestContextId},
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
    } on PlatformException catch (error) {
      // The native cancellation response is asynchronous. Once this Dart call
      // owns a cancelled token, or Android reports that the native network
      // listener cancelled it first, preserve the partial as a paused transfer.
      final details = error.details is Map ? error.details as Map : const {};
      if (cancel.cancelled ||
          error.code == 'media_cancelled' ||
          details['failureCategory'] == 'cancelled') {
        throw const Cancelled();
      }
      rethrow;
    } finally {
      active = false;
      callbacks.remove(jobId);
      _retireChannelHandler();
    }
  }

  /// Android reads Java Socket.localAddress; Dart Socket.address retains the
  /// address passed to connect and cannot identify the LAN interface used.
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
}

class MediaRelayRouteException extends StateError {
  MediaRelayRouteException(this.cause) : super('无法确定本机投屏地址，请检查与接收设备的网络连接');

  final Object cause;

  @override
  String toString() => '${super.toString()}\n原因：$cause';
}
