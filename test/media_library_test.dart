import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_export_runtime.dart';

class _CleanupRuntime extends NativeExportRuntime {
  String? failOnce;
  bool readerHeld = false;
  final deleted = <String>[];
  final batches = <List<String>>[];

  @override
  Future<List<String>> deleteOwnedSources(
    String taskId,
    List<String> sources, {
    String? mutationReservationId,
  }) async {
    batches.add(List.of(sources));
    if (readerHeld) {
      throw PlatformException(code: 'media_export', message: '媒体正在播放，请先停止');
    }
    final completed = <String>[];
    try {
      for (final source in sources) {
        await delete(source, allowMissing: true);
        completed.add(source);
      }
    } catch (_) {
      throw PlatformException(
        code: 'media_export',
        message: '暂时无法删除副本',
        details: {'deletedSources': completed},
      );
    }
    return completed;
  }

  @override
  Future<Map<String, Object?>> inspect(String source) async => {
    'size': await File(source).length(),
  };

  @override
  Future<Map<String, Object?>> stat(String source) => inspect(source);

  @override
  Future<void> delete(String source, {bool allowMissing = false}) async {
    if (source == failOnce) {
      failOnce = null;
      throw StateError('暂时无法删除副本');
    }
    final file = File(source);
    if (!await file.exists()) {
      if (!allowMissing) throw StateError('副本不存在');
    } else {
      await file.delete();
    }
    deleted.add(source);
  }
}

class _FailCacheReferenceDatabase extends AppDatabase {
  _FailCacheReferenceDatabase() : super(NativeDatabase.memory());
  bool failDetachedReference = false;

  @override
  Future<String> saveMediaTask(MediaTask task) {
    if (failDetachedReference && task.localRef?.endsWith('.media') == true) {
      return Future.error(StateError('cache reference persistence failed'));
    }
    return super.saveMediaTask(task);
  }
}

class _VerifiedCopyRuntime extends _CleanupRuntime {
  final reuses = <String>[];

  @override
  Future<String> copyVerified({
    required String source,
    required String destination,
    bool reuseExistingVerified = false,
  }) async {
    final target = File(destination);
    if (await target.exists()) {
      if (!reuseExistingVerified ||
          sha256.convert(await target.readAsBytes()).toString() !=
              sha256.convert(await File(source).readAsBytes()).toString()) {
        throw PlatformException(code: 'media_export', message: '已有副本不同');
      }
      reuses.add(destination);
    } else {
      await File(source).copy(destination);
    }
    return destination;
  }
}

class _DoubleFailureMoveRuntime extends _CleanupRuntime {
  _DoubleFailureMoveRuntime(this.target);
  final String target;

  @override
  Future<String> move({
    required String source,
    required Uri directory,
    required String fileName,
  }) async {
    await File(source).copy(target);
    throw PlatformException(
      code: 'media_move_incomplete',
      details: {
        'recoveryTarget': target,
        'sourceRetained': true,
        'rollbackFailed': true,
      },
    );
  }
}

class _MetadataFallbackRuntime extends NativeExportRuntime {
  bool readable = true;

  @override
  Future<Map<String, Object?>> inspect(String source) async {
    throw PlatformException(code: 'media_export', message: 'codec unavailable');
  }

  @override
  Future<Map<String, Object?>> stat(String source) async {
    if (!readable) throw PlatformException(code: 'media_permission');
    return {
      'size': source.startsWith('content://')
          ? -1
          : await File(source).length(),
    };
  }
}

class _MissingArtifactRuntime extends NativeExportRuntime {
  @override
  Future<Map<String, Object?>> inspect(String source) =>
      Future.error(PlatformException(code: 'media_file_missing'));

  @override
  Future<Map<String, Object?>> stat(String source) =>
      Future.error(PlatformException(code: 'media_file_missing'));
}

class _PermissionMetadataRuntime extends NativeExportRuntime {
  int statCalls = 0;

  @override
  Future<Map<String, Object?>> inspect(String source) =>
      Future.error(PlatformException(code: 'media_permission'));

  @override
  Future<Map<String, Object?>> stat(String source) async {
    statCalls++;
    return {'size': 1};
  }
}

class _OversizedMetadataRuntime extends NativeExportRuntime {
  int statCalls = 0;

  @override
  Future<Map<String, Object?>> inspect(String source) =>
      Future.error(PlatformException(code: 'media_file_too_large'));

  @override
  Future<Map<String, Object?>> stat(String source) async {
    statCalls++;
    return {'size': 1};
  }
}

class _ScanRuntime extends NativeExportRuntime {
  _ScanRuntime(this.files);

  final List<Map<String, Object?>> files;

  @override
  Future<Map<String, Object?>> scanMedia({String? directory}) async => {
    'files': files,
    'warnings': const <String>[],
  };

  @override
  Future<Map<String, Object?>> inspect(String source) async => {'size': 6};

  @override
  Future<Map<String, Object?>> stat(String source) async => {'size': 6};

  @override
  Future<List<String>> deleteOwnedSources(
    String taskId,
    List<String> sources, {
    String? mutationReservationId,
  }) async {
    for (final source in sources) {
      await delete(source, allowMissing: true);
    }
    return List.of(sources);
  }
}

class _DelayedScanRuntime extends _ScanRuntime {
  _DelayedScanRuntime(super.files);
  final started = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<Map<String, Object?>> scanMedia({String? directory}) async {
    started.complete();
    await resume.future;
    return super.scanMedia(directory: directory);
  }

  @override
  Future<void> delete(String source, {bool allowMissing = false}) async {
    if (source.startsWith('content:')) return;
    if (await File(source).exists()) await File(source).delete();
  }
}

class _MaterializeRuntime extends _ScanRuntime {
  _MaterializeRuntime(this.path) : super([]);
  final String path;
  final started = Completer<void>();
  final resume = Completer<void>();
  int materializeCalls = 0;

  @override
  Future<String> materialize(String source) async {
    materializeCalls++;
    started.complete();
    await resume.future;
    await File(path).writeAsBytes([1, 2, 3]);
    return path;
  }

  @override
  Future<void> delete(String source, {bool allowMissing = false}) async {
    if (source.startsWith('content:')) return;
    if (await File(source).exists()) await File(source).delete();
  }
}

void main() {
  late Directory root;
  late AppDatabase db;
  late MediaTaskStore tasks;
  late MediaLibrary library;
  late MediaTask task;
  late File output;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-lens-library-');
    db = AppDatabase(NativeDatabase.memory());
    tasks = MediaTaskStore(db: db, directoryProvider: () async => root);
    final candidate = MediaCandidate(
      id: 'episode-3',
      hostId: 1,
      generation: 1,
      sourceUrl: Uri.parse('https://example.com/watch/3'),
      mediaUrl: Uri.parse('https://cdn.example/episode-3/index.m3u8'),
      title: '示例系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    await db.saveMediaCandidate(candidate);
    task = tasks.create(candidate);
    task = tasks.transition(task.id, MediaTaskState.downloading);
    task = tasks.transition(task.id, MediaTaskState.playable);
    await db.saveMediaTask(task);
    output = File('${root.path}/media_exports/output.mp4');
    await output.parent.create(recursive: true);
    await output.writeAsBytes([1, 2, 3, 4, 5, 6]);
    library = MediaLibrary(db: db, tasks: tasks);
  });
  tearDown(() async {
    library.dispose();
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'artifact uses actual output bytes and persists title with current episode',
    () async {
      final item = await library.register(task, output.path);
      expect(item.name, '示例系列 - 第3集.mp4');
      expect(item.size, 6);
      expect(tasks.task(task.id)?.localRef, isNull);
      final restored = MediaLibrary(db: db, tasks: tasks);
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.items.single.name, item.name);
      expect((await restored.localFile(task.id))?.path, output.path);
    },
  );

  test(
    'configured directory receives real bytes without overwriting a collision',
    () async {
      await library.register(task, output.path);
      final directory = Directory('${root.path}/chosen');
      await directory.create();
      final previous = File('${directory.path}/${mediaExportFileName(task)}');
      await previous.writeAsBytes([9]);
      await library.deliver(task.id, directory.path);
      final delivered = library.item(task.id)!;
      expect(await File(delivered.location).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await previous.readAsBytes(), [9]);
      expect(delivered.location, endsWith('(2).mp4'));
      expect(await output.exists(), isFalse);
      expect(await (await library.localFile(task.id))!.readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
        6,
      ]);
    },
  );

  test('rename and move update actual file and durable location, delete removes it', () async {
    await library.register(task, output.path);
    await library.rename(task.id, '自定义名称');
    expect(await output.exists(), isFalse);
    expect(library.item(task.id)!.name, '自定义名称.mp4');
    final destination = Directory('${root.path}/moved');
    await library.move(task.id, destination.path);
    expect(library.item(task.id)!.location, '${destination.path}/自定义名称.mp4');
    expect(await (await library.localFile(task.id))!.length(), 6);
    await library.delete(task.id);
    expect(library.items, isEmpty);
    expect(await db.mediaArtifacts(), isEmpty);
    expect(await destination.list().toList(), isEmpty);
    expect(tasks.task(task.id), isNotNull);
  });

  test('double move failure keeps both published target and original source in the durable catalog', () async {
    final destination = await Directory('${root.path}/double-failed-move')
        .create();
    final target = '${destination.path}/recovered.mp4';
    final runtime = _DoubleFailureMoveRuntime(target);
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks, native: runtime);
    await library.register(task, output.path);
    await expectLater(
      library.move(task.id, destination.path),
      throwsA(isA<PlatformException>()),
    );
    expect(library.item(task.id)!.location, target);
    expect(library.item(task.id)!.libraryCopy, output.path);
    expect(await output.exists(), isTrue);
    expect(await File(target).readAsBytes(), await output.readAsBytes());
    final restored = MediaLibrary(db: db, tasks: tasks, native: runtime);
    addTearDown(restored.dispose);
    await restored.restore();
    expect(restored.item(task.id)!.location, target);
    expect(restored.item(task.id)!.libraryCopy, output.path);
    await restored.deliver(task.id, null);
    expect(await output.exists(), isFalse);
    expect(await File(target).length(), 6);
    expect(restored.item(task.id)!.libraryCopy, isNull);
  });

  test(
    'missing move recovery target preserves the only surviving source on retry',
    () async {
      final destination = await Directory(
        '${root.path}/missing-recovery-target',
      ).create();
      final target = '${destination.path}/recovered.mp4';
      final runtime = _DoubleFailureMoveRuntime(target);
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      await library.register(task, output.path);
      await expectLater(
        library.move(task.id, destination.path),
        throwsA(isA<PlatformException>()),
      );
      await File(target).delete();
      await expectLater(
        library.move(task.id, destination.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await output.exists(), isTrue);
      expect(runtime.deleted, isEmpty);
      final stored = (await db.mediaArtifacts()).single;
      expect(stored['location'], target);
      expect(stored['libraryCopy'], output.path);
      expect(library.item(task.id)!.libraryCopy, output.path);
    },
  );

  test('shared MP4 detach retries persist the cache reference before deleting the durable old path', () async {
    final failing = _FailCacheReferenceDatabase();
    addTearDown(failing.close);
    final candidate = MediaCandidate(
      id: 'detach-failure',
      hostId: 1,
      generation: 1,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
      title: 'detach failure',
      mime: 'video/mp4',
      source: MediaCandidateSource.dom,
    );
    await failing.saveMediaCandidate(candidate);
    final store = MediaTaskStore(
      db: failing,
      directoryProvider: () async => root,
    );
    final current = store.create(candidate);
    store.transition(current.id, MediaTaskState.downloading);
    store.transition(current.id, MediaTaskState.playable);
    store.setLocalRef(current.id, output.path);
    await store.flush(current.id);
    final separate = MediaLibrary(db: failing, tasks: store);
    addTearDown(separate.dispose);
    await separate.register(store.task(current.id)!, output.path);
    failing.failDetachedReference = true;
    await expectLater(separate.delete(current.id), throwsStateError);
    expect(store.task(current.id)!.localRef, endsWith('.media'));
    expect(
      (await failing.mediaTaskByCacheKey(current.cacheKey))!.localRef,
      output.path,
    );
    await expectLater(separate.delete(current.id), throwsStateError);
    expect(await output.exists(), isTrue);
    expect(
      (await failing.mediaTaskByCacheKey(current.cacheKey))!.localRef,
      output.path,
    );
    failing.failDetachedReference = false;
    await separate.delete(current.id);
    final rebuilt = MediaTaskStore(
      db: failing,
      directoryProvider: () async => root,
    );
    await rebuilt.restore();
    final retained = rebuilt.task(current.id)!;
    expect(retained.localRef, endsWith('.media'));
    expect(await File(retained.localRef!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
    expect(await output.exists(), isFalse);
  });

  test('shared MP4 detach recovers a verified published copy after failed persistence and restart', () async {
    final failing = _FailCacheReferenceDatabase();
    addTearDown(failing.close);
    final candidate = MediaCandidate(
      id: 'detach-restart',
      hostId: 1,
      generation: 1,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
      title: 'detach restart',
      mime: 'video/mp4',
      source: MediaCandidateSource.dom,
    );
    await failing.saveMediaCandidate(candidate);
    final store = MediaTaskStore(
      db: failing,
      directoryProvider: () async => root,
    );
    final current = store.create(candidate);
    store.transition(current.id, MediaTaskState.downloading);
    store.transition(current.id, MediaTaskState.playable);
    store.setLocalRef(current.id, output.path);
    await store.flush(current.id);
    final runtime = _VerifiedCopyRuntime();
    final first = MediaLibrary(db: failing, tasks: store, native: runtime);
    addTearDown(first.dispose);
    await first.register(store.task(current.id)!, output.path);
    failing.failDetachedReference = true;
    await expectLater(first.delete(current.id), throwsStateError);
    final copied = store.task(current.id)!.localRef!;
    expect(copied, endsWith('.media'));
    expect(await File(copied).exists(), isTrue);
    expect(
      (await failing.mediaTaskByCacheKey(current.cacheKey))!.localRef,
      output.path,
    );
    final restartedStore = MediaTaskStore(
      db: failing,
      directoryProvider: () async => root,
    );
    await restartedStore.restore();
    expect(restartedStore.task(current.id)!.localRef, output.path);
    final restarted = MediaLibrary(
      db: failing,
      tasks: restartedStore,
      native: runtime,
    );
    addTearDown(restarted.dispose);
    await restarted.restore();
    failing.failDetachedReference = false;
    // A same-size unrelated file at the recovery path must not be adopted.
    await File(copied).writeAsBytes([6, 5, 4, 3, 2, 1]);
    await expectLater(
      restarted.delete(current.id),
      throwsA(isA<PlatformException>()),
    );
    expect(await output.exists(), isTrue);
    expect(restarted.item(current.id), isNotNull);
    expect(
      (await failing.mediaTaskByCacheKey(current.cacheKey))!.localRef,
      output.path,
    );
    await output.copy(copied);
    final modified = await File(copied).lastModified();
    await restarted.delete(current.id);
    expect(runtime.reuses, [copied]);
    expect(await File(copied).lastModified(), modified);
    expect(
      (await failing.mediaTaskByCacheKey(current.cacheKey))!.localRef,
      copied,
    );
    expect(await File(copied).readAsBytes(), [1, 2, 3, 4, 5, 6]);
    expect(await output.exists(), isFalse);
  });

  test('delivering MP4 keeps the media task HLS cache and metadata', () async {
    final cacheDirectory = await tasks.cacheDirectory(
      storageDirectory: task.storageDirectoryName,
    );
    final hlsDirectory = Directory(
      '${cacheDirectory.path}/${task.cacheKey}.hls',
    );
    await hlsDirectory.create(recursive: true);
    final playlist = File('${hlsDirectory.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nsegment.ts\n');
    await File('${hlsDirectory.path}/segment.ts').writeAsBytes([1, 2, 3]);
    tasks.setLocalRef(task.id, playlist.path);
    await library.register(task, output.path);
    final destination = Directory('${root.path}/chosen-hls');
    await library.deliver(task.id, destination.path);

    expect(tasks.task(task.id)!.localRef, playlist.path);
    expect(await tasks.cachedFile(task.id), isNotNull);
    expect(await output.exists(), isFalse);
    expect(await File(library.item(task.id)!.location).exists(), isTrue);
  });

  test(
    'a legacy private copy is cleaned before changing delivery directory',
    () async {
      final oldDestination = File('${root.path}/old-export.mp4');
      await output.copy(oldDestination.path);
      final value = MediaArtifact(
        taskId: task.id,
        location: oldDestination.path,
        libraryCopy: output.path,
        name: mediaExportFileName(task),
        size: 6,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();

      final directory = Directory('${root.path}/new-export');
      await library.deliver(task.id, directory.path);
      final location = library.item(task.id)!.location;
      await library.deliver(task.id, directory.path);

      expect(await File(location).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await output.exists(), isFalse);
      expect(await oldDestination.exists(), isFalse);
      expect(library.item(task.id)!.libraryCopy, isNull);
      expect(await directory.list().length, 1);
      expect(library.item(task.id)!.location, location);
    },
  );

  test(
    'batched delivery is idempotent after the batch folder is applied',
    () async {
      final batchedCandidate = MediaCandidate(
        id: 'episode-batched',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.com/watch/batched'),
        mediaUrl: Uri.parse('https://cdn.example/episode-batched/index.m3u8'),
        title: '批量系列 - 第2集',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
      );
      await db.saveMediaCandidate(batchedCandidate);
      final batched = tasks.create(
        batchedCandidate,
        batchDirectory: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
      );
      final batchedSource = File('${root.path}/batched-source.mp4')
        ..writeAsBytesSync([7, 8, 9]);
      await library.register(batched, batchedSource.path);
      final directory = Directory('${root.path}/batched-output');

      await library.deliver(batched.id, directory.path);
      final first = library.item(batched.id)!;
      await library.deliver(batched.id, directory.path);

      expect(library.item(batched.id)!.location, first.location);
      expect(
        first.location,
        contains(
          '${Platform.pathSeparator}系统带我攻略弟弟（漫剧版）${Platform.pathSeparator}',
        ),
      );
      expect(first.location, isNot(contains('批次1792686431921372')));
      expect(
        await directory
            .list(recursive: true)
            .where((entity) => entity is File)
            .length,
        1,
      );
    },
  );

  test('copy cleanup persists progress and retries a later failure', () async {
    final runtime = _CleanupRuntime();
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks, native: runtime);
    final temporary = File('${root.path}/materialized.mp4');
    await output.copy(temporary.path);
    final destination = File('${root.path}/delivered.mp4');
    await output.copy(destination.path);
    final value = MediaArtifact(
      taskId: task.id,
      location: destination.path,
      libraryCopy: output.path,
      materializedCopy: temporary.path,
      name: mediaExportFileName(task),
      size: 6,
      createdAt: DateTime.now().toUtc(),
    );
    await db.saveMediaArtifact(task.id, value.toJson());
    await library.restore();
    runtime.failOnce = temporary.path;

    await expectLater(
      library.deliver(task.id, null),
      throwsA(isA<PlatformException>()),
    );
    final interrupted = (await db.mediaArtifacts()).single;
    expect(interrupted['libraryCopy'], isNull);
    expect(interrupted['materializedCopy'], temporary.path);
    await library.deliver(task.id, null);

    expect(runtime.deleted, [output.path, temporary.path]);
    expect(library.item(task.id)!.materializedCopy, isNull);
    expect(await destination.length(), 6);
  });

  test('native reader rejects the complete cleanup set without changing copy metadata', () async {
    final runtime = _CleanupRuntime();
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks, native: runtime);
    final temporary = await output.copy('${root.path}/materialized-reader.mp4');
    final destination = await output.copy('${root.path}/delivered-reader.mp4');
    final value = MediaArtifact(
      taskId: task.id,
      location: destination.path,
      libraryCopy: output.path,
      materializedCopy: temporary.path,
      name: mediaExportFileName(task),
      size: 6,
      createdAt: DateTime.now().toUtc(),
    );
    await db.saveMediaArtifact(task.id, value.toJson());
    await library.restore();
    runtime.readerHeld = true;
    await expectLater(
      library.deliver(task.id, null),
      throwsA(isA<PlatformException>()),
    );
    expect(runtime.batches.single, [output.path, temporary.path]);
    expect(runtime.deleted, isEmpty);
    expect(await output.exists(), isTrue);
    expect(await temporary.exists(), isTrue);
    expect(library.item(task.id)!.libraryCopy, output.path);
    expect(library.item(task.id)!.materializedCopy, temporary.path);
    final stored = (await db.mediaArtifacts()).single;
    expect(stored['libraryCopy'], output.path);
    expect(stored['materializedCopy'], temporary.path);
    runtime.readerHeld = false;
    await library.deliver(task.id, null);
    expect(runtime.deleted, [output.path, temporary.path]);
    expect(await destination.length(), 6);
    expect(library.item(task.id)!.libraryCopy, isNull);
    expect(library.item(task.id)!.materializedCopy, isNull);
  });

  test(
    'cleanup tolerates already deleted bytes after interrupted metadata save',
    () async {
      final runtime = _CleanupRuntime();
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      final missing = '${root.path}/already-deleted.mp4';
      final value = MediaArtifact(
        taskId: task.id,
        location: output.path,
        libraryCopy: missing,
        name: mediaExportFileName(task),
        size: 6,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();

      await library.deliver(task.id, null);
      expect(runtime.deleted, [missing]);
      expect(library.item(task.id)!.libraryCopy, isNull);
      expect(await output.length(), 6);
    },
  );

  test(
    'temporary SAF materialization is removed after relay cleanup',
    () async {
      final runtime = _CleanupRuntime();
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      final materialized = File('${root.path}/materialized-relay.mp4');
      await output.copy(materialized.path);
      final value = MediaArtifact(
        taskId: task.id,
        location: 'content://provider/document/42',
        materializedCopy: materialized.path,
        name: mediaExportFileName(task),
        size: 6,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();

      await library.releaseMaterializedCopy(task.id);

      expect(await materialized.exists(), isFalse);
      expect(library.item(task.id)!.location, value.location);
      expect(library.item(task.id)!.materializedCopy, isNull);
    },
  );

  test('file management rejects a retained playback or cast task', () async {
    await library.register(task, output.path);
    tasks.retain(task.id);
    await expectLater(library.rename(task.id, 'blocked'), throwsStateError);
    await expectLater(library.delete(task.id), throwsStateError);
    expect(await output.exists(), isTrue);
    tasks.release(task.id);
    await library.delete(task.id);
    expect(await output.exists(), isFalse);
  });

  test(
    'codec metadata failure preserves known metadata and exportability',
    () async {
      final runtime = _MetadataFallbackRuntime();
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      final value = MediaArtifact(
        taskId: task.id,
        location: output.path,
        name: mediaExportFileName(task),
        size: 6,
        durationMs: 227000,
        width: 1280,
        height: 720,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();

      final item = await library.inspect(task.id);
      await library.deliver(task.id, null);

      expect(item.size, 6);
      expect(item.mime, 'video/mp4');
      expect(item.durationMs, 227000);
      expect(item.width, 1280);
      expect(item.height, 720);
      expect(await output.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    },
  );

  test(
    'SAF metadata fallback preserves facts but permissions remain required',
    () async {
      final runtime = _MetadataFallbackRuntime();
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      final value = MediaArtifact(
        taskId: task.id,
        location: 'content://provider/tree/root/document/video',
        name: mediaExportFileName(task),
        size: 600,
        durationMs: 227000,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();

      final item = await library.inspect(task.id);
      await library.deliver(task.id, 'content://provider/tree/root');
      expect(item.size, 600);
      expect(item.durationMs, 227000);
      expect(library.item(task.id)!.location, value.location);

      runtime.readable = false;
      await expectLater(
        library.deliver(task.id, null),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'media_permission',
          ),
        ),
      );
      expect(library.item(task.id)!.location, value.location);
    },
  );

  test(
    'revoked SAF metadata does not retry the provider as a codec fallback',
    () async {
      final runtime = _PermissionMetadataRuntime();
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      final value = MediaArtifact(
        taskId: task.id,
        location: 'content://provider/tree/root/document/revoked',
        name: mediaExportFileName(task),
        size: 600,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();

      await expectLater(
        library.inspect(task.id),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'media_permission',
          ),
        ),
      );
      expect(runtime.statCalls, 0);
    },
  );

  test('bounded SAF metadata failures remain visible instead of falling back silently', () async {
    final runtime = _OversizedMetadataRuntime();
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks, native: runtime);
    final value = MediaArtifact(
      taskId: task.id,
      location: 'content://provider/tree/root/document/large',
      name: mediaExportFileName(task),
      size: 600,
      createdAt: DateTime.now().toUtc(),
    );
    await db.saveMediaArtifact(task.id, value.toJson());
    await library.restore();

    await expectLater(
      library.inspect(task.id),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'media_file_too_large',
        ),
      ),
    );
    expect(runtime.statCalls, 0);
  });

  test('missing exported document remains indexed for recovery', () async {
    final runtime = _MissingArtifactRuntime();
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks, native: runtime);
    final value = MediaArtifact(
      taskId: task.id,
      location: 'content://provider/tree/primary%3ADownload/document/missing',
      name: mediaExportFileName(task),
      size: 600,
      createdAt: DateTime.now().toUtc(),
    );
    await db.saveMediaArtifact(task.id, value.toJson());
    await library.restore();

    await expectLater(
      library.inspect(task.id),
      throwsA(isA<PlatformException>()),
    );
    expect(library.item(task.id), isNotNull);
    expect(await db.mediaArtifacts(), hasLength(1));
  });

  test(
    'missing artifact recovers a surviving private copy without deleting HLS',
    () async {
      final value = MediaArtifact(
        taskId: task.id,
        location: '${root.path}/missing.mp4',
        libraryCopy: output.path,
        name: mediaExportFileName(task),
        size: 6,
        createdAt: DateTime.now().toUtc(),
      );
      await db.saveMediaArtifact(task.id, value.toJson());
      await library.restore();
      await expectLater(
        library.inspect(task.id),
        throwsA(isA<FileSystemException>()),
      );
      final recovered = await library.recoverMissingArtifact(task.id);
      expect(recovered!.location, output.path);
      expect(recovered.libraryCopy, isNull);
      expect(await output.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(tasks.task(task.id), isNotNull);
    },
  );

  test(
    'legacy empty titles are backfilled before importing an existing MP4',
    () async {
      await db.saveMediaTask(
        task.copyWith(
          displayTitle: '',
          episodeLabel: null,
          localRef: output.path,
        ),
      );
      await tasks.restore();
      await library.restore();
      final restored = tasks.task(task.id)!;
      expect(restored.displayName, '示例系列 - 第3集');
      expect(library.items.single.name, '示例系列 - 第3集.mp4');
      expect(library.items.single.size, 6);
    },
  );

  test(
    'invalid rename cannot escape its directory and empty exports are rejected',
    () async {
      await library.register(task, output.path);
      await expectLater(
        library.rename(task.id, '../outside'),
        throwsFormatException,
      );
      final empty = File('${root.path}/empty.mp4');
      await empty.create();
      await expectLater(library.register(task, empty.path), throwsStateError);
      expect(await output.exists(), isTrue);
    },
  );

  test('deleting a legacy artifact keeps the shared task MP4 cache', () async {
    tasks.setLocalRef(task.id, output.path);
    await library.restore();

    await library.delete(task.id);

    expect(library.items, isEmpty);
    expect(await output.exists(), isFalse);
    expect(await (await tasks.cachedFile(task.id))!.readAsBytes(), [
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    expect(tasks.task(task.id)!.state, MediaTaskState.playable);
    final restored = MediaLibrary(db: db, tasks: tasks);
    addTearDown(restored.dispose);
    await restored.restore();
    expect(restored.items, isEmpty);
  });

  test('invalid configured URI never reports a delivered artifact', () async {
    final previous = await library.register(task, output.path);
    await expectLater(
      library.deliver(task.id, 'https://example.com/Movies'),
      throwsStateError,
    );
    expect(library.item(task.id)!.location, previous.location);
    expect(await output.length(), 6);
  });

  test(
    'rescan restores an MP4 after its catalog row is missing and is idempotent',
    () async {
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks);
      await library.restore();

      final first = await library.rescan();
      expect(first.added, 1);
      expect(first.found, 1);
      expect(library.items.single.location, output.path);
      expect(library.items.single.taskId, startsWith('library_'));
      expect(await db.mediaArtifacts(), hasLength(1));

      final second = await library.rescan();
      expect(second.added, 0);
      expect(library.items, hasLength(1));
    },
  );

  test('rescan indexes a persisted SAF document without copying it', () async {
    await output.delete();
    final runtime = _ScanRuntime([
      {
        'uri': 'content://provider/tree/root/document/video',
        'name': '扫描恢复.mp4',
        'size': 600,
        'modifiedMs': 1,
        'folder': '批次',
      },
    ]);
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks, native: runtime);
    final result = await library.rescan(
      directory: 'content://provider/tree/root',
    );
    expect(result.added, 1);
    final item = library.items.single;
    expect(item.location, 'content://provider/tree/root/document/video');
    expect(item.folder, '批次');
    expect(item.libraryCopy, isNull);
    expect(item.materializedCopy, isNull);
  });

  test('media artifact index survives deletion of its download task', () async {
    final item = await library.register(task, output.path);
    await tasks.delete(task.id);
    final restored = MediaLibrary(db: db, tasks: tasks);
    addTearDown(restored.dispose);
    await restored.restore();
    expect(restored.item(item.taskId), isNotNull);
    expect(await output.exists(), isTrue);
    tasks.retain(item.taskId);
    await expectLater(tasks.restore(), throwsStateError);
    tasks.release(item.taskId);
    await tasks.restore();
    tasks.retain(item.taskId);
    tasks.release(item.taskId);
  });

  for (final legacy in [false, true]) {
    test(
      'download deletion preserves ${legacy ? "legacy shared" : "independent"} MP4 and catalog after restart',
      () async {
        final cacheRoot = await tasks.cacheDirectory(
          storageDirectory: task.storageDirectoryName,
        );
        final cache = File('${cacheRoot.path}/${task.cacheKey}.media');
        await cache.writeAsBytes([7, 8, 9]);
        tasks.setLocalRef(task.id, legacy ? output.path : cache.path);
        final item = await library.register(task, output.path);
        await tasks.flush(task.id);
        final bytes = await output.readAsBytes();

        await MediaDownloadService(tasks: tasks).delete(task.id);

        expect(tasks.task(task.id), isNull);
        expect(await cache.exists(), isFalse);
        expect(await output.readAsBytes(), bytes);
        expect(await db.mediaArtifacts(), hasLength(1));
        final restoredTasks = MediaTaskStore(
          db: db,
          directoryProvider: () async => root,
        );
        final restoredLibrary = MediaLibrary(db: db, tasks: restoredTasks);
        addTearDown(restoredLibrary.dispose);
        await restoredTasks.restore();
        await restoredLibrary.restore();
        expect(restoredTasks.task(task.id), isNull);
        expect(restoredLibrary.item(item.taskId)?.location, item.location);
        expect(await restoredLibrary.localFile(item.taskId), isNotNull);
        restoredTasks.retain(item.taskId);
        await expectLater(
          restoredLibrary.delete(item.taskId),
          throwsStateError,
        );
        restoredTasks.release(item.taskId);
      },
    );
  }

  test('scan identity is replaced by its task identity durably', () async {
    await library.rescan();
    final scannedId = library.items.single.taskId;
    await library.register(task, output.path);
    expect(library.items.single.taskId, task.id);
    expect(library.item(scannedId), isNull);
    expect(await db.mediaArtifacts(), hasLength(1));
    final staleScan = MediaArtifact(
      taskId: scannedId,
      location: output.uri.toString(),
      name: '扫描.mp4',
      size: 6,
      createdAt: DateTime.now().toUtc(),
    );
    expect(await db.saveMediaArtifact(scannedId, staleScan.toJson()), task.id);
    expect((await db.mediaArtifacts()).single['taskId'], task.id);
    final restored = MediaLibrary(db: db, tasks: tasks);
    addTearDown(restored.dispose);
    await restored.restore();
    expect(restored.items.single.taskId, task.id);
  });

  test(
    'reusing a moved export path preserves both catalog identities',
    () async {
      await library.rescan();
      final original = library.items.single;
      final destination = Directory('${root.path}/moved-away');
      await library.move(original.taskId, destination.path);
      final moved = library.item(original.taskId)!;
      await output.writeAsBytes([7, 8, 9]);
      final result = await library.rescan();
      expect(result.added, 1);
      expect(library.items, hasLength(2));
      expect(library.item(original.taskId)!.location, moved.location);
      expect(await File(moved.location).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await output.readAsBytes(), [7, 8, 9]);
      expect(await db.mediaArtifacts(), hasLength(2));
    },
  );

  test(
    'scan started before deletion does not resurrect a stale document',
    () async {
      final runtime = _DelayedScanRuntime([
        {'uri': output.path, 'name': 'old.mp4', 'size': 6},
      ]);
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      await library.register(task, output.path);
      final scan = library.rescan();
      await runtime.started.future;
      runtime.resume.complete();
      await library.delete(task.id);
      final result = await scan;
      expect(result.added, 0);
      expect(library.items, isEmpty);
      expect(await db.mediaArtifacts(), isEmpty);
    },
  );

  test(
    'rejected file operation does not cancel a scan or overcount it',
    () async {
      final runtime = _DelayedScanRuntime([
        {
          'uri': 'content://provider/document/other',
          'name': '恢复.mp4',
          'size': 6,
        },
      ]);
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      await library.register(task, output.path);
      final scan = library.rescan();
      await runtime.started.future;
      tasks.retain(task.id);
      await expectLater(library.rename(task.id, '使用中'), throwsStateError);
      runtime.resume.complete();
      final result = await scan;
      tasks.release(task.id);
      expect(result.added, 1);
      expect(library.items, hasLength(2));
    },
  );

  test(
    'materialization holds a file lease until its catalog write completes',
    () async {
      final runtime = _MaterializeRuntime('${root.path}/materialized.mp4');
      await db.saveMediaArtifact(
        task.id,
        MediaArtifact(
          taskId: task.id,
          location: 'content://provider/document/video',
          name: '视频.mp4',
          size: 6,
          createdAt: DateTime.now().toUtc(),
        ).toJson(),
      );
      library.dispose();
      library = MediaLibrary(db: db, tasks: tasks, native: runtime);
      await library.restore();
      final pending = Future.wait([
        library.localFile(task.id),
        library.localFile(task.id),
      ]);
      await runtime.started.future;
      await expectLater(library.delete(task.id), throwsStateError);
      runtime.resume.complete();
      final files = await pending;
      expect(files.map((file) => file?.path), everyElement(runtime.path));
      expect(runtime.materializeCalls, 1);
      await library.delete(task.id);
      expect(await File(runtime.path).exists(), isFalse);
      expect(library.items, isEmpty);
      expect(await db.mediaArtifacts(), isEmpty);
    },
  );
}
