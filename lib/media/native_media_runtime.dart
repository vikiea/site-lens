import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/error_log.dart';
import '../domain/models.dart';
import 'media_service.dart';

/// Flutter facade for the Android native playback session. Candidate
/// validation remains in [NativePlaybackController]; this channel only
/// receives the URL after the user has explicitly selected a candidate.
class NativeMediaRuntime {
  NativeMediaRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/native_media') {
    _channel.setMethodCallHandler(_onNativeEvent);
  }

  final MethodChannel _channel;
  final _states = StreamController<NativePlaybackSession>.broadcast();
  Stream<NativePlaybackSession> get states => _states.stream;
  NativePlaybackSession? _active;
  NativePlaybackSession? get active => _active;

  Future<({double brightness, double volume})> levels() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('levels');
      return (
        brightness: (raw?['brightness'] as num?)?.toDouble() ?? 0.5,
        volume: (raw?['volume'] as num?)?.toDouble() ?? 0.5,
      );
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.native',
        context: 'method=levels',
        stack: stack,
      );
      rethrow;
    }
  }

  Future<({double brightness, double volume})> setBrightness(double value) =>
      _setLevel('brightness', value);

  Future<({double brightness, double volume})> setVolume(double value) =>
      _setLevel('volume', value);

  Future<({double brightness, double volume})> _setLevel(
    String method,
    double value,
  ) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(method, {
        'value': value.clamp(0, 1),
      });
      return (
        brightness: (raw?['brightness'] as num?)?.toDouble() ?? value,
        volume: (raw?['volume'] as num?)?.toDouble() ?? value,
      );
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.native',
        context: 'method=$method',
        stack: stack,
      );
      rethrow;
    }
  }

  Future<NativePlaybackSession> open(
    MediaCandidate candidate, {
    required int hostId,
    required int generation,
    required Uri sourceUrl,
    String? sessionId,
  }) async {
    const MediaCandidateValidator().validate(
      candidate,
      hostId: hostId,
      generation: generation,
      sourceUrl: sourceUrl,
    );
    final raw = await _invokeMap('open', {
      'sessionId': sessionId,
      'candidateId': candidate.id,
      'url': candidate.mediaUrl.toString(),
      'mime': candidate.effectiveMime,
      'sourceUrl': sourceUrl.toString(),
      'title': candidate.title,
    });
    return _decode(raw ?? const <String, Object?>{});
  }

  Future<NativePlaybackSession> openLocal(MediaTask task, File file) async {
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('本地缓存不存在');
    }
    final raw = await _invokeMap('openLocal', {
      'sessionId': 'play_${task.id}_${DateTime.now().microsecondsSinceEpoch}',
      'taskId': task.id,
      'candidateId': task.candidateId,
      'path': file.path,
      'mime': inferMediaMime(file.uri),
      'title': task.displayName,
    });
    return _decode(raw ?? const <String, Object?>{});
  }

  /// SAF files are read through their granted URI, without a second MP4 copy.
  Future<NativePlaybackSession> openDocument(MediaTask task, Uri uri) async {
    if (uri.scheme != 'content' || uri.host.isEmpty) {
      throw const FormatException('本地媒体地址无效');
    }
    final raw = await _invokeMap('openLocal', {
      'sessionId': 'play_${task.id}_${DateTime.now().microsecondsSinceEpoch}',
      'taskId': task.id,
      'candidateId': task.candidateId,
      'uri': uri.toString(),
      'mime': 'video/mp4',
      'title': task.displayName,
    });
    return _decode(raw ?? const <String, Object?>{});
  }

  Future<NativePlaybackSession> play({String? sessionId}) =>
      _command('play', _sessionArgument(sessionId));
  Future<NativePlaybackSession> pause({String? sessionId}) =>
      _command('pause', _sessionArgument(sessionId));
  Future<NativePlaybackSession> stop({String? sessionId}) =>
      _command('stop', _sessionArgument(sessionId));
  Future<NativePlaybackSession> close({String? sessionId}) =>
      _command('close', _sessionArgument(sessionId));

  Map<String, Object?> _sessionArgument(String? sessionId) => {
    if ((sessionId ?? _active?.id)?.isNotEmpty ?? false)
      'sessionId': sessionId ?? _active?.id,
  };

  Future<NativePlaybackSession> seek(Duration position, {String? sessionId}) =>
      _command('seek', <String, Object?>{
        ..._sessionArgument(sessionId),
        'positionMs': position.inMilliseconds,
      });

  Future<NativePlaybackSession> setSpeed(double speed, {String? sessionId}) =>
      _command('speed', <String, Object?>{
        ..._sessionArgument(sessionId),
        'speed': speed,
      });

  Future<NativePlaybackSession> state({String? sessionId}) =>
      _command('state', _sessionArgument(sessionId));

  Future<NativePlaybackSession> _command(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final raw = await _invokeMap(method, arguments);
    return _decode(raw ?? const <String, Object?>{});
  }

  Future<Map<String, Object?>?> _invokeMap(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>(method, arguments);
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.native',
        context: 'method=$method',
        stack: stack,
      );
      rethrow;
    }
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (call.method != 'state' || call.arguments is! Map) return;
    _decode(Map<String, Object?>.from(call.arguments as Map));
  }

  NativePlaybackSession _decode(Map<String, Object?> raw) {
    final value = NativePlaybackSession(
      id: raw['sessionId'] as String? ?? '',
      candidateId: raw['candidateId'] as String? ?? '',
      textureId: (raw['textureId'] as num?)?.toInt(),
      state: NativePlaybackState.values.firstWhere(
        (state) => state.name == raw['state'],
        orElse: () => NativePlaybackState.stopped,
      ),
      positionMs: (raw['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      videoWidth: (raw['videoWidth'] as num?)?.toInt() ?? 0,
      videoHeight: (raw['videoHeight'] as num?)?.toInt() ?? 0,
      speed: (raw['speed'] as num?)?.toDouble() ?? 1,
      errorCode: raw['errorCode'] as String?,
    );
    if (value.state == NativePlaybackState.failed) {
      AppErrorLogger.capture(
        StateError(value.errorCode ?? '原生媒体播放失败'),
        module: 'media.playback',
        context: 'session=${value.id}',
      );
    }
    _active = value.state == NativePlaybackState.stopped ? null : value;
    _states.add(value);
    return value;
  }

  Future<void> dispose() async {
    await _states.close();
    _channel.setMethodCallHandler(null);
  }
}
