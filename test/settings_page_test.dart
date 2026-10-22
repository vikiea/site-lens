import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/settings/settings_repository.dart';
import 'package:site_lens/ui/about_screen.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/data_management_screen.dart';
import 'package:site_lens/ui/glass_quality_cache.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/player_gestures_screen.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/software_update_screen.dart';
import 'package:site_lens/update/update_controller.dart';
import 'package:site_lens/update/update_service.dart';

import 'fake_update_platform.dart';
import 'fake_web_host_api.dart';

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

Future<void> pumpSettings(
  WidgetTester tester,
  AppController app, {
  UpdateController? update,
}) async {
  await tester.pumpWidget(settingsApp(app, update ?? quietUpdateController()));
  await tester.pumpAndSettle();
}

Future<void> scrollSettingsToEnd(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable);
  for (var i = 0; i < 6; i++) {
    await tester.drag(scrollable, const Offset(0, -500));
    await tester.pumpAndSettle();
  }
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

  testWidgets('settings home keeps categories visible in one page', (
    tester,
  ) async {
    await pumpSettings(tester, app);

    expect(find.text('外观'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    await tester.scrollUntilVisible(
      find.text('浏览'),
      200,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('浏览'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('媒体'),
      200,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('媒体'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('数据与诊断'),
      200,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('数据与诊断'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('应用'),
      200,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('应用'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
    expect(find.byType(Scrollable), findsOneWidget);
  });

  testWidgets('appearance keeps opacity compact and theme color in a menu', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    expect(find.textContaining('55 / 100'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('default-glass-opacity-marker')),
      findsOneWidget,
    );
    final opacityValue = tester.getRect(find.textContaining('55 / 100'));
    final opacitySlider = tester.getRect(find.byType(Slider));
    expect(
      (opacityValue.center.dy - opacitySlider.center.dy).abs(),
      lessThan(18),
    );
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.byTooltip('选择主题色'));
    await tester.pumpAndSettle();
    expect(find.text('雾松绿'), findsOneWidget);

    await tester.tap(find.text('雾松绿'));
    await tester.pumpAndSettle();
    expect(app.themePreset, ThemePresetId.mistPine);
    expect(
      (await SettingsRepository(db).read()).themePreset,
      ThemePresetId.mistPine,
    );
  });

  testWidgets('appearance settings persist through the existing setters', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(app.themeModePreference, ThemeModePreference.dark);
    expect(
      (await SettingsRepository(db).read()).themeMode,
      ThemeModePreference.dark,
    );

    await tester.tap(find.text('高质量'));
    await tester.pumpAndSettle();
    expect(app.effectiveGlassQuality, GlassQuality.premium);
    expect(find.text('高质量覆盖全部面板'), findsOneWidget);
    await tester.tap(find.text('高质量覆盖全部面板'));
    await tester.pumpAndSettle();
    expect(app.settings.highQualityAllSurfaces, isTrue);
  });

  testWidgets('about and software update are direct routes', (tester) async {
    await pumpSettings(tester, app);
    await scrollSettingsToEnd(tester);
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await scrollSettingsToEnd(tester);
    await tester.tap(find.text('软件更新'));
    await tester.pumpAndSettle();
    expect(find.byType(SoftwareUpdateScreen), findsOneWidget);
    expect(find.text('更新设置'), findsOneWidget);
    expect(find.text('稳定版'), findsOneWidget);
    await tester.pageBack();
  });

  testWidgets('complex settings stay on direct second-level pages', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.scrollUntilVisible(
      find.text('播放器手势'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.ensureVisible(find.text('播放器手势'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放器手势'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerGesturesScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('备份与恢复'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.ensureVisible(find.text('备份与恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份与恢复'));
    await tester.pumpAndSettle();
    expect(find.byType(DataManagementScreen), findsOneWidget);
  });

  testWidgets('beta token stays on the direct software update page', (
    tester,
  ) async {
    await app.updateSettings({'updateChannel': UpdateChannel.beta.name});
    await pumpSettings(tester, app);
    await scrollSettingsToEnd(tester);
    await tester.tap(find.text('软件更新'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub API Token'), findsOneWidget);
    expect(find.text('关于与更新'), findsNothing);
  });

  testWidgets('settings remain one page scrollable at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.updateSettings({
      'themeMode': 'dark',
      'themePreset': ThemePresetId.sunsetCoral.wireId,
      'glassOpacity': 100,
      'glassQualityMode': 'high',
      'highQualityAllSurfaces': true,
    });
    await pumpSettings(tester, app);
    expect(find.byType(Scrollable), findsOneWidget);
    expect(tester.takeException(), isNull);
    final surfaces = tester.widgetList<AdaptiveGlass>(
      find.byType(AdaptiveGlass),
    );
    expect(surfaces, isNotEmpty);
    expect(
      surfaces.every((surface) => surface.quality == GlassQuality.premium),
      isTrue,
    );
  });
}
