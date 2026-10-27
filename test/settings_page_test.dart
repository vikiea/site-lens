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
import 'package:site_lens/ui/ui_primitives.dart';
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

Widget settingsApp(
  AppController app,
  UpdateController update, {
  TargetPlatform? platform,
}) => ProviderScope(
  overrides: [updateControllerProvider.overrideWithValue(update)],
  child: ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final light = buildSiteLensTheme(
        app.themePreset,
        Brightness.light,
        glassOpacity: app.settings.glassOpacity,
      ).copyWith(platform: platform);
      final dark = buildSiteLensTheme(
        app.themePreset,
        Brightness.dark,
        glassOpacity: app.settings.glassOpacity,
      ).copyWith(platform: platform);
      return MaterialApp(
        theme: light,
        darkTheme: dark,
        themeMode: toThemeMode(app.themeModePreference),
        builder: (context, child) => SiteLensGlassPolicyScope(
          strategy: SiteLensGlassQualityStrategy(
            mode: app.settings.glassQualityMode,
            allSurfacesHighQuality: app.settings.highQualityAllSurfaces,
            adaptiveQualityOverride: app.effectiveGlassQuality,
            lightweightShaderSupported: true,
            backgroundMode: app.background.mode,
          ),
          child: SiteLensBackdrop(child: child!),
        ),
        home: Scaffold(
          body: SiteLensGlassGroup(child: SettingsPage(app: app)),
        ),
      );
    },
  ),
);

Future<void> pumpSettings(
  WidgetTester tester,
  AppController app, {
  UpdateController? update,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  });
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

Future<void> tapSettingAndWait(
  WidgetTester tester,
  AppController app,
  Finder target,
  bool Function() applied, {
  Offset? position,
}) async {
  var changed = false;
  void listener() {
    if (applied()) changed = true;
  }

  app.addListener(listener);
  try {
    if (position == null) {
      await tester.tap(target);
    } else {
      await tester.tapAt(position);
    }
    for (var attempt = 0; attempt < 100 && !changed; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      changed,
      isTrue,
      reason: 'setting did not publish its completed state',
    );
    await tester.pumpAndSettle();
  } finally {
    app.removeListener(listener);
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

  testWidgets('secure DNS is Android-only and exposes all built-ins', (
    tester,
  ) async {
    final update = quietUpdateController();
    await pumpSettings(tester, app, update: update);
    await tester.pumpWidget(
      settingsApp(app, update, platform: TargetPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('安全 DNS'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('安全 DNS'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SiteLensDisclosure),
        matching: find.byIcon(Icons.expand_more),
      ),
      findsWidgets,
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(SiteLensMenuSelector<SecureDnsProvider>),
            matching: find.text(SecureDnsProvider.off.label),
          )
          .first,
    );
    await tester.pumpAndSettle();
    for (final provider in SecureDnsProvider.values) {
      expect(find.text(provider.label), findsWidgets);
    }
    await tester.tap(find.text(SecureDnsProvider.cloudflare.label));
    await tester.pumpAndSettle();
    expect(app.settings.secureDnsProvider, SecureDnsProvider.cloudflare);

    await tester.pumpWidget(
      settingsApp(app, update, platform: TargetPlatform.iOS),
    );
    await tester.pumpAndSettle();
    expect(find.text('安全 DNS'), findsNothing);
  });

  testWidgets('background selector exposes the four global modes', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.tap(
      find
          .descendant(
            of: find.byType(SiteLensMenuSelector<BackgroundMode>),
            matching: find.text(BackgroundMode.defaultGradient.label),
          )
          .first,
    );
    await tester.pumpAndSettle();
    for (final mode in BackgroundMode.values) {
      expect(find.text(mode.label), findsWidgets);
    }
    await tester.tap(find.text(BackgroundMode.transparent.label));
    await tester.pumpAndSettle();
    expect(app.settings.backgroundMode, BackgroundMode.transparent);
  });

  testWidgets('cache action asks before clearing transient data', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tester.scrollUntilVisible(
      find.text('临时缓存'),
      300,
      scrollable: find.byType(Scrollable),
    );
    final clear = find.text('清除');
    await tester.scrollUntilVisible(
      clear,
      180,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('清除临时缓存？'), findsOneWidget);
    expect(find.textContaining('登录状态、标签页、媒体下载和导出文件会保留。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('清除临时缓存？'), findsNothing);
  });

  testWidgets(
    'appearance keeps opacity compact and theme colors collapsed in six columns',
    (tester) async {
      await pumpSettings(tester, app);
      expect(find.text('55 / 100'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('default-glass-opacity-marker')),
        findsOneWidget,
      );
      final opacityValue = tester.getRect(find.text('55 / 100'));
      final opacitySlider = tester.getRect(find.byType(Slider));
      expect(
        (opacityValue.center.dy - opacitySlider.center.dy).abs(),
        lessThan(18),
      );
      expect(find.byType(BottomSheet), findsNothing);

      expect(find.bySemanticsLabel('主题色 雾松绿'), findsNothing);
      await tester.tap(find.text('主题色'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('主题色 雾松绿'), findsOneWidget);
      final swatches = find.bySemanticsLabel(RegExp(r'^主题色 '));
      expect(swatches, findsNWidgets(ThemePresetId.values.length));
      final firstRow = ['星海蓝', '雾松绿', '鸢尾紫', '玫瑰灰', '砂岩铜', '石墨蓝灰'].map(
        (label) => tester.getTopLeft(find.bySemanticsLabel('主题色 $label')).dy,
      );
      expect(
        firstRow.map((value) => (value - firstRow.first).abs()),
        everyElement(lessThan(1)),
      );
      final secondRow = tester.getTopLeft(find.bySemanticsLabel('主题色 极光青')).dy;
      expect(secondRow, greaterThan(firstRow.first));
      await tester.tap(find.bySemanticsLabel('主题色 雾松绿'));
      await tester.pumpAndSettle();
      expect(app.themePreset, ThemePresetId.mistPine);
      await tester.runAsync(() async {
        expect(
          (await SettingsRepository(db).read()).themePreset,
          ThemePresetId.mistPine,
        );
      });
    },
  );

  testWidgets('appearance settings persist through the existing setters', (
    tester,
  ) async {
    await pumpSettings(tester, app);
    await tapSettingAndWait(
      tester,
      app,
      find.text('深色'),
      () => app.themeModePreference == ThemeModePreference.dark,
    );
    expect(app.themeModePreference, ThemeModePreference.dark);
    await tester.runAsync(() async {
      expect(
        (await SettingsRepository(db).read()).themeMode,
        ThemeModePreference.dark,
      );
    });

    expect(find.text('当前有效质量'), findsOneWidget);
    await tapSettingAndWait(
      tester,
      app,
      find.text('高质量'),
      () => app.settings.glassQualityMode == SiteLensGlassQualityMode.high,
    );
    expect(app.effectiveGlassQuality, GlassQuality.premium);
    await tester.runAsync(() async {
      expect(
        (await SettingsRepository(db).read()).glassQualityMode,
        SiteLensGlassQualityMode.high,
      );
    });
    expect(find.text('当前有效质量'), findsNothing);
    expect(find.text('高质量覆盖全部面板'), findsOneWidget);
    await tester.ensureVisible(find.text('高质量覆盖全部面板'));
    await tapSettingAndWait(
      tester,
      app,
      find.text('高质量覆盖全部面板'),
      () => app.settings.highQualityAllSurfaces,
    );
    expect(app.settings.highQualityAllSurfaces, isTrue);
    await tester.runAsync(() async {
      expect(
        (await SettingsRepository(db).read()).highQualityAllSurfaces,
        isTrue,
      );
    });
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
    expect(find.text('更新渠道'), findsOneWidget);
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
    await tester.runAsync(
      () => app.updateSettings({'updateChannel': UpdateChannel.beta.name}),
    );
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
    await tester.runAsync(
      () => app.updateSettings({
        'themeMode': 'dark',
        'themePreset': ThemePresetId.sunsetCoral.wireId,
        'glassOpacity': 100,
        'glassQualityMode': 'high',
        'highQualityAllSurfaces': true,
      }),
    );
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

  testWidgets('opacity controls fit narrow phone panels at every value', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final width in [320.0, 412.0]) {
      tester.view.physicalSize = Size(width, 800);
      for (final scale in [1.0, 2.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        for (final opacity in [0, 55, 100]) {
          await tester.runAsync(
            () => app.updateSettings({'glassOpacity': opacity}),
          );
          await pumpSettings(tester, app);
          expect(
            tester.takeException(),
            isNull,
            reason: 'width=$width scale=$scale opacity=$opacity',
          );
          final slider = tester.getRect(find.byType(Slider));
          expect(
            slider.right,
            closeTo(
              width -
                  SiteLensMetrics.pagePadding -
                  SiteLensMetrics.compactRowHorizontalPadding,
              1,
            ),
            reason: 'width=$width scale=$scale opacity=$opacity',
          );
          final label = tester.getCenter(find.text('不透明度'));
          final value = tester.getCenter(find.text('$opacity / 100'));
          expect(label.dy, closeTo(slider.center.dy, 1));
          expect(value.dy, closeTo(slider.center.dy, 1));
          expect(slider.right, greaterThan(value.dx));
          expect(slider.left, greaterThanOrEqualTo(0));
          expect(slider.right, lessThanOrEqualTo(width));
          expect(slider.width, greaterThan(48));
        }
      }
    }
  });

  testWidgets('narrow opacity slider keeps default reset and dragging', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => app.updateSettings({'glassOpacity': 0}));
    await pumpSettings(tester, app);
    await tapSettingAndWait(
      tester,
      app,
      find.byType(Slider),
      () => app.settings.glassOpacity == 55,
      position: tester.getCenter(
        find.byKey(const ValueKey('default-glass-opacity-marker')),
      ),
    );
    expect(find.text('55 / 100'), findsOneWidget);
    final slider = tester.getRect(find.byType(Slider));
    final drag = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('default-glass-opacity-marker')),
      ),
    );
    await drag.moveTo(Offset(slider.right - 24, slider.center.dy));
    await drag.up();
    await tester.pumpAndSettle();
    expect(app.settings.glassOpacity, greaterThan(55));
    await tester.runAsync(() async {
      expect(
        (await SettingsRepository(db).read()).glassOpacity,
        app.settings.glassOpacity,
      );
    });
    expect(tester.takeException(), isNull);
  });
}
