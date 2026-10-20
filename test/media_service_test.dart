import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/network/transport.dart';

class FakeNativeDownloads extends NativeDownloadRuntime {
  FakeNativeDownloads() : super(channel: const MethodChannel('fake_downloads'));

  final statuses = <String, Map<String, Object?>>{};
  final calls = <String>[];

  @override
  Future<Map<String, Object?>> start(
    MediaTask task,
    MediaCandidate candidate, {
    String? title,
    String? storageDirectory,
  }) async {
    calls.add('start:${task.id}');
    return statuses[task.id] ?? {'state': 'downloading'};
  }

  @override
  Future<Map<String, Object?>> status(String taskId) async =>
      statuses[taskId] ?? {'state': 'missing'};

  @override
  Future<void> pause(String taskId) async => calls.add('pause:$taskId');

  @override
  Future<void> cancel(String taskId) async => calls.add('cancel:$taskId');

  @override
  Future<void> delete(String taskId) async => calls.add('delete:$taskId');

  @override
  Future<Map<String, Object?>> resume(String taskId) async {
    calls.add('resume:$taskId');
    return statuses[taskId] ?? {'state': 'downloading'};
  }
}

MediaCandidate candidate({
  String id = 'candidate-1',
  String url = 'https://cdn.example/video.mp4',
  String mime = 'video/mp4',
  String title = 'video',
}) => MediaCandidate(
  id: id,
  hostId: 7,
  generation: 3,
  sourceUrl: Uri.parse('https://example.com/watch'),
  mediaUrl: Uri.parse(url),
  title: title,
  mime: mime,
  source: MediaCandidateSource.dom,
);

void main() {
  test('media task freezes the title and episode at creation', () {
    final store = MediaTaskStore();
    final task = store.create(candidate(title: '母衣半暖默许春朝 - 第3集'));
    expect(task.displayTitle, '母衣半暖默许春朝 - 第3集');
    expect(task.episodeLabel, '第3集');
    expect(task.displayName, '母衣半暖默许春朝 - 第3集');
  });

  test('media task prefers the episode marker in the media URL', () {
    final task = MediaTaskStore().create(
      candidate(
        title: '母衣半暖默许春朝 - 第1集',
        url: 'https://cdn.example/episode-3/video.mp4',
      ),
    );
    expect(task.episodeLabel, '第3集');
  });

  test('explicit episode titles replace stale page episode markers', () {
    expect(mediaTitleForEpisode('母衣半暖默许春朝 - 第4集', 7), '母衣半暖默许春朝 - 第7集');
  });

  test(
    'restoring a reused candidate ID keeps the task episode snapshot',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final original = candidate(
        id: 'reused',
        title: '系列 - 第7集',
        url: 'https://cdn.example/episode-7/index.m3u8',
      );
      await db.saveMediaCandidate(original);
      final firstStore = MediaTaskStore(db: db);
      final task = firstStore.create(original);
      await db.saveMediaTask(task);
      final replacement = candidate(
        id: 'reused',
        title: '系列 - 第8集',
        url: 'https://cdn.example/episode-8/index.m3u8',
      );
      await db.saveMediaCandidate(replacement);
      final restored = MediaTaskStore(db: db);

      await restored.restore();

      expect(restored.task(task.id)!.episodeLabel, '第7集');
    },
  );

  test('media candidate persistence refreshes a signed URL but rejects identity changes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final original = candidate(
      id: 'rotating',
      url: 'https://cdn.example/live/index.m3u8?token=old',
      mime: 'application/vnd.apple.mpegurl',
      title: '系列 - 第7集',
    );
    await db.saveMediaCandidate(original);
    await db.saveMediaCandidate(
      candidate(
        id: 'rotating',
        url: 'https://cdn.example/live/index.m3u8?token=new',
        mime: original.mime,
        title: original.title,
      ),
    );
    expect(
      (await db.mediaCandidate('rotating'))!.mediaUrl.queryParameters['token'],
      'new',
    );

    await db.saveMediaCandidate(
      candidate(
        id: 'rotating',
        url: 'https://cdn.example/other/index.m3u8?token=wrong',
        mime: original.mime,
        title: original.title,
      ),
    );
    expect(
      (await db.mediaCandidate('rotating'))!.mediaUrl.path,
      '/live/index.m3u8',
    );
  });

  test('media tasks deduplicate observation IDs for the same stream', () {
    final store = MediaTaskStore();
    final first = store.create(candidate(id: 'observation-1'));
    final second = store.create(candidate(id: 'observation-2'));
    expect(second.id, first.id);
    expect(store.tasks, hasLength(1));
  });

  test('explicit reauthorization rebinds a new observation without losing partial progress', () {
    final store = MediaTaskStore();
    final first = candidate(id: 'old-observation');
    final task = store.create(first);
    store.transition(task.id, MediaTaskState.downloading);
    store.updateProgress(task.id, 256);
    store.transition(task.id, MediaTaskState.reauthorize);
    final replacement = store.create(candidate(id: 'new-observation'));
    expect(replacement.id, task.id);
    expect(replacement.candidateId, 'new-observation');
    expect(replacement.bytesDownloaded, 256);
    expect(replacement.cacheKey, task.cacheKey);
    expect(store.tasks, hasLength(1));
  });

  test('series directory names remove episode markers safely', () {
    expect(mediaSeriesDirectoryName('母衣半暖默许春朝 - 第3集'), '母衣半暖默许春朝');
    expect(mediaSeriesDirectoryName('A/B: episode=12'), 'A_B');
    expect(mediaSeriesDirectoryName(''), '未命名媒体');
  });

  test('batch directory becomes the storage directory', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-batch-');
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(
      candidate(title: '系列 - 第1集'),
      batchDirectory: '批量下载一',
    );
    expect(task.storageDirectoryName, '批量下载一');
    final directory = await store.cacheDirectory(
      storageDirectory: task.storageDirectoryName,
    );
    expect(directory.path, endsWith('/media_cache/批量下载一'));
  });

  test('media playlist groups one series and sorts episodes', () {
    final store = MediaTaskStore();
    final first = store.create(
      candidate(
        title: '系列 - 第1集',
        id: 'episode-1',
        url: 'https://cdn.example/episode-1.mp4',
      ),
    );
    final second = store.create(
      candidate(
        title: '系列 - 第2集',
        id: 'episode-2',
        url: 'https://cdn.example/episode-2.mp4',
      ),
    );
    final other = store.create(
      candidate(
        title: '其他系列 - 第1集',
        id: 'other-1',
        url: 'https://cdn.example/other-1.mp4',
      ),
    );
    for (final task in [first, second, other]) {
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
    }

    final playlist = mediaPlaylistForTasks(store.tasks, second);
    expect(playlist.map((task) => task.episodeLabel), ['第1集', '第2集']);
  });

  test('media retry clears the previous human-readable failure reason', () {
    final store = MediaTaskStore();
    final task = store.create(candidate());
    store.transition(task.id, MediaTaskState.downloading);
    final failed = store.transition(
      task.id,
      MediaTaskState.failed,
      errorCode: MediaErrorCode.network,
      errorReason: '网络连接中断，请重试',
    );
    expect(failed.errorReason, '网络连接中断，请重试');
    final retrying = store.transition(task.id, MediaTaskState.downloading);
    expect(retrying.errorCode, isNull);
    expect(retrying.errorReason, isNull);
  });

  test('native playback controller enforces one session and safe controls', () {
    final controller = NativePlaybackController();
    final opening = controller.open(
      candidate(),
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
    );
    expect(opening.state, NativePlaybackState.preparing);
    expect(
      controller.transition(NativePlaybackState.playing).state,
      NativePlaybackState.playing,
    );
    expect(controller.seek(1200).positionMs, 1200);
    expect(controller.setSpeed(1.5).speed, 1.5);
    expect(controller.setSpeed(8).speed, 8);
    expect(() => controller.setSpeed(8.1), throwsRangeError);
    expect(
      () => controller.transition(NativePlaybackState.completed),
      returnsNormally,
    );
    expect(() => controller.seek(10), throwsStateError);
    final replacement = controller.open(
      candidate(url: 'https://cdn.example/other.mp4'),
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
    );
    expect(replacement.id, isNot(opening.id));
    expect(replacement.state, NativePlaybackState.preparing);
  });

  test('DOM collector rejects blob URLs and de-duplicates safe media URLs', () {
    final values = const MediaCandidateCollector().fromDom(
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
      elements: [
        {'url': 'https://cdn.example/video.mp4', 'mime': 'video/mp4'},
        {'url': 'https://cdn.example/video.mp4#fragment'},
        {'url': 'https://cdn.example/live/index.m3u8?token=one'},
        {'url': 'https://cdn.example/live/index.m3u8?token=two'},
        {'url': 'blob:https://example.com/id'},
        {'url': 'file:///private/video.mp4'},
      ],
    );
    expect(values, hasLength(2));
    expect(
      values.map((value) => value.effectiveMime),
      containsAll(['video/mp4', 'application/vnd.apple.mpegurl']),
    );
  });

  test('signed HLS observations share one session group', () {
    expect(
      mediaCandidateGroupKey(
        Uri.parse('https://cdn.example/live/index.m3u8?token=one'),
      ),
      mediaCandidateGroupKey(
        Uri.parse('https://cdn.example/live/index.m3u8?token=two'),
      ),
    );
  });

  test('HLS transport segments are never selectable media', () {
    final segment = candidate(
      url: 'https://cdn.example/live/segment0.ts?auth=short-lived',
      mime: 'video/mp2t',
    );
    expect(segment.isLikelyTransportSegment, isTrue);
    expect(
      () => const MediaCandidateValidator().validate(segment),
      throwsFormatException,
    );
  });

  test('titled HLS observations collapse to one display candidate', () {
    final first = candidate(
      url: 'https://cdn.example/live/index.m3u8?token=one',
      mime: 'application/vnd.apple.mpegurl',
    );
    final second = MediaCandidate(
      id: 'candidate-2',
      hostId: first.hostId,
      generation: first.generation,
      sourceUrl: first.sourceUrl,
      mediaUrl: Uri.parse('https://cdn.example/live/index.m3u8?token=two'),
      title: first.title,
      mime: first.mime,
      source: first.source,
    );
    expect(
      mediaCandidateDisplayGroupKey(first),
      mediaCandidateDisplayGroupKey(second),
    );
  });

  test('HLS downloads a local playlist, segments and encryption key', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-hls-download-',
    );
    addTearDown(() => root.delete(recursive: true));
    final playlistUrl = Uri.parse('https://cdn.example/video/index.m3u8');
    final http = _MapHttp({
      playlistUrl.toString(): FetchResponse(
        url: playlistUrl,
        status: 200,
        bytes: utf8.encode(
          '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI=key.bin\n'
          '#EXTINF:1,\nseg.ts\n'
          '#EXT-X-ENDLIST\n',
        ),
        headers: const {},
      ),
      'https://cdn.example/video/key.bin': FetchResponse(
        url: Uri.parse('https://cdn.example/video/key.bin'),
        status: 200,
        bytes: [1, 2, 3, 4],
        headers: {},
      ),
      'https://cdn.example/video/seg.ts': FetchResponse(
        url: Uri.parse('https://cdn.example/video/seg.ts'),
        status: 200,
        bytes: [5, 6, 7],
        headers: {},
      ),
    });
    final store = MediaTaskStore(directoryProvider: () async => root);
    final hls = candidate(
      url: playlistUrl.toString(),
      mime: 'application/vnd.apple.mpegurl',
    );
    final task = store.create(hls);
    final result = await MediaDownloadService(
      tasks: store,
      http: http,
    ).start(task, hls);
    expect(result.state, MediaTaskState.playable);
    expect(result.bytesDownloaded, greaterThan(0));
    final cached = await store.cachedFile(task.id);
    expect(cached, isNotNull);
    expect(await cached!.readAsString(), contains('resource_'));
    final cachedInput = const HlsPlaylistParser().parse(
      cached.uri,
      await cached.readAsString(),
    );
    expect(cachedInput.keys, hasLength(1));
    expect(
      cachedInput.keys.single.path,
      matches(RegExp(r'.*/resource_[0-9a-f]{64}\.bin$')),
    );
    expect(cached.parent.listSync(), hasLength(3));
    expect(http.calls, hasLength(3));
  });

  test(
    'direct media download resumes from bytes flushed before a reset',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-resume-');
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final media = candidate(url: 'https://cdn.example/video.mp4');
      final task = store.create(media);
      final http = _InterruptingHttp();

      final result = await MediaDownloadService(
        tasks: store,
        http: http,
      ).start(task, media);

      expect(result.state, MediaTaskState.playable);
      expect(http.offsets, [0, 3]);
      expect(await (await store.cachedFile(task.id))!.readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
        6,
      ]);
    },
  );

  test('native task reconciliation restores progress, local URI and playable state', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-native-task-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final cache = await store.cacheDirectory();
    final file = File('${cache.path}/cached.media')
      ..writeAsBytesSync([1, 2, 3]);
    final task = store.create(candidate());
    store.transition(task.id, MediaTaskState.downloading);
    final native = FakeNativeDownloads();
    native.statuses[task.id] = {
      'state': 'completed',
      'bytesDownloaded': 3,
      'totalBytes': 3,
      'localUri': file.uri.toString(),
    };
    await MediaDownloadService(tasks: store, native: native).reconcileNative();
    expect(store.task(task.id)?.state, MediaTaskState.playable);
    expect(store.task(task.id)?.bytesDownloaded, 3);
    expect(store.task(task.id)?.localRef, file.path);
    expect(await store.cachedFile(task.id), isNotNull);
  });

  test(
    'native pause/resume keeps the task state and records backend calls',
    () async {
      final store = MediaTaskStore();
      final task = store.create(candidate());
      final native = FakeNativeDownloads();
      final service = MediaDownloadService(tasks: store, native: native);
      native.statuses[task.id] = {'state': 'downloading'};
      await service.startNative(task, candidate());
      expect(store.task(task.id)?.state, MediaTaskState.downloading);
      await service.pauseNative(task.id);
      expect(store.task(task.id)?.state, MediaTaskState.paused);
      await service.resumeNative(task.id, candidate());
      expect(store.task(task.id)?.state, MediaTaskState.downloading);
      expect(native.calls, [
        'start:${task.id}',
        'pause:${task.id}',
        'start:${task.id}',
      ]);
    },
  );

  test(
    'delete acquires the task lock before cancelling native transport',
    () async {
      final store = MediaTaskStore();
      final task = store.create(candidate());
      final native = FakeNativeDownloads();
      final service = MediaDownloadService(tasks: store, native: native);
      store.retain(task.id);

      await expectLater(service.delete(task.id), throwsStateError);

      expect(native.calls, isEmpty);
      expect(store.task(task.id), isNotNull);
      store.release(task.id);
    },
  );

  test(
    'delete waits through cleanup and removes partial files and task row',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-delete-task-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate(title: '系列 - 第1集'));
      final directory = await store.cacheDirectory(
        storageDirectory: task.storageDirectoryName,
      );
      final partial = File('${directory.path}/${task.cacheKey}.part')
        ..writeAsBytesSync([1, 2]);
      final staging = Directory('${directory.path}/${task.cacheKey}.hls.part')
        ..createSync();
      File('${staging.path}/segment.part').writeAsBytesSync([3]);
      final native = FakeNativeDownloads();
      final service = MediaDownloadService(tasks: store, native: native);

      await service.delete(task.id);

      expect(await partial.exists(), isFalse);
      expect(await staging.exists(), isFalse);
      expect(store.task(task.id), isNull);
      expect(native.calls, ['cancel:${task.id}', 'delete:${task.id}']);
    },
  );

  test(
    'refreshTask ignores a missing native row for an active Dart task',
    () async {
      final store = MediaTaskStore();
      final task = store.create(candidate());
      store.transition(task.id, MediaTaskState.downloading);
      final native = FakeNativeDownloads();
      final refreshed = await MediaDownloadService(
        tasks: store,
        native: native,
      ).refreshTask(task.id);
      expect(refreshed.state, MediaTaskState.downloading);
    },
  );

  test('HTTP failures do not become playable cache entries', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-http-failure-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate());
    final http = _StatusHttp(404);
    final service = MediaDownloadService(tasks: store, http: http);
    await expectLater(
      service.start(task, candidate()),
      throwsA(isA<StateError>()),
    );
    expect(store.task(task.id)?.state, MediaTaskState.failed);
    expect(
      store.transition(task.id, MediaTaskState.downloading).state,
      MediaTaskState.downloading,
    );
  });

  test(
    'HLS 403 moves the task to reauthorize with actionable context',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-hls-403-');
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final media = candidate(
        url: 'https://cdn.example/live/index.m3u8?token=expired',
        mime: 'application/vnd.apple.mpegurl',
      );
      final task = store.create(media);
      await expectLater(
        MediaDownloadService(
          tasks: store,
          http: _StatusHttp(403),
        ).start(task, media),
        throwsA(isA<StateError>()),
      );
      final failed = store.task(task.id)!;
      expect(failed.state, MediaTaskState.reauthorize);
      expect(failed.errorCode, MediaErrorCode.authorizationRequired);
      expect(failed.errorReason, contains('返回播放页'));
    },
  );

  test(
    'media task store protects active references and restores state',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-media-');
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      expect(
        store.transition(task.id, MediaTaskState.downloading).state,
        MediaTaskState.downloading,
      );
      final completed = store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      store.retain(task.id);
      await expectLater(store.delete(task.id), throwsStateError);
      store.release(task.id);
      await store.delete(task.id);
      expect(store.task(completed.id), isNull);
    },
  );

  test('missing playable cache becomes a retryable task failure', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-missing-');
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate());
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.playable);
    store.setLocalRef(task.id, '${root.path}/missing/index.m3u8');

    await store.reconcileCachedFiles();

    final repaired = store.task(task.id)!;
    expect(repaired.state, MediaTaskState.failed);
    expect(repaired.errorCode, MediaErrorCode.cacheMissing);
    expect(repaired.errorReason, '文件缺失，请重新下载');
    expect(repaired.localRef, isNull);
  });

  test('zero-byte HLS resources are treated as a missing cache', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-zero-hls-');
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate(url: 'https://cdn.example/live.m3u8'));
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.playable);
    final cache = await store.cacheDirectory(
      seriesDirectory: task.seriesDirectoryName,
    );
    final playlist = File('${cache.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nsegment.ts\n');
    File('${cache.path}/segment.ts').createSync();
    store.setLocalRef(task.id, playlist.path);

    await store.reconcileCachedFiles();

    expect(store.task(task.id)!.state, MediaTaskState.failed);
    expect(store.task(task.id)!.errorCode, MediaErrorCode.cacheMissing);
  });

  test('exclusive media operations block new playback references', () {
    final store = MediaTaskStore();
    final task = store.create(candidate());
    store.acquireExclusive(task.id);
    expect(() => store.retain(task.id), throwsStateError);
    store.releaseExclusive(task.id);
    store.retain(task.id);
    expect(() => store.acquireExclusive(task.id), throwsStateError);
    store.release(task.id);
  });

  test('deleting one HLS task cache preserves adjacent episodes', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-delete-cache-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate(title: '系列 - 第1集'));
    final directory = await store.cacheDirectory(seriesDirectory: '系列');
    final cache = Directory('${directory.path}/${task.cacheKey}.hls')
      ..createSync();
    final playlist = File('${cache.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\nsegment.ts\n');
    File('${cache.path}/segment.ts').writeAsBytesSync([1]);
    final adjacent = File('${directory.path}/other-episode.marker')
      ..writeAsStringSync('keep');
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.playable);
    store.setLocalRef(task.id, playlist.path);

    await store.deleteCachedFiles(task.id);

    expect(await cache.exists(), isFalse);
    expect(await adjacent.exists(), isTrue);
    expect(store.task(task.id)!.state, MediaTaskState.failed);
    expect(store.task(task.id)!.errorCode, MediaErrorCode.cacheMissing);
  });

  test('HLS parser and validator accept only local complete inputs', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-');
    addTearDown(() => root.delete(recursive: true));
    final playlist = File('${root.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
    final segment = File('${root.path}/seg.ts')..writeAsBytesSync([0, 1, 2]);
    final input = const HlsPlaylistParser().parse(
      playlist.uri,
      await playlist.readAsString(),
    );
    expect(input.segments.single.path, segment.path);
    expect(
      const HlsInputValidator().validate(
        playlist: input.playlist,
        segments: input.segments,
      ),
      hasLength(2),
    );
    expect(
      () => const HlsInputValidator().validate(
        playlist: Uri.parse('https://cdn.example/index.m3u8'),
        segments: const [],
      ),
      throwsFormatException,
    );
  });

  test('HLS attributes accept unquoted encryption method and URI', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-hls-attributes-',
    );
    addTearDown(() => root.delete(recursive: true));
    final playlist = File('${root.path}/index.m3u8')
      ..writeAsStringSync(
        '#EXTM3U\n'
        '#EXT-X-KEY:METHOD=AES-128,URI=key.bin\n'
        '#EXTINF:1,\nseg.ts\n',
      );
    final key = File('${root.path}/key.bin')
      ..writeAsBytesSync(List.filled(16, 1));
    final segment = File('${root.path}/seg.ts')..writeAsBytesSync([0, 1, 2]);

    final input = const HlsPlaylistParser().parse(
      playlist.uri,
      await playlist.readAsString(),
    );

    expect(input.keys.single.path, key.path);
    expect(input.segments.single.path, segment.path);
  });

  test(
    'MP4 export reports progress and leaves a validated deliverable',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-export-');
      addTearDown(() => root.delete(recursive: true));
      final playlist = File('${root.path}/index.m3u8')
        ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
      final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1, 2, 3]);
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      final progress = <int>[];
      final service = Mp4ExportService(
        tasks: store,
        directoryProvider: () async => root,
        muxer:
            ({
              required HlsCacheInput input,
              required String outputPath,
              required void Function(int) onProgress,
              required Cancellation cancellation,
            }) async {
              expect(input.segments.single.path, segment.path);
              onProgress(50);
              await File(outputPath).writeAsBytes([9, 8, 7]);
            },
      );
      final successful = await service.export(
        task.id,
        HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
        onProgress: progress.add,
      );
      expect(successful.state, ExportState.deliverable);
      expect(await File(successful.outputPath!).exists(), isTrue);
      expect(store.task(task.id)?.localRef, isNull);
      expect(progress, containsAllInOrder([0, 50, 100]));
    },
  );

  test(
    'MP4 export keeps a Drift-backed task store out of the isolate message',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-export-drift-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final playlist = File('${root.path}/index.m3u8')
        ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
      final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1, 2, 3]);
      final store = MediaTaskStore(
        db: database,
        directoryProvider: () async => root,
      );
      final media = candidate();
      await database.saveMediaCandidate(media);
      final task = store.create(media);
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      final service = Mp4ExportService(
        tasks: store,
        directoryProvider: () async => root,
        muxer:
            ({
              required HlsCacheInput input,
              required String outputPath,
              required void Function(int) onProgress,
              required Cancellation cancellation,
            }) async {
              await File(outputPath).writeAsBytes([9, 8, 7]);
            },
      );

      final result = await service.export(
        task.id,
        HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
      );

      expect(result.state, ExportState.deliverable);
      expect(await File(result.outputPath!).readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'cancelled MP4 export removes the temporary output but keeps the task',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-export-cancel-',
      );
      addTearDown(() => root.delete(recursive: true));
      final playlist = File('${root.path}/index.m3u8')
        ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
      final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1]);
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      final cancel = Cancellation();
      final service = Mp4ExportService(
        tasks: store,
        directoryProvider: () async => root,
        muxer:
            ({
              required HlsCacheInput input,
              required String outputPath,
              required void Function(int) onProgress,
              required Cancellation cancellation,
            }) async {
              await File(outputPath).writeAsBytes([1, 2, 3]);
              cancellation.cancel();
              cancellation.check();
            },
      );
      final result = await service.export(
        task.id,
        HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
        cancellation: cancel,
      );
      expect(result.state, ExportState.cancelled);
      expect(store.task(task.id), isNotNull);
      expect(Directory('${root.path}/media_exports').listSync(), isEmpty);
    },
  );

  test(
    'HLS parser selects a local master variant without following network URLs',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-hls-master-',
      );
      addTearDown(() => root.delete(recursive: true));
      final low = Directory('${root.path}/low')..createSync();
      final high = Directory('${root.path}/high')..createSync();
      File('${low.path}/index.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXTINF:1,\nlow.ts\n');
      File('${high.path}/index.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXTINF:1,\nhigh.ts\n');
      File('${low.path}/low.ts').writeAsBytesSync([1]);
      File('${high.path}/high.ts').writeAsBytesSync([2]);
      final master = File('${root.path}/master.m3u8')
        ..writeAsStringSync(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nhigh/index.m3u8\n',
        );
      final input = await const HlsPlaylistParser().parseFile(master.uri);
      expect(input.segments.single.path, '${high.path}/high.ts');
      final remote = File('${root.path}/remote.m3u8')
        ..writeAsStringSync(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3\nhttps://cdn.example/high.m3u8\n',
        );
      await expectLater(
        const HlsPlaylistParser().parseFile(remote.uri),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('MP4 export preserves a native human-readable failure reason', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-export-error-',
    );
    addTearDown(() => root.delete(recursive: true));
    final playlist = File('${root.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
    final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1]);
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate());
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.completed);
    store.transition(task.id, MediaTaskState.playable);
    final service = Mp4ExportService(
      tasks: store,
      directoryProvider: () async => root,
      muxer:
          ({
            required HlsCacheInput input,
            required String outputPath,
            required void Function(int) onProgress,
            required Cancellation cancellation,
          }) async {
            throw PlatformException(
              code: 'media_export',
              message: 'HLS 分片不含音视频轨道',
            );
          },
    );
    final result = await service.export(
      task.id,
      HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
    );
    expect(result.state, ExportState.failed);
    expect(result.errorCode, 'HLS 分片不含音视频轨道');
  });

  test('relay authorization binds token to session, task and device', () {
    final auth = const RelayAuthorizer().issue(
      sessionId: 'session',
      taskId: 'task',
      deviceId: 'device',
    );
    const RelayAuthorizer().validate(
      auth,
      token: auth.token,
      sessionId: 'session',
      taskId: 'task',
      deviceId: 'device',
    );
    expect(
      () => const RelayAuthorizer().validate(
        auth,
        token: auth.token,
        sessionId: 'other',
        taskId: 'task',
        deviceId: 'device',
      ),
      throwsStateError,
    );
  });

  test('DLNA protocol info parser exposes narrow sink capabilities', () {
    final info = DlnaProtocolInfo.parse(
      '<GetProtocolInfoResponse><Sink>http-get:*:video/mp4:*,http-get:*:application/vnd.apple.mpegurl:*</Sink></GetProtocolInfoResponse>',
    );
    expect(info.supportsMime('video/mp4'), isTrue);
    expect(info.supportsMime('application/vnd.apple.mpegurl'), isTrue);
    expect(info.supportsMime('audio/flac'), isFalse);
    expect(
      DlnaProtocolInfo.parse('http-get:*:*:*').supportsMime('audio/flac'),
      isTrue,
    );
  });

  test('relay request parser accepts HEAD and bounded ranges only', () {
    expect(
      const RelayRequestValidator().validate(
        const RelayRequest(method: 'HEAD'),
      ),
      (start: null, end: null),
    );
    expect(
      const RelayRequestValidator().validate(
        const RelayRequest(method: 'GET', range: 'bytes=10-20'),
      ),
      (start: 10, end: 20),
    );
    expect(
      () => const RelayRequestValidator().validate(
        const RelayRequest(method: 'POST'),
      ),
      throwsStateError,
    );
  });

  test('HLS relay rewrites only local manifest resources', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-relay-');
    addTearDown(() => root.delete(recursive: true));
    final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1, 2, 3]);
    final playlist = File('${root.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
    final auth = const RelayAuthorizer().issue(
      sessionId: 's',
      taskId: 't',
      deviceId: 'd',
    );
    final relay = await HlsRelayServer.start(
      authorization: auth,
      playlist: playlist,
      allowedRoot: root,
      advertisedHost: '127.0.0.1',
    );
    addTearDown(relay.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(relay.url)).close();
    final body = await response.transform(const Utf8Decoder()).join();
    expect(response.statusCode, HttpStatus.ok);
    expect(body, contains('/hls/t/seg.ts?token=${auth.token}'));
    expect(segment.existsSync(), isTrue);
  });

  test(
    'local relay advertises a routable host and serves byte ranges',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-relay-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/video.mp4')
        ..writeAsBytesSync(List<int>.generate(32, (index) => index));
      final auth = const RelayAuthorizer().issue(
        sessionId: 'session',
        taskId: 'task',
        deviceId: 'device',
      );
      final relay = await MediaRelayServer.start(
        authorization: auth,
        file: file,
        allowedRoot: root,
        advertisedHost: '127.0.0.1',
      );
      addTearDown(relay.close);
      expect(relay.url.host, '127.0.0.1');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(relay.url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=4-7');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        await response.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        ),
        [4, 5, 6, 7],
      );
    },
  );
}

class _StatusHttp extends ControlledHttp {
  _StatusHttp(this.statusCode);
  final int statusCode;

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async => FetchResponse(
    url: url,
    status: statusCode,
    bytes: const [],
    headers: const {},
  );

  @override
  Future<FetchFileResponse> fetchToFile(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    required File destination,
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    int resumeOffset = 0,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    Duration timeout = const Duration(seconds: 15),
  }) async => FetchFileResponse(
    url: url,
    status: statusCode,
    headers: const {},
    bytesWritten: 0,
    totalBytes: resumeOffset,
    appended: false,
  );
}

class _MapHttp extends ControlledHttp {
  _MapHttp(this.responses);
  final Map<String, FetchResponse> responses;
  final calls = <String>[];

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async {
    calls.add(url.toString());
    final response = responses[url.toString()];
    if (response == null) throw StateError('missing $url');
    return response;
  }

  @override
  Future<FetchFileResponse> fetchToFile(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    required File destination,
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    int resumeOffset = 0,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add(url.toString());
    final response = responses[url.toString()];
    if (response == null) throw StateError('missing $url');
    if (onHeaders != null) await onHeaders(response.status, response.headers);
    final append = resumeOffset > 0 && response.status == 206;
    final bytes = response.bytes;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(
      append ? [...await destination.readAsBytes(), ...bytes] : bytes,
      flush: true,
    );
    return FetchFileResponse(
      url: response.url,
      status: response.status,
      headers: response.headers,
      bytesWritten: bytes.length,
      totalBytes: (append ? resumeOffset : 0) + bytes.length,
      appended: append,
    );
  }
}

class _InterruptingHttp extends ControlledHttp {
  final offsets = <int>[];
  var calls = 0;

  @override
  Future<FetchFileResponse> fetchToFile(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    required File destination,
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    int resumeOffset = 0,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls++;
    offsets.add(resumeOffset);
    if (calls == 1) {
      await onHeaders?.call(200, const {'etag': '"v1"'});
      await destination.writeAsBytes([1, 2, 3], flush: true);
      throw const SocketException('connection reset by peer');
    }
    expect(headers['Range'], 'bytes=3-');
    expect(headers['If-Range'], '"v1"');
    final responseHeaders = const {
      'etag': '"v1"',
      'content-range': 'bytes 3-5/6',
    };
    await onHeaders?.call(206, responseHeaders);
    final sink = destination.openWrite(mode: FileMode.append);
    await sink.addStream(Stream<List<int>>.value([4, 5, 6]));
    await sink.close();
    return FetchFileResponse(
      url: url,
      status: 206,
      headers: responseHeaders,
      bytesWritten: 3,
      totalBytes: 6,
      appended: true,
    );
  }
}
