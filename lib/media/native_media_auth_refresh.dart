import 'package:flutter/services.dart';

import '../domain/models.dart';

class MediaAuthorizationRefreshResult {
  const MediaAuthorizationRefreshResult({required this.state, this.reason});

  final String state;
  final String? reason;

  bool get refreshed => state == 'refreshed';
  bool get waitingExecution => state == 'waiting_execution';
}

/// Android-only bridge for a bounded same-origin authorization refresh.
/// Cookies and credentials never cross the Dart channel; the bridge returns
/// only a state and an opaque digest for diagnostics.
class NativeMediaAuthRefresh {
  NativeMediaAuthRefresh({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/media_auth');

  final MethodChannel _channel;

  Future<MediaAuthorizationRefreshResult> refresh(
    MediaTask task,
    MediaCandidate candidate,
  ) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('refresh', {
      'taskId': task.id,
      'pageUrl': task.sourceUrl.toString(),
      'mediaUrl': candidate.mediaUrl.toString(),
      'resourceKey': task.resourceKey,
    });
    return MediaAuthorizationRefreshResult(
      state: raw?['state'] as String? ?? 'waiting_execution',
      reason: raw?['reason'] as String?,
    );
  }
}
