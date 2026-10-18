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
import 'package:sqlite3/sqlite3.dart';

/// Synthetic public v1 fixture used to exercise the migration contract.
/// It has candidates=42, sources=1, probes=281, scripts=1.
final _fixture = File('test/fixtures/public_v1.sqlite');

File _copyFixture(Directory dir) {
  final target = File('${dir.path}/site_lens.sqlite');
  _fixture.copySync(target.path);
  return target;
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
      expect(raw.userVersion, 5);
      expect(raw.select('SELECT COUNT(*) AS c FROM probes').single['c'], 281);

      final scripts = await db.scripts();
      expect(scripts, hasLength(1));
      expect(scripts.single.enabled, isTrue);
      expect(scripts.single.approvedDigest, isNotNull);
      expect(
        scripts.single.approvedDigest,
        ScriptMetadata.parse(scripts.single.source)
            .digest(scripts.single.source, []),
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
    'repairs a v5 database whose profile script state columns are missing',
    () async {
      final file = File('${dir.path}/site_lens.sqlite');
      final raw = sqlite3.open(file.path);
      raw.execute(
        'CREATE TABLE profiles(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL)',
      );
      raw.execute(
        'CREATE TABLE scripts(id TEXT PRIMARY KEY, name TEXT NOT NULL, source TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, approved_digest TEXT)',
      );
      raw.execute(
        'CREATE TABLE profile_scripts(profile_id INTEGER NOT NULL, script_id TEXT NOT NULL, content_hash TEXT NOT NULL, PRIMARY KEY(profile_id,script_id))',
      );
      raw.execute("INSERT INTO profiles VALUES(1,'旧档案','2026-10-18')");
      raw.execute("INSERT INTO profile_scripts VALUES(1,'script','hash')");
      raw.execute('PRAGMA user_version=5');
      raw.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      // This is the exact write performed by a .user.js import. It must be
      // safe even when the previous release left user_version at 5 too early.
      await db.saveScript(
        const InstalledScript(
          id: 'script',
          name: '脚本',
          source: '// ==UserScript==\n// @name Script\n// @match https://example.com/*\n// ==/UserScript==\n',
        ),
      );

      final columns = await db
          .customSelect('PRAGMA table_info(profile_scripts)')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll(<String>['enabled', 'approved_digest']),
      );
      final link = (await db.profileScripts()).single;
      expect(link.enabled, isFalse);
      expect(link.approvedDigest, isNull);

      // Once repaired, opening the app again must not reapply the global
      // script switch over a profile-local choice.
      await db.setProfileScriptEnabled(1, 'script', true, digest: 'approved');
      await db.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      await reopened.customSelect('SELECT 1').get();
      final preserved = (await reopened.profileScripts()).single;
      expect(preserved.enabled, isTrue);
      expect(preserved.approvedDigest, 'approved');
    },
  );

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
}
