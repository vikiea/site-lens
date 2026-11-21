import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:sqlite3/sqlite3.dart';

Future<Set<String>> _storedRoutes(AppDatabase db, int profileId) async {
  return (await db
          .customSelect(
            'SELECT route FROM site_profile_routes WHERE profile_id=?',
            variables: [Variable(profileId)],
          )
          .get())
      .map((row) => row.read<String>('route'))
      .toSet();
}

Future<Map<String, List<String>>> _schema(AppDatabase db) async {
  final schema = <String, List<String>>{};
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  for (final table in tables) {
    final name = table.read<String>('name');
    schema[name] = (await db.customSelect('PRAGMA table_info($name)').get())
        .map((row) => row.read<String>('name'))
        .toList();
  }
  return schema;
}

/// Turns a current-version database back into the file a released v24 build
/// left on disk: no routes table, and the version that build reported.
void _rollBackToV24(File file) {
  final raw = sqlite3.open(file.path);
  try {
    raw.execute('DROP TABLE site_profile_routes');
    raw.userVersion = 24;
  } finally {
    raw.close();
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('site-lens-routes'));
  tearDown(() {
    AppDatabase.migrationDebugHook = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'a v24 profile keeps its behaviour and lands on the browse route',
    () async {
      final file = File('${dir.path}/upgrade.sqlite');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      final id = await seed.createProfile('已有档案', readySelector: 'article');
      await seed.setProfileLastLanding(
        id,
        Uri.parse('https://example.com/today'),
      );
      await seed.close();
      final before = (await _open(file)).single;
      _rollBackToV24(file);

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      final profile = (await db.profiles()).single;
      expect(profile.routes, {SiteRoute.browse});
      // Every field the released build showed is unchanged.
      expect(profile.id, before.id);
      expect(profile.name, before.name);
      expect(profile.enabled, before.enabled);
      expect(profile.readySelector, 'article');
      expect(profile.lastLanding, before.lastLanding);
      expect(profile.lastLandingAt, before.lastLandingAt);
      expect(profile.createdAt, before.createdAt);
    },
  );

  test('upgrading backfills every profile, including 未归类', () async {
    final file = File('${dir.path}/many.sqlite');
    final seed = AppDatabase(NativeDatabase(file));
    await seed.customSelect('SELECT 1').get();
    final curated = await seed.createProfile('已有档案');
    await seed.addCandidate(
      Uri.parse('https://manual.example/watch'),
      label: '手动',
    );
    await seed.close();
    final fallback = (await _open(file))
        .firstWhere((profile) => profile.name == unassignedProfileName);
    _rollBackToV24(file);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final profiles = await db.profiles();
    expect(profiles, hasLength(2));
    expect(
      profiles.every((profile) => profile.routes.contains(SiteRoute.browse)),
      isTrue,
    );
    expect(await _storedRoutes(db, curated), {SiteRoute.browse.storageName});
    expect(await _storedRoutes(db, fallback.id), {
      SiteRoute.browse.storageName,
    });
  });

  test('a fresh install and an upgraded file report the same tables', () async {
    final upgraded = File('${dir.path}/upgraded.sqlite');
    final seed = AppDatabase(NativeDatabase(upgraded));
    await seed.customSelect('SELECT 1').get();
    await seed.createProfile('已有档案');
    await seed.close();
    _rollBackToV24(upgraded);

    final migrated = AppDatabase(NativeDatabase(upgraded));
    addTearDown(migrated.close);
    await migrated.customSelect('SELECT 1').get();

    final fresh = AppDatabase(NativeDatabase(File('${dir.path}/fresh.sqlite')));
    addTearDown(fresh.close);
    await fresh.customSelect('SELECT 1').get();

    expect(await _schema(migrated), await _schema(fresh));
    expect((await _schema(fresh))['site_profile_routes'], [
      'profile_id',
      'route',
    ]);
  });

  test(
    'a failure inside the step is named and leaves no half-migrated routes',
    () async {
      final file = File('${dir.path}/failure.sqlite');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await seed.createProfile('已有档案');
      await seed.close();
      _rollBackToV24(file);

      AppDatabase.migrationDebugHook = (step) {
        if (step == 'v25-after-table') {
          throw StateError('injected failure in $step');
        }
      };
      final db = AppDatabase(NativeDatabase(file));
      await expectLater(
        db.customSelect('SELECT 1').get(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('v25-after-table'),
          ),
        ),
      );
      try {
        await db.close();
      } catch (_) {}

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 24);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='site_profile_routes'",
        ),
        isEmpty,
      );
      expect(
        raw.select('SELECT COUNT(*) AS c FROM profiles').single['c'],
        1,
        reason: 'the pre-upgrade profile survives the rollback',
      );
    },
  );

  test('reopening keeps exactly one browse route per profile', () async {
    final file = File('${dir.path}/idempotent.sqlite');
    final seed = AppDatabase(NativeDatabase(file));
    await seed.customSelect('SELECT 1').get();
    final id = await seed.createProfile('已有档案');
    await seed.close();
    _rollBackToV24(file);

    final first = AppDatabase(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    expect(await _storedRoutes(first, id), {SiteRoute.browse.storageName});
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    await second.customSelect('SELECT 1').get();
    expect(await _storedRoutes(second, id), {SiteRoute.browse.storageName});
    // A retried migration must not overwrite a route recorded afterwards.
    await second.customStatement(
      "INSERT INTO site_profile_routes(profile_id,route) VALUES(?,'direct')",
      [id],
    );
    await second.close();

    final third = AppDatabase(NativeDatabase(file));
    addTearDown(third.close);
    await third.customSelect('SELECT 1').get();
    expect((await third.profiles()).single.routes, {
      SiteRoute.direct,
      SiteRoute.browse,
    });
  });
}

Future<List<SiteProfile>> _open(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  try {
    return await db.profiles();
  } finally {
    await db.close();
  }
}
