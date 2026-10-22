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
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';
import 'package:site_lens/ui/player_gestures_screen.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/web_host.g.dart';
import 'package:site_lens/filter/filter_service.dart';

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
  child: ListenableBuilder(
    listenable: app,
    builder: (context, _) => MaterialApp(
      theme: buildSiteLensTheme(
        app.themePreset,
        Brightness.light,
        glassOpacity: app.settings.glassOpacity,
      ),
      darkTheme: buildSiteLensTheme(
        app.themePreset,
        Brightness.dark,
        glassOpacity: app.settings.glassOpacity,
      ),
      themeMode: toThemeMode(app.themeModePreference),
      builder: (context, child) => SiteLensGlassPolicyScope(
        strategy: SiteLensGlassQualityStrategy(
          mode: app.settings.glassQualityMode,
          allSurfacesHighQuality: app.settings.highQualityAllSurfaces,
          adaptiveQualityOverride: app.effectiveGlassQuality,
          shaderSupported: true,
        ),
        child: SiteLensBackdrop(child: child!),
      ),
      home: Scaffold(
        body: SiteLensGlassGroup(child: SettingsPage(app: app)),
      ),
    ),
  ),
);

Future<void> openSettingsEntry(WidgetTester tester, String title) async {
  final row = find.text(title);
  await tester.scrollUntilVisible(
    row,
    250,
    scrollable: find.byType(Scrollable),
  );
  await tester.tap(row);
  await tester.pumpAndSettle();
}

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
    await openSettingsEntry(tester, '外观与玻璃');
    expect(find.text('明暗模式'), findsOneWidget);
    expect(find.text('不透明度'), findsOneWidget);
    expect(find.textContaining('只影响面板背景填充'), findsNothing);
    expect(find.text('透明度'), findsNothing);
    expect(find.textContaining('55 / 100'), findsOneWidget);
    expect(find.text('高质量覆盖全部面板'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('default-glass-opacity-marker')),
      findsOneWidget,
    );
    await app.updateSettings({'glassOpacity': 22});
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('default-glass-opacity-marker')),
      warnIfMissed:
          false, // Visual marker intentionally lets the slider receive the tap.
    );
    await tester.pumpAndSettle();
    expect(app.settings.glassOpacity, 55);
    await tester.drag(find.byType(Slider), const Offset(-42, 0));
    await tester.pumpAndSettle();
    expect(app.settings.glassOpacity, lessThan(55));
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

  testWidgets('主题色 opens a third page and persists selection', (tester) async {
    await pumpSettings(tester, app);
    await openSettingsEntry(tester, '外观与玻璃');
    // Folded: the swatches are not in the built tree yet.
    expect(find.text('雾松绿'), findsNothing);

    await openSettingsEntry(tester, '主题色');
    await tester.pumpAndSettle();
    expect(find.text('雾松绿'), findsNothing);
    expect(find.bySemanticsLabel('主题色 雾松绿'), findsOneWidget);
    // Theme selection owns its route; the overview and appearance stay mounted.
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.bySemanticsLabel('主题色 雾松绿'));
    await tester.pumpAndSettle();
    expect(app.themePreset, ThemePresetId.mistPine);
    expect(
      (await SettingsRepository(db).read()).themePreset,
      ThemePresetId.mistPine,
    );
    // The selected theme remains visible until the route is left.
    expect(
      tester
          .widget<Semantics>(find.bySemanticsLabel('主题色 雾松绿'))
          .properties
          .selected,
      isTrue,
    );
  });

  testWidgets('rows are separated and glass quality is an explicit mode', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await openSettingsEntry(tester, '外观与玻璃');
    expect(find.text('玻璃质量'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    // Every setting-sized surface is gone: rows live in one panel per section.
    expect(find.byType(Card), findsNothing);

    final appearance = tester.getRect(find.text('明暗模式'));
    await tester.scrollUntilVisible(
      find.text('主题色'),
      250,
      scrollable: find.byType(Scrollable),
    );
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
    await openSettingsEntry(tester, '外观与玻璃');
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
    final automaticSwitch = find.widgetWithText(SwitchListTile, '高质量覆盖全部面板');
    expect(automaticSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(automaticSwitch).value, isTrue);
    await tester.tap(automaticSwitch);
    await tester.pumpAndSettle();
    expect(app.settings.highQualityAllSurfaces, isFalse);
    expect(
      (await SettingsRepository(db).read()).highQualityAllSurfaces,
      isFalse,
    );
  });

  testWidgets(
    'settings opens passive diagnostics and missing native query stays error',
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
        find.text('设备能力与平台策略'),
        400,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('设备能力与平台策略'), findsOneWidget);
      expect(find.text('查看实际能力、授权状态和当前策略'), findsOneWidget);
      expect(find.textContaining('private raw'), findsNothing);
      expect(find.textContaining('internal_reason'), findsNothing);
      expect(
        find.byKey(const ValueKey('details-host-capabilities')),
        findsNothing,
      );
      await tester.ensureVisible(find.text('设备能力与平台策略'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设备能力与平台策略'));
      await tester.pumpAndSettle();
      expect(find.text('当前环境'), findsOneWidget);
      await openSettingsEntry(tester, '其他能力');
      expect(find.textContaining('原生只读查询未完成'), findsOneWidget);
      expect(
        app.deviceDiagnostics.snapshot!.capabilities.single.state,
        CapabilityState.error,
      );
      expect(
        app.deviceDiagnostics.snapshot!.capabilities.single.effective,
        isNull,
      );
      expect(app.browserTabs, isEmpty);
      expect(app.hosts.sessions, isEmpty);
    },
  );

  testWidgets('long safety text is folded behind 详情 but kept in full', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await openSettingsEntry(tester, '后台与诊断');
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
    'overview links preserve navigation, tab policy and player gestures',
    (tester) async {
      await pumpSettings(tester, app);
      expect(find.text('全局关闭脚本'), findsNothing);
      expect(find.text('同站点标签页互相替换'), findsNothing);
      await openSettingsEntry(tester, '浏览设置');
      expect(find.byType(Scrollable), findsOneWidget);
      await tester.tap(find.text('同站点标签页互相替换'));
      await tester.pumpAndSettle();
      expect((await SettingsRepository(db).read()).replaceSameSiteTabs, isTrue);
      expect(find.text('入口跨域跳转后保留脚本'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openSettingsEntry(tester, '媒体管理');
      expect(find.byType(MediaManagementScreen), findsOneWidget);
      await openSettingsEntry(tester, '播放器手势');
      expect(find.byType(PlayerGesturesScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('外观与玻璃'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('广告与反跟踪 opens filter policy and persists its switch', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await openSettingsEntry(tester, '浏览设置');
    await tester.scrollUntilVisible(
      find.text('广告与反跟踪'),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.ensureVisible(find.text('广告与反跟踪'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('广告与反跟踪'));
    await tester.pumpAndSettle();
    expect(find.text('启用广告过滤'), findsOneWidget);
    expect(find.text('拦截域名'), findsOneWidget);
    expect(find.text('例外域名'), findsOneWidget);
    expect(find.text('规则源'), findsOneWidget);
    expect(find.textContaining('大型规则源会自动加载'), findsOneWidget);
    expect(app.filterSourceList, hasLength(builtInFilterSources.length));
    expect(
      app.filterSourceList.every((source) => source.kind == 'builtin'),
      isTrue,
    );

    await tester.tap(find.text('启用广告过滤'));
    await tester.pumpAndSettle();
    expect(app.filterPolicy.enabled, isTrue);
    expect((await db.filterPolicy()).enabled, isTrue);
  });

  testWidgets('settings exposes about and software update entries', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await openSettingsEntry(tester, '关于与更新');
    await tester.scrollUntilVisible(
      find.text('关于 Site Lens'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('关于 Site Lens'), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    for (final opacity in [0, 55, 100]) {
      testWidgets(
        'settings keep one scroll with large text, dark=$dark opacity=$opacity',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await app.updateSettings({
            'themeMode': dark ? 'dark' : 'light',
            'themePreset': ThemePresetId.sunsetCoral.wireId,
            'glassOpacity': opacity,
            'glassQualityMode': 'high',
            'highQualityAllSurfaces': true,
          });
          await pumpSettings(tester, app);
          expect(find.byType(Scrollable), findsOneWidget);
          await openSettingsEntry(tester, '外观与玻璃');
          expect(find.byType(Scrollable), findsOneWidget);
          final surfaces = tester.widgetList<AdaptiveGlass>(
            find.byType(AdaptiveGlass),
          );
          expect(surfaces, isNotEmpty);
          expect(
            surfaces.every(
              (surface) => surface.quality == GlassQuality.premium,
            ),
            isTrue,
          );
          await tester.scrollUntilVisible(
            find.text('主题色'),
            300,
            scrollable: find.byType(Scrollable),
          );
          await tester.tap(find.text('主题色'));
          await tester.pumpAndSettle();
          expect(find.byType(Scrollable), findsOneWidget);
          await tester.scrollUntilVisible(
            find.bySemanticsLabel('主题色 雾松绿'),
            250,
            scrollable: find.byType(Scrollable),
          );
          await tester.tap(find.bySemanticsLabel('主题色 雾松绿'));
          await tester.pumpAndSettle();
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(app.themePreset, ThemePresetId.mistPine);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('GitHub token entry is only shown for the beta channel', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await openSettingsEntry(tester, '关于与更新');
    await tester.scrollUntilVisible(
      find.text('更新渠道'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('更新渠道'), findsOneWidget);
    expect(find.text('GitHub API Token'), findsNothing);

    await app.updateSettings({'updateChannel': UpdateChannel.beta.name});
    await tester.pumpAndSettle();
    expect(find.text('GitHub API Token'), findsOneWidget);

    await app.updateSettings({'updateChannel': UpdateChannel.stable.name});
    await tester.pumpAndSettle();
    expect(find.text('GitHub API Token'), findsNothing);
  });
}
