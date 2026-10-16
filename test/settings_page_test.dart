import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/update/update_controller.dart';
import 'package:site_lens/update/update_service.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/settings/settings_repository.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/glass_quality_cache.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_update_platform.dart';
import 'fake_web_host_api.dart';

/// The update row subscribes to [updateControllerProvider]; the page is pumped
/// inside a scope with a controller that never touches the network.
UpdateController quietUpdateController() {
  final controller = UpdateController(
    service: UpdateService(
      platform: FakeUpdatePlatform(),
      workDirectoryLoader: () async =>
          Directory.systemTemp.createTemp('site-lens-quiet-work-'),
    ),
  );
  addTearDown(controller.dispose);
  return controller;
}

Widget settingsApp(AppController app, UpdateController update) => ProviderScope(
  overrides: [updateControllerProvider.overrideWithValue(update)],
  child: MaterialApp(
    home: ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(body: SettingsPage(app: app)),
    ),
  ),
);

Future<void> pumpSettings(
  WidgetTester tester,
  AppController app, {
  UpdateController? update,
}) async {
  await tester.pumpWidget(settingsApp(app, update ?? quietUpdateController()));
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late AppController app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = AppController(db, api: FakeWebHostApi());
    await app.load();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  test(
    'changing glass quality mode clears the runtime quality cache',
    () async {
      final cache = SiteLensGlassQualityCacheRepository(db);
      await cache.write(
        const SiteLensGlassQualityCache(
          quality: GlassQuality.premium,
          fingerprint: 'old-fingerprint',
        ),
      );
      await app.setGlassQualityMode(SiteLensGlassQualityMode.high);
      expect(await db.setting(SiteLensGlassQualityCacheRepository.key), isNull);
    },
  );

  testWidgets('明暗模式 switches inline, without a bottom sheet', (tester) async {
    await pumpSettings(tester, app);
    expect(find.text('明暗模式'), findsOneWidget);
    expect(find.text('不透明度'), findsOneWidget);
    expect(find.textContaining('只影响面板背景填充'), findsNothing);
    expect(find.text('透明度'), findsNothing);
    expect(find.textContaining('55 / 100'), findsOneWidget);
    expect(find.text('高质量覆盖全部面板'), findsNothing);
    expect(
      find.byKey(const ValueKey('default-glass-opacity-marker')),
      findsOneWidget,
    );
    await app.updateSettings({'glassOpacity': 22});
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('default-glass-opacity-marker')),
    );
    await tester.pumpAndSettle();
    expect(app.settings.glassOpacity, 55);
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

  testWidgets('rows are separated and glass quality is an explicit mode', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    expect(find.text('玻璃质量'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
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

  testWidgets('manual high quality updates the effective glass quality', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.tap(find.text('高质量'));
    await tester.pumpAndSettle();

    expect(app.settings.glassQualityMode, SiteLensGlassQualityMode.high);
    expect(app.effectiveGlassQuality, GlassQuality.premium);
    expect(find.text('当前有效质量'), findsOneWidget);
    expect(find.text('高质量'), findsWidgets);
    final allSurfaces = find.text('高质量覆盖全部面板');
    expect(allSurfaces, findsOneWidget);
    final switchTile = find.ancestor(
      of: allSurfaces,
      matching: find.byType(SwitchListTile),
    );
    expect(switchTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchTile).onChanged, isNotNull);

    await tester.tap(allSurfaces);
    await tester.pumpAndSettle();
    expect(app.settings.highQualityAllSurfaces, isTrue);

    await tester.tap(find.text('标准'));
    await tester.pumpAndSettle();
    expect(find.text('高质量覆盖全部面板'), findsNothing);

    await tester.tap(find.text('高质量'));
    await tester.pumpAndSettle();
    final restoredSwitch = find.ancestor(
      of: find.text('高质量覆盖全部面板'),
      matching: find.byType(SwitchListTile),
    );
    expect(restoredSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(restoredSwitch).value, isTrue);

    await tester.tap(find.text('自动'));
    await tester.pumpAndSettle();
    expect(find.text('高质量覆盖全部面板'), findsNothing);
  });

  testWidgets(
    'capability results have one readable summary without raw diagnostics',
    (tester) async {
      app.capabilities = HostCapabilities(
        platform: 'Android WebView private raw platform',
        reason: 'world=true; navigation=false; internal_reason',
        isolatedScripts: true,
        documentStart: false,
        privateProbes: true,
      );
      await pumpSettings(tester, app);
      await tester.scrollUntilVisible(
        find.text('检查宿主能力'),
        400,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('检查宿主能力'), findsOneWidget);
      expect(find.textContaining('脚本增强：支持'), findsOneWidget);
      expect(find.textContaining('页面注入：不可用'), findsOneWidget);
      expect(find.textContaining('private raw'), findsNothing);
      expect(find.textContaining('internal_reason'), findsNothing);
      expect(
        find.byKey(const ValueKey('details-host-capabilities')),
        findsNothing,
      );
      await tester.ensureVisible(find.text('检查宿主能力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查宿主能力'));
      await tester.pumpAndSettle();
      expect(find.text('网页增强能力可用'), findsOneWidget);
      expect(app.browserTabs, isEmpty);
      expect(app.hosts.sessions, isEmpty);
    },
  );

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

  testWidgets(
    'removed duplicate entries and new tab policy are visible in one settings page',
    (tester) async {
      await pumpSettings(tester, app);
      expect(find.text('入口跨域跳转后保留脚本'), findsNothing);
      expect(find.text('全局关闭脚本'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('脚本管理'),
        300,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('脚本管理'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('同站点标签页互相替换'),
        500,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('同站点标签页互相替换'), findsOneWidget);
      expect(find.text('检查宿主能力'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('details-host-capabilities')),
        findsNothing,
      );
    },
  );

  testWidgets('settings exposes about and software update entries', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.scrollUntilVisible(
      find.text('关于 Site Lens'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('关于 Site Lens'), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
  });
}
