import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';

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
