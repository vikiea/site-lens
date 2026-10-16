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
  testWidgets('role and mode policy keeps panels at standard', (tester) async {
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
        shaderSupported: true,
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
      expect(panel.quality, GlassQuality.standard);
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
      shaderSupported: true,
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
      shaderSupported: true,
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
        shaderSupported: true,
      );
      expect(
        strategy.resolve(context, role: SiteLensSurfaceRole.chrome).quality,
        GlassQuality.premium,
      );
    },
  );

  testWidgets('high quality panels share the premium optical treatment', (
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
        shaderSupported: true,
      ).resolve(context, role: SiteLensSurfaceRole.panel);
      final highPanel = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        allSurfacesHighQuality: true,
        shaderSupported: true,
      ).resolve(context, role: SiteLensSurfaceRole.panel);
      final highChrome = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        shaderSupported: true,
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
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });

  testWidgets('high Android chrome keeps premium optical parameters', (
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
        shaderSupported: true,
      ).resolve(context, role: SiteLensSurfaceRole.chrome);
      final high = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        shaderSupported: true,
      ).resolve(context, role: SiteLensSurfaceRole.chrome);

      expect(high.quality, GlassQuality.premium);
      expect(high.settings.thickness, greaterThan(standard.settings.thickness));
      expect(high.settings.rimLight, greaterThan(standard.settings.rimLight));
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });

  testWidgets('unsupported Android shader uses the compatibility plan', (
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
      final plan = const SiteLensGlassQualityStrategy(shaderSupported: false)
          .resolve(context, role: SiteLensSurfaceRole.panel);
      final highPanel = const SiteLensGlassQualityStrategy(
        mode: SiteLensGlassQualityMode.high,
        allSurfacesHighQuality: true,
        shaderSupported: false,
      ).resolve(context, role: SiteLensSurfaceRole.panel);
      final chrome = const SiteLensGlassQualityStrategy(shaderSupported: false)
          .resolve(context, role: SiteLensSurfaceRole.chrome);
      expect(plan.quality, GlassQuality.standard);
      expect(plan.useCompatibilityFallback, isTrue);
      expect(highPanel.quality, GlassQuality.premium);
      expect(highPanel.useCompatibilityFallback, isFalse);
      expect(chrome.useCompatibilityFallback, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  });

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
