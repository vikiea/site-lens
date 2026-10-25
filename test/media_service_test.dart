import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_directory_migration.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/network/transport.dart';

class FakeNativeDownloads extends NativeDownloadRuntime {
  FakeNativeDownloads() : super(channel: const MethodChannel('fake_downloads'));

  final statuses = <String, Map<String, Object?>>{};
  final calls = <String>[];
  void Function(String taskId)? onCancel;
  bool reservationEnabled = false;
  bool rejectReservation = false;

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
  Future<void> cancel(String taskId) async {
    calls.add('cancel:$taskId');
    onCancel?.call(taskId);
  }

  @override
  bool get supportsMutationReservation => reservationEnabled;

  @override
  Future<String?> reserveMutation(String taskId, List<String> paths) async {
    if (!reservationEnabled) return null;
    calls.add('reserve:$taskId');
    if (rejectReservation) throw StateError('media busy');
    return 'reservation:$taskId';
  }

  @override
  Future<void> releaseMutation(String reservationId) async =>
      calls.add('release:$reservationId');

  @override
  Future<void> delete(String taskId, {String? reservationId}) async =>
      calls.add(
        reservationId == null
            ? 'delete:$taskId'
            : 'delete:$taskId:$reservationId',
      );

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
  String sourceUrl = 'https://example.com/watch',
  int hostId = 7,
  int generation = 3,
}) => MediaCandidate(
  id: id,
  hostId: hostId,
  generation: generation,
  sourceUrl: Uri.parse(sourceUrl),
  mediaUrl: Uri.parse(url),
  title: title,
  mime: mime,
  source: MediaCandidateSource.dom,
);

void main() {
  test('native restorable playback state remains a distinct state', () {
    expect(
      NativePlaybackState.values,
      contains(NativePlaybackState.restorable),
    );
  });
  test('media task freezes the title and episode at creation', () {
    final store = MediaTaskStore();
    final task = store.create(candidate(title: '母衣半暖默许春朝 - 第3集'));
    expect(task.displayTitle, '母衣半暖默许春朝 - 第3集');
    expect(task.episodeLabel, '第3集');
    expect(task.displayName, '母衣半暖默许春朝 - 第3集');
    expect(task.resourceKey, hasLength(64));
  });

  test('resource identity survives host and generation changes', () {
    final first = MediaTaskStore().create(candidate(hostId: 7, generation: 3));
    final later = MediaTaskStore().create(candidate(hostId: 8, generation: 4));
    expect(later.cacheKey, isNot(first.cacheKey));
    expect(later.resourceKey, first.resourceKey);
  });

  test(
    'durable resource catalog converges task rows by resource identity',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final firstCandidate = candidate(hostId: 7, generation: 3);
      final secondCandidate = candidate(hostId: 8, generation: 4);
      await db.saveMediaCandidate(firstCandidate);
      await db.saveMediaCandidate(secondCandidate);
      final first = MediaTaskStore(db: db).create(firstCandidate);
      final second = MediaTaskStore(db: db).create(secondCandidate);
      await db.saveMediaTask(first);
      await db.saveMediaTask(second);
      expect(first.cacheKey, isNot(second.cacheKey));
      expect(first.resourceKey, second.resourceKey);
      expect(await db.mediaResourceKeys(), [first.resourceKey]);
      expect(
        await db.mediaResourceOwners(first.resourceKey),
        containsAll(<String>['task:${first.id}', 'task:${second.id}']),
      );
      await db.deleteMediaTask(first.id);
      expect(await db.mediaResourceOwners(first.resourceKey), [
        'task:${second.id}',
      ]);
    },
  );

  test(
    'media task prefers an explicit title over a stale media URL marker',
    () {
      final task = MediaTaskStore().create(
        candidate(
          title: '母衣半暖默许春朝 - 第1集',
          url: 'https://cdn.example/episode-3/video.mp4',
        ),
      );
      expect(task.episodeLabel, '第1集');
    },
  );

  test('media task falls back to a media URL marker for a generic title', () {
    final task = MediaTaskStore().create(
      candidate(title: 'video', url: 'https://cdn.example/episode-3/video.mp4'),
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
      expect(restored.task(task.id)!.resourceKey, hasLength(64));
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

  test('separate stores converge on one durable cache-key row', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final source = candidate(id: 'concurrent-observation');
    await db.saveMediaCandidate(source);
    final firstStore = MediaTaskStore(db: db);
    final secondStore = MediaTaskStore(db: db);

    final first = firstStore.create(source);
    await firstStore.flush(first.id);
    firstStore.transition(first.id, MediaTaskState.downloading);
    firstStore.updateProgress(first.id, 42, totalBytes: 100);
    await firstStore.flush(first.id);

    final second = secondStore.create(source);
    await secondStore.flush(second.id);

    expect(second.id, first.id);
    final persisted = (await db.mediaTasks()).single;
    expect(persisted.state, MediaTaskState.downloading);
    expect(persisted.bytesDownloaded, 42);
  });

  test(
    'database upsert returns the existing id on a legacy cache conflict',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final source = candidate(id: 'legacy-cache-conflict');
      await db.saveMediaCandidate(source);
      final store = MediaTaskStore(db: db);
      final first = store.create(source);
      store.transition(first.id, MediaTaskState.downloading);
      store.updateProgress(first.id, 42, totalBytes: 100);
      await store.flush(first.id);

      final foreignId = first.copyWith(
        id: 'legacy-racing-task',
        state: MediaTaskState.queued,
        bytesDownloaded: 0,
        totalBytes: null,
      );
      expect(await db.saveMediaTask(foreignId), first.id);
      final persisted = (await db.mediaTasks()).single;
      expect(persisted.id, first.id);
      expect(persisted.state, MediaTaskState.downloading);
      expect(persisted.bytesDownloaded, 42);

      final stale = MediaTask(
        id: first.id,
        candidateId: first.candidateId,
        hostId: first.hostId,
        generation: first.generation,
        sourceUrl: first.sourceUrl,
        cacheKey: first.cacheKey,
        state: MediaTaskState.failed,
        updatedAt: first.updatedAt.subtract(const Duration(minutes: 1)),
        displayTitle: first.displayTitle,
        bytesDownloaded: 42,
        totalBytes: 100,
      );
      await db.saveMediaTask(stale);
      expect((await db.mediaTasks()).single.state, MediaTaskState.downloading);
    },
  );

  test(
    'legacy cache conflicts alias the in-memory task to the durable row',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final source = candidate(id: 'legacy-alias');
      await db.saveMediaCandidate(source);
      final seed = MediaTaskStore()
          .create(source)
          .copyWith(
            id: 'legacy-task-id',
            state: MediaTaskState.downloading,
            bytesDownloaded: 42,
            totalBytes: 100,
          );
      await db.saveMediaTask(seed);

      final store = MediaTaskStore(db: db);
      final racing = store.create(source);
      await store.flush(racing.id);

      expect(store.task(racing.id)?.id, 'legacy-task-id');
      expect(store.task(racing.id)?.bytesDownloaded, 42);
      store.updateProgress(racing.id, 77, totalBytes: 100);
      await store.flush(racing.id);
      expect((await db.mediaTasks()).single.bytesDownloaded, 77);
    },
  );

  test('retrying a failed stream reuses its durable task row', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MediaTaskStore(db: db);
    final original = candidate(id: 'failed-observation');
    await db.saveMediaCandidate(original);
    final first = store.create(original);
    await store.flush(first.id);
    store.transition(first.id, MediaTaskState.failed, errorReason: '网络失败');
    await store.flush(first.id);

    final replacement = candidate(id: 'retry-observation');
    await db.saveMediaCandidate(replacement);
    final retry = store.create(replacement);
    await store.flush(retry.id);

    expect(retry.id, first.id);
    expect(retry.state, MediaTaskState.queued);
    expect(retry.candidateId, 'retry-observation');
    expect((await db.mediaTasks()), hasLength(1));
    expect((await db.mediaTasks()).single.state, MediaTaskState.queued);
  });

  test('task timestamps compare millisecond and microsecond precision chronologically', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final source = candidate(id: 'timestamp-precision');
    await db.saveMediaCandidate(source);
    final store = MediaTaskStore(db: db);
    final original = store.create(source);
    await store.flush(original.id);
    MediaTask snapshot(String time, MediaTaskState state) => MediaTask.fromJson(
      {...original.toJson(), 'updatedAt': time, 'state': state.name},
    );
    await db.saveMediaTask(
      snapshot('2099-01-01T00:00:00.123Z', MediaTaskState.failed),
    );
    await db.saveMediaTask(
      snapshot('2099-01-01T00:00:00.123001Z', MediaTaskState.queued),
    );
    expect((await db.mediaTasks()).single.state, MediaTaskState.queued);
    await db.saveMediaTask(
      snapshot('2099-01-01T00:00:00.123Z', MediaTaskState.failed),
    );
    expect((await db.mediaTasks()).single.state, MediaTaskState.queued);
  });

  test(
    'direct retry states persist their transition back to downloading',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final source = candidate(id: 'direct-retry-state');
      await db.saveMediaCandidate(source);
      final store = MediaTaskStore(db: db);
      final task = store.create(source);
      await store.flush(task.id);

      for (final retryState in [
        MediaTaskState.failed,
        MediaTaskState.cancelled,
        MediaTaskState.reauthorize,
      ]) {
        if (store.task(task.id)!.state != MediaTaskState.downloading) {
          store.transition(task.id, MediaTaskState.downloading);
          await store.flush(task.id);
        }
        store.transition(task.id, retryState);
        await store.flush(task.id);
        store.transition(task.id, MediaTaskState.downloading);
        await store.flush(task.id);
        expect(
          (await db.mediaTasks()).single.state,
          MediaTaskState.downloading,
        );
      }
    },
  );

  test('reauthorization accepts a rotated token for the same stream', () {
    final store = MediaTaskStore();
    final original = candidate(
      id: 'reauthorize-token-old',
      url: 'https://cdn.example/live/index.m3u8?token=old&v=720',
      mime: 'application/vnd.apple.mpegurl',
    );
    final task = store.create(original);
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.reauthorize);

    final refreshed = candidate(
      id: 'reauthorize-token-new',
      url: 'https://cdn.example/live/index.m3u8?token=new&v=720',
      mime: 'application/vnd.apple.mpegurl',
    );
    final retry = store.create(refreshed);

    expect(retry.id, task.id);
    expect(retry.candidateId, refreshed.id);
    expect(retry.cacheKey, task.cacheKey);
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

  test('retry keeps the persisted batch directory identity', () {
    final store = MediaTaskStore();
    final original = store.create(
      candidate(id: 'retry-old'),
      batchDirectory: '旧剧集 - 批次1792686431921372',
    );
    store.transition(original.id, MediaTaskState.downloading);
    store.transition(original.id, MediaTaskState.failed);

    final retry = store.create(
      candidate(id: 'retry-new'),
      batchDirectory: '新剧集 - 批次1792686431921373',
    );

    expect(retry.id, original.id);
    expect(retry.batchDirectory, '旧剧集');
    expect(retry.candidateId, 'retry-new');
  });

  test('series directory names remove episode markers safely', () {
    expect(mediaSeriesDirectoryName('母衣半暖默许春朝 - 第3集'), '母衣半暖默许春朝');
    expect(mediaSeriesDirectoryName('A/B: episode=12'), 'A_B');
    expect(mediaSeriesDirectoryName(''), '未命名媒体');
    expect(mediaFolderDisplayName('A/B'), 'A/B');
    expect(
      mediaFolderDisplayName('系统带我攻略弟弟（漫剧版） - 批次1792686431921372'),
      '系统带我攻略弟弟（漫剧版）',
    );
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

  test('legacy media folders are physically merged and catalog paths follow', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-migrate-');
    addTearDown(() => root.delete(recursive: true));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final source = candidate(
      id: 'legacy-folder-task',
      title: '系统带我攻略弟弟（漫剧版） - 第1集',
    );
    await db.saveMediaCandidate(source);
    final seed = MediaTaskStore(db: db, directoryProvider: () async => root);
    final task = seed.create(source, batchDirectory: '系统带我攻略弟弟（漫剧版）');
    final legacy = task.copyWith(
      updatedAt: task.updatedAt,
      batchDirectory: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
    );
    await db.saveMediaTask(legacy);

    final oldCache = Directory(
      '${root.path}/media_cache/系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
    )..createSync(recursive: true);
    final newCache = Directory('${root.path}/media_cache/系统带我攻略弟弟（漫剧版）')
      ..createSync(recursive: true);
    final oldFile = File('${oldCache.path}/${task.cacheKey}.media')
      ..writeAsBytesSync([1, 2, 3]);
    File('${newCache.path}/${task.cacheKey}.media').writeAsBytesSync([9]);
    final oldExport = Directory(
      '${root.path}/media_exports/系统带我攻略弟弟（漫剧版） - 批次1792686431921372/${task.cacheKey}',
    )..createSync(recursive: true);
    final oldExportFile = File('${oldExport.path}/episode.mp4')
      ..writeAsBytesSync([4, 5, 6]);
    final exported = MediaArtifact(
      taskId: task.id,
      location: oldExportFile.path,
      name: 'episode.mp4',
      size: 3,
      folder: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
      createdAt: task.updatedAt,
    );
    await db.saveMediaArtifact(task.id, exported.toJson());
    await db.saveMediaTask(
      legacy.copyWith(updatedAt: legacy.updatedAt, localRef: oldFile.path),
    );

    final restored = MediaTaskStore(
      db: db,
      directoryProvider: () async => root,
    );
    await restored.restore();
    final cleanTask = restored.task(task.id)!;
    expect(cleanTask.batchDirectory, '系统带我攻略弟弟（漫剧版）');
    expect(cleanTask.localRef, '${newCache.path}/${task.cacheKey}.media');
    expect(await File(cleanTask.localRef!).readAsBytes(), [1, 2, 3]);
    expect(await oldCache.exists(), isFalse);

    final library = MediaLibrary(db: db, tasks: restored);
    addTearDown(library.dispose);
    await library.restore();
    final migratedArtifact = library.item(task.id)!;
    expect(
      migratedArtifact.location,
      oldExportFile.path.replaceFirst(
        '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
        '系统带我攻略弟弟（漫剧版）',
      ),
    );
    expect(migratedArtifact.folder, '系统带我攻略弟弟（漫剧版）');
    expect(await File(migratedArtifact.location).readAsBytes(), [4, 5, 6]);
  });

  test(
    'corrupt media migration journal is discarded and rebuilt from disk',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-bad-journal-',
      );
      addTearDown(() => root.delete(recursive: true));
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.setSetting(MediaDirectoryMigration.journalKey, '{broken json');
      final legacy = Directory(
        '${root.path}/media_cache/系列 - 批次1792686431921372',
      )..createSync(recursive: true);
      File('${legacy.path}/episode.media').writeAsBytesSync([1, 2, 3]);

      await MediaDirectoryMigration(db).migrateLocal(root);

      expect(
        await File('${root.path}/media_cache/系列/episode.media').readAsBytes(),
        [1, 2, 3],
      );
      expect(await legacy.exists(), isFalse);
    },
  );

  test(
    'legacy cache identity stays stable while its display name is clean',
    () {
      final store = MediaTaskStore();
      final task = store.create(
        candidate(title: '系统带我攻略弟弟（漫剧版） - 第1集'),
        batchDirectory: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
      );

      expect(task.batchDirectory, '系统带我攻略弟弟（漫剧版）');
      expect(task.storageDirectoryName, '系统带我攻略弟弟（漫剧版）');
      expect(mediaFolderDisplayName(task.batchDirectory!), '系统带我攻略弟弟（漫剧版）');
    },
  );

  test('batch directory survives media task persistence and restore', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final source = candidate(id: 'batch-persisted', title: '系列 - 第1集');
    await db.saveMediaCandidate(source);
    final first = MediaTaskStore(db: db);
    final task = first.create(source, batchDirectory: '批次目录');
    await first.flush(task.id);

    final restored = MediaTaskStore(db: db);
    await restored.restore();

    expect(restored.task(task.id)?.batchDirectory, '批次目录');
    expect(restored.task(task.id)?.storageDirectoryName, '批次目录');
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

  test(
    'media playlist isolates same-title tasks from another source origin',
    () {
      final store = MediaTaskStore();
      final first = store.create(
        candidate(
          id: 'source-a-1',
          title: '同名系列 - 第1集',
          url: 'https://cdn-a.example/episode-1.mp4',
        ),
      );
      final second = store.create(
        candidate(
          id: 'source-a-2',
          title: '同名系列 - 第2集',
          url: 'https://cdn-a.example/episode-2.mp4',
        ),
      );
      final foreign = store.create(
        candidate(
          id: 'source-b-1',
          title: '同名系列 - 第1集',
          url: 'https://cdn-b.example/episode-1.mp4',
          sourceUrl: 'https://site-b.example/watch/1',
        ),
      );
      for (final task in [first, second, foreign]) {
        store.transition(task.id, MediaTaskState.downloading);
        store.transition(task.id, MediaTaskState.completed);
        store.transition(task.id, MediaTaskState.playable);
      }

      final playlist = mediaPlaylistForTasks(store.tasks, first);
      expect(playlist.map((task) => task.id), [first.id, second.id]);
      expect(playlist, isNot(contains(foreign)));
    },
  );

  test('media playlist keeps one series across document generations', () {
    final store = MediaTaskStore();
    final first = store.create(
      candidate(
        id: 'generation-1',
        title: '系列 - 第1集',
        url: 'https://cdn.example/episode-1.mp4',
        sourceUrl: 'https://example.com/video/42/',
        generation: 1,
      ),
    );
    final second = store.create(
      candidate(
        id: 'generation-2',
        title: '系列 - 第2集',
        url: 'https://cdn.example/episode-2.mp4',
        sourceUrl: 'https://example.com/video/42/ep-2/',
        generation: 2,
      ),
    );
    for (final task in [first, second]) {
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
    }

    expect(mediaPlaylistForTasks(store.tasks, first).map((task) => task.id), [
      first.id,
      second.id,
    ]);
  });

  test('media playlist isolates same-origin series paths', () {
    final store = MediaTaskStore();
    final first = store.create(
      candidate(
        id: 'path-a',
        title: '同名系列 - 第1集',
        url: 'https://cdn.example/a.mp4',
        sourceUrl: 'https://example.com/video/42/',
      ),
    );
    final foreign = store.create(
      candidate(
        id: 'path-b',
        title: '同名系列 - 第2集',
        url: 'https://cdn.example/b.mp4',
        sourceUrl: 'https://example.com/video/77/',
      ),
    );
    for (final task in [first, foreign]) {
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
    }

    expect(mediaPlaylistForTasks(store.tasks, first).map((task) => task.id), [
      first.id,
    ]);
  });

  test(
    'batch playlists stay isolated when one folder contains mixed series',
    () {
      final store = MediaTaskStore();
      final first = store.create(
        candidate(
          id: 'mixed-a',
          title: '系列甲 - 第1集',
          url: 'https://cdn.example/mixed-a.mp4',
          sourceUrl: 'https://example.com/video/42/',
        ),
        batchDirectory: '批量媒体',
      );
      final second = store.create(
        candidate(
          id: 'mixed-b',
          title: '系列乙 - 第1集',
          url: 'https://cdn.example/mixed-b.mp4',
          sourceUrl: 'https://example.com/video/77/',
        ),
        batchDirectory: '批量媒体',
      );
      for (final task in [first, second]) {
        store.transition(task.id, MediaTaskState.downloading);
        store.transition(task.id, MediaTaskState.completed);
        store.transition(task.id, MediaTaskState.playable);
      }

      expect(mediaPlaylistForTasks(store.tasks, first).map((task) => task.id), [
        first.id,
      ]);
    },
  );

  test('batch directory selection ignores generic active-player labels', () {
    final candidates = [
      candidate(id: 'generic', title: '媒体 · 集数未确认'),
      candidate(id: 'explicit-1', title: '系列 - 第1集'),
      candidate(id: 'explicit-2', title: '系列 - 第2集'),
    ];
    expect(mediaBatchDirectoryName(candidates), '系列');
    expect(
      mediaBatchDirectoryName([
        candidate(id: 'generic-only', title: '媒体 · 集数未确认'),
      ]),
      isNull,
    );
  });

  test('mixed explicit series use a neutral batch directory', () {
    expect(
      mediaBatchDirectoryName([
        candidate(id: 'a-1', title: '系列甲 - 第1集'),
        candidate(id: 'a-2', title: '系列甲 - 第2集'),
        candidate(id: 'b-1', title: '系列乙 - 第1集'),
      ]),
      isNull,
    );
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
        {'url': 'https://cdn.example/live/index.m3u8?signature=one'},
        {'url': 'https://cdn.example/live/index.m3u8?signature=two'},
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
        Uri.parse('https://cdn.example/live/index.m3u8?signature=one'),
      ),
      mediaCandidateGroupKey(
        Uri.parse('https://cdn.example/live/index.m3u8?signature=two'),
      ),
    );
  });

  test('line parameters remain distinct display identities', () {
    final first = Uri.parse(
      'https://cdn.example/live/index.m3u8?line=54&t=one',
    );
    final second = Uri.parse(
      'https://cdn.example/live/index.m3u8?line=55&t=two',
    );
    expect(
      mediaCandidateGroupKey(first),
      isNot(mediaCandidateGroupKey(second)),
    );
    expect(
      mediaCandidateAuthorizationKey(first),
      isNot(mediaCandidateAuthorizationKey(second)),
    );
    expect(
      mediaCandidateDisplayGroupKey(candidate(url: first.toString())),
      isNot(mediaCandidateDisplayGroupKey(candidate(url: second.toString()))),
    );
    expect(
      mediaCandidateGroupKey(Uri.parse('https://cdn.example/live/index.m3u8')),
      isNot(
        mediaCandidateGroupKey(
          Uri.parse('https://cdn.example/live/index.m3u8?line=54&t=one'),
        ),
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
      url: 'https://cdn.example/live/index.m3u8?signature=one',
      mime: 'application/vnd.apple.mpegurl',
    );
    final second = MediaCandidate(
      id: 'candidate-2',
      hostId: first.hostId,
      generation: first.generation,
      sourceUrl: first.sourceUrl,
      mediaUrl: Uri.parse('https://cdn.example/live/index.m3u8?signature=two'),
      title: first.title,
      mime: first.mime,
      source: first.source,
    );
    expect(
      mediaCandidateDisplayGroupKey(first),
      mediaCandidateDisplayGroupKey(second),
    );
  });

  test('same media URL stays one candidate even when page titles differ', () {
    final first = candidate(
      url: 'https://cdn.example/live/index.m3u8?signature=one',
      mime: 'application/vnd.apple.mpegurl',
    );
    final second = MediaCandidate(
      id: 'candidate-title-2',
      hostId: first.hostId,
      generation: first.generation,
      sourceUrl: first.sourceUrl,
      mediaUrl: Uri.parse('https://cdn.example/live/index.m3u8?signature=two'),
      title: '另一个页面标题',
      mime: first.mime,
      source: first.source,
    );
    expect(
      mediaCandidateDisplayGroupKey(first),
      mediaCandidateDisplayGroupKey(second),
    );
  });

  test(
    'display identity collapses auth rotation but task identity keeps token',
    () {
      final first = candidate(
        url: 'https://cdn.example/live/index.m3u8?token=one&v=720',
        mime: 'application/vnd.apple.mpegurl',
      );
      final refreshed = MediaCandidate(
        id: 'candidate-token-2',
        hostId: first.hostId,
        generation: first.generation,
        sourceUrl: first.sourceUrl,
        mediaUrl: Uri.parse(
          'https://cdn.example/live/index.m3u8?token=two&v=720',
        ),
        title: first.title,
        mime: first.mime,
        source: first.source,
      );
      expect(
        mediaCandidateDisplayGroupKey(first),
        mediaCandidateDisplayGroupKey(refreshed),
      );
      expect(
        mediaCandidateGroupKey(first.mediaUrl),
        isNot(mediaCandidateGroupKey(refreshed.mediaUrl)),
      );
    },
  );

  test('HLS selection parameters remain part of the candidate identity', () {
    final base = Uri.parse(
      'https://cdn.example/live/index.m3u8?signature=one&v=720',
    );
    final signedAgain = Uri.parse(
      'https://cdn.example/live/index.m3u8?signature=two&v=720',
    );
    final differentSelection = Uri.parse(
      'https://cdn.example/live/index.m3u8?signature=three&v=1080',
    );
    expect(mediaCandidateGroupKey(base), mediaCandidateGroupKey(signedAgain));
    expect(
      mediaCandidateGroupKey(
        Uri.parse('https://cdn.example/live/index.m3u8?token=one&v=720'),
      ),
      isNot(
        mediaCandidateGroupKey(
          Uri.parse('https://cdn.example/live/index.m3u8?token=two&v=720'),
        ),
      ),
    );
    expect(
      mediaCandidateGroupKey(base),
      isNot(mediaCandidateGroupKey(differentSelection)),
    );
  });

  test('playlist boundary hints identify the first and last episode', () {
    expect(
      mediaPlaylistBoundaryHint(index: 0, length: 3, offset: -1),
      '已经是第一集',
    );
    expect(
      mediaPlaylistBoundaryHint(index: 2, length: 3, offset: 1),
      '已经是最后一集',
    );
    expect(mediaPlaylistBoundaryHint(index: 1, length: 3, offset: -1), isNull);
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

  test('cachedBytes sums HLS resources instead of only the manifest', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-size-');
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(
      candidate(
        url: 'https://cdn.example/size/index.m3u8',
        mime: 'application/vnd.apple.mpegurl',
      ),
    );
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.completed);
    store.transition(task.id, MediaTaskState.playable);
    final directory = await store.cacheDirectory();
    final cache = Directory('${directory.path}/${task.cacheKey}.hls')
      ..createSync(recursive: true);
    final segment = File('${cache.path}/segment.ts')
      ..writeAsBytesSync(List.filled(97, 1));
    final init1 = File('${cache.path}/init-1.mp4')
      ..writeAsBytesSync(List.filled(17, 2));
    final init = File('${cache.path}/init-2.mp4')
      ..writeAsBytesSync(List.filled(31, 2));
    final playlist = File('${cache.path}/index.m3u8')
      ..writeAsStringSync(
        '#EXTM3U\n#EXT-X-MAP:URI="init-1.mp4"\n#EXTINF:1,\nsegment.ts\n'
        '#EXT-X-MAP:URI="init-2.mp4"\n#EXTINF:1,\nsegment.ts\n',
      );
    store.setLocalRef(task.id, playlist.path);

    expect(
      await store.cachedBytes(task.id),
      playlist.lengthSync() +
          segment.lengthSync() +
          init1.lengthSync() +
          init.lengthSync(),
    );
    final input = await const HlsPlaylistParser().parseFile(playlist.uri);
    expect(input.initSegments, hasLength(2));
    await init1.delete();
    await expectLater(validateHlsCacheInput(input), throwsFormatException);
    expect(await store.cachedFile(task.id), isNull);
  });

  test(
    'partial HLS playback accepts committed segments before ENDLIST',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-hls-partial-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(
        candidate(
          url: 'https://cdn.example/partial/index.m3u8',
          mime: 'application/vnd.apple.mpegurl',
        ),
      );
      store.transition(task.id, MediaTaskState.downloading);
      final directory = await store.cacheDirectory(
        storageDirectory: task.storageDirectoryName,
      );
      final cache = await Directory('${directory.path}/${task.cacheKey}.hls')
          .create(recursive: true);
      await File('${cache.path}/resource_segment.bin').writeAsBytes([1, 2, 3]);
      await File('${cache.path}/index.m3u8').writeAsString(
        '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nresource_segment.bin\n',
      );

      final partial = await store.partialPlaybackFile(task.id);

      expect(partial?.path, '${cache.path}/index.m3u8');
      expect(await store.cachedFile(task.id), isNull);
    },
  );

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
    'delete holds the exclusive lease while stopping native transport',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-delete-lease-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      final native = FakeNativeDownloads();
      native.statuses[task.id] = {'state': 'downloading'};
      native.onCancel = (id) => expect(store.isExclusive(id), isTrue);
      final service = MediaDownloadService(tasks: store, native: native);

      await service.startNative(task, candidate());
      await service.delete(task.id);

      expect(store.task(task.id), isNull);
      expect(native.calls, [
        'start:${task.id}',
        'cancel:${task.id}',
        'delete:${task.id}',
      ]);
    },
  );

  test(
    'delete reserves native and Dart cache paths before cancelling transport',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-delete-reservation-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      final native = FakeNativeDownloads()..reservationEnabled = true;
      native.statuses[task.id] = {'state': 'downloading'};
      final service = MediaDownloadService(tasks: store, native: native);

      await service.startNative(task, candidate());
      await service.delete(task.id);

      expect(native.calls, [
        'start:${task.id}',
        'reserve:${task.id}',
        'delete:${task.id}:reservation:${task.id}',
        'release:reservation:${task.id}',
      ]);
      expect(store.task(task.id), isNull);
    },
  );

  test('a failed export cleanup stops native writing before releasing its reservation', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-delete-before-hook-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate());
    final native = FakeNativeDownloads()
      ..reservationEnabled = true
      ..statuses[task.id] = {'state': 'downloading'};
    final service = MediaDownloadService(tasks: store, native: native);

    await service.startNative(task, candidate());
    await expectLater(
      service.delete(
        task.id,
        beforeDelete: (reservation) async {
          expect(reservation, 'reservation:${task.id}');
          throw StateError('导出副本仍被占用');
        },
      ),
      throwsStateError,
    );

    expect(native.calls, [
      'start:${task.id}',
      'reserve:${task.id}',
      'cancel:${task.id}',
      'release:reservation:${task.id}',
    ]);
    expect(store.task(task.id)?.state, MediaTaskState.cancelled);
  });

  test(
    'a rejected native reservation leaves the writer and task untouched',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-delete-reservation-reject-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      final native = FakeNativeDownloads()
        ..reservationEnabled = true
        ..rejectReservation = true;
      native.statuses[task.id] = {'state': 'downloading'};
      final service = MediaDownloadService(tasks: store, native: native);

      await service.startNative(task, candidate());
      await expectLater(service.delete(task.id), throwsStateError);

      expect(native.calls, ['start:${task.id}', 'reserve:${task.id}']);
      expect(store.task(task.id)?.state, MediaTaskState.downloading);
    },
  );

  test(
    'Dart writer remains behind the native reservation until flush completes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-dart-writer-reservation-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      final transport = _HeldDownloadHttp();
      final native = FakeNativeDownloads()..reservationEnabled = true;
      final service = MediaDownloadService(
        tasks: store,
        http: transport,
        native: native,
      );
      final running = service.start(task, candidate());
      addTearDown(() async {
        if (!transport.flushAllowed.isCompleted) {
          transport.flushAllowed.complete();
        }
        await running;
      });
      await transport.started.future.timeout(const Duration(seconds: 3));

      final deleting = service.delete(task.id);
      await transport.cancelled.future.timeout(const Duration(seconds: 3));
      expect(native.calls, ['reserve:${task.id}']);
      expect(store.isExclusive(task.id), isTrue);

      transport.flushAllowed.complete();
      await deleting.timeout(const Duration(seconds: 3));
      expect(native.calls, [
        'reserve:${task.id}',
        'delete:${task.id}:reservation:${task.id}',
        'release:reservation:${task.id}',
      ]);
      expect(store.task(task.id), isNull);
    },
  );

  test(
    'delete preserves a caller-owned lease through a failed file operation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-delete-held-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      final native = FakeNativeDownloads();
      final service = MediaDownloadService(tasks: store, native: native);
      await expectLater(
        service.delete(task.id, exclusiveAlreadyHeld: true),
        throwsStateError,
      );
      expect(native.calls, isEmpty);

      store.acquireExclusive(task.id);
      addTearDown(() => store.releaseExclusive(task.id));
      await expectLater(
        service.delete(
          task.id,
          exclusiveAlreadyHeld: true,
          beforeDelete: (_) async =>
              throw StateError('file reader remains held'),
        ),
        throwsStateError,
      );
      expect(store.task(task.id), isNotNull);
      expect(store.isExclusive(task.id), isTrue);
      expect(() => store.retain(task.id), throwsStateError);
      await service.delete(task.id, exclusiveAlreadyHeld: true);
      expect(store.task(task.id), isNull);
      expect(store.isExclusive(task.id), isTrue);
    },
  );

  test(
    'delete waits for an active writer and preserves a retained download',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-delete-writer-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      final transport = _HeldDownloadHttp();
      final service = MediaDownloadService(tasks: store, http: transport);
      final running = service.start(task, candidate());
      addTearDown(() async {
        if (!transport.flushAllowed.isCompleted) {
          transport.flushAllowed.complete();
        }
        await running;
      });
      await transport.started.future.timeout(const Duration(seconds: 3));
      store.retain(task.id);

      await expectLater(service.delete(task.id), throwsStateError);

      expect(transport.cancelled.isCompleted, isFalse);
      expect(store.task(task.id)?.state, MediaTaskState.downloading);
      expect(await transport.destination!.exists(), isTrue);
      store.release(task.id);
      final deleting = service.delete(task.id);
      await transport.cancelled.future.timeout(const Duration(seconds: 3));
      expect(store.isExclusive(task.id), isTrue);
      expect(await transport.destination!.readAsBytes(), [1, 2, 3]);
      expect(store.task(task.id), isNotNull);
      transport.flushAllowed.complete();
      await deleting.timeout(const Duration(seconds: 3));

      expect(store.task(task.id), isNull);
      expect(await transport.destination!.exists(), isFalse);
      expect(store.isExclusive(task.id), isFalse);
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

  test('deleting a task with a missing localRef removes deterministic orphan caches', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-delete-orphan-cache-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate(title: '系列 - 第2集'));
    final directory = await store.cacheDirectory(
      storageDirectory: task.storageDirectoryName,
    );
    final orphanHls = Directory('${directory.path}/${task.cacheKey}.hls')
      ..createSync();
    File('${orphanHls.path}/segment.ts').writeAsBytesSync([1, 2]);
    final orphanMedia = File('${directory.path}/${task.cacheKey}.media')
      ..writeAsBytesSync([3, 4]);
    final adjacent = File('${directory.path}/other-episode.marker')
      ..writeAsStringSync('keep');
    store.transition(task.id, MediaTaskState.downloading);
    store.transition(task.id, MediaTaskState.playable);
    store.setLocalRef(task.id, null);

    await MediaDownloadService(tasks: store).delete(task.id);

    expect(await orphanHls.exists(), isFalse);
    expect(await orphanMedia.exists(), isFalse);
    expect(await adjacent.exists(), isTrue);
    expect(store.task(task.id), isNull);
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
      final task = store.create(
        candidate(title: '系统带我攻略弟弟（漫剧版） - 第1集'),
        batchDirectory: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
      );
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
      expect(successful.outputPath, contains('系统带我攻略弟弟（漫剧版）'));
      expect(successful.outputPath, isNot(contains('批次1792686431921372')));
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
    int routeAttempt = 0,
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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
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
    int routeAttempt = 0,
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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
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

class _HeldDownloadHttp extends ControlledHttp {
  final started = Completer<void>();
  final cancelled = Completer<void>();
  final flushAllowed = Completer<void>();
  File? destination;

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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    this.destination = destination;
    await onHeaders?.call(200, const {'etag': '"held-writer"'});
    await destination.writeAsBytes([1, 2, 3], flush: true);
    final detach = cancel.onCancel(() => cancelled.complete());
    started.complete();
    try {
      await flushAllowed.future;
      cancel.check();
      return FetchFileResponse(
        url: url,
        status: 200,
        headers: const {},
        bytesWritten: 3,
        totalBytes: 3,
        appended: false,
      );
    } finally {
      detach();
    }
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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
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
