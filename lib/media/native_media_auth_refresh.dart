import 'package:flutter/services.dart';

import '../domain/models.dart';

/// One answer from the native authorization refresh.
///
/// [state] is kept raw so callers can tell `refreshed`, `unchanged`,
/// `reauthorize` and `waiting_execution` apart; [requiresPage] is the
/// page-reauthorization question the state answers.
///
/// [mediaUrl] is the main playlist address the source page itself requested
/// during the refresh. It is the only part of the page's session that crosses
/// the channel: cookie bytes, credentials and headers stay native, and the
/// address is never written to a log line.
class MediaAuthorizationRefreshResult {
  const MediaAuthorizationRefreshResult({
    required this.state,
    this.reason,
    this.mediaUrl,
    this.diagnostic,
  });

  final String state;
  final String? reason;
  final String? mediaUrl;
  final String? diagnostic;

  bool get refreshed => state == 'refreshed';
  bool get waitingExecution => state == 'waiting_execution';

  /// True when only a new visit to the source page can recover authorization.
  bool get requiresPage => state == 'reauthorize';
}

/// Android-only bridge for a bounded same-origin authorization refresh.
///
/// The refresh reloads the source page headlessly and adopts the main playlist
/// request that page issues itself. Cookie bytes and credentials never cross
/// the Dart channel; the page's own playlist address does, in [mediaUrl], and
/// is treated as an opaque locator — it is never logged.
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
      'logicalIdentity': mediaCandidateLogicalIdentity(candidate),
    });
    return _result(raw);
  }

  /// Refreshes many tasks that share one source page.
  ///
  /// Every request is answered exactly once, in the order given. A task whose
  /// own playlist was not captured during the page load is reported as
  /// `unchanged` or `reauthorize`; it never receives another task's address.
  Future<List<MediaAuthorizationRefreshResult>> refreshBatch(
    List<MediaAuthorizationRefreshRequest> batch,
  ) async {
    if (batch.isEmpty) return <MediaAuthorizationRefreshResult>[];
    final raw = await _channel.invokeMethod<Object?>('refreshBatch', {
      'requests': [
        for (final request in batch)
          {
            'taskId': request.taskId,
            'pageUrl': request.pageUrl.toString(),
            'mediaUrl': request.mediaUrl.toString(),
            'resourceKey': request.resourceKey,
            'logicalIdentity': request.logicalIdentity,
          },
      ],
    });
    final results = raw is Map ? raw['results'] : null;
    if (results is! List) return <MediaAuthorizationRefreshResult>[];
    return [
      for (final entry in results)
        if (entry is Map)
          _result(Map<String, Object?>.from(entry))
        else
          const MediaAuthorizationRefreshResult(state: 'waiting_execution'),
    ];
  }

  /// Fails closed: an unknown or missing payload never adopts an address.
  MediaAuthorizationRefreshResult _result(Map<String, Object?>? raw) {
    if (raw == null) {
      return const MediaAuthorizationRefreshResult(
        state: 'waiting_execution',
        reason: '授权刷新无响应',
      );
    }
    final state = raw['state'];
    if (state is! String || state.isEmpty) {
      return const MediaAuthorizationRefreshResult(
        state: 'waiting_execution',
        reason: '授权刷新状态缺失',
      );
    }
    final mediaUrl = raw['mediaUrl'];
    final adopted =
        state == 'refreshed' && mediaUrl is String && mediaUrl.isNotEmpty
        ? mediaUrl
        : null;
    final diagnostic = raw['diagnostic'];
    return MediaAuthorizationRefreshResult(
      state: state,
      reason: raw['reason'] as String?,
      mediaUrl: adopted,
      diagnostic: diagnostic is String && diagnostic.isNotEmpty
          ? diagnostic
          : null,
    );
  }
}

/// One task inside a [NativeMediaAuthRefresh.refreshBatch] call.
class MediaAuthorizationRefreshRequest {
  const MediaAuthorizationRefreshRequest({
    required this.taskId,
    required this.pageUrl,
    required this.mediaUrl,
    required this.logicalIdentity,
    this.resourceKey = '',
  });

  /// Builds a request from a task and the candidate whose address failed.
  factory MediaAuthorizationRefreshRequest.fromCandidate(
    MediaTask task,
    MediaCandidate candidate,
  ) => MediaAuthorizationRefreshRequest(
    taskId: task.id,
    pageUrl: task.sourceUrl,
    mediaUrl: candidate.mediaUrl,
    logicalIdentity: mediaCandidateLogicalIdentity(candidate),
    resourceKey: task.resourceKey,
  );

  final String taskId;
  final Uri pageUrl;
  final Uri mediaUrl;
  final String logicalIdentity;
  final String resourceKey;
}
