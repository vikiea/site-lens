import 'package:site_lens/settings/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/browser_entry.dart';
import 'package:site_lens/ui/profile_panel.dart';
import 'package:site_lens/ui/screens.dart';

void main() {
  testWidgets('empty product invites adding a profile and can create one', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    await app.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilesPanel(app: app, onOpen: (_) {}, onResume: () {}),
        ),
      ),
    );
    expect(find.text('我的站点'), findsOneWidget);
    expect(find.textContaining('还没有站点档案'), findsOneWidget);

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

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(app: app)),
        ),
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
