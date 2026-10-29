import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/media/media_organization.dart';

void main() {
  late AppDatabase db;
  late MediaOrganizationService organization;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    organization = MediaOrganizationService(
      db: db,
      collection: 'media-organization-test',
    );
  });

  tearDown(() async {
    organization.dispose();
    await db.close();
  });

  test('persists folder hierarchy, item placement, and virtual name', () async {
    final series = await organization.createFolder('系列');
    final season = await organization.createFolder('第一季', parentId: series.id);

    await organization.moveItems(['item-1'], season.id);
    await organization.renameItem('item-1', '虚拟标题');

    final restored = MediaOrganizationService.reader(
      db: db,
      collection: 'media-organization-test',
    );
    addTearDown(restored.dispose);
    await restored.restore();

    expect(restored.folder(series.id)?.name, '系列');
    expect(restored.folder(season.id)?.parentId, series.id);
    expect(restored.folderFor('item-1'), season.id);
    expect(restored.nameFor('item-1', '原始标题'), '虚拟标题');
  });

  test('folder item expansion includes all descendant folders', () async {
    final root = await organization.createFolder('根目录');
    final child = await organization.createFolder('子目录', parentId: root.id);
    await organization.moveItems(['root-item'], root.id);
    await organization.moveItems(['child-item'], child.id);

    expect(organization.itemIdsInFolder(root.id).toSet(), {
      'root-item',
      'child-item',
    });
    expect(organization.itemIdsInFolder(child.id), ['child-item']);
  });

  test('rejects moving a folder into itself or a descendant', () async {
    final parent = await organization.createFolder('父目录');
    final child = await organization.createFolder('子目录', parentId: parent.id);

    await expectLater(
      organization.moveFolder(parent.id, parent.id),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      organization.moveFolder(parent.id, child.id),
      throwsA(isA<StateError>()),
    );
  });

  test('legacy sync does not overwrite an existing virtual move', () async {
    final legacy = await organization.createFolder('旧批次目录');
    final destination = await organization.createFolder('新目录');

    await organization.restoreAndSync([
      const MediaOrganizationSeed(itemId: 'task-1', legacyFolder: '旧批次目录'),
    ]);
    expect(organization.folderFor('task-1'), legacy.id);

    await organization.moveItems(['task-1'], destination.id);
    await organization.restoreAndSync([
      const MediaOrganizationSeed(itemId: 'task-1', legacyFolder: '旧批次目录'),
    ]);

    expect(organization.folderFor('task-1'), destination.id);
  });

  test(
    'generated batch suffix is hidden while user folder names stay intact',
    () async {
      await organization.restoreAndSync([
        const MediaOrganizationSeed(
          itemId: 'task-batch',
          legacyFolder: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
        ),
      ]);
      final folderId = organization.folderFor('task-batch');
      expect(organization.folder(folderId!)?.name, '系统带我攻略弟弟（漫剧版）');

      await organization.renameFolder(folderId, '我的手动目录');
      await organization.restoreAndSync([
        const MediaOrganizationSeed(
          itemId: 'task-batch',
          legacyFolder: '系统带我攻略弟弟（漫剧版） - 批次1792686431921372',
        ),
      ]);
      expect(organization.folder(folderId)?.name, '我的手动目录');
    },
  );

  test('ordinary legacy folder names are not normalized or merged', () async {
    await organization.restoreAndSync([
      const MediaOrganizationSeed(itemId: 'slash', legacyFolder: 'A/B'),
      const MediaOrganizationSeed(itemId: 'underscore', legacyFolder: 'A_B'),
    ]);

    final slash = organization.folderFor('slash');
    final underscore = organization.folderFor('underscore');
    expect(slash, isNotNull);
    expect(underscore, isNotNull);
    expect(slash, isNot(underscore));
    expect(organization.folder(slash!)?.name, 'A/B');
    expect(organization.folder(underscore!)?.name, 'A_B');
  });

  test('automatic roots with children keep their legacy name', () async {
    const legacy = '系统带我攻略弟弟（漫剧版） - 批次1792686431921372';
    final automaticId =
        'folder_${sha256.convert(utf8.encode(legacy)).toString().substring(0, 24)}';
    await db.setSetting(
      organization.settingKey,
      jsonEncode({
        'folders': [
          {'id': automaticId, 'name': legacy, 'parentId': null},
          {'id': 'child', 'name': '手动子目录', 'parentId': automaticId},
        ],
        'itemFolders': {'one': automaticId},
        'itemNames': {},
        'imported': ['one'],
        'legacyFolders': {legacy: automaticId},
      }),
    );

    await organization.restoreAndSync([
      const MediaOrganizationSeed(itemId: 'one', legacyFolder: legacy),
    ]);

    expect(organization.folder(automaticId)?.name, legacy);
    expect(organization.folder('child')?.parentId, automaticId);
  });

  test('restored automatic roots merge without disturbing user-owned folders', () async {
    const legacy = '系统带我攻略弟弟（漫剧版） - 批次1792686431921372';
    final automaticId =
        'folder_${sha256.convert(utf8.encode(legacy)).toString().substring(0, 24)}';
    await db.setSetting(
      organization.settingKey,
      jsonEncode({
        'folders': [
          {'id': automaticId, 'name': legacy, 'parentId': null},
          {'id': 'series', 'name': '系统带我攻略弟弟（漫剧版）', 'parentId': null},
          {
            'id': 'manual',
            'name': '手动系列 - 批次1792686431921372',
            'parentId': null,
          },
        ],
        'itemFolders': {'one': automaticId, 'two': 'series', 'three': 'manual'},
        'itemNames': {'one': '我的剧集标题'},
        'imported': ['one', 'two', 'three'],
        'legacyFolders': {
          legacy: automaticId,
          '手动系列 - 批次1792686431921372': 'manual',
        },
      }),
    );
    const seeds = [
      MediaOrganizationSeed(itemId: 'one', legacyFolder: legacy),
      MediaOrganizationSeed(itemId: 'two'),
      MediaOrganizationSeed(itemId: 'three'),
    ];
    await organization.restoreAndSync(seeds);
    expect(organization.folder(automaticId), isNull);
    expect(organization.folderFor('one'), 'series');
    expect(organization.folderFor('two'), 'series');
    expect(organization.nameFor('one', 'fallback'), '我的剧集标题');
    expect(organization.folder('manual')?.name, '手动系列 - 批次1792686431921372');

    final restored = MediaOrganizationService.reader(
      db: db,
      collection: organization.collection,
    );
    addTearDown(restored.dispose);
    await restored.restoreAndSync(seeds);
    expect(restored.folderFor('one'), 'series');
    expect(restored.folder('manual')?.name, '手动系列 - 批次1792686431921372');
  });
}
