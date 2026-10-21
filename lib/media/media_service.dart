import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../diagnostics/error_log.dart';
import '../domain/models.dart';
import '../network/transport.dart';
import 'native_download_runtime.dart';
import 'native_export_runtime.dart';

class MediaErrorCode {
  static const staleGeneration = 'stale_generation';
  static const invalidUrl = 'invalid_url';
  static const unsupported = 'unsupported_format';
  static const authorizationRequired = 'reauthorize';
  static const diskFull = 'disk_full';
  static const network = 'network';
  static const cancelled = 'cancelled';
  static const relayDenied = 'relay_denied';
  static const cacheMissing = 'cache_missing';
}

String? mediaEpisodeLabel(String value) {
  final match = RegExp(
    r'(?:第\s*(\d+)\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*(\d+)\b)',
    caseSensitive: false,
  ).firstMatch(value);
  final route = RegExp(
    r'(?:vodplay|play)/[0-9]+-[0-9]+-([0-9]+)(?:[./?#]|$)',
    caseSensitive: false,
  ).firstMatch(value);
  final number = match?.group(1) ?? match?.group(2) ?? route?.group(1);
  return number == null ? null : '第${int.parse(number)}集';
}

String mediaTitleForEpisode(String title, int episodeNumber) {
  var value = title.trim().replaceAll(RegExp(r'\s+'), ' ');
  value = value
      .replaceAll(
        RegExp(
          r'\s*[-–—|]?\s*(?:第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  if (value.isEmpty) value = '媒体';
  return '$value - 第$episodeNumber集';
}

String mediaExportFileName(MediaTask task) {
  final raw = task.displayName.trim().isEmpty ? task.id : task.displayName;
  final safe = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_')
      .replaceAll('..', '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  final runes = (safe.isEmpty ? task.id : safe).runes.toList();
  return '${String.fromCharCodes(runes.length <= 70 ? runes : runes.skip(runes.length - 70))}.mp4';
}

String mediaPlaylistEntryName(Iterable<MediaTask> playlist, MediaTask task) {
  final duplicates = playlist.where(
    (item) => item.displayName == task.displayName,
  );
  if (duplicates.length <= 1) return task.displayName;
  // Old tasks can share stale episode metadata even though their streams
  // differ. Preserve their recorded title while giving each resource a stable
  // visible identity; never invent an episode number from download order.
  final ordered = duplicates.toList()
    ..sort((a, b) => a.cacheKey.compareTo(b.cacheKey));
  final index = ordered.indexWhere((item) => item.id == task.id);
  return '${task.displayName} · 来源 ${index + 1}';
}

String? mediaPlaylistBoundaryHint({
  required int index,
  required int length,
  required int offset,
}) {
  if (length <= 0 || offset == 0) return null;
  final target = index + offset;
  if (target < 0) return '已经是第一集';
  if (target >= length) return '已经是最后一集';
  return null;
}

List<MediaTask> mediaPlaylistForTasks(
  Iterable<MediaTask> tasks,
  MediaTask current,
) {
  final items = tasks
      .where(
        (task) =>
            task.seriesDirectoryName == current.seriesDirectoryName &&
            (task.state == MediaTaskState.completed ||
                task.state == MediaTaskState.playable),
      )
      .toList();
  if (!items.any((task) => task.id == current.id) &&
      (current.state == MediaTaskState.completed ||
          current.state == MediaTaskState.playable)) {
    items.add(current);
  }
  int? episode(MediaTask task) {
    final match = RegExp(r'(\d+)').firstMatch(task.episodeLabel ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  items.sort((left, right) {
    final a = episode(left);
    final b = episode(right);
    if (a != null && b != null && a != b) return a.compareTo(b);
    if (a != null && b == null) return -1;
    if (a == null && b != null) return 1;
    final title = left.displayName.toLowerCase().compareTo(
      right.displayName.toLowerCase(),
    );
    return title == 0 ? left.updatedAt.compareTo(right.updatedAt) : title;
  });
  return List.unmodifiable(items);
}

enum NativePlaybackState {
  preparing,
  playing,
  paused,
  buffering,
  completed,
  stopped,
  failed,
}

class NativePlaybackSession {
  const NativePlaybackSession({
    required this.id,
    required this.candidateId,
    required this.state,
    this.textureId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.speed = 1,
    this.errorCode,
  });

  final String id;
  final String candidateId;
  final NativePlaybackState state;
  final int? textureId;
  final int positionMs;
  final int durationMs;
  final int videoWidth;
  final int videoHeight;
  final double speed;
  final String? errorCode;
}

/// User-triggered native playback state. The platform Media3 adapter can
/// mirror this state, while the Dart controller rejects stale candidates and
/// guarantees one active session at a time.
class NativePlaybackController {
  NativePlaybackController({MediaCandidateValidator? validator})
    : validator = validator ?? const MediaCandidateValidator();

  final MediaCandidateValidator validator;
  NativePlaybackSession? _active;
  NativePlaybackSession? get active => _active;

  NativePlaybackSession open(
    MediaCandidate candidate, {
    required int hostId,
    required int generation,
    required Uri sourceUrl,
  }) {
    validator.validate(
      candidate,
      hostId: hostId,
      generation: generation,
      sourceUrl: sourceUrl,
    );
    _active = NativePlaybackSession(
      id: 'play_${DateTime.now().microsecondsSinceEpoch}',
      candidateId: candidate.id,
      state: NativePlaybackState.preparing,
    );
    return _active!;
  }

  NativePlaybackSession transition(
    NativePlaybackState next, {
    String? errorCode,
  }) {
    final current = _active;
    if (current == null) throw StateError('原生播放会话不存在');
    final allowed = switch (current.state) {
      NativePlaybackState.preparing => {
        NativePlaybackState.playing,
        NativePlaybackState.buffering,
        NativePlaybackState.failed,
        NativePlaybackState.stopped,
      },
      NativePlaybackState.playing => {
        NativePlaybackState.paused,
        NativePlaybackState.buffering,
        NativePlaybackState.completed,
        NativePlaybackState.stopped,
        NativePlaybackState.failed,
      },
      NativePlaybackState.paused => {
        NativePlaybackState.playing,
        NativePlaybackState.stopped,
        NativePlaybackState.failed,
      },
      NativePlaybackState.buffering => {
        NativePlaybackState.playing,
        NativePlaybackState.paused,
        NativePlaybackState.stopped,
        NativePlaybackState.failed,
      },
      NativePlaybackState.completed ||
      NativePlaybackState.stopped ||
      NativePlaybackState.failed => <NativePlaybackState>{},
    };
    if (!allowed.contains(next) && next != current.state) {
      throw StateError('非法原生播放状态迁移 ${current.state.name} -> ${next.name}');
    }
    _active = NativePlaybackSession(
      id: current.id,
      candidateId: current.candidateId,
      state: next,
      positionMs: current.positionMs,
      videoWidth: current.videoWidth,
      videoHeight: current.videoHeight,
      speed: current.speed,
      errorCode: errorCode,
    );
    return _active!;
  }

  NativePlaybackSession seek(int positionMs) {
    final current = _active;
    if (current == null ||
        (current.state != NativePlaybackState.playing &&
            current.state != NativePlaybackState.paused)) {
      throw StateError('当前状态不可拖动');
    }
    if (positionMs < 0) throw RangeError('播放位置无效');
    _active = NativePlaybackSession(
      id: current.id,
      candidateId: current.candidateId,
      state: current.state,
      positionMs: positionMs,
      videoWidth: current.videoWidth,
      videoHeight: current.videoHeight,
      speed: current.speed,
      errorCode: current.errorCode,
    );
    return _active!;
  }

  NativePlaybackSession setSpeed(double speed) {
    final current = _active;
    if (current == null || speed <= 0 || speed > 8) {
      throw RangeError('播放倍速无效');
    }
    _active = NativePlaybackSession(
      id: current.id,
      candidateId: current.candidateId,
      state: current.state,
      positionMs: current.positionMs,
      videoWidth: current.videoWidth,
      videoHeight: current.videoHeight,
      speed: speed,
      errorCode: current.errorCode,
    );
    return _active!;
  }
}

class MediaCandidateValidator {
  const MediaCandidateValidator();

  MediaCandidate validate(
    MediaCandidate candidate, {
    int? hostId,
    int? generation,
    Uri? sourceUrl,
  }) {
    if (hostId != null && candidate.hostId != hostId ||
        generation != null && candidate.generation != generation) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    if (!candidate.playable ||
        candidate.mediaUrl.scheme == 'blob' ||
        candidate.isLikelyTransportSegment) {
      throw const FormatException(MediaErrorCode.invalidUrl);
    }
    if (candidate.sourceUrl.userInfo.isNotEmpty ||
        candidate.mediaUrl.userInfo.isNotEmpty) {
      throw const FormatException(MediaErrorCode.invalidUrl);
    }
    if (sourceUrl != null && candidate.sourceUrl.origin != sourceUrl.origin) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    return candidate;
  }
}

/// Converts safe DOM observations into immutable candidates. The WebView host
/// may call this for `<audio>`/`<video>` elements; it never receives cookies or
/// authorization headers from the page.
class MediaCandidateCollector {
  const MediaCandidateCollector();

  List<MediaCandidate> fromDom({
    required int hostId,
    required int generation,
    required Uri sourceUrl,
    required Iterable<Map<String, Object?>> elements,
  }) {
    final result = <MediaCandidate>[];
    final seen = <String>{};
    for (final element in elements) {
      final raw = element['url'];
      if (raw is! String) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null || !['http', 'https'].contains(uri.scheme)) continue;
      final key = mediaCandidateKey(uri);
      if (!seen.add(key)) continue;
      final title = (element['title'] as String? ?? '').trim();
      final thumbnail = optionalMediaUri(element['thumbnail'] as String?);
      final rawMime = (element['mime'] as String? ?? '').trim();
      final mime = rawMime.isEmpty ? inferMediaMime(uri) : rawMime;
      final candidate = MediaCandidate(
        id: 'dom:$hostId:$generation:${sha256.convert(utf8.encode(key))}',
        hostId: hostId,
        generation: generation,
        sourceUrl: sourceUrl,
        mediaUrl: uri.removeFragment(),
        title: title.length > 512 ? title.substring(0, 512) : title,
        mime: mime.length > 128 ? mime.substring(0, 128) : mime,
        source: MediaCandidateSource.dom,
        thumbnailUrl: thumbnail,
        durationMs: (element['durationMs'] as num?)?.toInt(),
        createdAt: DateTime.now().toUtc(),
      );
      try {
        const MediaCandidateValidator().validate(
          candidate,
          hostId: hostId,
          generation: generation,
          sourceUrl: sourceUrl,
        );
        result.add(candidate);
      } on FormatException {
        // Invalid or credential-bearing URLs are simply not candidates.
      } on StateError {
        // A stale source is not allowed to leak into a later document.
      }
    }
    return List.unmodifiable(result);
  }
}

class MediaTaskStore {
  MediaTaskStore({Future<Directory> Function()? directoryProvider, this.db})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  final AppDatabase? db;
  final _tasks = <String, MediaTask>{};
  final _localMediaReferences = <String, MediaTask>{};
  final _byCacheKey = <String, String>{};
  final _references = <String, int>{};
  final _exclusive = <String>{};
  final _directoryLocks = <String, Future<void>>{};
  final _writes = <String, Future<void>>{};
  final _writeFailures = <String, (Object, StackTrace)>{};
  final _aliases = <String, String>{};
  final _authorizationKeys = <String, String>{};

  String _resolveId(String id) {
    var current = id;
    final seen = <String>{};
    while (true) {
      final next = _aliases[current];
      if (next == null || !seen.add(current)) break;
      current = next;
    }
    return current;
  }

  /// Returns the durable row identity after a cache-key race has been
  /// reconciled. Callers that keep task-scoped queues must use this identity.
  String resolveTaskId(String id) => _resolveId(id);

  void _saveTask(MediaTask task) {
    if (db == null) return;
    final previous = _writes[task.id] ?? Future<void>.value();
    var failureId = task.id;
    final write = previous.then<void>((_) async {
      final canonicalId = await db!.saveMediaTask(task);
      if (canonicalId == task.id) return;
      final current = _tasks[task.id];
      final persisted = await db!.mediaTaskByCacheKey(task.cacheKey);
      if (current == null && persisted == null) return;
      _aliases[task.id] = canonicalId;
      failureId = canonicalId;
      final oldTail = _writes.remove(task.id);
      if (oldTail != null) _writes[canonicalId] = oldTail;
      final references = _references.remove(task.id);
      if (references != null) {
        _references[canonicalId] = (_references[canonicalId] ?? 0) + references;
      }
      if (_exclusive.remove(task.id)) _exclusive.add(canonicalId);
      final failure = _writeFailures[task.id];
      if (failure != null) {
        _writeFailures[canonicalId] = failure;
      }
      _writeFailures.remove(task.id);
      _tasks.remove(task.id);
      final authorizationKey = _authorizationKeys.remove(task.id);
      if (authorizationKey != null) {
        _authorizationKeys[canonicalId] = authorizationKey;
      }
      _tasks[canonicalId] = (persisted ?? current!).copyWith(id: canonicalId);
      _byCacheKey[task.cacheKey] = canonicalId;
    });
    // Keep a settled queue tail so later writes can recover. Critical callers
    // still see the latest failure through flush(), instead of treating an
    // in-memory progress update as durably saved.
    _writes[task.id] = write.then<void>(
      (_) {
        _writeFailures.remove(failureId);
      },
      onError: (Object error, StackTrace stack) {
        _writeFailures[failureId] = (error, stack);
        AppErrorLogger.capture(error, module: 'media.store', stack: stack);
      },
    );
  }

  Future<void> flush(String taskId) async {
    var resolved = _resolveId(taskId);
    await (_writes[resolved] ?? _writes[taskId]);
    resolved = _resolveId(taskId);
    final failure = _writeFailures[resolved] ?? _writeFailures[taskId];
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }

  Future<void> flushAll() async {
    for (final id in _writes.keys.toList()) {
      await flush(id);
    }
  }

  MediaTask? task(String id) => _tasks[_resolveId(id)];

  /// Local library files share playback/file locks without becoming downloads
  /// or acquiring a synthetic network candidate.
  MediaTask? referenceTask(String id) => task(id) ?? _localMediaReferences[id];
  void registerLocalMediaReference(MediaTask reference) {
    _localMediaReferences[reference.id] = reference;
  }

  void unregisterLocalMediaReference(String id) =>
      _localMediaReferences.remove(id);
  List<MediaTask> get tasks => List.unmodifiable(_tasks.values);

  MediaTask? taskForCandidate(MediaCandidate candidate) {
    final id = _byCacheKey[cacheKey(candidate)];
    return id == null ? null : task(id);
  }

  MediaTask rebindCandidate(
    String taskId,
    MediaCandidate candidate, {
    bool allowAuthorizationRefresh = false,
  }) {
    const validator = MediaCandidateValidator();
    validator.validate(candidate);
    final canonicalId = _resolveId(taskId);
    final current = task(canonicalId) ?? (throw StateError('媒体任务不存在'));
    if (candidate.id == current.candidateId) return current;
    if (current.state == MediaTaskState.downloading ||
        current.state == MediaTaskState.playable ||
        current.state == MediaTaskState.completed ||
        !canDelete(canonicalId)) {
      throw StateError('媒体任务正在使用，请稍后重新选择媒体');
    }
    if (candidate.hostId != current.hostId ||
        candidate.generation != current.generation ||
        candidate.sourceUrl.removeFragment() !=
            current.sourceUrl.removeFragment() ||
        !allowAuthorizationRefresh && cacheKey(candidate) != current.cacheKey) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    final next = current.copyWith(candidateId: candidate.id);
    _tasks[canonicalId] = next;
    _authorizationKeys[canonicalId] = mediaCandidateAuthorizationKey(
      candidate.mediaUrl,
    );
    _saveTask(next);
    return next;
  }

  String cacheKey(
    MediaCandidate candidate, {
    String quality = '',
    String audio = '',
  }) {
    // Candidate IDs are observation IDs and can change when a page re-reports
    // the same stream. Use the normalized media identity so repeated sniffing
    // and app restores converge on one task.
    final input =
        '${candidate.hostId}|${candidate.generation}|${mediaCandidateGroupKey(candidate.mediaUrl)}|$quality|$audio';
    return sha256.convert(utf8.encode(input)).toString();
  }

  MediaTask create(
    MediaCandidate candidate, {
    String quality = '',
    String audio = '',
    String? batchDirectory,
  }) {
    const validator = MediaCandidateValidator();
    validator.validate(candidate);
    final key = cacheKey(candidate, quality: quality, audio: audio);
    var existingId = _byCacheKey[key];
    var existing = existingId == null ? null : _tasks[existingId];
    if (existing == null) {
      final authorizationKey = mediaCandidateAuthorizationKey(
        candidate.mediaUrl,
      );
      existing = _tasks.values
          .where(
            (task) =>
                task.state == MediaTaskState.reauthorize &&
                task.hostId == candidate.hostId &&
                task.generation == candidate.generation &&
                task.sourceUrl.removeFragment() ==
                    candidate.sourceUrl.removeFragment() &&
                _authorizationKeys[task.id] == authorizationKey,
          )
          .firstOrNull;
      existingId = existing?.id;
    }
    if (existing?.state == MediaTaskState.reauthorize) {
      return rebindCandidate(
        existing!.id,
        candidate,
        allowAuthorizationRefresh: true,
      );
    }
    if (existing != null) {
      if (existing.state != MediaTaskState.cancelled &&
          existing.state != MediaTaskState.failed) {
        return existing;
      }
      if (!canDelete(existing.id)) throw StateError('媒体任务仍在使用，请稍后重试');
      final rebound = existing.candidateId == candidate.id
          ? existing
          : rebindCandidate(existing.id, candidate);
      final retry = rebound.copyWith(
        state: MediaTaskState.queued,
        errorCode: null,
        errorReason: null,
        batchDirectory: batchDirectory == null
            ? rebound.batchDirectory
            : _normalizeBatchDirectory(batchDirectory),
      );
      _tasks[retry.id] = retry;
      _saveTask(retry);
      return retry;
    }
    // The cache identity is already unique for one host/generation/media
    // selection. Deriving the row identity from it makes two stores racing to
    // enqueue the same candidate converge on one SQLite row as well.
    final id = 'media_$key';
    final task = MediaTask(
      id: id,
      candidateId: candidate.id,
      hostId: candidate.hostId,
      generation: candidate.generation,
      sourceUrl: candidate.sourceUrl,
      cacheKey: key,
      state: MediaTaskState.queued,
      updatedAt: DateTime.now().toUtc(),
      displayTitle: candidate.title.trim(),
      batchDirectory: _normalizeBatchDirectory(batchDirectory),
      episodeLabel: _candidateEpisodeLabel(candidate),
    );
    _tasks[id] = task;
    _authorizationKeys[id] = mediaCandidateAuthorizationKey(candidate.mediaUrl);
    _byCacheKey[key] = id;
    _saveTask(task);
    return task;
  }

  static String? _normalizeBatchDirectory(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty
        ? null
        : mediaSeriesDirectoryName(trimmed).replaceAll('..', '_');
  }

  static String? _candidateEpisodeLabel(MediaCandidate candidate) {
    // Prefer a concrete media identity, then the per-resource title (including
    // explicit DOM episode metadata), then the current document URL.
    for (final value in [
      candidate.mediaUrl.toString(),
      candidate.title,
      candidate.sourceUrl.toString(),
    ]) {
      final label = mediaEpisodeLabel(value);
      if (label != null) return label;
    }
    return null;
  }

  Future<void> restore() async {
    if (_references.isNotEmpty || _exclusive.isNotEmpty) {
      throw StateError('媒体正在使用，停止播放、投屏或文件操作后才能重新载入任务');
    }
    await flushAll();
    final persisted = await db?.mediaTasks();
    if (persisted == null) return;
    final repaired = <MediaTask>[];
    final authorizationKeys = <String, String>{};
    for (final task in persisted) {
      final candidate = await db!.mediaCandidate(task.candidateId);
      final missingTitle =
          task.displayTitle.trim().isEmpty ||
          {
            '媒体',
            'video',
            'media',
          }.contains(task.displayTitle.trim().toLowerCase());
      final sameIdentity =
          candidate != null && task.cacheKey == cacheKey(candidate);
      final next = !sameIdentity
          ? task
          : task.copyWith(
              displayTitle: missingTitle && candidate.title.trim().isNotEmpty
                  ? candidate.title.trim()
                  : task.displayTitle,
              episodeLabel:
                  task.episodeLabel ?? _candidateEpisodeLabel(candidate),
            );
      repaired.add(next);
      authorizationKeys[next.id] = mediaCandidateAuthorizationKey(
        candidate?.mediaUrl ?? task.sourceUrl,
      );
      if (next.displayTitle != task.displayTitle ||
          next.episodeLabel != task.episodeLabel) {
        await db!.saveMediaTask(next);
      }
    }
    if (_references.isNotEmpty || _exclusive.isNotEmpty) {
      throw StateError('媒体正在使用，无法重新载入任务');
    }
    _tasks
      ..clear()
      ..addEntries(repaired.map((task) => MapEntry(task.id, task)));
    _aliases.clear();
    _references.clear();
    _exclusive.clear();
    _authorizationKeys
      ..clear()
      ..addAll(authorizationKeys);
    _byCacheKey
      ..clear()
      ..addEntries(repaired.map((task) => MapEntry(task.cacheKey, task.id)));
    await reconcileCachedFiles();
  }

  MediaTask transition(
    String id,
    MediaTaskState state, {
    Object? errorCode = _unset,
    Object? errorReason = _unset,
  }) {
    final canonicalId = _resolveId(id);
    final task = _tasks[canonicalId];
    if (task == null) throw StateError('媒体任务不存在');
    final allowed = switch (task.state) {
      MediaTaskState.queued => {
        MediaTaskState.downloading,
        MediaTaskState.cancelled,
        MediaTaskState.failed,
      },
      MediaTaskState.downloading => {
        MediaTaskState.paused,
        MediaTaskState.completed,
        MediaTaskState.playable,
        MediaTaskState.cancelled,
        MediaTaskState.failed,
        MediaTaskState.reauthorize,
      },
      MediaTaskState.paused => {
        MediaTaskState.downloading,
        MediaTaskState.cancelled,
        MediaTaskState.failed,
        MediaTaskState.reauthorize,
      },
      MediaTaskState.completed => {
        MediaTaskState.failed,
        MediaTaskState.playable,
        MediaTaskState.cancelled,
      },
      MediaTaskState.playable => {
        MediaTaskState.cancelled,
        MediaTaskState.failed,
      },
      MediaTaskState.reauthorize => {
        MediaTaskState.downloading,
        MediaTaskState.cancelled,
        MediaTaskState.failed,
      },
      MediaTaskState.cancelled || MediaTaskState.failed => {
        MediaTaskState.downloading,
        MediaTaskState.cancelled,
      },
    };
    if (!allowed.contains(state) && state != task.state) {
      throw StateError('非法媒体任务状态迁移 ${task.state.name} -> ${state.name}');
    }
    final next = task.copyWith(
      state: state,
      errorCode: state == MediaTaskState.downloading
          ? null
          : identical(errorCode, _unset)
          ? task.errorCode
          : errorCode as String?,
      errorReason: state == MediaTaskState.downloading
          ? null
          : identical(errorReason, _unset)
          ? task.errorReason
          : errorReason as String?,
    );
    _tasks[canonicalId] = next;
    _saveTask(next);
    return next;
  }

  static const _unset = Object();

  MediaTask updateProgress(String id, int bytesDownloaded, {int? totalBytes}) {
    final canonicalId = _resolveId(id);
    final task = _tasks[canonicalId];
    if (task == null) throw StateError('媒体任务不存在');
    if (bytesDownloaded < 0 ||
        totalBytes != null && totalBytes < bytesDownloaded) {
      throw RangeError('媒体任务进度无效');
    }
    final next = task.copyWith(
      bytesDownloaded: bytesDownloaded,
      totalBytes:
          totalBytes ??
          (task.totalBytes != null && task.totalBytes! >= bytesDownloaded
              ? task.totalBytes
              : null),
    );
    _tasks[canonicalId] = next;
    _saveTask(next);
    return next;
  }

  MediaTask setLocalRef(String id, String? localRef) {
    final canonicalId = _resolveId(id);
    final task = _tasks[canonicalId];
    if (task == null) throw StateError('媒体任务不存在');
    final next = task.copyWith(localRef: localRef);
    _tasks[canonicalId] = next;
    _saveTask(next);
    return next;
  }

  void retain(String taskId) {
    final canonicalId = _resolveId(taskId);
    if (referenceTask(canonicalId) == null) throw StateError('媒体文件不存在');
    if (_exclusive.contains(canonicalId)) {
      throw StateError('媒体任务正在执行文件操作，请稍后重试');
    }
    _references[canonicalId] = (_references[canonicalId] ?? 0) + 1;
  }

  void release(String taskId) {
    final canonicalId = _resolveId(taskId);
    final count = _references[canonicalId] ?? 0;
    if (count <= 1) {
      _references.remove(canonicalId);
    } else {
      _references[canonicalId] = count - 1;
    }
  }

  bool canDelete(String taskId) =>
      (_references[_resolveId(taskId)] ?? 0) == 0 &&
      !_exclusive.contains(_resolveId(taskId));

  bool isExclusive(String taskId) => _exclusive.contains(_resolveId(taskId));

  void acquireExclusive(String taskId) {
    final canonicalId = _resolveId(taskId);
    if (referenceTask(canonicalId) == null) throw StateError('媒体文件不存在');
    if (!canDelete(canonicalId) || !_exclusive.add(canonicalId)) {
      throw StateError('媒体任务仍被播放、导出、投屏或管理占用');
    }
  }

  void releaseExclusive(String taskId) => _exclusive.remove(_resolveId(taskId));

  Future<T> withExclusive<T>(String taskId, Future<T> Function() action) async {
    acquireExclusive(taskId);
    try {
      return await action();
    } finally {
      releaseExclusive(taskId);
    }
  }

  Future<void> delete(
    String taskId, {
    bool exclusiveAlreadyHeld = false,
  }) async {
    if (!exclusiveAlreadyHeld) {
      await withExclusive(
        taskId,
        () => delete(taskId, exclusiveAlreadyHeld: true),
      );
      return;
    }
    if (!isExclusive(taskId)) throw StateError('媒体任务未持有排他操作锁');
    await flush(taskId);
    final canonicalId = _resolveId(taskId);
    await db?.deleteMediaTask(canonicalId);
    _tasks.remove(canonicalId);
    _authorizationKeys.remove(canonicalId);
    _writes.remove(canonicalId);
    _writeFailures.remove(canonicalId);
    _aliases.removeWhere((key, value) => key == taskId || value == canonicalId);
    _byCacheKey.removeWhere((_, id) => id == canonicalId);
  }

  Future<void> reconcileCachedFiles() async {
    for (final task in tasks) {
      if ((task.state == MediaTaskState.playable ||
              task.state == MediaTaskState.completed) &&
          task.localRef != null) {
        final file = await cachedFile(task.id);
        if (!identical(this.task(task.id), task)) continue;
        if (file == null) {
          markCacheMissing(task.id);
        } else {
          final bytes = await cachedBytes(task.id);
          if (!identical(this.task(task.id), task)) continue;
          if (bytes != null &&
              (task.bytesDownloaded != bytes || task.totalBytes != bytes)) {
            updateProgress(task.id, bytes, totalBytes: bytes);
          }
        }
      }
    }
  }

  MediaTask markCacheMissing(String taskId) {
    final current = task(taskId) ?? (throw StateError('媒体任务不存在'));
    if (current.state != MediaTaskState.completed &&
        current.state != MediaTaskState.playable) {
      return current;
    }
    setLocalRef(taskId, null);
    updateProgress(taskId, 0, totalBytes: current.totalBytes);
    return transition(
      taskId,
      MediaTaskState.failed,
      errorCode: MediaErrorCode.cacheMissing,
      errorReason: '文件缺失，请重新下载',
    );
  }

  Future<void> deleteCachedFiles(
    String taskId, {
    bool exclusiveAlreadyHeld = false,
  }) async {
    if (!exclusiveAlreadyHeld) {
      await withExclusive(
        taskId,
        () => deleteCachedFiles(taskId, exclusiveAlreadyHeld: true),
      );
      return;
    }
    if (!isExclusive(taskId)) throw StateError('媒体任务未持有排他操作锁');
    final current = task(taskId) ?? (throw StateError('媒体任务不存在'));
    final file = await cachedFile(taskId, validateHls: false);
    if (file != null) {
      // Only a task-specific HLS directory may be removed recursively; a
      // series directory can contain other episodes and must remain intact.
      if (file.parent.uri.pathSegments.where((v) => v.isNotEmpty).lastOrNull ==
          '${current.cacheKey}.hls') {
        await file.parent.delete(recursive: true);
      } else {
        await file.delete();
      }
    }
    final directory = await cacheDirectory(
      storageDirectory: current.storageDirectoryName,
    );
    // A missing or stale localRef must not turn task deletion into a metadata
    // only operation. Recover the deterministic Dart cache names from the
    // task key so an orphaned complete HLS directory or direct media file is
    // removed as well. The HLS directory is task-scoped, while the parent may
    // contain adjacent episodes and is therefore retained.
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(current.cacheKey)) {
      throw StateError('媒体缓存身份无效');
    }
    for (final orphan in [
      Directory('${directory.path}/${current.cacheKey}.hls'),
      File('${directory.path}/${current.cacheKey}.media'),
    ]) {
      if (await orphan.exists()) {
        await orphan.delete(recursive: orphan is Directory);
      }
    }
    for (final partial in [
      File('${directory.path}/${current.cacheKey}.part'),
      File('${directory.path}/${current.cacheKey}.part.resume.json'),
      File('${directory.path}/${current.cacheKey}.part.resume.json.tmp'),
      File('${directory.path}/${current.cacheKey}.part.resume'),
      File('${directory.path}/${current.cacheKey}.part.resume.tmp'),
      Directory('${directory.path}/${current.cacheKey}.hls.part'),
    ]) {
      if (await partial.exists()) {
        await partial.delete(recursive: partial is Directory);
      }
    }
    markCacheMissing(taskId);
    setLocalRef(taskId, null);
  }

  Future<Directory> cacheDirectory({
    String? seriesDirectory,
    String? storageDirectory,
  }) async {
    final root = await _directoryProvider();
    final base = Directory('${root.path}/media_cache');
    final requested = storageDirectory ?? seriesDirectory;
    final safeSeries = requested == null || requested.isEmpty
        ? null
        : mediaSeriesDirectoryName(requested).replaceAll('..', '_');
    final directory = safeSeries == null
        ? base
        : Directory('${base.path}/$safeSeries');
    final path = directory.absolute.path;
    final previous = _directoryLocks[path] ?? Future<void>.value();
    final current = previous.then((_) => directory.create(recursive: true));
    _directoryLocks[path] = current;
    try {
      await current;
    } finally {
      if (identical(_directoryLocks[path], current)) {
        _directoryLocks.remove(path);
      }
    }
    return directory;
  }

  Future<Directory> cacheRootDirectory() => cacheDirectory();

  /// Returns the bytes occupied by the complete local media cache. For HLS,
  /// the playlist itself is only a manifest, so include its selected playlist,
  /// segments, init segment and encryption keys instead of reporting the
  /// manifest's few kilobytes.
  Future<int?> cachedBytes(String taskId) async {
    final playlist = await cachedFile(taskId, validateHls: false);
    if (playlist == null) return null;
    final files = <String, File>{playlist.path: playlist};
    if (playlist.path.toLowerCase().endsWith('.m3u8')) {
      final input = await const HlsPlaylistParser().parseFile(playlist.uri);
      await validateHlsCacheInput(input);
      final key = task(taskId)?.cacheKey;
      final folderName = playlist.parent.uri.pathSegments
          .where((value) => value.isNotEmpty)
          .lastOrNull;
      if (key != null && folderName == '$key.hls') {
        var total = 0;
        await for (final entity in playlist.parent.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) total += await entity.length();
        }
        return total > 0 ? total : null;
      }
      for (final uri in [
        input.playlist,
        ...input.segments,
        if (input.initSegment != null) input.initSegment!,
        ...input.initSegments,
        ...input.keys,
      ]) {
        final file = File(uri.toFilePath());
        files[file.path] = file;
      }
    }
    var total = 0;
    for (final file in files.values) {
      if (!await file.exists()) return null;
      total += await file.length();
    }
    return total > 0 ? total : null;
  }

  Future<File?> cachedFile(String taskId, {bool validateHls = true}) async {
    final task = this.task(taskId);
    final ref = task?.localRef;
    if (ref == null) return null;
    final root = (await cacheRootDirectory()).absolute.path;
    final appRoot = (await _directoryProvider()).absolute.path;
    final exportRoot = Directory('$appRoot/media_exports').absolute.path;
    final file = File(ref).absolute;
    if (!await file.exists() || (validateHls && await file.length() <= 0)) {
      return null;
    }
    final canonical = await file.resolveSymbolicLinks();
    final roots = [root, exportRoot];
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        roots.add('${external.absolute.path}/Download/site-lens');
      }
    }
    final canonicalRoots = <String>[];
    for (final allowed in roots) {
      final directory = Directory(allowed);
      canonicalRoots.add(
        await directory.exists()
            ? await directory.resolveSymbolicLinks()
            : allowed,
      );
    }
    if (!canonicalRoots.any(
      (allowed) => canonical.startsWith('$allowed${Platform.pathSeparator}'),
    )) {
      throw StateError('缓存引用越界');
    }
    if (validateHls && file.path.toLowerCase().endsWith('.m3u8')) {
      try {
        final input = await const HlsPlaylistParser().parseFile(file.uri);
        await validateHlsCacheInput(input);
      } catch (_) {
        return null;
      }
    }
    return file;
  }
}

/// Resumable, app-private media download orchestration. The native Media3
/// implementation can replace this transport while keeping the same task
/// states and cache keys.
class MediaDownloadService {
  MediaDownloadService({
    required this.tasks,
    ControlledHttp? http,
    this.native,
    this.authorize,
    this.tlsTransfer,
  }) : http = http ?? ControlledHttp();

  final MediaTaskStore tasks;
  final ControlledHttp http;
  final Future<void> Function(Uri, Uri, File, int, Cancellation)? tlsTransfer;

  /// Optional Android OS-managed backend. The deterministic Dart backend stays
  /// available for tests and platforms without DownloadManager.
  final NativeDownloadRuntime? native;
  final MediaCandidate Function(MediaTask task, MediaCandidate candidate)?
  authorize;
  Future<void> Function(MediaTask task)? onCompleted;
  final _active = <String, Cancellation>{};
  final _running = <String, Future<MediaTask>>{};
  final _controls = <String, Future<void>>{};
  final _stopping = <String>{};
  final _dartTasks = <String>{};

  /// Resume identity keeps content selectors while dropping only credentials
  /// that are expected to rotate. It is separate from [mediaCandidateGroupKey]
  /// because a UI-equivalent URL can still identify a different representation.
  String _resumeContentIdentity(Uri url) {
    const volatileCredentials = {
      'auth',
      'auth_key',
      'expires',
      'expire',
      'exp',
      'hmac',
      'sig',
      'sign',
      'signature',
      't',
      'time',
      'timestamp',
      'via',
      'via_bm',
      'token',
    };
    final clean = url.removeFragment();
    final query = clean.queryParametersAll.entries
        .where(
          (entry) => !volatileCredentials.contains(entry.key.toLowerCase()),
        )
        .expand(
          (entry) => entry.value.map(
            (value) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(value)}',
          ),
        )
        .join('&');
    final base = clean
        .replace(queryParameters: const <String, String>{})
        .toString()
        .replaceFirst(RegExp(r'\?$'), '');
    return query.isEmpty ? base : '$base?$query';
  }

  Future<void> reconcileNative() async {
    for (final task in tasks.tasks) {
      await refreshTask(task.id);
    }
  }

  /// Refresh only the backend owning this task. Missing native rows must never
  /// overwrite a Dart HLS download or a completed local cache.
  Future<MediaTask> refreshTask(String taskId) async {
    final result = await _control(taskId, (id) async {
      var current = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
      if (_active.containsKey(id) || _dartTasks.contains(id)) {
        return current;
      }
      final candidate = await tasks.db?.mediaCandidate(current.candidateId);
      if (candidate?.isHls == true) {
        if (current.state == MediaTaskState.downloading) {
          return tasks.transition(id, MediaTaskState.paused);
        }
        return current;
      }
      if (native == null) return current;
      final status = await native!.status(id);
      current = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
      if (status['state'] == 'missing') return current;
      return _applyNativeStatus(current, status);
    });
    await tasks.flush(result.id);
    return tasks.task(result.id) ?? result;
  }

  MediaTask _applyNativeStatus(MediaTask task, Map<String, Object?> status) {
    var current = tasks.task(task.id) ?? (throw StateError('媒体任务不存在'));
    // A late snapshot must not revive a deliberately cancelled task.
    if (current.state == MediaTaskState.cancelled) return current;
    final state = status['state'] as String?;
    final rawErrorCode = status['errorCode']?.toString();
    final effectiveState = rawErrorCode == MediaErrorCode.authorizationRequired
        ? 'reauthorize'
        : state;
    final bytes = (status['bytesDownloaded'] as num?)?.toInt();
    final total = (status['totalBytes'] as num?)?.toInt();
    if (bytes != null && bytes >= 0) {
      current = tasks.updateProgress(
        task.id,
        bytes,
        totalBytes: total != null && total >= bytes ? total : null,
      );
    }
    final localUri = status['localUri'] as String?;
    if (localUri != null && localUri.startsWith('file://')) {
      current = tasks.setLocalRef(task.id, Uri.parse(localUri).toFilePath());
    }
    if (rawErrorCode == MediaErrorCode.cacheMissing &&
        (current.state == MediaTaskState.completed ||
            current.state == MediaTaskState.playable)) {
      return tasks.markCacheMissing(task.id);
    }
    if (state == 'completed' &&
        (current.state == MediaTaskState.downloading ||
            current.state == MediaTaskState.paused)) {
      if (current.state == MediaTaskState.paused) {
        current = tasks.transition(task.id, MediaTaskState.downloading);
      }
      current = tasks.transition(task.id, MediaTaskState.completed);
      current = tasks.transition(task.id, MediaTaskState.playable);
    } else if (state == 'paused' &&
        current.state == MediaTaskState.downloading) {
      current = tasks.transition(task.id, MediaTaskState.paused);
    } else if ((effectiveState == 'failed' ||
            effectiveState == 'reauthorize') &&
        (current.state == MediaTaskState.downloading ||
            current.state == MediaTaskState.paused)) {
      current = tasks.transition(
        task.id,
        effectiveState == 'reauthorize'
            ? MediaTaskState.reauthorize
            : MediaTaskState.failed,
        errorCode: rawErrorCode == MediaErrorCode.cacheMissing
            ? MediaErrorCode.cacheMissing
            : _errorCode(rawErrorCode),
        errorReason:
            status['errorReason'] as String? ??
            _nativeErrorReason(rawErrorCode),
      );
    }
    return current;
  }

  Future<T> _control<T>(String taskId, Future<T> Function(String id) action) {
    final id = tasks.resolveTaskId(taskId);
    final previous = _controls[id] ?? Future<void>.value();
    final result = previous.then((_) => action(id));
    final completed = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _controls[id] = completed;
    completed.then((_) {
      if (identical(_controls[id], completed)) _controls.remove(id);
    });
    return result;
  }

  /// Stop transport and await all writes before publishing the paused state.
  Future<MediaTask> pause(String taskId) => _stop(taskId, cancelled: false);
  Future<MediaTask> cancel(String taskId) => _stop(taskId, cancelled: true);
  Future<MediaTask> pauseNative(String taskId) => pause(taskId);

  Future<MediaTask> _stop(String taskId, {required bool cancelled}) {
    final id = tasks.resolveTaskId(taskId);
    // Mark synchronously so a start queued during this operation cannot race it.
    _stopping.add(id);
    _active[id]?.cancel();
    final current = tasks.task(id);
    final nativeStop =
        current != null &&
            !_dartTasks.contains(id) &&
            current.state != MediaTaskState.completed &&
            current.state != MediaTaskState.playable
        ? cancelled
              ? native?.cancel(id)
              : native?.pause(id)
        : null;
    return _control(id, (id) async {
      try {
        final running = _running[id];
        if (nativeStop != null) await nativeStop;
        if (running != null) {
          try {
            await running;
          } catch (_) {
            /* keep the resumable partial */
          }
        }
        final latest = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
        if (latest.state == MediaTaskState.playable ||
            latest.state == MediaTaskState.completed) {
          await tasks.flush(id);
          return latest;
        }
        if (cancelled && latest.state != MediaTaskState.cancelled) {
          final result = tasks.transition(id, MediaTaskState.cancelled);
          await tasks.flush(id);
          return result;
        }
        if (!cancelled && latest.state == MediaTaskState.downloading) {
          final result = tasks.transition(id, MediaTaskState.paused);
          await tasks.flush(id);
          return result;
        }
        await tasks.flush(id);
        return latest;
      } finally {
        _stopping.remove(id);
      }
    });
  }

  /// Deletes cached bytes only after transport has stopped. [deleteTask]
  /// controls whether the task row is also deleted. [beforeDelete] runs under
  /// the same task lock, allowing the owner to delete exported artifacts safely.
  Future<void> delete(
    String taskId, {
    bool deleteTask = true,
    Future<void> Function()? beforeDelete,
  }) async {
    final id = tasks.resolveTaskId(taskId);
    if (!tasks.canDelete(id)) {
      throw StateError('媒体正在播放、导出或投屏，请先停止');
    }
    _stopping.add(id);
    _active[id]?.cancel();
    final nativeCancel = !_dartTasks.contains(id) ? native?.cancel(id) : null;
    try {
      await _control(id, (id) async {
        // Acquire the file-operation lock before touching transport. A
        // retained playback/export/cast reference therefore fails closed and
        // cannot be interrupted by a rejected delete request.
        await tasks.withExclusive(id, () async {
          if (nativeCancel != null) await nativeCancel;
          try {
            await _running[id];
          } catch (_) {
            // The partial file remains resumable after a transport failure.
          }
          final current = tasks.task(id);
          if (current == null) return;
          if (nativeCancel == null && !_dartTasks.contains(id)) {
            await native?.cancel(id);
          }
          try {
            if (beforeDelete != null) await beforeDelete();
          } catch (_) {
            final latest = tasks.task(id);
            if (latest != null && latest.state == MediaTaskState.downloading) {
              tasks.transition(id, MediaTaskState.cancelled);
            }
            rethrow;
          }
          await native?.delete(id);
          await tasks.deleteCachedFiles(id, exclusiveAlreadyHeld: true);
          if (deleteTask) {
            await tasks.delete(id, exclusiveAlreadyHeld: true);
          } else if (tasks.task(id)?.state == MediaTaskState.downloading ||
              tasks.task(id)?.state == MediaTaskState.paused) {
            tasks.transition(id, MediaTaskState.cancelled);
            await tasks.flush(id);
          }
        });
        _dartTasks.remove(id);
      });
    } finally {
      _stopping.remove(id);
    }
  }

  Future<MediaTask> resumeNative(String taskId, MediaCandidate candidate) =>
      startNative(
        tasks.task(taskId) ?? (throw StateError('媒体任务不存在')),
        candidate,
      );

  Future<MediaTask> _launch(
    MediaTask task,
    Future<MediaTask> Function(String id) action,
  ) {
    final requestedId = tasks.resolveTaskId(task.id);
    if (_stopping.contains(requestedId) || tasks.isExclusive(requestedId)) {
      return Future.error(StateError('媒体任务正在停止或管理文件，请稍后重试'));
    }
    final pending = _running[requestedId] ?? _running[task.id];
    if (pending != null) return pending;
    if (_controls.containsKey(requestedId)) {
      return Future.error(StateError('媒体任务正在停止或管理文件，请稍后重试'));
    }
    late final Future<MediaTask> result;
    result = Future<MediaTask>(() async {
      await tasks.flush(task.id);
      final id = tasks.resolveTaskId(task.id);
      if (id != requestedId) _running[id] = result;
      try {
        final value = await action(id);
        await tasks.flush(id);
        return tasks.task(id) ?? value;
      } catch (error) {
        await tasks.flush(id);
        rethrow;
      } finally {
        if (id != requestedId && identical(_running[id], result)) {
          _running.remove(id);
        }
      }
    });
    _running[requestedId] = result;
    result.then<void>(
      (_) {
        if (identical(_running[requestedId], result)) {
          _running.remove(requestedId);
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_running[requestedId], result)) {
          _running.remove(requestedId);
        }
      },
    );
    return result;
  }

  Future<MediaTask> startNative(MediaTask task, MediaCandidate candidate) {
    if (native == null || candidate.isHls) return start(task, candidate);
    return _launch(
      task,
      (id) => _control(id, (id) async {
        if (_stopping.contains(id)) throw const Cancelled();
        var current = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
        final authorized = authorize == null
            ? candidate
            : authorize!(current, candidate);
        _validateTaskCandidate(current, authorized);
        if (current.state == MediaTaskState.playable ||
            current.state == MediaTaskState.completed) {
          return current;
        }
        current = tasks.transition(id, MediaTaskState.downloading);
        try {
          final status = await native!.start(
            current,
            authorized,
            title: current.displayName,
            storageDirectory: current.storageDirectoryName,
          );
          return _applyNativeStatus(current, status);
        } catch (error, stack) {
          _fail(id, error, stack, 'startNative');
          rethrow;
        }
      }),
    );
  }

  void _validateTaskCandidate(MediaTask task, MediaCandidate candidate) {
    const MediaCandidateValidator().validate(
      candidate,
      hostId: task.hostId,
      generation: task.generation,
      sourceUrl: task.sourceUrl,
    );
    if (task.candidateId != candidate.id) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
  }

  void _fail(String id, Object error, StackTrace stack, String operation) {
    AppErrorLogger.capture(
      error,
      module: 'media.download',
      context: '$operation:$id',
      stack: stack,
    );
    if (tasks.task(id)?.state == MediaTaskState.downloading) {
      final code = _errorCode(error.toString());
      tasks.transition(
        id,
        code == MediaErrorCode.authorizationRequired
            ? MediaTaskState.reauthorize
            : MediaTaskState.failed,
        errorCode: code,
        errorReason: readableError(error),
      );
    }
  }

  Future<MediaTask> start(
    MediaTask task,
    MediaCandidate candidate, {
    int maxBytes = 2 * 1024 * 1024 * 1024,
  }) => _launch(
    task,
    (id) => _control(id, (id) async {
      if (_stopping.contains(id)) throw const Cancelled();
      final currentTask = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
      final authorized = authorize == null
          ? candidate
          : authorize!(currentTask, candidate);
      _validateTaskCandidate(currentTask, authorized);
      _dartTasks.add(id);
      final cancel = Cancellation();
      _active[id] = cancel;
      try {
        final previous = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
        if (previous.state == MediaTaskState.playable ||
            previous.state == MediaTaskState.completed) {
          return previous;
        }
        if (authorized.isHls) {
          return await _startHls(
            currentTask,
            authorized,
            cancel: cancel,
            maxBytes: maxBytes,
          );
        }
        var current = tasks.task(id) ?? (throw StateError('媒体任务不存在'));
        if (current.state == MediaTaskState.completed ||
            current.state == MediaTaskState.playable) {
          return current;
        }
        current = tasks.transition(id, MediaTaskState.downloading);
        final directory = await tasks.cacheDirectory(
          storageDirectory: task.storageDirectoryName,
        );
        final base = File('${directory.path}/${task.cacheKey}.part');
        await _downloadFile(
          authorized.mediaUrl,
          base,
          cancel,
          document: authorized.sourceUrl,
          maxBytes: maxBytes,
        );
        cancel.check();
        final size = await base.length();
        if (size == 0) throw StateError('媒体响应为空');
        final destination = File('${directory.path}/${task.cacheKey}.media');
        if (await destination.exists()) await destination.delete();
        if (_stopping.contains(id)) throw const Cancelled();
        final finalFile = await base.rename(destination.path);
        await _deleteResumeState(base);
        current = tasks.updateProgress(id, size, totalBytes: size);
        tasks.setLocalRef(id, finalFile.path);
        current = tasks.transition(id, MediaTaskState.completed);
        return tasks.transition(id, MediaTaskState.playable);
      } on Cancelled {
        if (tasks.task(id)?.state == MediaTaskState.downloading) {
          tasks.transition(id, MediaTaskState.paused);
        }
        return tasks.task(id)!;
      } catch (error, stack) {
        _fail(id, error, stack, 'download');
        rethrow;
      } finally {
        if (identical(_active[id], cancel)) _active.remove(id);
        _dartTasks.remove(id);
      }
    }),
  );

  /// Downloads an HLS playlist and its referenced local resources. Android's
  /// DownloadManager can fetch a single URL, but a `.m3u8` is only an index;
  /// handing it to DownloadManager leaves a task at zero bytes or stores an
  /// unusable playlist. Rewriting every referenced segment to an app-private
  /// file makes the result playable and exportable after the source tab closes.
  Future<MediaTask> _startHls(
    MediaTask task,
    MediaCandidate candidate, {
    required int maxBytes,
    required Cancellation cancel,
  }) async {
    var current = tasks.task(task.id) ?? task;
    Directory? staging;
    try {
      current = tasks.transition(task.id, MediaTaskState.downloading);
      final directory = await tasks.cacheDirectory(
        storageDirectory: task.storageDirectoryName,
      );
      staging = Directory('${directory.path}/${task.cacheKey}.hls.part');
      await staging.create(recursive: true);
      final finalDirectory = Directory(
        '${directory.path}/${task.cacheKey}.hls',
      );
      if (await finalDirectory.exists()) {
        await finalDirectory.delete(recursive: true);
      }
      var playlistUri = candidate.mediaUrl;
      var fetched = await _fetchHlsText(
        playlistUri,
        cancel,
        document: candidate.sourceUrl,
      );
      playlistUri = fetched.url;
      var playlistText = fetched.text;
      for (var depth = 0; depth < 3; depth++) {
        final variant = _selectHlsVariant(playlistUri, playlistText);
        if (variant == null) break;
        fetched = await _fetchHlsText(
          variant,
          cancel,
          document: candidate.sourceUrl,
        );
        playlistUri = fetched.url;
        playlistText = fetched.text;
      }
      if (_selectHlsVariant(playlistUri, playlistText) != null) {
        throw const FormatException('HLS 变体层级过深');
      }
      if (!playlistText.contains('#EXTM3U')) {
        throw const FormatException('媒体地址不是有效 HLS 清单');
      }

      final resources = await _readHlsResources(staging);
      await _pruneHlsResources(staging, resources, playlistUri, playlistText);
      var downloadedBytes = 0;
      for (final name in resources.values) {
        final file = File('${staging.path}/$name');
        if (await file.exists()) downloadedBytes += await file.length();
      }
      var totalBytes = utf8.encode(playlistText).length + downloadedBytes;
      current = tasks.updateProgress(task.id, downloadedBytes);
      var segmentCount = 0;
      var hasSegment = false;
      final output = <String>[];
      final lines = playlistText.split(RegExp(r'\r?\n'));
      for (var index = 0; index < lines.length; index++) {
        cancel.check();
        final line = lines[index];
        if (line.startsWith('#EXT-X-BYTERANGE:')) {
          throw const FormatException('暂不支持 HLS 字节范围分片');
        }
        if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
          final method = _hlsAttribute(line, 'METHOD')?.trim().toUpperCase();
          final raw = _hlsAttribute(line, 'URI');
          if (raw != null && method != 'NONE') {
            final local = await _downloadHlsResource(
              raw,
              playlistUri,
              staging,
              resources,
              cancel,
              totalBytes,
              maxBytes,
              document: candidate.sourceUrl,
            );
            totalBytes += local.bytes;
            output.add(_replaceHlsUri(line, local.name));
          } else {
            output.add(line);
          }
          continue;
        }
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          output.add(line);
          continue;
        }
        if (++segmentCount > 2048) {
          throw const FormatException('HLS 分片数量过多');
        }
        final local = await _downloadHlsResource(
          trimmed,
          playlistUri,
          staging,
          resources,
          cancel,
          totalBytes,
          maxBytes,
          document: candidate.sourceUrl,
        );
        totalBytes += local.bytes;
        hasSegment = true;
        output.add(local.name);
        current = tasks.updateProgress(task.id, totalBytes);
      }
      if (!hasSegment) throw const FormatException('HLS 清单没有媒体分片');
      final temporaryPlaylist = File('${staging.path}/index.m3u8');
      await temporaryPlaylist.writeAsString(output.join('\n'), flush: true);
      final resourceState = File('${staging.path}/resources.json');
      if (await resourceState.exists()) await resourceState.delete();
      if (_stopping.contains(task.id)) throw const Cancelled();
      await staging.rename(finalDirectory.path);
      final finalFile = File('${finalDirectory.path}/index.m3u8');
      tasks.setLocalRef(task.id, finalFile.path);
      final cachedBytes = await tasks.cachedBytes(task.id);
      if (cachedBytes == null) throw StateError('HLS 缓存文件不完整');
      cancel.check();
      if (_stopping.contains(task.id)) throw const Cancelled();
      current = tasks.updateProgress(
        task.id,
        cachedBytes,
        totalBytes: cachedBytes,
      );
      current = tasks.transition(task.id, MediaTaskState.completed);
      current = tasks.transition(task.id, MediaTaskState.playable);
      final completed = tasks.setLocalRef(task.id, finalFile.path);
      final callback = onCompleted;
      if (callback != null && !_stopping.contains(task.id)) {
        unawaited(
          Future<void>(() async {
            if (!_stopping.contains(task.id) && tasks.task(task.id) != null) {
              await callback(completed);
            }
          }).catchError((Object error, StackTrace stack) {
            AppErrorLogger.capture(error, module: 'media.export', stack: stack);
          }),
        );
      }
      return completed;
    } on Cancelled {
      if (tasks.task(task.id)?.state == MediaTaskState.downloading) {
        current = tasks.transition(task.id, MediaTaskState.paused);
      }
      return current;
    } catch (error, stack) {
      _fail(task.id, error, stack, 'hls');
      rethrow;
    } finally {
      // Keep the partial HLS directory after pause/failure. The resource map
      // lets a later start skip segments already written to disk.
      _active.remove(task.id);
    }
  }

  Future<({Uri url, String text})> _fetchHlsText(
    Uri url,
    Cancellation cancel, {
    required Uri document,
  }) async {
    final response = await _fetchMediaWithRetry(
      url,
      connect: const {'*'},
      document: document,
      cancel: cancel,
      maxBytes: 16 * 1024 * 1024,
    );
    if (response.status < 200 || response.status >= 300) {
      if (response.status == 401 || response.status == 403) {
        throw StateError(
          'HLS 清单 HTTP ${response.status}：下载地址已失效或被服务器拒绝，请返回播放页刷新并重新选择媒体；如网页通过代理播放，请保持相同代理后重试',
        );
      }
      throw StateError('HLS 清单 HTTP ${response.status}');
    }
    return (url: response.url, text: utf8.decode(response.bytes));
  }

  Uri? _selectHlsVariant(Uri playlist, String text) {
    final variants = <({int bandwidth, Uri url})>[];
    final lines = text.split(RegExp(r'\r?\n'));
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final bandwidth =
          int.tryParse(
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '',
          ) ??
          0;
      final next = lines
          .skip(index + 1)
          .map((value) => value.trim())
          .firstWhere(
            (value) => value.isNotEmpty && !value.startsWith('#'),
            orElse: () => '',
          );
      if (next.isNotEmpty) {
        variants.add((bandwidth: bandwidth, url: playlist.resolve(next)));
      }
    }
    if (variants.isEmpty) return null;
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants.first.url;
  }

  String? _hlsAttribute(String line, String name) {
    final separator = line.indexOf(':');
    final attributes = separator < 0 ? line : line.substring(separator + 1);
    final match = RegExp(
      "(?:^|[,;\\s])\\s*${RegExp.escape(name)}\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^,;\\s]*))",
      caseSensitive: false,
    ).firstMatch(attributes);
    return match?.group(1) ?? match?.group(2) ?? match?.group(3);
  }

  String _replaceHlsUri(String line, String localName) {
    final pattern = RegExp(
      r'''(\bURI\s*=\s*)(?:"[^"]*"|'[^']*'|[^,;\s]*)''',
      caseSensitive: false,
    );
    return line.replaceFirstMapped(
      pattern,
      (match) => '${match.group(1)}"$localName"',
    );
  }

  Future<({String name, int bytes})> _downloadHlsResource(
    String raw,
    Uri playlist,
    Directory staging,
    Map<String, String> resources,
    Cancellation cancel,
    int downloaded,
    int maxBytes, {
    required Uri document,
  }) async {
    final remote = playlist.resolve(raw);
    if (!['http', 'https'].contains(remote.scheme) ||
        remote.userInfo.isNotEmpty) {
      throw const FormatException('HLS 分片地址无效');
    }
    // A completed HLS resource is content, not a UI candidate. Preserve the
    // full signed resource URL so a new version/signature cannot reuse an old
    // key or segment merely because its path is the same. The partial file
    // below keeps a stable resume name, so an interrupted transfer can still
    // continue across a refreshed signature after validator checks.
    final key = sha256
        .convert(utf8.encode(remote.removeFragment().toString()))
        .toString();
    final existing = resources[key];
    if (existing != null) {
      final cached = File('${staging.path}/$existing');
      if (await cached.exists() && await cached.length() > 0) {
        return (name: existing, bytes: 0);
      }
      resources.remove(key);
    }
    final name = 'resource_$key.bin';
    final resumeKey = sha256
        .convert(utf8.encode(_resumeContentIdentity(remote)))
        .toString();
    final partial = File('${staging.path}/resume_$resumeKey.part');
    await _downloadFile(
      remote,
      partial,
      cancel,
      document: document,
      maxBytes: min(64 * 1024 * 1024, maxBytes),
    );
    cancel.check();
    final size = await partial.length();
    if (size == 0) throw StateError('HLS 分片响应为空');
    if (downloaded + size > maxBytes) {
      throw StateError('媒体响应超过 $maxBytes 字节');
    }
    await partial.rename('${staging.path}/$name');
    await _deleteResumeState(partial);
    resources[key] = name;
    await _writeHlsResources(staging, resources);
    return (name: name, bytes: size);
  }

  Future<Map<String, String>> _readHlsResources(Directory staging) async {
    final file = File('${staging.path}/resources.json');
    if (!await file.exists()) return <String, String>{};
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return <String, String>{};
      final entries = raw['version'] == 2 ? raw['resources'] : raw;
      if (entries is! Map) return <String, String>{};
      final result = <String, String>{};
      for (final entry in entries.entries) {
        final key = entry.key.toString();
        final name = entry.value.toString();
        if (key.isNotEmpty &&
            RegExp(r'^resource_(?:[0-9a-f]{64}|\d{5})\.bin$').hasMatch(name) &&
            await File('${staging.path}/$name').exists()) {
          result[key] = name;
        }
      }
      return result;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _pruneHlsResources(
    Directory staging,
    Map<String, String> resources,
    Uri playlist,
    String text,
  ) async {
    final keys = <String>{};
    final resumeNames = <String>{};
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      final reference =
          line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')
          ? _hlsAttribute(line, 'URI')
          : line.isEmpty || line.startsWith('#')
          ? null
          : line;
      if (reference != null) {
        final remote = playlist.resolve(reference);
        final resumeKey = sha256
            .convert(utf8.encode(_resumeContentIdentity(remote)))
            .toString();
        resumeNames.add('resume_$resumeKey.part');
        keys.add(
          sha256
              .convert(
                utf8.encode(
                  playlist.resolve(reference).removeFragment().toString(),
                ),
              )
              .toString(),
        );
      }
    }
    resources.removeWhere((key, _) => !keys.contains(key));
    final names = {
      for (final key in keys) 'resource_$key.bin',
      ...resources.values,
    };
    await for (final file in staging.list()) {
      if (file is! File) continue;
      final match = RegExp(
        r'^(resource_(?:[0-9a-f]{64}|\d{5})\.bin)(?:$|\.part)',
      ).firstMatch(file.uri.pathSegments.last);
      if (match != null && !names.contains(match.group(1))) {
        await file.delete();
      }
      final resume = RegExp(
        r'^(resume_[0-9a-f]{64}\.part)(?:$|\.resume(?:\.json)?(?:\.tmp)?$)',
      ).firstMatch(file.uri.pathSegments.last);
      if (resume != null && !resumeNames.contains(resume.group(1))) {
        await file.delete();
      }
    }
    await _writeHlsResources(staging, resources);
  }

  Future<void> _writeHlsResources(
    Directory staging,
    Map<String, String> resources,
  ) async {
    final file = File('${staging.path}/resources.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 2, 'resources': resources}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _deleteResumeState(File partial) async {
    final metadata = File('${partial.path}.resume.json');
    if (await metadata.exists()) await metadata.delete();
    final temporary = File('${metadata.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    for (final suffix in ['.resume', '.resume.tmp']) {
      final nativeState = File('${partial.path}$suffix');
      if (await nativeState.exists()) await nativeState.delete();
    }
  }

  Future<Map<String, dynamic>> _resumeState(File partial) async {
    try {
      final json = jsonDecode(
        await File('${partial.path}.resume.json').readAsString(),
      );
      return json is Map<String, dynamic> ? json : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String? _responseValidator(Map<String, String> headers) {
    final etag = headers[HttpHeaders.etagHeader];
    if (etag != null && etag.startsWith('"') && etag.endsWith('"')) return etag;
    final modified = headers[HttpHeaders.lastModifiedHeader];
    if (modified == null) return null;
    try {
      HttpDate.parse(modified);
      return modified;
    } catch (_) {
      return null;
    }
  }

  ({int start, int end, int? total})? _parseMediaContentRange(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(raw);
    if (match == null) return null;
    return (
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: match.group(3) == '*' ? null : int.parse(match.group(3)!),
    );
  }

  /// Retry from flushed bytes, never from bytes buffered only in memory.
  /// Sidecars contain a hashed resource identity and validators, no credentials.
  Future<void> _downloadFile(
    Uri url,
    File partial,
    Cancellation cancel, {
    required Uri document,
    required int maxBytes,
  }) async {
    final nativeResume = File('${partial.path}.resume');
    if (tlsTransfer != null && await nativeResume.exists()) {
      await tlsTransfer!(url, document, partial, maxBytes, cancel);
      cancel.check();
      return;
    }
    final identity = sha256
        .convert(utf8.encode(_resumeContentIdentity(url)))
        .toString();
    Object lastError = const SocketException('媒体连接失败');
    var attempt = 0;
    while (true) {
      cancel.check();
      final metadata = await _resumeState(partial);
      final validator = metadata['validator'] as String?;
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > 0 &&
          (metadata['identity'] != identity || validator == null)) {
        // Without a validator two representations cannot safely be joined.
        await partial.writeAsBytes(const [], flush: true);
        offset = 0;
      }
      try {
        final response = await http.fetchToFile(
          url,
          connect: const {'*'},
          document: document,
          cancel: cancel,
          destination: partial,
          mediaRequest: true,
          resumeOffset: offset,
          maxBytes: maxBytes,
          routeAttempt: attempt,
          headers: {
            if (offset > 0) 'Range': 'bytes=$offset-',
            if (offset > 0 && validator != null) 'If-Range': validator,
          },
          onHeaders: (status, headers) async {
            final received = _responseValidator(headers);
            if (status == 206 &&
                offset > 0 &&
                (received == null || received != validator)) {
              await partial.writeAsBytes(const [], flush: true);
              await _deleteResumeState(partial);
              throw const HttpException('媒体响应验证标识缺失或已变化，重新下载');
            }
            final state = File('${partial.path}.resume.json');
            final temporary = File('${state.path}.tmp');
            await temporary.writeAsString(
              jsonEncode({
                'identity': identity,
                'validator': received ?? (status == 206 ? validator : null),
              }),
              flush: true,
            );
            await temporary.rename(state.path);
          },
        );
        cancel.check();
        if (response.status == 416) {
          final match = RegExp(
            r'^bytes \*/(\d+)$',
          ).firstMatch(response.headers[HttpHeaders.contentRangeHeader] ?? '');
          final total = match == null ? null : int.tryParse(match.group(1)!);
          if (offset > 0 &&
              total == offset &&
              _responseValidator(response.headers) == validator) {
            return;
          }
          await partial.writeAsBytes(const [], flush: true);
          await _deleteResumeState(partial);
          lastError = StateError('媒体 Range 已失效，重新下载');
          if (attempt >= 3) throw lastError;
          await Future<void>.delayed(
            Duration(milliseconds: 100 * (1 << attempt)),
          );
          attempt++;
          continue;
        }
        if (response.status == 401 || response.status == 403) {
          throw StateError('媒体下载需要重新授权 HTTP ${response.status}');
        }
        if (_retryableMediaStatus(response.status)) {
          throw HttpException('媒体服务器暂时不可用 HTTP ${response.status}');
        }
        if (response.status != 200 && response.status != 206) {
          throw StateError('媒体下载 HTTP ${response.status}');
        }
        if (response.status == 206) {
          final range = _parseMediaContentRange(
            response.headers[HttpHeaders.contentRangeHeader],
          );
          final received = await partial.length();
          if (range?.total != null && received < range!.total!) {
            if (_responseValidator(response.headers) == null &&
                validator == null) {
              throw const HttpException('媒体分段响应缺少验证标识');
            }
            // Some CDNs cap an open-ended Range response. Keep the flushed
            // bytes and request the next interval from the new offset.
            attempt = 0;
            continue;
          }
        }
        return;
      } on Cancelled {
        rethrow;
      } on SocketException catch (error) {
        lastError = error;
      } on HandshakeException catch (error) {
        lastError = error;
      } on TlsException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = error;
      } on HttpException catch (error) {
        lastError = error;
      }
      cancel.check();
      if (attempt < 3) {
        await Future<void>.delayed(
          Duration(milliseconds: 100 * (1 << attempt)),
        );
        attempt++;
      } else {
        if ((lastError is TlsException || lastError is SocketException) &&
            tlsTransfer != null) {
          // Dart and Android keep different validator sidecars. Transfer
          // ownership to Android before its first write so a later retry
          // cannot join native bytes using an older Dart validator.
          // Android can also recover CDN connections that reset before Dart
          // reports a TLS error, using the same verified system route.
          for (final suffix in ['.resume.json', '.resume.json.tmp']) {
            final state = File('${partial.path}$suffix');
            if (await state.exists()) await state.delete();
          }
          await tlsTransfer!(url, document, partial, maxBytes, cancel);
          cancel.check();
          return;
        }
        throw lastError;
      }
    }
  }

  /// CDN edges can reset an otherwise valid request while rotating a signed
  /// segment host. Each attempt creates a fresh HttpClient/connection, which
  /// lets DNS failover and TCP/TLS setup choose another edge. HTTP errors are
  /// retried only for statuses that are normally transient.
  Future<FetchResponse> _fetchMediaWithRetry(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    Map<String, String> headers = const {},
    int maxBytes = 1024 * 1024,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      cancel.check();
      try {
        final response = await http.fetch(
          url,
          connect: connect,
          document: document,
          cancel: cancel,
          headers: headers,
          mediaRequest: true,
          maxBytes: maxBytes,
          routeAttempt: attempt,
        );
        if (!_retryableMediaStatus(response.status) || attempt == 2) {
          return response;
        }
        lastError = StateError('媒体服务器暂时不可用 HTTP ${response.status}');
      } on Cancelled {
        rethrow;
      } on SocketException catch (error) {
        lastError = error;
      } on HandshakeException catch (error) {
        lastError = error;
      } on TlsException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = error;
      } on HttpException catch (error) {
        lastError = error;
      }
      if (attempt < 2) {
        await Future<void>.delayed(
          Duration(milliseconds: 250 * (1 << attempt)),
        );
      }
    }
    throw lastError ?? const SocketException('媒体连接失败');
  }

  static bool _retryableMediaStatus(int status) =>
      status == 408 || status == 425 || status == 429 || status >= 500;

  static String _errorCode(String? raw) {
    final value = (raw ?? '').toLowerCase();
    if (value == MediaErrorCode.cacheMissing) {
      return MediaErrorCode.cacheMissing;
    }
    if (value == MediaErrorCode.authorizationRequired ||
        value == 'reauthorize') {
      return MediaErrorCode.authorizationRequired;
    }
    if (value.contains('auth') ||
        value.contains('401') ||
        value.contains('403') ||
        value.contains('授权')) {
      return MediaErrorCode.authorizationRequired;
    }
    if (value.contains('disk') || value.contains('space')) {
      return MediaErrorCode.diskFull;
    }
    if (value.contains('cancel')) return MediaErrorCode.cancelled;
    return MediaErrorCode.network;
  }

  static String _nativeErrorReason(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return '后台下载失败，请重试';
    if (value == MediaErrorCode.cacheMissing) return '后台下载文件缺失，请重试';
    return switch (_errorCode(value)) {
      MediaErrorCode.authorizationRequired => '下载地址需要重新授权',
      MediaErrorCode.diskFull => '设备存储空间不足',
      MediaErrorCode.cancelled => '下载已取消',
      _ => '网络连接中断，已保留已下载内容，可重试',
    };
  }
}

/// Validates a local HLS task before handing it to a native muxer.  No remote
/// URI, path traversal, or missing segment can reach the native media pipeline.
class HlsInputValidator {
  const HlsInputValidator();

  List<Uri> validate({
    required Uri playlist,
    required List<Uri> segments,
    Uri? initSegment,
    List<Uri> initSegments = const [],
    List<Uri> keys = const [],
  }) {
    if (playlist.scheme != 'file' || playlist.path.isEmpty) {
      throw const FormatException('HLS 清单必须来自本地缓存');
    }
    final root = File(playlist.toFilePath()).parent.absolute;
    final rootPath = root.existsSync()
        ? root.resolveSymbolicLinksSync()
        : root.path;
    final all = <Uri>[
      playlist,
      ...segments,
      ?initSegment,
      ...initSegments,
      ...keys,
    ];
    for (final uri in all) {
      if (uri.scheme != 'file') {
        throw const FormatException('HLS 输入包含远程地址或越界路径');
      }
      if (uri.pathSegments.contains('..')) {
        throw const FormatException('HLS 输入包含远程地址或越界路径');
      }
      final file = File(uri.toFilePath()).absolute;
      final canonical = file.existsSync()
          ? file.resolveSymbolicLinksSync()
          : file.path;
      if (!canonical.startsWith('$rootPath${Platform.pathSeparator}') &&
          canonical != rootPath) {
        throw const FormatException('HLS 输入包含远程地址或越界路径');
      }
      if (!file.existsSync() || file.lengthSync() <= 0) {
        throw const FormatException('HLS 输入分片缺失');
      }
    }
    return List.unmodifiable(all);
  }
}

// Keep the isolate boundary limited to strings and lists of strings. Creating
// the closure inside export() can capture the service and its unsendable Drift
// database connection; sending Uri-rich domain objects also couples this
// worker to their isolate transfer behavior.
Future<void> validateHlsCacheInput(HlsCacheInput input) =>
    _validateHlsCachePathsInIsolate(
      playlistPath: input.playlist.toFilePath(),
      segmentPaths: input.segments.map((value) => value.toFilePath()).toList(),
      initSegmentPath: input.initSegment?.toFilePath(),
      initSegmentPaths: input.initSegments
          .map((value) => value.toFilePath())
          .toList(),
      keyPaths: input.keys.map((value) => value.toFilePath()).toList(),
    );

Future<void> _validateHlsCachePathsInIsolate({
  required String playlistPath,
  required List<String> segmentPaths,
  required String? initSegmentPath,
  required List<String> initSegmentPaths,
  required List<String> keyPaths,
}) => Isolate.run(() {
  const validator = HlsInputValidator();
  validator.validate(
    playlist: Uri.file(playlistPath),
    segments: segmentPaths.map(Uri.file).toList(),
    initSegment: initSegmentPath == null ? null : Uri.file(initSegmentPath),
    initSegments: initSegmentPaths.map(Uri.file).toList(),
    keys: keyPaths.map(Uri.file).toList(),
  );
});

class HlsCacheInput {
  const HlsCacheInput({
    required this.playlist,
    required this.segments,
    this.initSegment,
    this.initSegments = const [],
    this.keys = const [],
  });

  final Uri playlist;
  final List<Uri> segments;
  final Uri? initSegment;
  final List<Uri> initSegments;
  final List<Uri> keys;
}

class HlsPlaylistParser {
  const HlsPlaylistParser();

  /// Reads a cached master playlist and selects the highest-bandwidth local
  /// variant. It never follows an HTTP(S) URI and therefore cannot turn the
  /// export path into a remote downloader.
  Future<HlsCacheInput> parseFile(Uri playlist) async {
    if (playlist.scheme != 'file') {
      throw const FormatException('HLS 清单必须来自本地缓存');
    }
    final file = File(playlist.toFilePath());
    if (!await file.exists()) throw const FormatException('HLS 清单缺失');
    final text = await file.readAsString();
    final variants = <({int bandwidth, Uri uri})>[];
    final lines = text.split(RegExp(r'\r?\n'));
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final bandwidth =
          int.tryParse(
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '',
          ) ??
          0;
      final uriLine = lines
          .skip(index + 1)
          .map((value) => value.trim())
          .firstWhere(
            (value) => value.isNotEmpty && !value.startsWith('#'),
            orElse: () => '',
          );
      if (uriLine.isEmpty) continue;
      final resolved = playlist.resolve(uriLine);
      if (resolved.scheme != 'file') {
        throw const FormatException('HLS 清单包含远程变体');
      }
      variants.add((bandwidth: bandwidth, uri: resolved));
    }
    if (variants.isNotEmpty) {
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      return parseFile(variants.first.uri);
    }
    return parse(playlist, text);
  }

  HlsCacheInput parse(Uri playlist, String text) {
    if (playlist.scheme != 'file') {
      throw const FormatException('HLS 清单必须来自本地缓存');
    }
    final base = File(playlist.toFilePath()).parent.uri;
    final segments = <Uri>[];
    final keys = <Uri>[];
    final inits = <Uri>[];
    Uri? init;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#EXTM3U')) continue;
      if (line.startsWith('#EXT-X-MAP:')) {
        final value = _attribute(line, 'URI');
        if (value != null) {
          init = _local(base, value);
          inits.add(init);
        }
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        final method = _attribute(line, 'METHOD');
        final value = _attribute(line, 'URI');
        if (method != null &&
            method.trim().toUpperCase() != 'NONE' &&
            value != null) {
          keys.add(_local(base, value));
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      segments.add(_local(base, line));
    }
    if (segments.isEmpty) throw const FormatException('HLS 清单没有媒体分片');
    return HlsCacheInput(
      playlist: playlist,
      segments: List.unmodifiable(segments),
      initSegment: init,
      initSegments: List.unmodifiable(inits),
      keys: List.unmodifiable(keys),
    );
  }

  String? _attribute(String line, String name) {
    final separator = line.indexOf(':');
    final attributes = separator < 0 ? line : line.substring(separator + 1);
    final match = RegExp(
      "(?:^|[,;\\s])\\s*${RegExp.escape(name)}\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^,;\\s]*))",
      caseSensitive: false,
    ).firstMatch(attributes);
    return match?.group(1) ?? match?.group(2) ?? match?.group(3);
  }

  Uri _local(Uri base, String value) {
    final uri = base.resolve(value);
    if (uri.scheme != 'file') {
      throw const FormatException('HLS 清单包含远程资源');
    }
    return uri;
  }
}

typedef Mp4Muxer = Future<void> Function({
  required HlsCacheInput input,
  required String outputPath,
  required void Function(int) onProgress,
  required Cancellation cancellation,
});

/// Orchestrates a single local-only HLS export. The muxer is injected so the
/// Dart layer can be tested without a platform runtime; production uses the
/// pinned Media3 Transformer and Inspector implementation.
class Mp4ExportService {
  Mp4ExportService({
    required this.tasks,
    this.muxer,
    this.native,
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final MediaTaskStore tasks;
  final Mp4Muxer? muxer;
  final NativeExportRuntime? native;
  final Future<Directory> Function() _directoryProvider;

  Future<Mp4ExportTask> export(
    String taskId,
    HlsCacheInput input, {
    Cancellation? cancellation,
    void Function(int progress)? onProgress,
  }) async {
    final task = tasks.task(taskId);
    if (task == null) throw StateError('媒体任务不存在');
    if (task.state != MediaTaskState.completed &&
        task.state != MediaTaskState.playable) {
      throw StateError('媒体缓存尚未完成');
    }
    final cancel = cancellation ?? Cancellation();
    final report = onProgress ?? (_) {};
    final id = 'export_${DateTime.now().microsecondsSinceEpoch}';
    Directory? outputDirectory;
    File? temporary;
    File? output;
    var committed = false;
    // Validation itself reads the cache asynchronously, so it needs the same
    // lease as Transformer and the final output scan.
    tasks.retain(taskId);
    try {
      cancel.check();
      await validateHlsCacheInput(input);
      cancel.check();
      final root = await _directoryProvider();
      final exportFolder = task.batchDirectory == null
          ? id
          : '${mediaSeriesDirectoryName(task.batchDirectory!)}/$id';
      outputDirectory = Directory('${root.path}/media_exports/$exportFolder');
      await outputDirectory.create(recursive: true);
      output = File('${outputDirectory.path}/${mediaExportFileName(task)}');
      temporary = File('${output.path}.part');
      report(0);
      cancel.check();
      final injectedMuxer = muxer;
      if (injectedMuxer != null) {
        await injectedMuxer(
          input: input,
          outputPath: temporary.path,
          onProgress: report,
          cancellation: cancel,
        );
      } else if (native != null) {
        if (!await native!.validateLocalInput(input.playlist.toFilePath())) {
          throw StateError('HLS 本地输入校验失败');
        }
        cancel.check();
        report(10);
        final jobId = 'export-${DateTime.now().microsecondsSinceEpoch}';
        var nativeJobActive = true;
        cancel.onCancel(() {
          if (!nativeJobActive) return;
          // The mux call remains awaited until the native writer has stopped.
          // A cancellation-channel failure must not escape the user's action.
          unawaited(native!.cancel(jobId: jobId).catchError((Object _) {}));
        });
        try {
          cancel.check();
          await native!.muxHls(
            playlist: input.playlist.toFilePath(),
            output: temporary.path,
            jobId: jobId,
          );
        } finally {
          nativeJobActive = false;
        }
        report(90);
      } else {
        throw StateError(MediaErrorCode.unsupported);
      }
      cancel.check();
      if (!await temporary.exists() || await temporary.length() == 0) {
        throw StateError('导出文件为空');
      }
      if (native != null) {
        final validationJobId =
            'validate-${DateTime.now().microsecondsSinceEpoch}';
        var validationActive = true;
        cancel.onCancel(() {
          if (!validationActive) return;
          unawaited(
            native!.cancel(jobId: validationJobId).catchError((Object _) {}),
          );
        });
        try {
          cancel.check();
          if (!await native!.validateOutput(
            temporary.path,
            jobId: validationJobId,
          )) {
            throw StateError('输出校验失败');
          }
        } finally {
          validationActive = false;
        }
      }
      cancel.check();
      await temporary.rename(output.path);
      cancel.check();
      committed = true;
      report(100);
      // MediaLibrary registers the MP4 separately so the original HLS cache
      // remains available after delivery failure or an explicit file deletion.
      return Mp4ExportTask(
        id: id,
        mediaTaskId: taskId,
        state: ExportState.deliverable,
        outputPath: output.path,
        progress: 100,
      );
    } catch (error, stack) {
      // A native cancellation arrives as PlatformException. The cancellation
      // token still owns the user-visible terminal state and never logs a
      // cancelled export as a failure.
      final cancelled = error is Cancelled || cancel.cancelled;
      if (!committed) {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
        if (output != null && await output.exists()) await output.delete();
        if (outputDirectory != null &&
            await outputDirectory.exists() &&
            await outputDirectory.list().isEmpty) {
          await outputDirectory.delete();
        }
      }
      if (!cancelled) {
        AppErrorLogger.capture(
          error,
          module: 'media.export',
          context: 'task=$taskId',
          stack: stack,
        );
      }
      return Mp4ExportTask(
        id: id,
        mediaTaskId: taskId,
        state: cancelled ? ExportState.cancelled : ExportState.failed,
        outputPath: output?.path,
        errorCode: cancelled
            ? MediaErrorCode.cancelled
            : error is PlatformException &&
                  error.message != null &&
                  error.message!.trim().isNotEmpty
            ? readableError(StateError(error.message!))
            : readableError(error),
        progress: 0,
      );
    } finally {
      tasks.release(taskId);
    }
  }

  Future<Mp4ExportTask> deliver(Mp4ExportTask task, Uri destination) async {
    if (task.state != ExportState.deliverable || task.outputPath == null) {
      throw StateError('导出文件尚未校验完成');
    }
    final runtime = native;
    if (runtime == null) throw StateError('当前平台未提供 MP4 转封装服务');
    if (destination.scheme == 'content' &&
        destination.pathSegments.contains('tree') &&
        !destination.pathSegments.contains('document')) {
      final sourceName =
          File(task.outputPath!).uri.pathSegments.lastOrNull ?? 'media.mp4';
      await runtime.deliverToDirectory(
        source: task.outputPath!,
        directory: destination,
        fileName: sourceName.toLowerCase().endsWith('.mp4')
            ? sourceName
            : '$sourceName.mp4',
      );
    } else {
      await runtime.deliver(source: task.outputPath!, destination: destination);
    }
    return task.copyWith(state: ExportState.delivered, progress: 100);
  }
}

enum ExportState {
  queued,
  preparing,
  muxing,
  validating,
  deliverable,
  delivered,
  cancelled,
  failed,
}

class Mp4ExportTask {
  const Mp4ExportTask({
    required this.id,
    required this.mediaTaskId,
    required this.state,
    this.outputPath,
    this.errorCode,
    this.progress = 0,
  });
  final String id;
  final String mediaTaskId;
  final ExportState state;
  final String? outputPath;
  final String? errorCode;
  final int progress;

  Mp4ExportTask copyWith({ExportState? state, int? progress}) => Mp4ExportTask(
    id: id,
    mediaTaskId: mediaTaskId,
    state: state ?? this.state,
    outputPath: outputPath,
    errorCode: errorCode,
    progress: progress ?? this.progress,
  );
}

class RelayAuthorization {
  const RelayAuthorization({
    required this.token,
    required this.sessionId,
    required this.expiresAt,
    required this.taskId,
    required this.deviceId,
  });
  final String token;
  final String sessionId;
  final DateTime expiresAt;
  final String taskId;
  final String deviceId;

  bool get expired => DateTime.now().toUtc().isAfter(expiresAt);
}

class RelayAuthorizer {
  const RelayAuthorizer();

  RelayAuthorization issue({
    required String sessionId,
    required String taskId,
    required String deviceId,
    Duration ttl = const Duration(minutes: 5),
  }) {
    if (ttl <= Duration.zero || ttl > const Duration(minutes: 15)) {
      throw ArgumentError('中继授权期限无效');
    }
    final random = Random.secure();
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    return RelayAuthorization(
      token: token,
      sessionId: sessionId,
      expiresAt: DateTime.now().toUtc().add(ttl),
      taskId: taskId,
      deviceId: deviceId,
    );
  }

  void validate(
    RelayAuthorization authorization, {
    required String token,
    required String sessionId,
    required String taskId,
    required String deviceId,
  }) {
    if (authorization.expired ||
        authorization.token != token ||
        authorization.sessionId != sessionId ||
        authorization.taskId != taskId ||
        authorization.deviceId != deviceId) {
      throw StateError(MediaErrorCode.relayDenied);
    }
  }
}

class RelayRequest {
  const RelayRequest({required this.method, this.range});
  final String method;
  final String? range;
}

class RelayRequestValidator {
  const RelayRequestValidator();

  ({int? start, int? end}) validate(RelayRequest request) {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      throw StateError(MediaErrorCode.relayDenied);
    }
    final raw = request.range;
    if (raw == null || raw.trim().isEmpty) return (start: null, end: null);
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(raw.trim());
    if (match == null) throw StateError(MediaErrorCode.relayDenied);
    final start = int.parse(match.group(1)!);
    final end = match.group(2)!.isEmpty ? null : int.parse(match.group(2)!);
    if (end != null && end < start) {
      throw StateError(MediaErrorCode.relayDenied);
    }
    return (start: start, end: end);
  }
}

/// A small, protocol-independent DLNA session state machine. The UPnP/SOAP
/// adapter owns transport details and calls these transitions after it has
/// received the corresponding device response.
class CastSessionController {
  CastSessionController({required this.tasks, RelayAuthorizer? relayAuthorizer})
    : relayAuthorizer = relayAuthorizer ?? const RelayAuthorizer();

  final MediaTaskStore tasks;
  final RelayAuthorizer relayAuthorizer;
  CastSession? _active;
  CastSession? get active => _active;

  CastSession begin({required CastDevice device, required String mediaTaskId}) {
    if (_active != null &&
        _active!.state != CastSessionState.stopped &&
        _active!.state != CastSessionState.failed) {
      throw StateError('已有投屏会话');
    }
    if (tasks.referenceTask(mediaTaskId) == null) throw StateError('媒体文件不存在');
    final session = CastSession(
      id: 'cast_${DateTime.now().microsecondsSinceEpoch}',
      deviceId: device.id,
      mediaTaskId: mediaTaskId,
      state: CastSessionState.discovering,
      createdAt: DateTime.now().toUtc(),
    );
    _active = session;
    tasks.retain(mediaTaskId);
    return session;
  }

  CastSession transition(CastSessionState next, {String? errorCode}) {
    final current = _active;
    if (current == null) throw StateError('投屏会话不存在');
    final allowed = switch (current.state) {
      CastSessionState.discovering => {
        CastSessionState.connecting,
        CastSessionState.failed,
        CastSessionState.stopped,
      },
      CastSessionState.connecting => {
        CastSessionState.settingMedia,
        CastSessionState.failed,
        CastSessionState.stopped,
      },
      CastSessionState.settingMedia => {
        CastSessionState.playing,
        CastSessionState.failed,
        CastSessionState.stopped,
      },
      CastSessionState.playing => {
        CastSessionState.paused,
        CastSessionState.stopped,
        CastSessionState.failed,
      },
      CastSessionState.paused => {
        CastSessionState.playing,
        CastSessionState.stopped,
        CastSessionState.failed,
      },
      CastSessionState.stopped => <CastSessionState>{},
      CastSessionState.failed => {CastSessionState.stopped},
    };
    if (!allowed.contains(next) && next != current.state) {
      throw StateError('非法投屏状态迁移 ${current.state.name} -> ${next.name}');
    }
    final updated = CastSession(
      id: current.id,
      deviceId: current.deviceId,
      mediaTaskId: current.mediaTaskId,
      state: next,
      createdAt: current.createdAt,
      relayToken: current.relayToken,
      errorCode: errorCode,
    );
    _active = updated;
    if ((next == CastSessionState.stopped || next == CastSessionState.failed) &&
        current.state != CastSessionState.stopped &&
        current.state != CastSessionState.failed) {
      tasks.release(current.mediaTaskId);
    }
    return updated;
  }

  RelayAuthorization authorizeRelay({
    required String deviceId,
    Duration ttl = const Duration(minutes: 5),
  }) {
    final session = _active;
    if (session == null ||
        session.state == CastSessionState.stopped ||
        session.state == CastSessionState.failed) {
      throw StateError(MediaErrorCode.relayDenied);
    }
    return relayAuthorizer.issue(
      sessionId: session.id,
      taskId: session.mediaTaskId,
      deviceId: deviceId,
      ttl: ttl,
    );
  }
}
