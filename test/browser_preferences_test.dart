import 'package:site_lens/settings/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeWebHostApi api;
  late AppController app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    api = FakeWebHostApi();
    app = AppController(db, api: api);
    await app.load();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  test('the two browsing policies default in opposite directions', () async {
    // Entry redirects are followed by default (the mirror funnel), while the
    // pull gesture stays with the page until the user asks for it.
    expect(app.followEntryRedirects, isTrue);
    expect(app.pullToRefresh, isFalse);
    expect(app.hostPreferences.followEntryRedirects, isTrue);
    expect(app.hostPreferences.pullToRefresh, isFalse);
  });

  test('a new host is created with the current policy', () async {
    await app.setFollowEntryRedirects(false);
    await app.setPullToRefresh(true);
    api.created.clear();

    await app.openUrl(Uri.parse('https://a.example/'), label: 'a');

    expect(api.created, hasLength(1));
    final created = api.createdWith[api.created.single]!;
    expect(created.followEntryRedirects, isFalse);
    expect(created.pullToRefresh, isTrue);
  });

  test('flipping a switch persists it and pushes it to live hosts', () async {
    await app.openUrl(Uri.parse('https://a.example/'), label: 'a');
    final host = app.hosts.sessions.values.single;
    api.applied.clear();

    await app.setFollowEntryRedirects(false);
    await app.setPullToRefresh(true);

    // One push per switch, each carrying the whole policy, addressed at the host
    // that is already running.
    expect(api.applied, hasLength(2));
    expect(api.applied.last.followEntryRedirects, isFalse);
    expect(api.applied.last.pullToRefresh, isTrue);
    expect(host.disposed, isFalse);

    // A fresh controller over the same database reads both back (both differ
    // from their defaults, so this is a real round trip).
    final reopened = AppController(db, api: FakeWebHostApi());
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.followEntryRedirects, isFalse);
    expect(reopened.pullToRefresh, isTrue);
  });

  test(
    'missing or migrated rows keep each switch at its own default',
    () async {
      // Entry redirects: only an explicit 'false' turns the policy off, so an
      // absent row cannot silently weaken the fail-closed default.
      // Pull-to-refresh: only an explicit 'true' turns the gesture on, so an absent
      // row cannot silently take the gesture away from the page.
      await db.setSetting(followEntryRedirectsKey, '');
      await db.setSetting(pullToRefreshKey, '');
      final controller = AppController(db, api: FakeWebHostApi());
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.followEntryRedirects, isTrue);
      expect(controller.pullToRefresh, isFalse);
      expect(controller.hosts.preferences.followEntryRedirects, isTrue);
      expect(controller.hosts.preferences.pullToRefresh, isFalse);

      // ...and the opposite explicit values are honoured.
      await SettingsRepository(db).update({'followEntryRedirects': false});
      await SettingsRepository(db).update({'pullToRefresh': true});
      final strict = AppController(db, api: FakeWebHostApi());
      addTearDown(strict.dispose);
      await strict.load();
      expect(strict.followEntryRedirects, isFalse);
      expect(strict.pullToRefresh, isTrue);
    },
  );

  testWidgets('the settings page owns both switches', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SettingsPage(app: app)));

    // 高级与诊断 is a section label, not a collapsible block: its rows are
    // already in the tree, so there is nothing to tap open.
    await tester.scrollUntilVisible(
      find.text('高级与诊断'),
      400,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('高级与诊断'), findsOneWidget);
    final entry = find.text('入口跨域跳转后保留脚本');
    final pull = find.text('浏览页下拉刷新（Android）');
    await tester.scrollUntilVisible(
      entry,
      500,
      scrollable: find.byType(Scrollable),
    );
    expect(entry, findsOneWidget);
    expect(pull, findsOneWidget);

    await tester.ensureVisible(
      find.widgetWithText(SwitchListTile, '入口跨域跳转后保留脚本'),
    );
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(app.followEntryRedirects, isFalse);
    expect(
      (await SettingsRepository(db).read()).followEntryRedirects,
      isFalse,
      reason: 'the switch has to survive a restart, not just the session',
    );

    await tester.ensureVisible(
      find.widgetWithText(SwitchListTile, '浏览页下拉刷新（Android）'),
    );
    await tester.pumpAndSettle();
    await tester.tap(pull);
    await tester.pumpAndSettle();
    expect(app.pullToRefresh, isTrue);
    expect((await SettingsRepository(db).read()).pullToRefresh, isTrue);
  });
}
