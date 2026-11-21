import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/route_health.dart';
import 'package:sqlite3/sqlite3.dart';

Future<Map<String, List<Map<String, Object?>>>> _schema(AppDatabase db) async {
  final schema = <String, List<Map<String, Object?>>>{};
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  for (final table in tables) {
    final name = table.read<String>('name');
    schema[name] = (await db.customSelect('PRAGMA table_info($name)').get())
        .map(
          (row) => {
            'name': row.read<String>('name'),
            'type': row.read<String>('type'),
            'notnull': row.read<int>('notnull'),
            'dflt': row.readNullable<String>('dflt_value'),
            'pk': row.read<int>('pk'),
          },
        )
        .toList();
  }
  return schema;
}

/// Turns a current-version file back into what a released v25 build left:
/// no per-出口 table, and a `profile_pages` without the 出口 column.
///
/// The column is removed by table rebuild rather than `DROP COLUMN`, which an
/// older on-device SQLite may not support.
void _rollBackToV25(File file) {
  final raw = sqlite3.open(file.path);
  try {
    raw.execute('DROP TABLE site_profile_health');
    raw.execute(
      'CREATE TABLE profile_pages_v25 AS '
      'SELECT id,profile_id,url,region_selector,enabled,refreshed_at,error '
      'FROM profile_pages',
    );
    raw.execute('DROP TABLE profile_pages');
    raw.execute(
      'CREATE TABLE profile_pages(id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, '
      'url TEXT NOT NULL, region_selector TEXT NOT NULL, '
      'enabled INTEGER NOT NULL DEFAULT 1, refreshed_at TEXT, error TEXT, '
      'UNIQUE(profile_id, url))',
    );
    raw.execute(
      'INSERT INTO profile_pages(id,profile_id,url,region_selector,enabled,'
      'refreshed_at,error) SELECT id,profile_id,url,region_selector,enabled,'
      'refreshed_at,error FROM profile_pages_v25',
    );
    raw.execute('DROP TABLE profile_pages_v25');
    raw.userVersion = 25;
  } finally {
    raw.close();
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('site-lens-routes-h'));
  tearDown(() {
    AppDatabase.migrationDebugHook = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('出口健康表', () {
    test('两条出口各自一条记录，互不覆盖', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.createProfile('站');
      await db.customStatement(
        "INSERT OR IGNORE INTO site_profile_health(profile_id,route) VALUES(?, 'direct')",
        [id],
      );
      await db.customStatement(
        "INSERT OR IGNORE INTO site_profile_health(profile_id,route) VALUES(?, 'browse')",
        [id],
      );

      await db.saveRouteHealth(
        id,
        SiteRoute.direct,
        ProfileHealth(
          profileId: id,
          state: ProfileHealthState.ok,
          lastCheckedAt: DateTime(2026, 11, 21, 12),
          lastOkAt: DateTime(2026, 11, 21, 12),
        ),
      );
      await db.saveRouteHealth(
        id,
        SiteRoute.browse,
        ProfileHealth(
          profileId: id,
          state: ProfileHealthState.failing,
          consecutiveFailures: 2,
          lastCheckedAt: DateTime(2026, 11, 21, 12),
          lastFailureCategory: 'tls_handshake',
        ),
        failureDetail: 'TLS 握手失败',
        stationKey: 'https://a.example/',
      );

      final rows = {
        for (final row in await db.routeHealthRows()) row.route: row,
      };
      expect(rows.keys, {SiteRoute.direct, SiteRoute.browse});
      expect(rows[SiteRoute.direct]!.health.state, ProfileHealthState.ok);
      expect(rows[SiteRoute.direct]!.health.lastFailureRoute, isNull);
      expect(rows[SiteRoute.browse]!.health.state, ProfileHealthState.failing);
      expect(
        rows[SiteRoute.browse]!.health.lastFailureRoute,
        SiteRoute.browse.storageName,
      );
      expect(
        rows[SiteRoute.browse]!.health.lastFailureCategory,
        'tls_handshake',
      );
    });

    test('档案删除时出口记录跟着走', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.createProfile('站');
      await db.customStatement(
        "INSERT INTO site_profile_health(profile_id,route) VALUES(?, 'browse')",
        [id],
      );
      await db.deleteProfile(id);
      expect(await db.routeHealthRows(), isEmpty);
    });

    test('聚合徽章读的是两条出口的记录', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.createProfile('站');
      await db.customStatement(
        "INSERT INTO site_profile_health(profile_id,route) VALUES(?, 'direct')",
        [id],
      );
      await db.customStatement(
        "INSERT INTO site_profile_health(profile_id,route) VALUES(?, 'browse')",
        [id],
      );
      await db.saveRouteHealth(
        id,
        SiteRoute.direct,
        ProfileHealth(
          profileId: id,
          state: ProfileHealthState.ok,
          lastCheckedAt: DateTime(2026, 11, 21, 12),
        ),
      );
      await db.saveRouteHealth(
        id,
        SiteRoute.browse,
        ProfileHealth(
          profileId: id,
          state: ProfileHealthState.failing,
          lastCheckedAt: DateTime(2026, 11, 21, 12),
          lastFailureCategory: 'timeout',
        ),
      );

      final record = routeHealthFromStored(
        profileId: id,
        routes: {SiteRoute.direct, SiteRoute.browse},
        pages: await db.profilePages(profileId: id),
        verdicts: {
          for (final row in await db.routeHealthRows()) row.route: row.health,
        },
      );

      expect(record.state, ProfileHealthState.ok);
      expect(record.failedRoutes, {SiteRoute.browse});
      expect(record.summary, contains('浏览出口不可用'));
      expect(record.summary, contains('探测超时'));
    });
  });

  group('发布页结果落在既有列上', () {
    test('发布页带出口，失败时 error 与 refreshed_at 一起写', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.createProfile('站');
      await db.addProfilePage(
        id,
        Uri.parse('https://cdn.example/latest'),
        'main',
        route: SiteRoute.direct,
      );

      final page = (await db.profilePages(profileId: id)).single;
      expect(page.route, SiteRoute.direct);
      expect(page.error, isNull);

      await db.profilePageRefreshed(page.id, error: 'DNS 解析失败，请检查网络后重试');
      final failed = (await db.profilePages(profileId: id)).single;
      expect(failed.error, contains('DNS'));
      expect(failed.refreshedAt, isNotNull);

      // Success clears the error: it is the page's verdict, not a log.
      await db.profilePageRefreshed(page.id);
      expect((await db.profilePages(profileId: id)).single.error, isNull);
    });

    test('两页分属两条出口时，只有失败那页的出口被点名', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.createProfile('站');
      await db.addProfilePage(
        id,
        Uri.parse('https://api.example/latest'),
        'main',
        route: SiteRoute.direct,
      );
      await db.addProfilePage(
        id,
        Uri.parse('https://www.example/latest'),
        'main',
      );
      final pages = await db.profilePages(profileId: id);
      final api = pages.firstWhere((p) => p.route == SiteRoute.direct);
      final web = pages.firstWhere((p) => p.route == SiteRoute.browse);
      await db.profilePageRefreshed(web.id);
      await db.profilePageRefreshed(api.id, error: '操作超时，请稍后重试');

      final record = routeHealthFromStored(
        profileId: id,
        routes: {SiteRoute.direct, SiteRoute.browse},
        pages: await db.profilePages(profileId: id),
        verdicts: const {},
      );

      expect(record.state, ProfileHealthState.ok);
      expect(record.failedRoutes, {SiteRoute.direct});
      expect(record.summary, allOf(contains('直连出口'), contains('api.example')));
    });
  });

  group('v25 -> v26 迁移', () {
    test('升级后每个档案在它具备的出口上各有一条记录', () async {
      final file = File('${dir.path}/upgrade.sqlite');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      final id = await seed.createProfile('已有档案');
      await seed.customStatement(
        "INSERT INTO site_profile_routes(profile_id,route) VALUES(?, 'direct')",
        [id],
      );
      await seed.close();
      _rollBackToV25(file);

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      final rows = await db.routeHealthRows();
      expect(rows.map((row) => row.route), {
        SiteRoute.direct,
        SiteRoute.browse,
      });
      expect(
        rows.every((row) => row.health.state == ProfileHealthState.unknown),
        isTrue,
        reason: 'a seeded row says "not checked yet", never "failing"',
      );
      // The page route column lands with a value the build can read.
      expect(
        (await db.profilePages(
          profileId: id,
        )).every((p) => p.route == SiteRoute.browse),
        isTrue,
      );
    });

    test('全新安装与升级后的库结构一致', () async {
      final upgraded = File('${dir.path}/upgraded.sqlite');
      final seed = AppDatabase(NativeDatabase(upgraded));
      await seed.customSelect('SELECT 1').get();
      await seed.createProfile('已有档案');
      await seed.close();
      _rollBackToV25(upgraded);

      final migrated = AppDatabase(NativeDatabase(upgraded));
      addTearDown(migrated.close);
      await migrated.customSelect('SELECT 1').get();

      final fresh = AppDatabase(
        NativeDatabase(File('${dir.path}/fresh.sqlite')),
      );
      addTearDown(fresh.close);
      await fresh.customSelect('SELECT 1').get();

      expect(await _schema(migrated), await _schema(fresh));
      expect(
        (await _schema(fresh))['profile_pages']!.map((c) => c['name']),
        contains('route'),
      );
      expect(
        (await _schema(fresh))['site_profile_health']!.map((c) => c['name']),
        [
          'profile_id',
          'route',
          'state',
          'consecutive_failures',
          'last_checked_at',
          'last_ok_at',
          'failure_category',
          'failure_detail',
          'station_key',
          'last_failure_route',
        ],
      );
    });

    test('中途失败会被点名，且不留半张表', () async {
      final file = File('${dir.path}/failure.sqlite');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await seed.createProfile('已有档案');
      await seed.close();
      _rollBackToV25(file);

      AppDatabase.migrationDebugHook = (step) {
        if (step == 'v26-after-table') {
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
            contains('v26-after-table'),
          ),
        ),
      );
      try {
        await db.close();
      } catch (_) {}

      final raw = sqlite3.open(file.path);
      addTearDown(raw.close);
      expect(raw.userVersion, 25);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='site_profile_health'",
        ),
        isEmpty,
      );
    });

    test('重跑迁移不会覆盖已经写下的出口判定', () async {
      final file = File('${dir.path}/idempotent.sqlite');
      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      final id = await seed.createProfile('已有档案');
      await seed.close();
      _rollBackToV25(file);

      final first = AppDatabase(NativeDatabase(file));
      await first.customSelect('SELECT 1').get();
      await first.saveRouteHealth(
        id,
        SiteRoute.browse,
        ProfileHealth(
          profileId: id,
          state: ProfileHealthState.failing,
          consecutiveFailures: 2,
          lastCheckedAt: DateTime(2026, 11, 21, 12),
        ),
      );
      await first.close();

      // A lagging build re-runs the same step.
      final lagging = sqlite3.open(file.path);
      lagging.userVersion = 25;
      lagging.close();

      final second = AppDatabase(NativeDatabase(file));
      addTearDown(second.close);
      await second.customSelect('SELECT 1').get();
      final rows = await second.routeHealthRows();
      expect(
        rows.firstWhere((row) => row.route == SiteRoute.browse).health.state,
        ProfileHealthState.failing,
      );
    });
  });
}
