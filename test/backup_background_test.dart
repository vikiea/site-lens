import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/background/background_asset_store.dart';
import 'package:site_lens/backup/backup_service.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';

void main() {
  final png1x1 = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    ),
  );
  late Directory root;
  late AppDatabase db;
  late BackgroundAssetStore assets;
  late BackupService backup;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-lens-backup-bg-');
    assets = BackgroundAssetStore(rootProvider: () async => root);
    db = AppDatabase(NativeDatabase.memory());
    backup = BackupService(db, backgroundAssets: assets);
    final assetId = await assets.importBytes(png1x1, 'png');
    await db.setSetting(
      AppPolicy.settingsKey,
      AppSettings(
        backgroundMode: BackgroundMode.customImage,
        backgroundAssetId: assetId,
      ).encode(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('v2 backup carries and restores the background asset', () async {
    final bytes = await backup.export();
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.findFile('background.json'), isNotNull);
    expect(
      archive.files.any((file) => file.name.startsWith('background/')),
      isTrue,
    );

    final snapshot = await backup.validate(bytes);
    expect(snapshot.background, isNotNull);
    await backup.restore(snapshot);
    expect(await assets.fileFor(snapshot.background!.assetId), isNotNull);
  });
}
