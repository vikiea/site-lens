import 'package:site_lens/settings/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/update/update_controller.dart';
import 'package:site_lens/update/update_service.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/browser_entry.dart';
import 'package:site_lens/ui/profile_panel.dart';
import 'package:site_lens/ui/screens.dart';

import 'fake_update_platform.dart';
import 'fake_web_host_api.dart';

void main() {
  testWidgets('home exposes import and detection actions in the app bar', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    await app.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWithValue(app)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('导入档案包'), findsOneWidget);
    expect(find.byTooltip('全部检测'), findsOneWidget);
    expect(find.byTooltip('站点操作'), findsNothing);

    await tester.tap(find.text('浏览'));
    await tester.pump();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('新建标签页'), findsOneWidget);
    await tester.tap(find.text('媒体'));
    await tester.pump();
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).appBar, isNull);
    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.text('站点'));
    await tester.pump();
    expect(find.text('Site Lens'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await app.shutdown();
    await db.close();
  });

  testWidgets('site cards label stale recommendations and expose detection', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    final profileId = await db.createProfile('示例站');
    await db.addCandidate(
      Uri.parse('https://example.com/'),
      label: '主地址',
      profileId: profileId,
    );
    final candidate = (await db.candidates()).single;
    await db.saveProbe(
      ProbeResult(
        round: 1,
        candidateId: candidate.id,
        stage: ProbeStage.homepage,
        status: ProbeStatus.ready,
        entryUrl: candidate.url,
        finalUrl: candidate.url,
        checkedAt: DateTime(2026, 10, 17),
      ),
    );
    await app.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilesPanel(app: app, onOpen: (_) {}, onResume: () {}),
        ),
      ),
    );

    expect(find.text('本轮暂无推荐'), findsOneWidget);
    expect(find.byTooltip('检测此档案'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await app.shutdown();
    await db.close();
  });

  testWidgets('empty product invites adding a profile and can create one', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    await app.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ProfilesPanel(app: app, onOpen: (_) {}, onResume: () {}),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('我的站点'), findsNothing);
    expect(find.textContaining('还没有站点档案'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '添加站点'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '添加站点'));
    await tester.pumpAndSettle();
    // URL-first entry, with the manual form as the documented fallback.
    expect(find.text('开始侦察'), findsOneWidget);
    await tester.tap(find.text('手动填写'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), '示例站');
    await tester.enterText(fields.at(3), 'main');
    await tester.tap(find.widgetWithText(FilledButton, '创建档案'));
    await tester.pumpAndSettle();

    expect(find.text('示例站'), findsOneWidget);
    final profile = (await db.profiles()).single;
    expect(profile.readySelector, 'main');

    await tester.pumpWidget(const SizedBox());
    await app.shutdown();
    await db.close();
  });

  testWidgets(
    'startup loading does not present an empty profile state before hydration',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      try {
        await db.createProfile('已保存站点');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProfilesPanel(app: app, onOpen: (_) {}, onResume: () {}),
            ),
          ),
        );

        expect(app.persistentStateLoaded, isFalse);
        expect(find.textContaining('还没有站点档案'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.runAsync(app.load);
        await tester.pump();

        expect(app.persistentStateLoaded, isTrue);
        expect(find.text('已保存站点'), findsOneWidget);
        expect(find.textContaining('还没有站点档案'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      } finally {
        // Shutdown awaits futures created in the widget test's fake async zone.
        // Keep cleanup in that zone so addTearDown cannot strand those futures.
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
  );

  testWidgets(
    'scripts tab groups by profile and 未绑定, and recovery toggle works',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      await app.load();
      await app.db.createProfile('甲站');
      await app.scripts.save(
        '// ==UserScript==\n// @name S\n// @match https://a.example/*\n// @grant GM_addStyle\n// ==/UserScript==\n',
      );
      await app.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScriptsPage(app: app)),
        ),
      );
      expect(find.text('未绑定'), findsOneWidget);
      expect(find.text('甲站'), findsOneWidget);
      // The script has no binding yet, so it lives in the 未绑定 group.
      expect(app.unboundScripts, hasLength(1));

      final update = UpdateController(
        service: UpdateService(platform: FakeUpdatePlatform()),
      );
      addTearDown(update.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [updateControllerProvider.overrideWithValue(update)],
          child: MaterialApp(
            home: Scaffold(body: SettingsPage(app: app)),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('高级与诊断'),
        200,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('高级与诊断'), findsOneWidget);
      expect(find.text('全局关闭脚本'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('后台存活检查'),
        200,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('后台存活检查'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScriptsPage(app: app)),
        ),
      );
      expect(find.text('全局关闭脚本'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(SwitchListTile, '全局关闭脚本'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect((await SettingsRepository(db).read()).scriptsDisabled, isTrue);

      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      await db.close();
    },
  );

  testWidgets('site cards expose disabled state and script editor actions', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    await app.load();
    final profileId = await app.db.createProfile('停用档案');
    await app.db.setProfileEnabled(profileId, false);
    await app.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilesPanel(app: app, onOpen: (_) {}, onResume: () {}),
        ),
      ),
    );
    expect(find.text('站点已停用'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.pumpWidget(
      MaterialApp(home: ScriptManagementScreen(app: app)),
    );
    expect(find.text('脚本状态'), findsOneWidget);
    expect(find.byTooltip('导入 .user.js'), findsOneWidget);
    expect(find.byTooltip('新建或粘贴脚本'), findsOneWidget);
    await tester.tap(find.byTooltip('新建或粘贴脚本'));
    await tester.pumpAndSettle();
    expect(find.text('脚本元数据'), findsOneWidget);
    expect(find.text('保存后会撤销当前确认摘要；重新启用时需要再次确认权限和固定依赖。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await app.shutdown();
    await db.close();
  });

  testWidgets('browser tab page and resume row are inert without a session', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    await app.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserTabsPage(app: app, onResume: (_) {}, onNewTab: () {}),
        ),
      ),
    );
    expect(find.text('还没有打开的标签页'), findsOneWidget);

    // Without an open session the in-page resume row must not appear.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeBrowserBar(app: app, onResume: () {}),
        ),
      ),
    );
    expect(find.byType(ListTile), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await app.shutdown();
    await db.close();
  });

  testWidgets('tab switcher opens as a grid sheet on the nav bar', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    await app.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showTabSwitcher(context, app),
                child: const Text('open-switcher'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-switcher'));
    await tester.pumpAndSettle();
    expect(find.text('标签页 0/8'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await app.shutdown();
    await db.close();
  });
}
