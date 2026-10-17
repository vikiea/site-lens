import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
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
    this.positionMs = 0,
    this.speed = 1,
    this.errorCode,
  });

  final String id;
  final String candidateId;
  final NativePlaybackState state;
  final int positionMs;
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
      speed: current.speed,
      errorCode: current.errorCode,
    );
    return _active!;
  }

  NativePlaybackSession setSpeed(double speed) {
    final current = _active;
    if (current == null || speed <= 0 || speed > 4) {
      throw RangeError('播放倍速无效');
    }
    _active = NativePlaybackSession(
      id: current.id,
      candidateId: current.candidateId,
      state: current.state,
      positionMs: current.positionMs,
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
    if (!candidate.playable || candidate.mediaUrl.scheme == 'blob') {
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
      final key = uri.removeFragment().toString();
      if (!seen.add(key)) continue;
      final title = (element['title'] as String? ?? '').trim();
      final mime = (element['mime'] as String? ?? '').trim();
      final candidate = MediaCandidate(
        id: 'dom:$hostId:$generation:${sha256.convert(utf8.encode(key))}',
        hostId: hostId,
        generation: generation,
        sourceUrl: sourceUrl,
        mediaUrl: uri.removeFragment(),
        title: title.length > 512 ? title.substring(0, 512) : title,
        mime: mime.length > 128 ? mime.substring(0, 128) : mime,
        source: MediaCandidateSource.dom,
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
  final _byCacheKey = <String, String>{};
  final _references = <String, int>{};
  MediaTask? task(String id) => _tasks[id];
  List<MediaTask> get tasks => List.unmodifiable(_tasks.values);

  String cacheKey(
    MediaCandidate candidate, {
    String quality = '',
    String audio = '',
  }) {
    final input = '${candidate.id}|${candidate.mediaUrl}|$quality|$audio';
    return sha256.convert(utf8.encode(input)).toString();
  }

  MediaTask create(
    MediaCandidate candidate, {
    String quality = '',
    String audio = '',
  }) {
    const validator = MediaCandidateValidator();
    validator.validate(candidate);
    final key = cacheKey(candidate, quality: quality, audio: audio);
    final existingId = _byCacheKey[key];
    final existing = existingId == null ? null : _tasks[existingId];
    if (existing != null &&
        existing.state != MediaTaskState.cancelled &&
        existing.state != MediaTaskState.failed) {
      return existing;
    }
    final id =
        'media_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final task = MediaTask(
      id: id,
      candidateId: candidate.id,
      hostId: candidate.hostId,
      generation: candidate.generation,
      sourceUrl: candidate.sourceUrl,
      cacheKey: key,
      state: MediaTaskState.queued,
      updatedAt: DateTime.now().toUtc(),
    );
    _tasks[id] = task;
    _byCacheKey[key] = id;
    if (db != null) unawaited(db!.saveMediaTask(task));
    return task;
  }

  Future<void> restore() async {
    final persisted = await db?.mediaTasks();
    if (persisted == null) return;
    _tasks
      ..clear()
      ..addEntries(persisted.map((task) => MapEntry(task.id, task)));
    _byCacheKey
      ..clear()
      ..addEntries(persisted.map((task) => MapEntry(task.cacheKey, task.id)));
  }

  MediaTask transition(String id, MediaTaskState state, {String? errorCode}) {
    final task = _tasks[id];
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
        MediaTaskState.playable,
        MediaTaskState.cancelled,
      },
      MediaTaskState.playable => {MediaTaskState.cancelled},
      MediaTaskState.reauthorize => {
        MediaTaskState.downloading,
        MediaTaskState.cancelled,
        MediaTaskState.failed,
      },
      MediaTaskState.cancelled || MediaTaskState.failed => <MediaTaskState>{},
    };
    if (!allowed.contains(state) && state != task.state) {
      throw StateError('非法媒体任务状态迁移 ${task.state.name} -> ${state.name}');
    }
    final next = task.copyWith(state: state, errorCode: errorCode);
    _tasks[id] = next;
    if (db != null) unawaited(db!.saveMediaTask(next));
    return next;
  }

  MediaTask updateProgress(String id, int bytesDownloaded, {int? totalBytes}) {
    final task = _tasks[id];
    if (task == null) throw StateError('媒体任务不存在');
    if (bytesDownloaded < 0 ||
        totalBytes != null && totalBytes < bytesDownloaded) {
      throw RangeError('媒体任务进度无效');
    }
    final next = task.copyWith(
      bytesDownloaded: bytesDownloaded,
      totalBytes: totalBytes ?? task.totalBytes,
    );
    _tasks[id] = next;
    if (db != null) unawaited(db!.saveMediaTask(next));
    return next;
  }

  MediaTask setLocalRef(String id, String? localRef) {
    final task = _tasks[id];
    if (task == null) throw StateError('媒体任务不存在');
    final next = task.copyWith(localRef: localRef);
    _tasks[id] = next;
    if (db != null) unawaited(db!.saveMediaTask(next));
    return next;
  }

  void retain(String taskId) {
    if (!_tasks.containsKey(taskId)) throw StateError('媒体任务不存在');
    _references[taskId] = (_references[taskId] ?? 0) + 1;
  }

  void release(String taskId) {
    final count = _references[taskId] ?? 0;
    if (count <= 1) {
      _references.remove(taskId);
    } else {
      _references[taskId] = count - 1;
    }
  }

  bool canDelete(String taskId) => (_references[taskId] ?? 0) == 0;

  Future<void> delete(String taskId) async {
    if (!canDelete(taskId)) throw StateError('媒体任务仍被播放、导出或投屏占用');
    _tasks.remove(taskId);
    _byCacheKey.removeWhere((_, id) => id == taskId);
    // Keep completed task metadata for recovery unless the caller explicitly
    // asks to delete it from the durable store.
    await db?.deleteMediaTask(taskId);
  }

  Future<Directory> cacheDirectory() async {
    final root = await _directoryProvider();
    final directory = Directory('${root.path}/media_cache');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File?> cachedFile(String taskId) async {
    final task = _tasks[taskId];
    final ref = task?.localRef;
    if (ref == null) return null;
    final root = (await cacheDirectory()).absolute.path;
    final file = File(ref).absolute;
    if (!file.path.startsWith('$root${Platform.pathSeparator}')) {
      throw StateError('缓存引用越界');
    }
    return await file.exists() ? file : null;
  }
}

/// Resumable, app-private media download orchestration. The native Media3
/// implementation can replace this transport while keeping the same task
/// states and cache keys.
class MediaDownloadService {
  MediaDownloadService({required this.tasks, ControlledHttp? http, this.native})
    : http = http ?? ControlledHttp();

  final MediaTaskStore tasks;
  final ControlledHttp http;

  /// Optional Android OS-managed backend. The deterministic Dart backend stays
  /// available for tests and platforms without DownloadManager.
  final NativeDownloadRuntime? native;
  final _active = <String, Cancellation>{};

  Future<MediaTask> startNative(
    MediaTask task,
    MediaCandidate candidate,
  ) async {
    final runtime = native;
    if (runtime == null) return start(task, candidate);
    const validator = MediaCandidateValidator();
    validator.validate(
      candidate,
      hostId: task.hostId,
      generation: task.generation,
      sourceUrl: task.sourceUrl,
    );
    if (task.candidateId != candidate.id) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    var current = tasks.task(task.id) ?? task;
    if (current.state == MediaTaskState.queued ||
        current.state == MediaTaskState.paused) {
      current = tasks.transition(task.id, MediaTaskState.downloading);
    }
    Map<String, Object?> status;
    try {
      status = await runtime.start(current, candidate);
    } catch (error) {
      if (tasks.task(task.id)?.state == MediaTaskState.downloading) {
        tasks.transition(
          task.id,
          MediaTaskState.failed,
          errorCode:
              error is StateError && error.message.toString().contains('授权')
              ? MediaErrorCode.authorizationRequired
              : MediaErrorCode.network,
        );
      }
      rethrow;
    }
    final state = status['state'] as String?;
    final bytes = (status['bytesDownloaded'] as num?)?.toInt();
    final total = (status['totalBytes'] as num?)?.toInt();
    if (bytes != null) {
      current = tasks.updateProgress(task.id, bytes, totalBytes: total);
    }
    if (state == 'completed') {
      current = tasks.transition(task.id, MediaTaskState.completed);
      current = tasks.transition(task.id, MediaTaskState.playable);
    } else if (state == 'failed') {
      current = tasks.transition(
        task.id,
        MediaTaskState.failed,
        errorCode: MediaErrorCode.network,
      );
    }
    return current;
  }

  Future<MediaTask> start(
    MediaTask task,
    MediaCandidate candidate, {
    int maxBytes = 2 * 1024 * 1024 * 1024,
  }) async {
    const validator = MediaCandidateValidator();
    validator.validate(
      candidate,
      hostId: task.hostId,
      generation: task.generation,
      sourceUrl: task.sourceUrl,
    );
    if (task.candidateId != candidate.id) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    final cancel = Cancellation();
    _active[task.id] = cancel;
    var current = tasks.task(task.id) ?? task;
    try {
      current = tasks.transition(task.id, MediaTaskState.downloading);
      final directory = await tasks.cacheDirectory();
      final base = File('${directory.path}/${task.cacheKey}.part');
      final finalFile = File('${directory.path}/${task.cacheKey}.media');
      final offset = await base.exists() ? await base.length() : 0;
      final response = await http.fetch(
        candidate.mediaUrl,
        connect: const {'*'},
        document: candidate.sourceUrl,
        cancel: cancel,
        headers: offset == 0 ? const {} : {'Range': 'bytes=$offset-'},
        maxBytes: maxBytes,
      );
      cancel.check();
      final append = offset > 0 && response.status == 206;
      if (offset > 0 && !append) {
        // A server that ignored Range would duplicate bytes. Start over only
        // after proving the response was a complete 200 body.
        await base.delete();
      }
      final sink = base.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      await sink.addStream(Stream<List<int>>.fromIterable([response.bytes]));
      await sink.close();
      cancel.check();
      final size = await base.length();
      if (size == 0) throw StateError('媒体响应为空');
      await base.rename(finalFile.path);
      current = tasks.updateProgress(
        task.id,
        size,
        totalBytes: _contentLength(response, size, offset, append),
      );
      current = tasks.transition(task.id, MediaTaskState.completed);
      current = tasks.transition(task.id, MediaTaskState.playable);
      return tasks.setLocalRef(task.id, finalFile.path);
    } on Cancelled {
      if (tasks.task(task.id)?.state == MediaTaskState.downloading) {
        current = tasks.transition(task.id, MediaTaskState.paused);
      }
      return current;
    } on StateError catch (error) {
      if (tasks.task(task.id)?.state == MediaTaskState.downloading) {
        final code = error.message.contains('授权')
            ? MediaErrorCode.authorizationRequired
            : MediaErrorCode.network;
        current = tasks.transition(
          task.id,
          MediaTaskState.failed,
          errorCode: code,
        );
      }
      rethrow;
    } finally {
      _active.remove(task.id);
    }
  }

  void pause(String taskId) => _active[taskId]?.cancel();

  static int _contentLength(
    FetchResponse response,
    int size,
    int offset,
    bool append,
  ) {
    final raw = response.headers[HttpHeaders.contentLengthHeader];
    final length = raw == null ? null : int.tryParse(raw);
    if (length == null) return size;
    return append ? offset + length : length;
  }
}

/// Validates a local HLS task before handing it to a native muxer.  No remote
/// URI, path traversal, or missing segment can reach FFmpeg.
class HlsInputValidator {
  const HlsInputValidator();

  List<Uri> validate({
    required Uri playlist,
    required List<Uri> segments,
    Uri? initSegment,
    List<Uri> keys = const [],
  }) {
    if (playlist.scheme != 'file' || playlist.path.isEmpty) {
      throw const FormatException('HLS 清单必须来自本地缓存');
    }
    final root = File(playlist.toFilePath()).parent.absolute;
    final rootPath = root.existsSync()
        ? root.resolveSymbolicLinksSync()
        : root.path;
    final all = <Uri>[playlist, ...segments, ?initSegment, ...keys];
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
      if (!file.existsSync()) {
        throw const FormatException('HLS 输入分片缺失');
      }
    }
    return List.unmodifiable(all);
  }
}

class HlsCacheInput {
  const HlsCacheInput({
    required this.playlist,
    required this.segments,
    this.initSegment,
    this.keys = const [],
  });

  final Uri playlist;
  final List<Uri> segments;
  final Uri? initSegment;
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
    Uri? init;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#EXTM3U')) continue;
      if (line.startsWith('#EXT-X-MAP:')) {
        final value = _attribute(line, 'URI');
        if (value != null) init = _local(base, value);
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        final method = _attribute(line, 'METHOD');
        final value = _attribute(line, 'URI');
        if (method != null && method != 'NONE' && value != null) {
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
      keys: List.unmodifiable(keys),
    );
  }

  String? _attribute(String line, String name) {
    final match = RegExp('$name="([^"]+)"').firstMatch(line);
    return match?.group(1);
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
/// Dart layer can be tested without shipping an FFmpeg binary; production
/// supplies the fixed-version JNI implementation.
class Mp4ExportService {
  Mp4ExportService({
    required this.tasks,
    this._muxer,
    this.native,
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final MediaTaskStore tasks;
  final Mp4Muxer? _muxer;
  final NativeExportRuntime? native;
  final Future<Directory> Function() _directoryProvider;

  Future<Mp4ExportTask> export(
    String taskId,
    HlsCacheInput input, {
    Cancellation? cancellation,
  }) async {
    final task = tasks.task(taskId);
    if (task == null) throw StateError('媒体任务不存在');
    if (task.state != MediaTaskState.completed &&
        task.state != MediaTaskState.playable) {
      throw StateError('媒体缓存尚未完成');
    }
    const validator = HlsInputValidator();
    validator.validate(
      playlist: input.playlist,
      segments: input.segments,
      initSegment: input.initSegment,
      keys: input.keys,
    );
    final cancel = cancellation ?? Cancellation();
    final root = await _directoryProvider();
    final outputDirectory = Directory('${root.path}/media_exports');
    await outputDirectory.create(recursive: true);
    final id = 'export_${DateTime.now().microsecondsSinceEpoch}';
    final output = File('${outputDirectory.path}/$id.mp4');
    final temporary = File('${output.path}.part');
    tasks.retain(taskId);
    try {
      cancel.check();
      final muxer = _muxer;
      if (muxer != null) {
        await muxer(
          input: input,
          outputPath: temporary.path,
          onProgress: (_) {},
          cancellation: cancel,
        );
      } else if (native != null) {
        await native!.muxHls(
          playlist: input.playlist.toFilePath(),
          output: temporary.path,
        );
      } else {
        throw StateError(MediaErrorCode.unsupported);
      }
      cancel.check();
      if (!await temporary.exists() || await temporary.length() == 0) {
        throw StateError('导出文件为空');
      }
      await temporary.rename(output.path);
      return Mp4ExportTask(
        id: id,
        mediaTaskId: taskId,
        state: ExportState.deliverable,
        outputPath: output.path,
      );
    } on Cancelled {
      if (await temporary.exists()) await temporary.delete();
      return Mp4ExportTask(
        id: id,
        mediaTaskId: taskId,
        state: ExportState.cancelled,
        outputPath: output.path,
        errorCode: MediaErrorCode.cancelled,
      );
    } catch (error) {
      if (await temporary.exists()) await temporary.delete();
      return Mp4ExportTask(
        id: id,
        mediaTaskId: taskId,
        state: ExportState.failed,
        outputPath: output.path,
        errorCode: error is StateError ? error.message : 'export_failed',
      );
    } finally {
      tasks.release(taskId);
    }
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
  });
  final String id;
  final String mediaTaskId;
  final ExportState state;
  final String? outputPath;
  final String? errorCode;
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
    final token = sha256
        .convert(
          utf8.encode(
            '$sessionId|$taskId|$deviceId|${DateTime.now().microsecondsSinceEpoch}',
          ),
        )
        .toString();
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
    if (_active != null && _active!.state != CastSessionState.stopped) {
      throw StateError('已有投屏会话');
    }
    if (tasks.task(mediaTaskId) == null) throw StateError('媒体任务不存在');
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
      },
      CastSessionState.connecting => {
        CastSessionState.settingMedia,
        CastSessionState.failed,
      },
      CastSessionState.settingMedia => {
        CastSessionState.playing,
        CastSessionState.failed,
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
      CastSessionState.stopped ||
      CastSessionState.failed => <CastSessionState>{},
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
    if (next == CastSessionState.stopped || next == CastSessionState.failed) {
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
