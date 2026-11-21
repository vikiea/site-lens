import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/profile_panel.dart';

import 'fake_web_host_api.dart';

void main() {
  late AppDatabase db;
  late AppController app;
  late SiteProfile profile;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = AppController(db, api: FakeWebHostApi());
    final profileId = await db.createProfile('示例站');
    await db.addCandidate(
      Uri.parse('https://primary.example/'),
      label: '主地址',
      profileId: profileId,
    );
    await db.addCandidate(
      Uri.parse('https://backup.example/'),
      label: '备用地址一',
      profileId: profileId,
    );
    await app.load();
    profile = app.profiles.singleWhere((value) => value.id == profileId);
    final primary = app.sitesForProfile(profileId).first;
    await db.saveProbe(
      ProbeResult(
        round: 1,
        candidateId: primary.id,
        stage: ProbeStage.homepage,
        status: ProbeStatus.ready,
        entryUrl: primary.url,
        finalUrl: primary.url,
        checkedAt: DateTime(2026, 10, 16, 8),
        elapsed: const Duration(milliseconds: 120),
      ),
    );
    await app.load();
  });

  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  testWidgets(
    'backup addresses and history are independently collapsible glass panels',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: ProfileDetailScreen(
            app: app,
            profile: profile,
            onEnter: (_) {},
            onEnterProfile: (_) async {},
            onResume: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final backupTile = find.byKey(const ValueKey('profile-backup-addresses'));
      // 出口与基站面板插在顶部卡片之后，备用地址被推到了首屏之下。
      await tester.scrollUntilVisible(
        backupTile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(backupTile, findsOneWidget);
      expect(find.text('备用地址一'), findsOneWidget);

      await tester.tap(backupTile);
      await tester.pumpAndSettle();
      expect(find.text('备用地址一'), findsNothing);

      await tester.tap(backupTile);
      await tester.pumpAndSettle();
      expect(find.text('备用地址一'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      final historyTile = find.byKey(const ValueKey('profile-history'));
      expect(historyTile, findsOneWidget);
      expect(find.textContaining('最近 1 条检测记录'), findsOneWidget);
      expect(find.byType(SiteLensPanel), findsWidgets);

      await tester.ensureVisible(historyTile);
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>(
            'profile-history-entry-1-2026-10-16T08:00:00.000',
          ),
        ),
        findsNothing,
      );

      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>(
            'profile-history-entry-1-2026-10-16T08:00:00.000',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('详情页显示分出口的健康与当前可用基站', (tester) async {
    final adapter = FakeSiteAdapter(
      id: 'fake-detail',
      profileId: profile.id,
      addresses: [Uri.parse('https://primary.example/')],
    );
    adapter.stations = [
      BaseStation(
        origin: Uri.parse('https://station.example/'),
        preferred: true,
      ),
    ];
    app.installTheaterAdapter(profile.id, adapter);
    // 这份档案两条出口都具备，才能表达「直连失败、浏览仍可用」。
    await db.setProfileRoutes(profile.id, {SiteRoute.direct, SiteRoute.browse});
    await app.load();
    profile = app.profiles.singleWhere((value) => value.id == profile.id);
    // The direct route is failing while the browse route still works: the
    // panel must name the 出口 that failed, not declare the site broken.
    await db.customStatement(
      "INSERT OR REPLACE INTO site_profile_health"
      "(profile_id,route,state,last_checked_at,failure_category) "
      "VALUES(?, 'direct', 'failing', '2026-11-21T12:00:00.000', 'tls_handshake')",
      [profile.id],
    );
    await db.customStatement(
      "INSERT OR REPLACE INTO site_profile_health"
      "(profile_id,route,state,last_checked_at) "
      "VALUES(?, 'browse', 'ok', '2026-11-21T12:00:00.000')",
      [profile.id],
    );
    await app.refreshProfileHealth();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: ProfileDetailScreen(
          app: app,
          profile: profile,
          onEnter: (_) {},
          onEnterProfile: (_) async {},
          onResume: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('route-health-panel'));
    await tester.scrollUntilVisible(
      panel,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);

    final routes = find.byKey(const ValueKey('route-health-routes'));
    expect(
      find.descendant(of: routes, matching: find.text('直连出口')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: routes, matching: find.text('浏览出口')),
      findsOneWidget,
    );
    expect(find.textContaining('直连出口不可用'), findsOneWidget);

    final stations = find.byKey(const ValueKey('route-health-stations'));
    await tester.scrollUntilVisible(
      stations,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('https://station.example'), findsOneWidget);
    expect(find.text('首选'), findsOneWidget);
  });

  testWidgets('profile filter policy can be customized and reset to global', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: ProfileFilterSettingsScreen(
          app: app,
          profileId: profile.id,
          profileName: profile.name,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('当前跟随全局策略'), findsOneWidget);

    await tester.tap(find.text('启用广告过滤'));
    await tester.pumpAndSettle();
    expect(app.profileFilterPolicies.containsKey(profile.id), isTrue);
    expect(find.text('恢复跟随全局策略'), findsOneWidget);

    await tester.tap(find.text('恢复跟随全局策略'));
    await tester.pumpAndSettle();
    expect(app.profileFilterPolicies.containsKey(profile.id), isFalse);
  });

  testWidgets('详情页可以打开直连出口，打开之后剧场才把这个档案当成站点', (tester) async {
    // 真机上没有任何别的地方会写这条出口：这是用户把一份档案变成剧站点的入口。
    expect(
      profile.routes.contains(SiteRoute.direct),
      isFalse,
      reason: '新档案默认只有浏览出口',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: ProfileDetailScreen(
          app: app,
          profile: profile,
          onEnter: (_) {},
          onEnterProfile: (_) async {},
          onResume: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('profile-direct-route'));
    // 高级区默认折叠：先展开，再滚到开关。
    await tester.scrollUntilVisible(
      find.text('高级：发布页与选择器'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级：发布页与选择器'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      toggle,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('直连出口'), findsOneWidget);
    expect(find.textContaining('剧场不列出这个站点'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final saved = app.profiles.singleWhere((value) => value.id == profile.id);
    expect(saved.routes, contains(SiteRoute.direct), reason: '打开开关就该把直连出口写进档案');
    expect(
      saved.routes,
      contains(SiteRoute.browse),
      reason: '打开直连出口不该把浏览出口去掉（ADR-0002：两条出口并列）',
    );

    // 关回去只撤掉直连出口，浏览出口还在。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final reverted = app.profiles.singleWhere(
      (value) => value.id == profile.id,
    );
    expect(reverted.routes, isNot(contains(SiteRoute.direct)));
    expect(reverted.routes, contains(SiteRoute.browse));
  });
}
