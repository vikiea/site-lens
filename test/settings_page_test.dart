import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/settings_repository.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/screens.dart';

Future<void> pumpSettings(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) => Scaffold(body: SettingsPage(app: app)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late AppController app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = AppController(db);
    await app.load();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  testWidgets('明暗模式 switches inline, without a bottom sheet', (tester) async {
    await pumpSettings(tester, app);
    expect(find.text('明暗模式'), findsOneWidget);
    final segmented = find.byType(SiteLensSegmented<ThemeModePreference>);
    expect(segmented, findsOneWidget);
    expect(tester.getSize(segmented).height, SiteLensMetrics.segmentedHeight);
    final selectedPills = find.descendant(
      of: segmented,
      matching: find.byType(AnimatedContainer),
    );
    expect(selectedPills, findsNWidgets(3));
    for (final pill in selectedPills.evaluate()) {
      expect(
        tester.getSize(find.byWidget(pill.widget)).height,
        SiteLensMetrics.segmentedHeight -
            SiteLensMetrics.segmentedInset * 2 -
            2,
      );
    }
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(app.themeModePreference, ThemeModePreference.dark);
    expect(
      (await SettingsRepository(db).read()).themeMode,
      ThemeModePreference.dark,
    );

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(app.themeModePreference, ThemeModePreference.light);
  });

  testWidgets('主题色 stays folded until asked for, then selects inline', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    // Folded: the swatches are not in the built tree yet.
    expect(find.text('雾松绿'), findsNothing);

    await tester.tap(find.text('主题色'));
    await tester.pumpAndSettle();
    expect(find.text('雾松绿'), findsNothing);
    expect(find.bySemanticsLabel('主题色 雾松绿'), findsOneWidget);
    // Still no sheet: the choice happens inside the section.
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.bySemanticsLabel('主题色 雾松绿'));
    await tester.pumpAndSettle();
    expect(app.themePreset, ThemePresetId.mistPine);
    expect(
      (await SettingsRepository(db).read()).themePreset,
      ThemePresetId.mistPine,
    );
    // Selecting does not fold the block again.
    expect(find.text('雾松绿'), findsWidgets);
  });

  testWidgets('rows are separated and the material is not a preference', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    expect(find.text('玻璃效果'), findsNothing);
    // Every setting-sized surface is gone: rows live in one panel per section.
    expect(find.byType(Card), findsNothing);

    final appearance = tester.getRect(find.text('明暗模式'));
    final themeRow = tester.getRect(find.text('主题色'));
    expect(
      themeRow.top - appearance.bottom,
      greaterThan(20),
      reason: 'the mode control and the theme row are not cramped together',
    );
  });

  testWidgets('long safety text is folded behind 详情 but kept in full', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.scrollUntilVisible(
      find.text('后台存活检查'),
      300,
      scrollable: find.byType(Scrollable),
    );
    // The row keeps a short summary...
    expect(find.text('仅充电 + WiFi，每天最多两次；只做 HTTP 初筛'), findsOneWidget);
    // ...and the full wording is folded directly beneath it.
    expect(find.textContaining('不会干扰登录状态与用户脚本'), findsNothing);
    final details = find.byKey(const ValueKey('details-background-health'));
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('不会干扰登录状态与用户脚本'),
      200,
      scrollable: find.byType(Scrollable),
    );
    expect(find.textContaining('不会干扰登录状态与用户脚本'), findsOneWidget);
  });
}
