import 'package:flutter/services.dart';

import '../domain/models.dart';

/// OS-managed download bridge. The durable task snapshot stays in
/// [MediaTaskStore]; Android's DownloadManager supplies process-death and
/// network-change recovery for the bytes.
class NativeDownloadRuntime {
  NativeDownloadRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/native_download');

  final MethodChannel _channel;

  Future<Map<String, Object?>> start(
    MediaTask task,
    MediaCandidate candidate, {
    String? title,
  }) async {
    if (task.candidateId != candidate.id ||
        task.hostId != candidate.hostId ||
        task.generation != candidate.generation) {
      throw StateError('stale_generation');
    }
    if (!candidate.playable) throw const FormatException('invalid_url');
    final value = await _channel.invokeMapMethod<String, Object?>('start', {
      'taskId': task.id,
      'candidateId': candidate.id,
      'generation': candidate.generation,
      'url': candidate.mediaUrl.toString(),
      'sourceUrl': candidate.sourceUrl.toString(),
      'title':
          title ??
          (task.displayName.isEmpty ? candidate.title : task.displayName),
    });
    return value ?? const <String, Object?>{};
  }

  Future<Map<String, Object?>> status(String taskId) async =>
      await _channel.invokeMapMethod<String, Object?>('status', {
        'taskId': taskId,
      }) ??
      const <String, Object?>{};

  Future<void> cancel(String taskId) =>
      _channel.invokeMethod<void>('cancel', {'taskId': taskId});

  Future<void> pause(String taskId) =>
      _channel.invokeMethod<void>('pause', {'taskId': taskId});

  Future<Map<String, Object?>> resume(String taskId) async =>
      await _channel.invokeMapMethod<String, Object?>('resume', {
        'taskId': taskId,
      }) ??
      const <String, Object?>{};

  Future<void> delete(String taskId) =>
      _channel.invokeMethod<void>('delete', {'taskId': taskId});
}
