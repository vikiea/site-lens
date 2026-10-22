import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';

void main() {
  for (final scenario in ['tight', 'zero', 'keyboard']) {
    testWidgets('bounded glass handles $scenario constraints', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 640),
              viewInsets: scenario == 'keyboard'
                  ? const EdgeInsets.only(bottom: 640)
                  : EdgeInsets.zero,
            ),
            child: SiteLensGlassPolicyScope(
              strategy: const SiteLensGlassQualityStrategy(
                mode: SiteLensGlassQualityMode.high,
                allSurfacesHighQuality: true,
                shaderSupported: true,
              ),
              child: ListView(
                children: [
                  SizedBox(
                    height: scenario == 'zero' ? 0 : 1000,
                    child: const SiteLensPanel(
                      scrollingContent: true,
                      child: SizedBox(height: 3000),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final glass = find.byType(AdaptiveGlass);
      if (scenario == 'tight') {
        expect(glass, findsOneWidget);
        expect(tester.getSize(glass).height, lessThanOrEqualTo(448));
        expect(
          tester.widget<AdaptiveGlass>(glass).quality,
          GlassQuality.premium,
        );
      } else {
        expect(glass, findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final mode in SiteLensGlassQualityMode.values) {
    testWidgets('ordinary $mode panels have one page scroll owner', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SiteLensGlassPolicyScope(
            strategy: SiteLensGlassQualityStrategy(
              mode: mode,
              allSurfacesHighQuality: true,
              shaderSupported: true,
              adaptiveQualityOverride: GlassQuality.premium,
            ),
            child: Scaffold(
              body: ListView(
                children: [
                  for (var i = 0; i < 6; i++)
                    SiteLensPanel(
                      child: SizedBox(height: 180, child: Text('面板 $i')),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scrollable), findsOneWidget);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      await tester.drag(find.text('面板 0'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(200));
      await tester.scrollUntilVisible(
        find.text('面板 5'),
        250,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('面板 5').hitTestable(), findsOneWidget);
      await tester.drag(find.byType(Scrollable), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(position.pixels, lessThan(position.maxScrollExtent));
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'long premium panel stays viewport bounded in $brightness at scale $scale',
        (tester) async {
          tester.view.physicalSize = const Size(360, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(() => tester.view.reset());
          final content = GlobalKey();
          final panel = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildSiteLensTheme(ThemePresetId.sunsetCoral, brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(360, 640),
                  textScaler: TextScaler.linear(scale),
                ),
                child: SiteLensGlassPolicyScope(
                  strategy: const SiteLensGlassQualityStrategy(
                    mode: SiteLensGlassQualityMode.high,
                    allSurfacesHighQuality: true,
                    shaderSupported: true,
                  ),
                  child: Scaffold(
                    body: ListView(
                      children: [
                        SiteLensPanel(
                          key: panel,
                          scrollingContent: true,
                          child: Column(
                            key: content,
                            children: List.generate(
                              100,
                              (i) => ListTile(title: Text('长面板项目 $i · 中文说明')),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final glass = find.descendant(
            of: find.byKey(panel),
            matching: find.byType(AdaptiveGlass),
          );
          expect(
            tester.widget<AdaptiveGlass>(glass).quality,
            GlassQuality.premium,
          );
          expect(
            tester.getSize(glass).height,
            lessThanOrEqualTo(640 * 0.7 + 1),
          );
          expect(tester.getSize(find.byKey(content)).height, greaterThan(640));
          final inner = find
              .descendant(
                of: find.byKey(panel),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.scrollUntilVisible(
            find.text('长面板项目 99 · 中文说明'),
            500,
            scrollable: inner,
            maxScrolls: 100,
          );
          expect(find.text('长面板项目 99 · 中文说明').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('short premium panel keeps the available width', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SiteLensGlassPolicyScope(
          strategy: const SiteLensGlassQualityStrategy(
            mode: SiteLensGlassQualityMode.high,
            allSurfacesHighQuality: true,
            shaderSupported: true,
          ),
          child: Scaffold(
            body: ListView(
              children: const [
                SiteLensPanel(
                  key: ValueKey('short-panel'),
                  child: Icon(Icons.check),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('short-panel'));
    final glass = find.descendant(
      of: panel,
      matching: find.byType(AdaptiveGlass),
    );
    expect(tester.getSize(glass).width, 360);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
