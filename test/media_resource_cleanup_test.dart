import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/media/media_resource_coordinator.dart';
import 'package:site_lens/media/media_service.dart';

class _RetryingCleanupCoordinator extends MediaResourceCoordinator {
  _RetryingCleanupCoordinator({required super.rootProvider});

  bool failOnce = true;
  Future<void> Function()? beforeDelete;

  @override
  Future<bool> deleteIf(String key, Future<bool> Function() predicate) async {
    if (failOnce) {
      failOnce = false;
      throw const FileSystemException('temporary cleanup failure');
    }
    await beforeDelete?.call();
    return super.deleteIf(key, predicate);
  }
}

void main() {
  const key =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  late Directory root;
  late AppDatabase db;
  late MediaTaskStore tasks;
  late _RetryingCleanupCoordinator coordinator;
  late File resource;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('media-resource-cleanup-');
    db = AppDatabase(NativeDatabase.memory());
    tasks = MediaTaskStore(db: db, directoryProvider: () async => root);
    await tasks.ready;
    coordinator = _RetryingCleanupCoordinator(rootProvider: () async => root);
    resource = await coordinator.ensure(key, (File partial) async {
      await partial.writeAsBytes([1, 2, 3]);
    });
    await db.addMediaResourceOwner(key, 'task:deleted', 'task');
    await db.removeMediaResourceOwner(key, 'task:deleted');
  });

  tearDown(() async {
    tasks.dispose();
    await db.close();
    await root.delete(recursive: true);
  });

  MediaDownloadService service() =>
      MediaDownloadService(tasks: tasks, resourceCoordinator: coordinator);

  test(
    'failed orphan cleanup is recovered by a new service instance',
    () async {
      await service().reconcileOrphanedSharedResources();
      expect(await resource.exists(), isTrue);
      expect(await db.mediaResourceKeys(), [key]);

      await service().reconcileOrphanedSharedResources();

      expect(await resource.exists(), isFalse);
      expect(await db.mediaResourceKeys(), isEmpty);
    },
  );

  test('startup reconciliation preserves resources with an owner', () async {
    await db.addMediaResourceOwner(key, 'task:active', 'task');
    coordinator.failOnce = false;

    await service().reconcileOrphanedSharedResources();

    expect(await resource.readAsBytes(), [1, 2, 3]);
    expect(await db.mediaResourceKeys(), [key]);
    expect(await db.mediaResourceOwners(key), ['task:active']);
  });

  test(
    'cleanup rechecks owners after acquiring the filesystem lease',
    () async {
      coordinator.failOnce = false;
      coordinator.beforeDelete = () =>
          db.addMediaResourceOwner(key, 'task:new', 'task');

      await service().reconcileOrphanedSharedResources();

      expect(await resource.readAsBytes(), [1, 2, 3]);
      expect(await db.mediaResourceOwners(key), ['task:new']);
    },
  );
}
