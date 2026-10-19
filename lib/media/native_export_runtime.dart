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
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('muxHls', {
      'playlist': playlist,
      'output': output,
    });
    return result?['output'] as String? ?? output;
  }

  Future<bool> validateOutput(String path) async =>
      await _channel.invokeMethod<bool>('validateOutput', {'path': path}) ??
      false;

  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  Future<void> deliver({required String source, required Uri destination}) =>
      _channel.invokeMethod<void>('deliver', {
        'source': source,
        'destination': destination.toString(),
      });

  Future<void> deliverToDirectory({
    required String source,
    required Uri directory,
    required String fileName,
  }) => _channel.invokeMethod<void>('deliverToDirectory', {
    'source': source,
    'directory': directory.toString(),
    'fileName': fileName,
  });
}
