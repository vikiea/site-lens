import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/settings/settings_repository.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/player_gestures_screen.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'fake_web_host_api.dart';

void main() {
  testWidgets('media library notice dismissal survives recreating settings', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: app,
            builder: (_, _) => MediaLibraryScreen(app: app),
          ),
        ),
      );
      expect(find.text('不再提示'), findsOneWidget);
      await tester.tap(find.text('不再提示'));
      await tester.pumpAndSettle();
      expect(find.text('不再提示'), findsNothing);
      expect(
        (await SettingsRepository(db).read()).mediaLibraryNoticeDismissed,
        isTrue,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      await db.close();
    }
  });
  testWidgets('gesture setting stays inline and help stays folded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.dark),
          home: PlayerGesturesScreen(app: app),
        ),
      );
      expect(find.text('手势用途'), findsNothing);
      expect(find.textContaining('向上增加'), findsNothing);
      final label = tester.getRect(find.text('上下滑动'));
      final choice = tester.getRect(find.text('亮度 / 音量'));
      expect((label.center.dy - choice.center.dy).abs(), lessThan(2));
      final selector = tester.getRect(
        find.byType(SiteLensMenuSelector<PlayerVerticalGestureMode>),
      );
      final otherSummary = tester.getRect(find.text('快进 / 快退'));
      expect(selector.right, closeTo(otherSummary.right, 1));
      final trigger = tester.widget<TextButton>(
        find.descendant(
          of: find.byTooltip('选择上下滑动操作'),
          matching: find.byType(TextButton),
        ),
      );
      expect(trigger.style!.textStyle!.resolve({})!.fontSize, 12.5);
      await tester.tap(find.byTooltip('选择上下滑动操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一集 / 下一集'));
      await tester.pumpAndSettle();
      expect(
        app.playerVerticalGesture,
        PlayerVerticalGestureMode.episodeSwitch,
      );
      expect(
        (await SettingsRepository(db).read()).playerVerticalGesture,
        PlayerVerticalGestureMode.episodeSwitch,
      );
      await tester.tap(find.text('详情').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('向上滑动切换下一集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      await db.close();
    }
  });

  testWidgets('foldable rows keep keyboard focus without a grey overlay', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: const Scaffold(
          body: SiteLensFoldable(
            child: ExpansionTile(title: Text('详情'), children: [Text('完整说明')]),
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(ExpansionTile));
    expect(Theme.of(context).focusColor, Colors.transparent);
    expect(Theme.of(context).highlightColor, Colors.transparent);
    expect(Theme.of(context).splashFactory, NoSplash.splashFactory);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('完整说明'), findsOneWidget);
  });

  testWidgets('gesture help rows remain bounded at narrow large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2.5)),
              child: PlayerGesturesScreen(app: app),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('显示 / 隐藏控制栏'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      await db.close();
    }
  });

  testWidgets('playlist truncates the left side and preserves episode suffix', (
    tester,
  ) async {
    const title = '很长很长的系列标题需要从左侧省略 - 第123集';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 150, child: SiteLensLeadingEllipsisText(title)),
        ),
      ),
    );
    final text = tester.widget<Text>(find.byType(Text).last);
    expect(text.data, startsWith('…'));
    expect(text.data, endsWith('第123集'));
    expect(text.semanticsLabel, title);
  });
}
