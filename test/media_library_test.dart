import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_export_runtime.dart';

class _CleanupRuntime extends NativeExportRuntime {
  String? failOnce;
  final deleted = <String>[];

  @override
  Future<Map<String, Object?>> inspect(String source) async => {
    'size': await File(source).length(),
  };

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

    await expectLater(library.deliver(task.id, null), throwsStateError);
    final interrupted = (await db.mediaArtifacts()).single;
    expect(interrupted['libraryCopy'], isNull);
    expect(interrupted['materializedCopy'], temporary.path);
    await library.deliver(task.id, null);

    expect(runtime.deleted, [output.path, temporary.path]);
    expect(library.item(task.id)!.materializedCopy, isNull);
    expect(await destination.length(), 6);
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
}
