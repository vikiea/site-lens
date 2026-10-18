import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

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
    final raw = await _channel.invokeMapMethod<String, Object?>('open', {
      'sessionId': sessionId,
      'candidateId': candidate.id,
      'url': candidate.mediaUrl.toString(),
    });
    return _decode(raw ?? const <String, Object?>{});
  }

  Future<NativePlaybackSession> openLocal(MediaTask task, File file) async {
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('本地缓存不存在');
    }
    final raw = await _channel.invokeMapMethod<String, Object?>('openLocal', {
      'sessionId': 'play_${task.id}',
      'candidateId': task.candidateId,
      'path': file.path,
    });
    return _decode(raw ?? const <String, Object?>{});
  }

  Future<NativePlaybackSession> play() => _command('play');
  Future<NativePlaybackSession> pause() => _command('pause');
  Future<NativePlaybackSession> stop() => _command('stop');
  Future<NativePlaybackSession> close() => _command('close');

  Future<NativePlaybackSession> seek(Duration position) => _command(
    'seek',
    <String, Object?>{'positionMs': position.inMilliseconds},
  );

  Future<NativePlaybackSession> setSpeed(double speed) =>
      _command('speed', <String, Object?>{'speed': speed});

  Future<NativePlaybackSession> _command(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      method,
      arguments,
    );
    return _decode(raw ?? const <String, Object?>{});
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
      speed: (raw['speed'] as num?)?.toDouble() ?? 1,
      errorCode: raw['errorCode'] as String?,
    );
    _active = value.state == NativePlaybackState.stopped ? null : value;
    _states.add(value);
    return value;
  }

  Future<void> dispose() async {
    await _states.close();
    _channel.setMethodCallHandler(null);
  }
}
