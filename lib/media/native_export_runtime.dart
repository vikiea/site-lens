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

  Future<void> deliver({required String source, required Uri destination}) =>
      _channel.invokeMethod<void>('deliver', {
        'source': source,
        'destination': destination.toString(),
      });
}
