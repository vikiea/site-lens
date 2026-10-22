import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform,
        TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/screens.dart';

import 'fake_web_host_api.dart';

class _ThemeApp extends AppController {
  _ThemeApp(super.db) : super(api: FakeWebHostApi());
  @override
  Future<void> initialize() => load();
}

void main() {
  test('system bar icon polarity follows the app brightness', () {
    final light = siteLensSystemUiOverlayStyle(Brightness.light);
    final dark = siteLensSystemUiOverlayStyle(Brightness.dark);

    expect(light.statusBarIconBrightness, Brightness.dark);
    expect(light.systemNavigationBarIconBrightness, Brightness.dark);
    expect(light.statusBarBrightness, Brightness.light);
    expect(dark.statusBarIconBrightness, Brightness.light);
    expect(dark.systemNavigationBarIconBrightness, Brightness.light);
    expect(dark.statusBarBrightness, Brightness.dark);
  });

  testWidgets('glass opacity controls Flutter glass surfaces', (tester) async {
    final theme = buildSiteLensTheme(
      ThemePresetId.oceanBlue,
      Brightness.light,
      glassOpacity: 22,
    );
    await tester.pumpWidget(MaterialApp(theme: theme, home: const SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    final panel = siteLensGlassSettings(context);
    final chrome = siteLensGlassSettings(
      context,
      role: SiteLensSurfaceRole.chrome,
    );
    expect(panel.visibility, closeTo(1, 0.001));
    expect(panel.bodyMode, GlassBodyMode.clear);
    expect(panel.glassColor.a, closeTo(0.22, 0.001));
    final expectedLightBase = SiteLensColors.of(context).glassSurface;
    expect(panel.glassColor.r, closeTo(expectedLightBase.r, 0.001));
    expect(panel.glassColor.g, closeTo(expectedLightBase.g, 0.001));
    expect(panel.glassColor.b, closeTo(expectedLightBase.b, 0.001));
    final lowAlphaProgress = (0.22 / 0.55).clamp(0.0, 1.0);
    final frostFactor =
        0.15 + 0.85 * Curves.easeOut.transform(lowAlphaProgress);
    expect(panel.blur, greaterThan(0));
    expect(panel.frost, greaterThan(0));
    expect(panel.frostOpacity, closeTo(0.73 * frostFactor, 0.001));
    if (defaultTargetPlatform == TargetPlatform.android) {
      expect(panel.refractiveIndex, closeTo(1.08, 0.001));
      expect(panel.shadow, isEmpty);
    }
    expect(chrome.visibility, closeTo(1, 0.001));
    expect(chrome.bodyMode, GlassBodyMode.clear);
    expect(chrome.glassColor.a, closeTo(0.22, 0.001));

    final defaultTheme = buildSiteLensTheme(
      ThemePresetId.oceanBlue,
      Brightness.light,
      glassOpacity: 45,
    );
    await tester.pumpWidget(
      MaterialApp(theme: defaultTheme, home: const SizedBox()),
    );
    final defaultContext = tester.element(find.byType(SizedBox));
    final defaultPanel = siteLensGlassSettings(defaultContext);
    final fullTheme = buildSiteLensTheme(
      ThemePresetId.oceanBlue,
      Brightness.light,
      glassOpacity: 100,
    );
    await tester.pumpWidget(
      MaterialApp(theme: fullTheme, home: const SizedBox()),
    );
    final fullContext = tester.element(find.byType(SizedBox));
    final fullPanel = siteLensGlassSettings(fullContext);
    expect(fullPanel.frostOpacity, closeTo(defaultPanel.frostOpacity, 0.001));
    expect(fullPanel.blur, greaterThan(0));
    expect(fullPanel.frost, greaterThan(0));
  });

  testWidgets('glass opacity remains exact on Android surfaces', (
    tester,
  ) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      Future<void> pumpOpacity(int opacity) => tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(
            ThemePresetId.oceanBlue,
            Brightness.light,
            glassOpacity: opacity,
          ),
          home: Builder(
            builder: (_) => SizedBox(key: ValueKey<String>('opacity-$opacity')),
          ),
        ),
      );

      await pumpOpacity(100);
      await tester.pumpAndSettle();
      final fullContext = tester.element(
        find.byKey(const ValueKey<String>('opacity-100')),
      );
      final fullPanel = siteLensGlassSettings(fullContext);
      expect(fullPanel.glassColor.a, closeTo(1.0, 0.001));

      await pumpOpacity(0);
      await tester.pumpAndSettle();
      final clearContext = tester.element(
        find.byKey(const ValueKey<String>('opacity-0')),
      );
      final clearPanel = siteLensGlassSettings(clearContext);
      expect(clearPanel.glassColor.a, closeTo(0.0, 0.001));
      final clearChrome = siteLensGlassSettings(
        clearContext,
        role: SiteLensSurfaceRole.chrome,
      );
      expect(clearChrome.glassColor.a, closeTo(0.16, 0.001));
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });

  test('theme AppBar carries the matching system overlay style', () {
    final light = buildSiteLensTheme(
      ThemePresetId.oceanBlue,
      Brightness.light,
    ).appBarTheme.systemOverlayStyle;
    final dark = buildSiteLensTheme(
      ThemePresetId.oceanBlue,
      Brightness.dark,
    ).appBarTheme.systemOverlayStyle;

    expect(light?.statusBarIconBrightness, Brightness.dark);
    expect(dark?.statusBarIconBrightness, Brightness.light);
  });

  testWidgets(
    'persisted and live themes drive MaterialApp without replacing the shell',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ThemeApp(db);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      await app.updateSettings({
        'themeMode': 'dark',
        'themePreset': 'iris_violet',
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWithValue(app)],
          child: const SiteLensApp(),
        ),
      );
      await tester.pumpAndSettle();
      var material = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(material.scrollBehavior, isA<SiteLensScrollBehavior>());
      expect(material.themeMode, ThemeMode.dark);
      expect(
        material.darkTheme!.colorScheme.primary,
        buildSiteLensTheme(
          ThemePresetId.irisViolet,
          Brightness.dark,
        ).colorScheme.primary,
      );
      expect(find.byType(SiteLensBottomNavigation), findsOneWidget);
      final navigation = find.byType(SiteLensBottomNavigation);
      expect(
        find.descendant(of: navigation, matching: find.byType(Badge)),
        findsNothing,
        reason: 'the bottom navigation stays compact without a badge',
      );
      expect(
        find.descendant(of: navigation, matching: find.text('站点')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: navigation, matching: find.text('浏览')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: navigation, matching: find.text('媒体')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: navigation, matching: find.text('设置')),
        findsOneWidget,
      );
      expect(tester.getSize(navigation).height, 60);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await app.setThemeModePreference(ThemeModePreference.light);
      await app.setThemePreset(ThemePresetId.mistPine);
      await tester.pumpAndSettle();
      material = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(material.themeMode, ThemeMode.light);
      expect(
        material.theme!.colorScheme.primary,
        buildSiteLensTheme(
          ThemePresetId.mistPine,
          Brightness.light,
        ).colorScheme.primary,
      );
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('主题色'), findsOneWidget);
      expect(find.text('玻璃质量'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
      await tester.runAsync(app.shutdown);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
