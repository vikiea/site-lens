import 'package:flutter/services.dart';

/// Restricted Android bridge for validating local HLS inputs and copying a
/// verified MP4 to a user-selected Storage Access Framework destination.
class NativeExportRuntime {
  NativeExportRuntime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/native_export') {
    // Test doubles inject their own channel before a Flutter binding exists;
    // only the production channel needs the native-to-Dart event handler.
    if (channel == null) {
      try {
        _channel.setMethodCallHandler(_onNativeEvent);
      } on AssertionError {
        // A pure Dart test may construct the runtime before Flutter binding
        // initialization. The injected native channel is unused in that path.
      }
    }
  }

  final MethodChannel _channel;
  final _progressCallbacks = <String, void Function(int)>{};

  Future<bool> validateLocalInput(
    String path, {
    List<String> resourcePaths = const [],
    List<String> allowedRoots = const [],
  }) async =>
      await _channel.invokeMethod<bool>('validateLocalInput', {
        'path': path,
        'resourcePaths': resourcePaths,
        'allowedRoots': allowedRoots,
      }) ??
      false;

  Future<String?> pickDirectory() =>
      _channel.invokeMethod<String>('pickDirectory');

  Future<Map<String, Object?>> directAccessState() async =>
      await _channel.invokeMapMethod<String, Object?>('directAccessState') ??
      const <String, Object?>{};

  Future<bool> requestDirectAccess() async =>
      await _channel.invokeMethod<bool>('requestDirectAccess') ?? false;

  Future<bool> checkDirectDirectory(String path) async =>
      await _channel.invokeMethod<bool>('checkDirectDirectory', {
        'path': path,
      }) ??
      false;

  Future<void> configureDirectRoot(String? path) =>
      _channel.invokeMethod<void>('configureDirectRoot', {'path': path});

  Future<void> beginBackgroundExport(String taskId) =>
      _channel.invokeMethod<void>('beginBackgroundExport', {'taskId': taskId});

  Future<void> endBackgroundExport(String taskId) =>
      _channel.invokeMethod<void>('endBackgroundExport', {'taskId': taskId});

  Future<List<Map<String, Object?>>> listDirectDirectory(String path) async {
    final raw = await _channel.invokeMethod<List<Object?>>(
      'listDirectDirectory',
      {'path': path},
    );
    return [
      for (final value in raw ?? const <Object?>[])
        if (value is Map)
          Map<String, Object?>.from(value.cast<String, Object?>()),
    ];
  }

  Future<bool> checkDirectory(Uri directory) async =>
      await _channel.invokeMethod<bool>('checkDirectory', {
        'directory': directory.toString(),
      }) ??
      false;

  Future<bool> isDocumentWithinTree({
    required Uri directory,
    required Uri document,
  }) async =>
      await _channel.invokeMethod<bool>('isDocumentWithinTree', {
        'directory': directory.toString(),
        'document': document.toString(),
      }) ??
      false;

  Future<List<Map<String, Object?>>> listDirectory(Uri directory) async {
    final raw = await _channel.invokeMethod<List<Object?>>('listDirectory', {
      'directory': directory.toString(),
    });
    return [
      for (final value in raw ?? const <Object?>[])
        if (value is Map)
          Map<String, Object?>.from(value.cast<String, Object?>()),
    ];
  }

  Future<String> createDirectory({
    required Uri directory,
    required String name,
  }) async => (await _channel.invokeMethod<String>('createDirectory', {
    'directory': directory.toString(),
    'name': name,
  }))!;

  Future<Map<String, Object?>> copyEntry({
    required String source,
    required Uri directory,
    bool move = false,
    bool reportRewrites = false,
    bool deferDelete = false,
  }) async =>
      await _channel.invokeMapMethod<String, Object?>('copyEntry', {
        'source': source,
        'directory': directory.toString(),
        'move': move,
        'reportRewrites': reportRewrites,
        'deferDelete': deferDelete,
      }) ??
      const <String, Object?>{};

  Future<String> muxHls({
    required String playlist,
    required String output,
    List<String> resourcePaths = const [],
    List<String> allowedRoots = const [],
    String? jobId,
    void Function(int progress)? onProgress,
  }) async {
    final resolvedJobId =
        jobId ?? 'export-${DateTime.now().microsecondsSinceEpoch}';
    if (onProgress != null) _progressCallbacks[resolvedJobId] = onProgress;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('muxHls', {
        'playlist': playlist,
        'output': output,
        'resourcePaths': resourcePaths,
        'allowedRoots': allowedRoots,
        'jobId': resolvedJobId,
      });
      return result?['output'] as String? ?? output;
    } finally {
      _progressCallbacks.remove(resolvedJobId);
    }
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (call.method != 'exportProgress' || call.arguments is! Map) return;
    final raw = Map<String, Object?>.from(call.arguments as Map);
    final jobId = raw['jobId'] as String?;
    final progress = (raw['progress'] as num?)?.toInt();
    if (jobId == null || progress == null) return;
    _progressCallbacks[jobId]?.call(progress.clamp(0, 100).toInt());
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
    bool reuseExistingIfSameSize = false,
  }) async => (await _channel.invokeMethod<String>('deliverToDirectory', {
    'source': source,
    'directory': directory.toString(),
    'fileName': fileName,
    'subdirectory': ?subdirectory,
    'reuseExistingIfSameSize': reuseExistingIfSameSize,
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

  Future<String> sha256(String source) async =>
      (await _channel.invokeMethod<String>('sha256', {'source': source}))!;

  /// Enumerates MP4 documents in app storage and persisted, user-granted trees.
  Future<Map<String, Object?>> scanMedia({String? directory}) async =>
      (await _channel.invokeMapMethod<String, Object?>('scanMedia', {
        'directory': ?directory,
      }))!;

  Future<String> materialize(String source) async =>
      (await _channel.invokeMethod<String>('materialize', {'source': source}))!;

  /// Holds one native mutation reservation for the full set before any delete.
  /// Completed deletions are returned even when a later provider operation fails.
  Future<List<String>> deleteOwnedSources(
    String taskId,
    List<String> sources, {
    String? mutationReservationId,
  }) async =>
      await _channel.invokeListMethod<String>('deleteOwnedSources', {
        'taskId': taskId,
        'sources': sources,
        'mutationReservationId': ?mutationReservationId,
      }) ??
      const [];

  Future<String> copyVerified({
    required String source,
    required String destination,
    bool reuseExistingVerified = false,
  }) async => (await _channel.invokeMethod<String>('copyVerified', {
    'source': source,
    'destination': destination,
    'reuseExistingVerified': reuseExistingVerified,
  }))!;

  Future<String> rename(String source, String fileName) async =>
      (await _channel.invokeMethod<String>('rename', {
        'source': source,
        'fileName': fileName,
      }))!;

  Future<String> move({
    required String source,
    required Uri directory,
    required String fileName,
    bool reuseExistingVerified = false,
  }) async => (await _channel.invokeMethod<String>('move', {
    'source': source,
    'directory': directory.toString(),
    'fileName': fileName,
    'reuseExistingVerified': reuseExistingVerified,
  }))!;

  Future<void> delete(String source, {bool allowMissing = false}) =>
      _channel.invokeMethod<void>('delete', {
        'source': source,
        'allowMissing': allowMissing,
      });
}
