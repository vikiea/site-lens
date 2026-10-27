import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/backup/backup_service.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';

Uint8List rewrite(Uint8List input, void Function(Map<String, dynamic>) change) {
  final archive = ZipDecoder().decodeBytes(input);
  final manifest = jsonDecode(
    utf8.decode(archive.findFile('manifest.json')!.readBytes()!),
  ) as Map<String, dynamic>;
  final body = jsonDecode(
    utf8.decode(archive.findFile('business.json')!.readBytes()!),
  ) as Map<String, dynamic>;
  change(body);
  final contents = utf8.encode(jsonEncode(body));
  manifest['bytes'] = contents.length;
  manifest['sha256'] = sha256.convert(contents).toString();
  final header = utf8.encode(jsonEncode(manifest));
  return ZipEncoder().encodeBytes(
    Archive()
      ..add(
        ArchiveFile('manifest.json', header.length, header)
          ..compression = CompressionType.none,
      )
      ..add(
        ArchiveFile('business.json', contents.length, contents)
          ..compression = CompressionType.none,
      ),
  );
}

Uint8List rewriteSchema(
  Uint8List input,
  int schema,
  void Function(Map<String, dynamic>) change,
) {
  final archive = ZipDecoder().decodeBytes(input);
  final manifest = jsonDecode(
    utf8.decode(archive.findFile('manifest.json')!.readBytes()!),
  ) as Map<String, dynamic>;
  final body = jsonDecode(
    utf8.decode(archive.findFile('business.json')!.readBytes()!),
  ) as Map<String, dynamic>;
  manifest['schema'] = schema;
  change(body);
  final contents = utf8.encode(jsonEncode(body));
  manifest['bytes'] = contents.length;
  manifest['sha256'] = sha256.convert(contents).toString();
  final header = utf8.encode(jsonEncode(manifest));
  return ZipEncoder().encodeBytes(
    Archive()
      ..add(
        ArchiveFile('manifest.json', header.length, header)
          ..compression = CompressionType.none,
      )
      ..add(
        ArchiveFile('business.json', contents.length, contents)
          ..compression = CompressionType.none,
      ),
  );
}

void main() {
  // REGRESSION CONTRACT: MEDIA-UPGRADE-001
  late AppDatabase db;
  late BackupService backup;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    backup = BackupService(db);
    await db.setting(AppPolicy.settingsKey); // Force schema creation.
    await db.customStatement(
      "INSERT INTO profiles(id,name,created_at) VALUES(1,'保留档案','2026-10-11')",
    );
    await db.customStatement(
      "INSERT INTO scripts VALUES('script','脚本','// ==UserScript==\n// @name Backup fixture\n// @match https://example.com/*\n// @grant GM_getValue\n// ==/UserScript==\n',1,'old-approval')",
    );
    await db.customStatement(
      "INSERT INTO script_values VALUES('script','key','42')",
    );
    final content = utf8.encode('resource');
    await db.customStatement('INSERT INTO resources VALUES(?,?,?,?,?,?)', [
      'script',
      0,
      'resource',
      'https://example.com/res',
      sha256.convert(content).toString(),
      Uint8List.fromList(content),
    ]);
    await db.setSetting(AppPolicy.settingsKey, const AppSettings().encode());
    await db.setSetting('health_daily_counter', '2');
  });
  tearDown(() => db.close());

  test(
    'schema 13 watch saves gain the later progress defaults on import',
    () async {
      await db.customStatement(
        'INSERT INTO watch_saves(owner_id,source_key,source_url,series_key,episode_number,title,page_url,host_id,generation,state,profile_id,created_at,updated_at,position_ms,duration_ms,evidence_revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          'watch-legacy',
          'source',
          'https://example.com/source',
          'series',
          1,
          'Episode 1',
          'https://example.com/watch',
          1,
          1,
          'paused',
          null,
          '2026-10-11',
          '2026-10-11',
          1234,
          5000,
          'revision',
        ],
      );
      final archive = await backup.export();
      final bytes = rewriteSchema(archive, 13, (data) {
        final row = (data['tables']['watch_saves'] as List).single as Map;
        row.remove('position_ms');
        row.remove('duration_ms');
        row.remove('evidence_revision');
      });
      final snapshot = await backup.validate(bytes);
      await backup.restore(snapshot);
      final restored = (await db.watchSaves()).single;
      expect(restored.positionMs, 0);
      expect(restored.durationMs, isNull);
      expect(restored.evidenceRevision, '');
    },
  );

  test('schema 8 through 11 business backups stay compatible with current media indexing', () async {
    for (final schema in [8, 9, 10, 11, 12, 13, 14, 15, 16]) {
      final source = ZipDecoder().decodeBytes(await backup.export());
      final manifest = jsonDecode(
        utf8.decode(source.findFile('manifest.json')!.readBytes()!),
      ) as Map<String, dynamic>;
      manifest['schema'] = schema;
      final header = utf8.encode(jsonEncode(manifest));
      final body = source.findFile('business.json')!.readBytes()!;
      final bytes = ZipEncoder().encodeBytes(
        Archive()
          ..add(
            ArchiveFile('manifest.json', header.length, header)
              ..compression = CompressionType.none,
          )
          ..add(
            ArchiveFile('business.json', body.length, body)
              ..compression = CompressionType.none,
          ),
      );
      final snapshot = await backup.validate(bytes);
      expect(snapshot.profiles, 1);
      await backup.restore(snapshot);
      expect((await db.profiles()).single.name, '保留档案');
    }
  });

  test('business backup roundtrips resources, values, preferences and disables approvals', () async {
    final bytes = await backup.export();
    final snapshot = await backup.validate(bytes);
    expect(snapshot.profiles, 1);
    expect(snapshot.scripts, 1);
    await db.customStatement("UPDATE profiles SET name='changed'");
    await backup.restore(snapshot);
    expect((await db.profiles()).single.name, '保留档案');
    expect((await db.scripts()).single.enabled, false);
    expect((await db.scripts()).single.approvedDigest, isNull);
    expect((await db.values('script'))['key'], 42);
    expect(await db.setting('health_daily_counter'), isNull);
    expect(await db.setting(AppPolicy.settingsKey), isNotNull);
    expect((await db.customSelect('SELECT * FROM resources').get()).length, 1);
  });
  test(
    'business backup excludes media cache and credential-bearing task rows',
    () async {
      await db.customStatement(
        "INSERT INTO media_candidates(id,host_id,generation,source_url,media_url,title,mime,source,created_at) VALUES('c',1,1,'https://example.com/','https://cdn.example/video.mp4','video','video/mp4','dom','2026-10-11')",
      );
      await db.customStatement(
        "INSERT INTO media_tasks(id,candidate_id,host_id,generation,source_url,cache_key,state,updated_at,local_ref) VALUES('t','c',1,1,'https://example.com/','cache','playable','2026-10-11','/private/cache.mp4')",
      );
      final archive = ZipDecoder().decodeBytes(await backup.export());
      final body = jsonDecode(
        utf8.decode(archive.findFile('business.json')!.readBytes()!),
      ) as Map<String, dynamic>;
      final tables = body['tables'] as Map<String, dynamic>;
      expect(tables.containsKey('media_candidates'), isFalse);
      expect(tables.containsKey('media_tasks'), isFalse);
    },
  );
  test('restore constraint failure rolls back all business data', () async {
    final bytes = rewrite(await backup.export(), (data) {
      data['tables']['script_values'][0]['script_id'] = 'missing';
    });
    final snapshot = await backup.validate(bytes);
    await expectLater(backup.restore(snapshot), throwsA(anything));
    expect((await db.scripts()).single.enabled, true);
    expect((await db.profiles()).single.name, '保留档案');
    expect((await db.values('script'))['key'], 42);
  });
  test(
    'rejects bad schema, fields and resource digest before any write',
    () async {
      final bytes = await backup.export();
      for (final change in <void Function(Map<String, dynamic>)>[
        (data) => data['tables']['scripts'][0]['unexpected'] = true,
        (data) => data['tables']['resources'][0]['hash'] = 'corrupt',
        (data) => data['tables']['settings'].add({
          'key': 'runtime-secret',
          'value': 'x',
        }),
      ]) {
        await expectLater(
          backup.validate(rewrite(bytes, change)),
          throwsA(isA<FormatException>()),
        );
      }
      expect((await db.scripts()).single.enabled, true);
    },
  );
  test(
    'rejects traversal, duplicate entries and compressed archives',
    () async {
      for (final file in [
        ArchiveFile('../business.json', 1, [1]),
        ArchiveFile('business.json', 1, [1]),
      ]) {
        final invalid = ZipEncoder().encodeBytes(Archive()..add(file));
        await expectLater(
          backup.validate(invalid),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
  test(
    'local and central ZIP headers must agree before reading any body',
    () async {
      final bytes = await backup.export();
      for (final offset in [6, 8, 18, 22, 26]) {
        final invalid = Uint8List.fromList(bytes);
        invalid[offset] = offset == 8 ? 8 : 1;
        await expectLater(backup.validate(invalid), throwsA(anything));
      }
    },
  );
  test(
    'malformed business models are rejected before replacing the database',
    () async {
      final bytes = await backup.export();
      for (final change in <void Function(Map<String, dynamic>)>[
        (data) => data['tables']['profiles'][0]['created_at'] = 'invalid',
        (data) => data['tables']['profiles'][0]['id'] = 'invalid-integer',
        (data) => data['tables']['probes'].add({'id': 1, 'result': 'not-json'}),
        (data) => data['tables']['settings'].add({
          'key': AppPolicy.browserSessionsKey,
          'value': 'not-json',
        }),
      ]) {
        await expectLater(
          backup.validate(rewrite(bytes, change)),
          throwsA(anything),
        );
        expect((await db.profiles()).single.name, '保留档案');
        expect((await db.scripts()).single.enabled, true);
      }
    },
  );
  test('fake directory count and oversized local filenames reject before directory expansion', () async {
    final archive = Archive();
    for (var i = 0; i < 64; i++) {
      archive.add(
        ArchiveFile('file$i', 1, [0])..compression = CompressionType.none,
      );
    }
    final bytes = ZipEncoder().encodeBytes(archive);
    final data = ByteData.sublistView(bytes);
    final footer = bytes.length - 22;
    data.setUint16(footer + 8, 2, Endian.little);
    data.setUint16(footer + 10, 2, Endian.little);
    await expectLater(backup.validate(bytes), throwsA(isA<FormatException>()));
    final valid = await backup.export();
    ByteData.sublistView(valid).setUint16(26, 65535, Endian.little);
    await expectLater(backup.validate(valid), throwsA(isA<FormatException>()));
  });
  test('a backup carrying the removed v1 settings record is refused', () async {
    final bytes = rewrite(await backup.export(), (data) {
      final settings = data['tables']['settings'] as List;
      final index = settings.indexWhere(
        (row) => row['key'] == AppPolicy.settingsKey,
      );
      settings[index]['value'] = jsonEncode({
        'version': 1,
        'themePreset': 'iris_violet',
        'glassMode': 'frosted',
      });
    });
    await expectLater(backup.validate(bytes), throwsA(isA<FormatException>()));
    // Refused before anything is written: the live row is untouched.
    expect(await db.setting(AppPolicy.settingsKey), isNotNull);
  });

  test(
    'session record exceeding startup bound cannot replace existing data',
    () async {
      final bytes = rewrite(
        await backup.export(),
        (data) => data['tables']['settings'].add({
          'key': AppPolicy.browserSessionsKey,
          'value': jsonEncode({
            'version': 1,
            'activeId': 'a',
            'tabs': [
              {
                'id': 'a',
                'initialUrl': 'https://example.com/',
                'currentUrl': 'https://example.com/',
                'title': 'a',
                'selectorOverride': 'x' * 270000,
              },
            ],
          }),
        }),
      );
      await expectLater(
        backup.validate(bytes),
        throwsA(isA<FormatException>()),
      );
      expect((await db.profiles()).single.name, '保留档案');
      expect((await db.scripts()).single.enabled, true);
    },
  );
}
