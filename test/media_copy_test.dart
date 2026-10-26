import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';

MediaCandidate _candidate({
  String id = 'copy-candidate',
  String mime = 'video/mp4',
  String url = 'https://cdn.example/video.mp4',
}) => MediaCandidate(
  id: id,
  hostId: 7,
  generation: 3,
  sourceUrl: Uri.parse('https://example.com/watch'),
  mediaUrl: Uri.parse(url),
  title: '复制测试媒体',
  mime: mime,
  source: MediaCandidateSource.dom,
);

void main() {
  late Directory root;
  late AppDatabase db;
  late MediaTaskStore tasks;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-lens-media-copy-');
    db = AppDatabase(NativeDatabase.memory());
    tasks = MediaTaskStore(db: db, directoryProvider: () async => root);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'copyCompleted creates independent bytes and a new task identity',
    () async {
      final candidate = _candidate();
      await db.saveMediaCandidate(candidate);
      var task = tasks.create(candidate);
      task = tasks.transition(task.id, MediaTaskState.downloading);
      task = tasks.transition(task.id, MediaTaskState.playable);

      final source = File(
        p.join(root.path, 'media_cache', '${task.cacheKey}.media'),
      );
      await source.parent.create(recursive: true);
      final bytes = List<int>.generate(128, (index) => index % 251);
      await source.writeAsBytes(bytes);
      tasks.setLocalRef(task.id, source.path);
      tasks.updateProgress(task.id, bytes.length, totalBytes: bytes.length);

      final copied = await tasks.copyCompleted(task.id);

      expect(copied.id, isNot(task.id));
      expect(copied.cacheKey, isNot(task.cacheKey));
      expect(await File(copied.localRef!).readAsBytes(), bytes);

      await source.delete();
      expect(await File(copied.localRef!).readAsBytes(), bytes);
    },
  );

  test('copyCompleted refuses a busy lease', () async {
    final candidate = _candidate(id: 'busy-copy-candidate');
    await db.saveMediaCandidate(candidate);
    var task = tasks.create(candidate);
    task = tasks.transition(task.id, MediaTaskState.downloading);
    task = tasks.transition(task.id, MediaTaskState.playable);
    final source = File(
      p.join(root.path, 'media_cache', '${task.cacheKey}.media'),
    );
    await source.parent.create(recursive: true);
    await source.writeAsBytes([1, 2, 3]);
    tasks.setLocalRef(task.id, source.path);
    tasks.updateProgress(task.id, 3, totalBytes: 3);

    tasks.retain(task.id);
    addTearDown(() => tasks.release(task.id));

    await expectLater(tasks.copyCompleted(task.id), throwsA(isA<StateError>()));
  });

  test('copyLocalHls copies relative key, init, and segment files', () async {
    final sourceRoot = Directory(p.join(root.path, 'source-hls'));
    final destination = Directory(p.join(root.path, 'copied-hls'));
    await Directory(p.join(sourceRoot.path, 'keys')).create(recursive: true);
    await Directory(p.join(sourceRoot.path, 'segments'))
        .create(recursive: true);

    final key = File(p.join(sourceRoot.path, 'keys', 'key.bin'));
    final init = File(p.join(sourceRoot.path, 'init.mp4'));
    final segment = File(p.join(sourceRoot.path, 'segments', '0.ts'));
    await key.writeAsBytes([9, 8, 7]);
    await init.writeAsBytes([1, 2, 3, 4]);
    await segment.writeAsBytes([5, 6, 7, 8, 9]);
    final manifest = File(p.join(sourceRoot.path, 'index.m3u8'));
    await manifest.writeAsString('''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"
#EXTINF:4,
segments/0.ts
#EXT-X-ENDLIST
''');

    await copyLocalHls(manifest, destination);

    expect(
      await File(p.join(destination.path, 'keys', 'key.bin')).readAsBytes(),
      [9, 8, 7],
    );
    expect(await File(p.join(destination.path, 'init.mp4')).readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    expect(
      await File(p.join(destination.path, 'segments', '0.ts')).readAsBytes(),
      [5, 6, 7, 8, 9],
    );
    expect(
      await File(p.join(destination.path, 'index.m3u8')).readAsString(),
      await manifest.readAsString(),
    );

    await sourceRoot.delete(recursive: true);
    expect(
      await File(p.join(destination.path, 'keys', 'key.bin')).readAsBytes(),
      [9, 8, 7],
    );
  });

  test('copyLocalHls rejects traversal outside the source folder', () async {
    final sourceRoot = Directory(p.join(root.path, 'unsafe-hls'));
    await sourceRoot.create(recursive: true);
    final outside = File(p.join(root.path, 'outside.ts'));
    await outside.writeAsBytes([1]);
    final manifest = File(p.join(sourceRoot.path, 'index.m3u8'));
    await manifest.writeAsString('''#EXTM3U
#EXTINF:1,
../outside.ts
#EXT-X-ENDLIST
''');

    await expectLater(
      copyLocalHls(manifest, Directory(p.join(root.path, 'unsafe-copy'))),
      throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
    );
  });

  test(
    'copyLocalHls materializes controlled shared resource symlinks',
    () async {
      final taskRoot = Directory(
        p.join(root.path, 'media_cache', 'series', 'task.hls'),
      );
      final sharedRoot = Directory(
        p.join(root.path, 'media_cache', 'shared_resources'),
      );
      final destination = Directory(p.join(root.path, 'copied-shared-hls'));
      await taskRoot.create(recursive: true);
      await sharedRoot.create(recursive: true);
      final sharedKey = File(p.join(sharedRoot.path, 'key.bin'))
        ..writeAsBytesSync(List.filled(16, 3));
      await Link(p.join(taskRoot.path, 'key.bin')).create(sharedKey.path);
      File(p.join(taskRoot.path, 'segment.ts')).writeAsBytesSync([1, 2, 3]);
      final manifest = File(p.join(taskRoot.path, 'index.m3u8'))
        ..writeAsStringSync(
          '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:1,\n'
          'segment.ts\n'
          '#EXT-X-ENDLIST\n',
        );

      await copyLocalHls(manifest, destination);

      expect(
        await File(p.join(destination.path, 'key.bin')).readAsBytes(),
        List.filled(16, 3),
      );
      expect(await File(p.join(destination.path, 'segment.ts')).readAsBytes(), [
        1,
        2,
        3,
      ]);
      await taskRoot.delete(recursive: true);
      await sharedRoot.delete(recursive: true);
      expect(
        await File(p.join(destination.path, 'key.bin')).readAsBytes(),
        List.filled(16, 3),
      );
    },
  );
}
