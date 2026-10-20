import 'package:site_lens/settings/settings_repository.dart';

import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/scripts/metadata.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:sqlite3/sqlite3.dart';

/// Synthetic public v1 fixture used to exercise the migration contract.
/// It has candidates=42, sources=1, probes=281, scripts=1.
final _fixture = File('test/fixtures/public_v1.sqlite');

File _copyFixture(Directory dir) {
  final target = File('${dir.path}/site_lens.sqlite');
  _fixture.copySync(target.path);
  return target;
}

Future<File> _v4ContractFixture(Directory dir) async {
  final file = File('${dir.path}/v4-contract.sqlite');
  final seed = AppDatabase(NativeDatabase(file));
  await seed.customSelect('SELECT 1').get();
  await seed.saveScript(
    const InstalledScript(
      id: 'legacy',
      name: 'Legacy',
      source: '// ==UserScript==\n// @name Legacy\n// @match https://example.com/*\n// ==/UserScript==\n',
    ),
  );
  await seed.close();

  final raw = sqlite3.open(file.path);
  try {
    for (final table in [
      'script_approvals',
      'media_tasks',
      'media_candidates',
      'filter_policies',
      'filter_snapshots',
      'filter_sources',
    ]) {
      raw.execute('DROP TABLE $table');
    }
    raw.execute(
      "ALTER TABLE scripts ADD COLUMN network_mode TEXT NOT NULL DEFAULT 'declared'",
    );
    raw.execute('ALTER TABLE scripts ADD COLUMN approval_reason TEXT');
    raw.execute('ALTER TABLE scripts ADD COLUMN approved_at TEXT');
    raw.execute(
      'ALTER TABLE scripts ADD COLUMN public_confirmed INTEGER NOT NULL DEFAULT 0',
    );
    raw.execute(
      "UPDATE scripts SET network_mode='public', approval_reason='fixture', approved_at='2026-10-17T00:00:00Z', public_confirmed=1 WHERE id='legacy'",
    );
    raw.userVersion = 4;
  } finally {
    raw.close();
  }
  return file;
}

Future<File> _v9MediaTaskFixture(Directory dir) async {
  final file = File('${dir.path}/v9-media-task.sqlite');
  final seed = AppDatabase(NativeDatabase(file));
  await seed.customSelect('SELECT 1').get();
  await seed.saveMediaCandidate(
    MediaCandidate(
      id: 'legacy-media-candidate',
      hostId: 3,
      generation: 5,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: Uri.parse('https://cdn.example/episode-1.m3u8'),
      title: '旧媒体 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    ),
  );
  await seed.close();

  final raw = sqlite3.open(file.path);
  try {
    raw.execute('PRAGMA foreign_keys = OFF');
    raw.execute('DROP TABLE media_tasks');
    raw.execute(
      'CREATE TABLE media_tasks('
      'id TEXT PRIMARY KEY, candidate_id TEXT NOT NULL REFERENCES media_candidates(id) ON DELETE CASCADE, '
      'host_id INTEGER NOT NULL, generation INTEGER NOT NULL, source_url TEXT NOT NULL, '
      'cache_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL, updated_at TEXT NOT NULL, '
      'display_title TEXT NOT NULL DEFAULT \'\', episode_label TEXT, '
      'bytes_downloaded INTEGER NOT NULL DEFAULT 0, total_bytes INTEGER, error_code TEXT, '
      'error_reason TEXT, local_ref TEXT)',
    );
    raw.execute(
      'INSERT INTO media_tasks(id,candidate_id,host_id,generation,source_url,cache_key,state,updated_at,display_title,episode_label,bytes_downloaded) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      [
        'legacy-media-task',
        'legacy-media-candidate',
        3,
        5,
        'https://example.com/watch',
        List.filled(64, 'a').join(),
        'queued',
        '2026-10-20T00:00:00Z',
        '旧媒体 - 第1集',
        '第1集',
        0,
      ],
    );
    raw.userVersion = 9;
  } finally {
    raw.close();
  }
  return file;
}

List<Map<String, Object?>> _rows(Database db, String sql) =>
    db.select(sql).map((r) => Map<String, Object?>.from(r)).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('site-lens-migration'));
  tearDown(() {
    AppDatabase.migrationDebugHook = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'fixture is still the v1 baseline used by the public migration contract',
    () {
      final raw = sqlite3.open(_fixture.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 1);
      expect(
        raw.select('SELECT COUNT(*) AS c FROM candidates').single['c'],
        42,
      );
      expect(raw.select('SELECT COUNT(*) AS c FROM sources').single['c'], 1);
      expect(raw.select('SELECT COUNT(*) AS c FROM probes').single['c'], 281);
      expect(raw.select('SELECT COUNT(*) AS c FROM scripts').single['c'], 1);
      final probes = raw
          .select('SELECT result FROM probes')
          .map(
            (row) =>
                jsonDecode(row['result'] as String) as Map<String, dynamic>,
          )
          .toList();
      expect(probes.map((row) => row['stage']).toSet(), {'http', 'homepage'});
      expect(
        probes.map((row) => row['status']).toSet(),
        ProbeStatus.values.map((status) => status.name).toSet(),
      );
    },
  );

  test(
    'v1 -> v2 migration preserves every row and keeps the script enabled',
    () async {
      final file = _copyFixture(dir);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      // Migration runs lazily on first use.
      await db.customSelect('SELECT 1').get();

      final profiles = await db.profiles();
      expect(profiles, hasLength(1));
      final profile = profiles.single;
      expect(profile.name, 'Public source');
      expect(profile.readySelector, 'main');

      final pages = await db.profilePages();
      expect(pages, hasLength(1));
      expect(pages.single.profileId, profile.id);
      expect(pages.single.url.toString(), 'https://source.example/');
      expect(pages.single.regionSelector, '@latest-addresses');

      final candidates = await db.candidates();
      expect(candidates, hasLength(42));
      expect(candidates.every((c) => c.profileId == profile.id), isTrue);

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 10);
      expect(raw.select('SELECT COUNT(*) AS c FROM probes').single['c'], 281);

      final scripts = await db.scripts();
      expect(scripts, hasLength(1));
      expect(scripts.single.enabled, isTrue);
      expect(scripts.single.approvedDigest, isNotNull);
      expect(
        scripts.single.approvedDigest,
        ScriptMetadata.parse(scripts.single.source)
            .legacyDigest(scripts.single.source, []),
      );
      expect(scripts.single.source.length, greaterThan(1000000));

      // Scripts are never auto-bound to a profile.
      expect(await db.profileScripts(), isEmpty);

      final health = await db.profileHealth(profile.id);
      expect(health.state, ProfileHealthState.unknown);
      expect(health.consecutiveFailures, 0);
      // sources is retained (not dropped) so a v1 code rollback still reads it.
      expect(await db.sources(), hasLength(1));
    },
  );

  test('every candidate row survives the migration field-for-field', () async {
    const sql =
        'SELECT id,label,url,source_id,ready_selector,enabled FROM candidates ORDER BY id';
    final before = sqlite3.open(_fixture.path);
    final expected = _rows(before, sql);
    before.close();

    final file = _copyFixture(dir);
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    final after = sqlite3.open(file.path);
    addTearDown(after.close);
    expect(_rows(after, sql), expected);

    // settings and the whole probe history are carried across untouched.
    final baseline = sqlite3.open(_fixture.path);
    addTearDown(baseline.close);
    expect(
      _rows(after, 'SELECT key,value FROM settings ORDER BY key'),
      _rows(baseline, 'SELECT key,value FROM settings ORDER BY key'),
    );
    expect(
      _rows(after, 'SELECT id,result FROM probes ORDER BY id'),
      _rows(baseline, 'SELECT id,result FROM probes ORDER BY id'),
    );
    expect(
      _rows(
        after,
        "SELECT id,label,url,region_selector,enabled,refreshed_at,error FROM sources ORDER BY id",
      ),
      _rows(
        baseline,
        "SELECT id,label,url,region_selector,enabled,refreshed_at,error FROM sources ORDER BY id",
      ),
    );
  });

  test(
    'migrated public fixture script still produces a live registration',
    () async {
      final file = _copyFixture(dir);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      // The fixture has scripts globally disabled; enable them for this check.
      await SettingsRepository(db).update({'scriptsDisabled': false});
      final scripts = ScriptService(
        db,
        ControlledHttp(),
        sourceDirectory: () async => dir,
      );
      final registrations = await scripts.registrations();
      expect(registrations, hasLength(1));
      expect(registrations.single.id, isNotEmpty);
      expect(registrations.single.privileged, isTrue);
      final installed = (await db.scripts()).single;
      expect(
        registrations.single.revision,
        ScriptMetadata.parse(installed.source).digest(installed.source, []),
      );
      final published = File(registrations.single.sourcePath);
      expect(await published.readAsString(), installed.source);
      final executed = await Process.run('node', [
        '-e',
        "const fs = require('node:fs'); const vm = require('node:vm'); "
            "const context = {GM_getValue: (_key, fallback) => fallback}; "
            "vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'), context); "
            "process.stdout.write(String(context.publicMigrationFixture));",
        published.path,
      ]);
      expect(executed.exitCode, 0, reason: executed.stderr.toString());
      expect(executed.stdout.toString(), '8');
    },
  );

  test('manual candidates are grouped into 未归类, not orphaned', () async {
    final file = _copyFixture(dir);
    final raw = sqlite3.open(file.path);
    raw.execute(
      "INSERT INTO candidates(label,url,source_id,ready_selector) VALUES('手动','https://manual.example/',NULL,'main')",
    );
    raw.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final profiles = await db.profiles();
    expect(profiles.map((p) => p.name), contains(unassignedProfileName));
    final fallback = profiles.firstWhere(
      (p) => p.name == unassignedProfileName,
    );
    final manual = (await db.candidates()).firstWhere(
      (c) => c.url.host == 'manual.example',
    );
    expect(manual.profileId, fallback.id);
    expect(await db.candidates(), hasLength(43));
  });

  test('a mid-migration failure rolls back to an intact v1 database', () async {
    final file = _copyFixture(dir);
    // Fail only after profiles and every candidate have been copied, so the
    // rollback genuinely has partial v2 work to undo.
    AppDatabase.migrationDebugHook = (step) {
      if (step == 'after-candidates') throw StateError('injected failure');
    };
    final db = AppDatabase(NativeDatabase(file));
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(isA<StateError>()),
    );
    try {
      await db.close();
    } catch (_) {}

    // The on-disk file must still be exactly v1 with no half-applied profiles.
    final raw = sqlite3.open(file.path);
    addTearDown(raw.close);
    expect(raw.userVersion, 1);
    expect(
      raw.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='profiles'",
      ),
      isEmpty,
    );
    expect(raw.select('SELECT COUNT(*) AS c FROM candidates').single['c'], 42);
    expect(raw.select('SELECT COUNT(*) AS c FROM scripts').single['c'], 1);
  });

  test('v4 to v5 failure rolls back every new contract table', () async {
    final file = _copyFixture(dir);
    var failed = false;
    AppDatabase.migrationDebugHook = (step) {
      if (step == 'v5-after-tables') {
        failed = true;
        throw StateError('injected v5 failure');
      }
    };
    final db = AppDatabase(NativeDatabase(file));
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(isA<StateError>()),
    );
    await db.close();
    expect(failed, isTrue);
    final raw = sqlite3.open(file.path);
    addTearDown(raw.close);
    // Drift keeps the original user_version until the failed upgrade is
    // retried; the important rollback boundary is the absence of all v5 rows.
    expect(raw.userVersion, 1);
    expect(
      raw.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_tasks'",
      ),
      isEmpty,
    );
    expect(
      raw.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='filter_sources'",
      ),
      isEmpty,
    );
    expect(raw.select('SELECT COUNT(*) AS c FROM candidates').single['c'], 42);
  });

  test('migration is idempotent across repeated opens', () async {
    final file = _copyFixture(dir);
    var db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    expect(await db.profiles(), hasLength(1));
    expect(await db.candidates(), hasLength(42));
    expect(await db.profilePages(), hasLength(1));
  });

  test(
    'migration is retry-safe when user_version lags the committed data',
    () async {
      final file = _copyFixture(dir);
      var db = AppDatabase(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      await db.close();
      // Simulate dying between the data commit and SQLite's user_version bump.
      final raw = sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 1');
      raw.close();

      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      // No duplicate ALTER failure, no duplicated profiles, no lost candidates.
      expect(await db.profiles(), hasLength(1));
      expect(await db.profilePages(), hasLength(1));
      expect(await db.candidates(), hasLength(42));
    },
  );

  test(
    'v4 -> v8 preserves the legacy approval shape and creates contract tables',
    () async {
      final file = await _v4ContractFixture(dir);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 10);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='filter_snapshots'",
        ),
        hasLength(1),
      );
      final approval = raw
          .select(
            'SELECT network_mode,approval_reason,approved_at,public_confirmed FROM script_approvals WHERE script_id=\'legacy\'',
          )
          .single;
      expect(approval['network_mode'], 'public');
      expect(approval['approval_reason'], 'fixture');
      expect(approval['approved_at'], '2026-10-17T00:00:00Z');
      expect(approval['public_confirmed'], 1);
    },
  );

  test(
    'v4 -> v5 rollback leaves the original v4 schema and data intact',
    () async {
      final file = await _v4ContractFixture(dir);
      AppDatabase.migrationDebugHook = (step) {
        if (step == 'v5-after-tables') throw StateError('injected v5 failure');
      };
      final db = AppDatabase(NativeDatabase(file));
      await expectLater(
        db.customSelect('SELECT 1').get(),
        throwsA(isA<StateError>()),
      );
      await db.close();

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 4);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='filter_sources'",
        ),
        isEmpty,
      );
      expect(
        raw.select('SELECT id FROM scripts WHERE id=\'legacy\''),
        hasLength(1),
      );
      expect(
        raw.select('PRAGMA table_info(scripts)').map((row) => row['name']),
        contains('network_mode'),
      );
    },
  );

  test('v9 -> v10 adds batch_directory without losing media tasks', () async {
    final file = await _v9MediaTaskFixture(dir);
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final raw = sqlite3.open(file.path);
    addTearDown(raw.close);
    expect(raw.userVersion, 10);
    expect(
      raw.select('PRAGMA table_info(media_tasks)').map((row) => row['name']),
      contains('batch_directory'),
    );

    final store = MediaTaskStore(db: db);
    await store.restore();
    final task = store.task('legacy-media-task')!;
    expect(task.batchDirectory, isNull);
    await db.saveMediaTask(task.copyWith(batchDirectory: '批次目录'));
    expect((await db.mediaTasks()).single.batchDirectory, '批次目录');
  });

  test(
    'v9 -> v10 migration is reentrant when the column already exists',
    () async {
      final file = File('${dir.path}/v9-column-present.sqlite');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await seed.close();

      final before = sqlite3.open(file.path);
      before.userVersion = 9;
      before.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 10);
      expect(
        raw
            .select('PRAGMA table_info(media_tasks)')
            .where((row) => row['name'] == 'batch_directory'),
        hasLength(1),
      );
    },
  );
}
