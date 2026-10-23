import 'package:flutter/services.dart';

import '../domain/models.dart';

/// OS-managed download bridge. The durable task snapshot stays in
/// [MediaTaskStore]; Android WorkManager supplies process-death and
/// network-change recovery for the bytes.
class NativeDownloadRuntime {
  NativeDownloadRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/native_download');

  final MethodChannel _channel;

  /// Android exposes a cross-call mutation reservation. Test doubles can
  /// override this to keep their in-memory backend behavior unchanged.
  bool get supportsMutationReservation => true;

  Future<Map<String, Object?>> start(
    MediaTask task,
    MediaCandidate candidate, {
    String? title,
    String? storageDirectory,
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
      'storageDirectory': storageDirectory ?? task.storageDirectoryName,
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

  /// Consolidates legacy batch directories in the Android-owned download
  /// root and updates native task records after each successful merge.
  Future<void> migrateLegacyDirectories() =>
      _channel.invokeMethod<void>('migrateLegacyDirectories');

  Future<String?> reserveMutation(String taskId, List<String> paths) async =>
      _channel.invokeMethod<String>('reserveMutation', {
        'taskId': taskId,
        'paths': paths,
      });

  Future<void> releaseMutation(String reservationId) => _channel
      .invokeMethod<void>('releaseMutation', {'reservationId': reservationId});

  Future<void> delete(String taskId, {String? reservationId}) =>
      _channel.invokeMethod<void>('delete', {
        'taskId': taskId,
        ...?(reservationId == null ? null : {'reservationId': reservationId}),
      });
}
