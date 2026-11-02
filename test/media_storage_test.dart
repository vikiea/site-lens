import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/media_storage.dart';
import 'package:site_lens/media/media_storage_mode.dart';
import 'package:site_lens/media/native_export_runtime.dart';

class _DirectoryCacheRuntime extends NativeExportRuntime {
  int listCalls = 0;
  bool available = true;

  @override
  Future<void> configureDirectRoot(String? path) async {}

  @override
  Future<bool> checkDirectDirectory(String path) async => available;

  @override
  Future<List<Map<String, Object?>>> listDirectDirectory(String path) async {
    listCalls++;
    return [
      {
        'path': '$path/series',
        'name': 'series',
        'directory': true,
        'size': 0,
        'modifiedMs': 10,
      },
      {
        'path': '$path/readme.txt',
        'name': 'readme.txt',
        'directory': false,
        'size': 12,
        'modifiedMs': 11,
      },
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late MediaTaskStore tasks;
  late MediaLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-lens-storage-');
    db = AppDatabase(NativeDatabase.memory());
    tasks = MediaTaskStore(db: db, directoryProvider: () async => root);
    library = MediaLibrary(db: db, tasks: tasks);
  });

  tearDown(() async {
    library.dispose();
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'uses an app-private media root when no system directory is configured',
    () async {
      final storage = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => null,
      );

      final resolved = await storage.resolve();

      expect(resolved.kind, MediaStorageKind.appPrivate);
      expect(resolved.permission, MediaStoragePermission.unconfigured);
      expect(resolved.location, endsWith('/media_exports'));
      expect(await Directory(resolved.location).exists(), isTrue);
    },
  );

  test(
    'directory snapshots reuse memory and persist across service instances',
    () async {
      final destination = Directory('${root.path}/system-media')
        ..createSync(recursive: true);
      final runtime = _DirectoryCacheRuntime();
      final first = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => destination.path,
        configuredMode: () async => MediaStorageMode.directPath,
        native: runtime,
      );

      final fresh = await first.listDirectory();
      expect(fresh, hasLength(2));
      expect(runtime.listCalls, 1);
      expect(await first.cachedDirectory(), hasLength(2));
      expect(runtime.listCalls, 1);

      first.invalidate();
      final second = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => destination.path,
        configuredMode: () async => MediaStorageMode.directPath,
        native: runtime,
      );
      expect(await second.cachedDirectory(), hasLength(2));
      expect(runtime.listCalls, 1);
      runtime.available = false;
      second.invalidate();
      expect(
        await second.cachedDirectorySnapshot(
          rootId: destination.absolute.path,
          directory: destination.absolute.path,
        ),
        isNull,
      );
    },
  );

  test('only artifacts outside a configured root need migration', () async {
    final destination = Directory('${root.path}/system-media')
      ..createSync(recursive: true);
    final outside = File('${root.path}/outside.mp4')..writeAsBytesSync([1, 2]);
    final inside = File('${destination.path}/inside.mp4')
      ..writeAsBytesSync([1, 2]);
    await db.saveMediaArtifact(
      'outside',
      MediaArtifact(
        taskId: 'outside',
        location: outside.path,
        name: outside.uri.pathSegments.last,
        size: 2,
        createdAt: DateTime.now().toUtc(),
        storageRootId: root.path,
        relativePath: 'outside.mp4',
      ).toJson(),
    );
    await db.saveMediaArtifact(
      'inside',
      MediaArtifact(
        taskId: 'inside',
        location: inside.path,
        name: inside.uri.pathSegments.last,
        size: 2,
        createdAt: DateTime.now().toUtc(),
        storageRootId: destination.path,
        relativePath: 'inside.mp4',
      ).toJson(),
    );
    await library.restore();
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => destination.path,
    );

    expect(await storage.needsMigration(library.item('outside')!), isTrue);
    expect(await storage.needsMigration(library.item('inside')!), isFalse);
  });

  test('a mode switch recognizes an existing file through its persisted relative path', () async {
    final destination = Directory('${root.path}/system-media/series')
      ..createSync(recursive: true);
    final existing = File('${destination.path}/episode.mp4')
      ..writeAsBytesSync([1, 2, 3]);
    await db.saveMediaArtifact(
      'same-physical-file',
      MediaArtifact(
        taskId: 'same-physical-file',
        location: 'content://provider/tree/old/document/old/series/episode',
        name: 'episode.mp4',
        size: 3,
        createdAt: DateTime.now().toUtc(),
        relativePath: 'series/episode.mp4',
        storageRootId: 'content://provider/tree/old',
        storageKind: 'safTree',
        migrationState: 'complete',
      ).toJson(),
    );
    await library.restore();
    const channel = MethodChannel('test.media-storage-identity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'configureDirectRoot':
              return null;
            case 'checkDirectDirectory':
              return true;
            case 'sha256':
              return 'same-content-digest';
          }
          throw PlatformException(code: 'unexpected', message: call.method);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => destination.parent.path,
      native: NativeExportRuntime(channel: channel),
    );

    expect(
      await storage.needsMigration(library.item('same-physical-file')!),
      isFalse,
    );
    expect(await existing.exists(), isTrue);
  });

  test(
    'explicit migration preserves the persisted relative directory',
    () async {
      final destination = Directory('${root.path}/system-media')
        ..createSync(recursive: true);
      final sourceDirectory = Directory('${root.path}/old-media/series')
        ..createSync(recursive: true);
      final source = File('${sourceDirectory.path}/episode.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      await db.saveMediaArtifact(
        'preserve-folder',
        MediaArtifact(
          taskId: 'preserve-folder',
          location: source.path,
          name: 'episode.mp4',
          size: 3,
          createdAt: DateTime.now().toUtc(),
          relativePath: 'series/episode.mp4',
          folder: 'series',
          storageRootId: sourceDirectory.parent.path,
        ).toJson(),
      );
      await library.restore();
      final storage = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => destination.path,
      );

      await storage.migrateArtifact('preserve-folder');

      expect(
        await File('${destination.path}/series/episode.mp4').readAsBytes(),
        [1, 2, 3],
      );
      expect(await File('${destination.path}/episode.mp4').exists(), isFalse);
      expect(
        library.item('preserve-folder')!.relativePath,
        'series/episode.mp4',
      );
    },
  );

  test(
    'does not migrate when SAF and direct path representations are unproven',
    () async {
      final destination = Directory('${root.path}/system-media')
        ..createSync(recursive: true);
      await db.saveMediaArtifact(
        'unknown-representation',
        MediaArtifact(
          taskId: 'unknown-representation',
          location: 'content://provider/tree/old/document/old/series/episode',
          name: 'episode.mp4',
          size: 3,
          createdAt: DateTime.now().toUtc(),
          relativePath: 'series/episode.mp4',
        ).toJson(),
      );
      await library.restore();
      final storage = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => destination.path,
      );

      await expectLater(
        storage.needsMigration(library.item('unknown-representation')!),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        storage.migrateArtifact('unknown-representation'),
        throwsA(isA<StateError>()),
      );
      expect(await Directory('${destination.path}/series').exists(), isFalse);
      expect(await db.setting(MediaStorageService.migrationJournalKey), isNull);
    },
  );

  test('lists and creates real directories in the app-private root', () async {
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => null,
    );
    final rootValue = await storage.resolve();

    final created = await storage.createDirectory(
      parent: rootValue.location,
      name: 'Season 1',
    );
    final entries = await storage.listDirectory();

    expect(created, endsWith('/Season 1'));
    expect(entries.single.name, 'Season 1');
    expect(entries.single.directory, isTrue);
  });

  test(
    'whole-directory copy preserves non-media files and hierarchy',
    () async {
      final storage = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => null,
      );
      final rootValue = await storage.resolve();
      final source = Directory('${rootValue.location}/source/sub')
        ..createSync(recursive: true);
      File('${rootValue.location}/source/video.mp4').writeAsBytesSync([1, 2]);
      File('${source.path}/notes.txt').writeAsStringSync('keep');
      final destination = Directory('${rootValue.location}/destination')
        ..createSync(recursive: true);

      await storage.copyEntry('${rootValue.location}/source', destination.path);

      expect(await File('${destination.path}/source/video.mp4').readAsBytes(), [
        1,
        2,
      ]);
      expect(
        await File('${destination.path}/source/sub/notes.txt').readAsString(),
        'keep',
      );
    },
  );

  test(
    'whole-directory move keeps the source until catalog rewrites commit',
    () async {
      final storage = MediaStorageService(
        tasks: tasks,
        library: library,
        configuredRoot: () async => null,
      );
      final rootValue = await storage.resolve();
      final source = Directory('${rootValue.location}/source')
        ..createSync(recursive: true);
      final sourceFile = File('${source.path}/video.mp4')
        ..writeAsBytesSync([1, 2]);
      final destination = Directory('${rootValue.location}/destination')
        ..createSync(recursive: true);

      final rewrites = await storage.copyEntry(
        source.path,
        destination.path,
        move: true,
      );

      expect(await sourceFile.exists(), isTrue);
      expect(await File('${destination.path}/source/video.mp4').readAsBytes(), [
        1,
        2,
      ]);
      expect(rewrites[sourceFile.path], '${destination.path}/source/video.mp4');

      await storage.deleteEntry(source.path);
      expect(await source.exists(), isFalse);
    },
  );

  test('moved migration journal keeps the original index when content differs', () async {
    final destination = Directory('${root.path}/system-media')
      ..createSync(recursive: true);
    final source = File('${root.path}/episode.mp4')..writeAsBytesSync([1, 2]);
    final target = File('${destination.path}/episode.mp4')
      ..writeAsBytesSync([3, 4]);
    await db.saveMediaArtifact(
      'journal-mismatch',
      MediaArtifact(
        taskId: 'journal-mismatch',
        location: source.path,
        name: 'episode.mp4',
        size: 2,
        createdAt: DateTime.now().toUtc(),
        storageRootId: root.path,
        relativePath: 'episode.mp4',
      ).toJson(),
    );
    await library.restore();
    await db.setSetting(
      MediaStorageService.migrationJournalKey,
      '{"journal-mismatch":{"target":"${destination.path}","fileName":"episode.mp4","phase":"moved"}}',
    );
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => destination.path,
    );

    await storage.reconcileMigrationJournal();

    expect(library.item('journal-mismatch')!.location, source.path);
    expect(await target.exists(), isTrue);
    expect(
      await db.setting(MediaStorageService.migrationJournalKey),
      isNotEmpty,
    );
  });

  test('rejects traversal and protects the media root from deletion', () async {
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => null,
    );
    final rootValue = await storage.resolve();

    await expectLater(
      storage.createDirectory(parent: rootValue.location, name: '../outside'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      storage.deleteEntry(rootValue.location),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      storage.deleteEntry(Directory(rootValue.location).uri.toString()),
      throwsA(isA<StateError>()),
    );
  });

  test('keeps SAF child directories within the selected tree and rejects other documents', () async {
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => 'content://provider/tree/root',
    );
    final item = MediaArtifact(
      taskId: 'saf-child',
      location: 'content://provider/tree/root/document/root/child/video',
      name: 'child.mp4',
      size: 1,
      createdAt: DateTime.now().toUtc(),
    );

    expect(
      await storage.isArtifactInDirectory(
        item,
        'content://provider/tree/root/document/root/child',
      ),
      isTrue,
    );
    await expectLater(
      storage.isArtifactInDirectory(
        item,
        'content://provider/tree/root/document/other',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('artifact storage metadata survives a real rename', () async {
    final storageRoot = Directory('${root.path}/media_exports')
      ..createSync(recursive: true);
    final source = File('${storageRoot.path}/before.mp4')
      ..writeAsBytesSync([1, 2, 3]);
    await db.saveMediaArtifact(
      'metadata',
      MediaArtifact(
        taskId: 'metadata',
        location: source.path,
        name: 'before.mp4',
        size: 3,
        createdAt: DateTime.now().toUtc(),
        storageRootId: 'private-root',
        relativePath: 'before.mp4',
        storageKind: 'appPrivate',
        migrationState: 'complete',
      ).toJson(),
    );
    await library.restore();

    await library.rename('metadata', 'after');
    final item = library.item('metadata')!;

    expect(item.name, 'after.mp4');
    expect(item.storageRootId, 'private-root');
    expect(item.relativePath, 'before.mp4');
    expect(item.storageKind, 'appPrivate');
    expect(item.migrationState, 'complete');
  });

  test('keeps a journaled move when the source cannot prove target identity', () async {
    final mediaRoot = Directory('${root.path}/media_exports')
      ..createSync(recursive: true);
    final target = File('${mediaRoot.path}/recovered.mp4')
      ..writeAsBytesSync([1, 2, 3]);
    await db.saveMediaArtifact(
      'journal',
      MediaArtifact(
        taskId: 'journal',
        location: '${root.path}/missing.mp4',
        name: 'recovered.mp4',
        size: 3,
        createdAt: DateTime.now().toUtc(),
      ).toJson(),
    );
    await db.setSetting(
      MediaStorageService.migrationJournalKey,
      '{"journal":{"source":"${root.path}/missing.mp4","target":"${mediaRoot.path}","fileName":"recovered.mp4","phase":"planned"}}',
    );
    library.dispose();
    library = MediaLibrary(db: db, tasks: tasks);
    final storage = MediaStorageService(
      tasks: tasks,
      library: library,
      configuredRoot: () async => null,
    );

    await storage.reconcileMigrationJournal();

    expect(library.item('journal')!.location, '${root.path}/missing.mp4');
    expect(await storage.pendingMigrationCount(), 1);
    expect(await target.exists(), isTrue);
  });
}
