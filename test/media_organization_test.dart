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
}
