import 'package:flutter/services.dart';

/// Restricted Android bridge for validating local HLS inputs and copying a
/// verified MP4 to a user-selected Storage Access Framework destination.
class NativeExportRuntime {
  NativeExportRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/native_export');

  final MethodChannel _channel;

  Future<bool> validateLocalInput(String path) async =>
      await _channel.invokeMethod<bool>('validateLocalInput', {'path': path}) ??
      false;

  Future<String?> pickDirectory() =>
      _channel.invokeMethod<String>('pickDirectory');

  Future<String> muxHls({
    required String playlist,
    required String output,
    String? jobId,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('muxHls', {
      'playlist': playlist,
      'output': output,
      'jobId': jobId ?? 'export-${DateTime.now().microsecondsSinceEpoch}',
    });
    return result?['output'] as String? ?? output;
  }

  Future<bool> validateOutput(String path, {String? jobId}) async =>
      await _channel.invokeMethod<bool>('validateOutput', {
        'path': path,
        'jobId': ?jobId,
      }) ??
      false;

  Future<void> cancel({String? jobId}) {
    final arguments = <String, Object?>{};
    if (jobId != null) arguments['jobId'] = jobId;
    return _channel.invokeMethod<void>('cancel', arguments);
  }

  Future<void> deliver({required String source, required Uri destination}) =>
      _channel.invokeMethod<void>('deliver', {
        'source': source,
        'destination': destination.toString(),
      });

  Future<String> deliverToDirectory({
    required String source,
    required Uri directory,
    required String fileName,
    String? subdirectory,
  }) async => (await _channel.invokeMethod<String>('deliverToDirectory', {
    'source': source,
    'directory': directory.toString(),
    'fileName': fileName,
    'subdirectory': ?subdirectory,
  }))!;

  Future<Map<String, Object?>> inspect(String source) async => (await _channel
      .invokeMapMethod<String, Object?>('inspect', {'source': source}))!;

  /// Read-only sample report for media acceptance. Scans at most two million
  /// samples and reports the first 512 PTS/sizes per track in decode order.
  Future<Map<String, Object?>> inspectSamples(String path) async =>
      (await _channel.invokeMapMethod<String, Object?>('inspectSamples', {
        'source': path,
      }))!;

  /// Checks readable bytes independently of optional codec metadata.
  Future<Map<String, Object?>> stat(String source) async => (await _channel
      .invokeMapMethod<String, Object?>('stat', {'source': source}))!;

  /// Enumerates MP4 documents in app storage and persisted, user-granted trees.
  Future<Map<String, Object?>> scanMedia({String? directory}) async =>
      (await _channel.invokeMapMethod<String, Object?>('scanMedia', {
        'directory': ?directory,
      }))!;

  Future<String> materialize(String source) async =>
      (await _channel.invokeMethod<String>('materialize', {'source': source}))!;

  Future<String> rename(String source, String fileName) async =>
      (await _channel.invokeMethod<String>('rename', {
        'source': source,
        'fileName': fileName,
      }))!;

  Future<String> move({
    required String source,
    required Uri directory,
    required String fileName,
  }) async => (await _channel.invokeMethod<String>('move', {
    'source': source,
    'directory': directory.toString(),
    'fileName': fileName,
  }))!;

  Future<void> delete(String source, {bool allowMissing = false}) =>
      _channel.invokeMethod<void>('delete', {
        'source': source,
        'allowMissing': allowMissing,
      });
}
