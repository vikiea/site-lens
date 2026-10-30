import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/media_storage.dart';

void main() {
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

  test('reconciles a journaled local move after catalog persistence failure', () async {
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

    expect(library.item('journal')!.location, target.path);
    expect(await storage.pendingMigrationCount(), 0);
  });
}
