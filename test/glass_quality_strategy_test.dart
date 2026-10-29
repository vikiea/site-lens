import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_quality_cache.dart';
import 'package:site_lens/ui/glass_quality_strategy.dart';

void main() {
  // REGRESSION CONTRACT: UI-GLASS-001
  testWidgets('HCPP restores Flutter glass while native overlays stay fenced', (
    tester,
  ) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      for (final brightness in Brightness.values) {
        for (final opacity in [0, 55, 100]) {
          late BuildContext context;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildSiteLensTheme(
                ThemePresetId.sunsetCoral,
                brightness,
                glassOpacity: opacity,
              ),
              themeAnimationDuration: Duration.zero,
              themeAnimationCurve: Curves.linear,
              home: Builder(
                builder: (value) {
                  context = value;
                  return const SizedBox();
                },
              ),
            ),
          );
          await tester.pump();
          for (final enabled in [false, true]) {
            final strategy = SiteLensGlassQualityStrategy(
              mode: SiteLensGlassQualityMode.high,
              allSurfacesHighQuality: true,
              webViewVisible: true,
              hcppEffective: enabled,
              lightweightShaderSupported: true,
            );
            for (final role in [
              SiteLensSurfaceRole.panel,
              SiteLensSurfaceRole.chrome,
            ]) {
              final plan = strategy.resolve(context, role: role);
              expect(plan.useCompatibilityFallback, isFalse);
              expect(plan.quality, GlassQuality.premium);
            }
            final overlay = strategy.resolve(
              context,
              role: SiteLensSurfaceRole.platformView,
            );
            expect(overlay.quality, GlassQuality.standard);
            expect(overlay.useCompatibilityFallback, true);
            expect(overlay.platformViewBackdrop, false);
            final panel = strategy.resolve(
              context,
              role: SiteLensSurfaceRole.panel,
            );
            expect(panel.glassColor.a, closeTo(opacity / 100, 0.005));
          }
        }
      }
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });
  testWidgets('role and mode policy applies premium to Flutter panels', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    for (final mode in SiteLensGlassQualityMode.values) {
      final strategy = SiteLensGlassQualityStrategy(
        mode: mode,
        adaptiveQualityOverride: GlassQuality.premium,
        lightweightShaderSupported: true,
      );
      final panel = strategy.resolve(context, role: SiteLensSurfaceRole.panel);
      final chrome = strategy.resolve(
        context,
        role: SiteLensSurfaceRole.chrome,
      );
      final platformView = strategy.resolve(
        context,
        role: SiteLensSurfaceRole.platformView,
      );
      expect(
        panel.quality,
        mode == SiteLensGlassQualityMode.high
            ? GlassQuality.premium
            : GlassQuality.standard,
      );
      expect(platformView.quality, GlassQuality.standard);
      expect(platformView.platformViewBackdrop, isTrue);
      expect(
        chrome.quality,
        mode == SiteLensGlassQualityMode.standard
            ? GlassQuality.standard
            : GlassQuality.premium,
      );
    }
  });

  testWidgets(
    'transparent backdrop keeps glass rendering for Flutter surfaces',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.dark),
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );

      const strategy = SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        allSurfacesHighQuality: true,
        backgroundMode: BackgroundMode.transparent,
        lightweightShaderSupported: true,
      );
      for (final role in SiteLensSurfaceRole.values) {
        expect(
          strategy.resolve(context, role: role).useCompatibilityFallback,
          isFalse,
        );
      }
    },
  );

  testWidgets('menu glass protects controls beneath its transparent surface', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    for (final mode in BackgroundMode.values) {
      final strategy = SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        backgroundMode: mode,
        lightweightShaderSupported: true,
      );
      final menu = strategy.resolve(context, role: SiteLensSurfaceRole.menu);
      final chrome = strategy.resolve(
        context,
        role: SiteLensSurfaceRole.chrome,
      );
      expect(menu.settings.effectiveBackerColor, isNotNull);
      expect(
        menu.settings.effectiveBackerColor!.a,
        closeTo(SiteLensGlassTokens.menuBackdropProtectionAlpha, 0.001),
      );
      expect(chrome.settings.effectiveBackerColor, isNull);
    }
  });

  testWidgets('automatic follows adaptive quality for eligible chrome', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    final strategy = SiteLensGlassQualityStrategy(
      adaptiveQualityOverride: GlassQuality.standard,
      lightweightShaderSupported: true,
    );
    expect(
      strategy.resolve(context, role: SiteLensSurfaceRole.chrome).quality,
      GlassQuality.standard,
    );
  });

  testWidgets('high mode can apply premium to content panels', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    const strategy = SiteLensGlassQualityStrategy(
      mode: SiteLensGlassQualityMode.high,
      allSurfacesHighQuality: true,
      adaptiveQualityOverride: GlassQuality.premium,
      lightweightShaderSupported: true,
    );
    expect(
      strategy.resolve(context, role: SiteLensSurfaceRole.panel).quality,
      GlassQuality.premium,
    );
    expect(
      strategy.resolve(context, role: SiteLensSurfaceRole.platformView).quality,
      GlassQuality.standard,
    );
  });

  testWidgets('automatic panel coverage follows adaptive quality and safety', (
    tester,
  ) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      for (final quality in GlassQuality.values) {
        for (final coverage in [false, true]) {
          final strategy = SiteLensGlassQualityStrategy(
            allSurfacesHighQuality: coverage,
            adaptiveQualityOverride: quality,
            lightweightShaderSupported: true,
          );
          expect(
            strategy.resolve(context, role: SiteLensSurfaceRole.panel).quality,
            coverage && quality == GlassQuality.premium
                ? GlassQuality.premium
                : GlassQuality.standard,
          );
          final browsing = SiteLensGlassQualityStrategy(
            allSurfacesHighQuality: coverage,
            adaptiveQualityOverride: quality,
            webViewVisible: true,
            lightweightShaderSupported: true,
          );
          final panel = browsing.resolve(
            context,
            role: SiteLensSurfaceRole.panel,
          );
          final chrome = browsing.resolve(
            context,
            role: SiteLensSurfaceRole.chrome,
          );
          final platformView = browsing.resolve(
            context,
            role: SiteLensSurfaceRole.platformView,
          );
          expect(
            panel.quality,
            coverage && quality == GlassQuality.premium
                ? GlassQuality.premium
                : GlassQuality.standard,
          );
          expect(
            chrome.quality,
            quality == GlassQuality.premium
                ? GlassQuality.premium
                : GlassQuality.standard,
          );
          expect(panel.useCompatibilityFallback, isFalse);
          expect(chrome.useCompatibilityFallback, isFalse);
          expect(platformView.quality, GlassQuality.standard);
          expect(platformView.useCompatibilityFallback, isTrue);
        }
      }
      const standard = SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.standard,
        allSurfacesHighQuality: true,
        adaptiveQualityOverride: GlassQuality.premium,
      );
      expect(
        standard.resolve(context, role: SiteLensSurfaceRole.panel).quality,
        GlassQuality.standard,
      );
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });

  testWidgets(
    'high mode requests premium even when adaptive quality is standard',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      final strategy = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        adaptiveQualityOverride: GlassQuality.standard,
        lightweightShaderSupported: true,
      );
      expect(
        strategy.resolve(context, role: SiteLensSurfaceRole.chrome).quality,
        GlassQuality.premium,
      );
    },
  );

  testWidgets(
    'high quality Android panels keep premium parameters outside WebView',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(
              ThemePresetId.oceanBlue,
              Brightness.light,
            ),
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        );
        final standard = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.standard,
          lightweightShaderSupported: true,
        ).resolve(context, role: SiteLensSurfaceRole.panel);
        final highPanel = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          lightweightShaderSupported: true,
        ).resolve(context, role: SiteLensSurfaceRole.panel);
        final highChrome = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          lightweightShaderSupported: true,
        ).resolve(context, role: SiteLensSurfaceRole.chrome);

        expect(highPanel.quality, GlassQuality.premium);
        expect(highPanel.settings.thickness, highChrome.settings.thickness);
        expect(highPanel.settings.rimLight, highChrome.settings.rimLight);
        expect(
          highPanel.settings.thickness,
          greaterThan(standard.settings.thickness),
        );
        expect(
          highPanel.settings.rimLight,
          greaterThan(standard.settings.rimLight),
        );

        const browsing = SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          webViewVisible: true,
          lightweightShaderSupported: true,
        );
        final browsingPanel = browsing.resolve(
          context,
          role: SiteLensSurfaceRole.panel,
        );
        expect(browsingPanel.quality, GlassQuality.premium);
        expect(
          browsingPanel.settings.thickness,
          greaterThan(standard.settings.thickness),
        );
        expect(
          browsingPanel.settings.rimLight,
          greaterThan(standard.settings.rimLight),
        );
        expect(browsingPanel.useCompatibilityFallback, isFalse);
        expect(browsingPanel.settings.blur, greaterThan(0));
        expect(browsingPanel.settings.frost, greaterThan(0));
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    },
  );

  testWidgets('high Android chrome keeps premium parameters outside WebView', (
    tester,
  ) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      final standard = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.standard,
        lightweightShaderSupported: true,
      ).resolve(context, role: SiteLensSurfaceRole.chrome);
      final high = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        lightweightShaderSupported: true,
      ).resolve(context, role: SiteLensSurfaceRole.chrome);

      expect(high.quality, GlassQuality.premium);
      expect(high.settings.thickness, greaterThan(standard.settings.thickness));
      expect(high.settings.rimLight, greaterThan(standard.settings.rimLight));

      const browsing = SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        webViewVisible: true,
        lightweightShaderSupported: true,
      );
      final browsingChrome = browsing.resolve(
        context,
        role: SiteLensSurfaceRole.chrome,
      );
      expect(browsingChrome.quality, GlassQuality.premium);
      expect(
        browsingChrome.settings.thickness,
        greaterThan(standard.settings.thickness),
      );
      expect(
        browsingChrome.settings.rimLight,
        greaterThan(standard.settings.rimLight),
      );
      expect(browsingChrome.useCompatibilityFallback, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });

  testWidgets(
    'Android WebView overlays avoid live backdrop sampling while Flutter stays premium',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(
              ThemePresetId.oceanBlue,
              Brightness.light,
            ),
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        );

        const browsing = SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          webViewVisible: true,
          lightweightShaderSupported: true,
        );
        final overlay = browsing.resolve(
          context,
          role: SiteLensSurfaceRole.platformView,
        );
        final panel = browsing.resolve(
          context,
          role: SiteLensSurfaceRole.panel,
        );
        final ordinaryChrome = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          lightweightShaderSupported: true,
        ).resolve(context, role: SiteLensSurfaceRole.chrome);
        final idlePlatformView = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          lightweightShaderSupported: true,
        ).resolve(context, role: SiteLensSurfaceRole.platformView);

        expect(overlay.platformViewBackdrop, isFalse);
        expect(overlay.useCompatibilityFallback, isTrue);
        expect(panel.quality, GlassQuality.premium);
        expect(panel.useCompatibilityFallback, isFalse);
        expect(ordinaryChrome.quality, GlassQuality.premium);
        expect(ordinaryChrome.platformViewBackdrop, isFalse);
        expect(ordinaryChrome.useCompatibilityFallback, isFalse);
        expect(idlePlatformView.platformViewBackdrop, isTrue);
        expect(idlePlatformView.useCompatibilityFallback, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    },
  );

  testWidgets(
    'Android WebView safety covers panels and chrome while preserving idle quality',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(
              ThemePresetId.oceanBlue,
              Brightness.light,
            ),
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        );
        const browsing = SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          webViewVisible: true,
          lightweightShaderSupported: true,
        );
        final panel = browsing.resolve(
          context,
          role: SiteLensSurfaceRole.panel,
        );
        final chrome = browsing.resolve(
          context,
          role: SiteLensSurfaceRole.chrome,
        );
        final platformView = browsing.resolve(
          context,
          role: SiteLensSurfaceRole.platformView,
        );
        expect(panel.useCompatibilityFallback, isFalse);
        expect(chrome.useCompatibilityFallback, isFalse);
        expect(platformView.useCompatibilityFallback, isTrue);
        expect(panel.platformViewBackdrop, isFalse);
        expect(chrome.platformViewBackdrop, isFalse);
        expect(platformView.platformViewBackdrop, isFalse);
        const idle = SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          lightweightShaderSupported: true,
        );
        expect(
          idle.resolve(context, role: SiteLensSurfaceRole.panel).quality,
          GlassQuality.premium,
        );
        expect(
          idle
              .resolve(context, role: SiteLensSurfaceRole.panel)
              .useCompatibilityFallback,
          isFalse,
        );
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    },
  );

  testWidgets(
    'unknown Skia shader capability keeps Flutter glass on AdaptiveGlass',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(
              ThemePresetId.oceanBlue,
              Brightness.light,
            ),
            home: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        );
        final plan = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          webViewVisible: true,
        ).resolve(context, role: SiteLensSurfaceRole.panel);
        expect(plan.quality, GlassQuality.premium);
        expect(plan.useCompatibilityFallback, isFalse);

        final unsupported = const SiteLensGlassQualityStrategy(
          lightweightShaderSupported: false,
        ).resolve(context, role: SiteLensSurfaceRole.panel);
        final highPanel = const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.high,
          allSurfacesHighQuality: true,
          lightweightShaderSupported: false,
        ).resolve(context, role: SiteLensSurfaceRole.panel);
        final chrome = const SiteLensGlassQualityStrategy(
          lightweightShaderSupported: false,
        ).resolve(context, role: SiteLensSurfaceRole.chrome);
        expect(unsupported.quality, GlassQuality.standard);
        expect(unsupported.useCompatibilityFallback, isTrue);
        expect(highPanel.quality, GlassQuality.premium);
        expect(highPanel.useCompatibilityFallback, isTrue);
        expect(chrome.useCompatibilityFallback, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    },
  );

  test(
    'quality cache persists and validates its renderer fingerprint',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = SiteLensGlassQualityCacheRepository(db);
      const cache = SiteLensGlassQualityCache(
        quality: GlassQuality.premium,
        p75Ms: 12.5,
        p95Ms: 14.2,
        fingerprint: 'site-lens-glass-v1|app=1.0|platform=android|shader=true',
      );

      await repository.write(cache);
      final restored = await repository.read();
      expect(restored?.quality, GlassQuality.premium);
      expect(restored?.p75Ms, 12.5);
      expect(restored?.p95Ms, 14.2);
      expect(restored?.matches(cache.fingerprint), isTrue);
      expect(restored?.matches('different'), isFalse);
      final fingerprint = SiteLensGlassFingerprint.current(appVersion: '1.0.0');
      expect(fingerprint, contains('|runtime='));
      expect(fingerprint, contains('|renderer='));

      await repository.clear();
      expect(await repository.read(), isNull);
    },
  );
}
