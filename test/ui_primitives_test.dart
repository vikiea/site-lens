import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/ui_primitives.dart';

void main() {
  testWidgets('page shell shows titles and preserves back and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => SiteLensPageScaffold(
            title: '根页面',
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SiteLensPageScaffold(
                    title: '子页面',
                    body: Text('子页面内容'),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('根页面'), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: SiteLensPageScaffold(
          title: '操作页',
          actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.add))],
          body: const SizedBox(),
        ),
      ),
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets(
    'refresh action rotates until complete and honors reduced motion',
    (tester) async {
      Widget button({required bool refreshing, bool reducedMotion = false}) =>
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: SiteLensRefreshButton(
                tooltip: '刷新规则',
                refreshing: refreshing,
                onPressed: () {},
              ),
            ),
          );
      await tester.pumpWidget(button(refreshing: false));
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(button(refreshing: true));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('刷新规则，刷新中'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<RotationTransition>(find.byType(RotationTransition))
            .turns
            .value,
        greaterThan(0),
      );
      await tester.pumpWidget(button(refreshing: true, reducedMotion: true));
      expect(
        tester
            .widget<RotationTransition>(find.byType(RotationTransition))
            .turns
            .value,
        0,
      );
      await tester.pumpWidget(button(refreshing: false));
      await tester.pumpAndSettle();
      expect(find.byTooltip('刷新规则'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('bottom navigation keeps one shared chrome surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: const Scaffold(
          body: SiteLensNavigationSurface(
            child: SizedBox(width: 240, height: 60),
          ),
        ),
      ),
    );

    final surface = tester.widget<SiteLensGlassSurface>(
      find.byType(SiteLensGlassSurface),
    );
    expect(surface.role, SiteLensSurfaceRole.chrome);
    expect(
      find.byType(AdaptiveGlass).evaluate().isNotEmpty ||
          find.byType(ClipPath).evaluate().isNotEmpty,
      isTrue,
    );
  });

  testWidgets('accordion keeps one detail open per controller', (tester) async {
    final controller = SiteLensAccordionController();
    await tester.pumpWidget(
      MaterialApp(
        home: SiteLensPanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SiteLensAccordion(
                id: 'one',
                controller: controller,
                title: const Text('第一项'),
                details: (_) => const Text('第一项详情'),
              ),
              const Divider(height: 1),
              SiteLensAccordion(
                id: 'two',
                controller: controller,
                title: const Text('第二项'),
                details: (_) => const Text('第二项详情'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('第一项'));
    await tester.pumpAndSettle();
    expect(find.text('第一项详情'), findsOneWidget);
    expect(find.text('第二项详情'), findsNothing);
    await tester.tap(find.text('第二项'));
    await tester.pumpAndSettle();
    expect(find.text('第一项详情'), findsNothing);
    expect(find.text('第二项详情'), findsOneWidget);
  });

  testWidgets('glass alert dialog keeps Material dialog semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.dark),
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const SiteLensAlertDialog(
                title: Text('确认'),
                content: Text('测试内容'),
                actions: [TextButton(onPressed: null, child: Text('关闭'))],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(SiteLensGlassSurface), findsOneWidget);
    expect(find.text('测试内容'), findsOneWidget);
  });
}
