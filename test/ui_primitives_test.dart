import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/background/background_snapshot.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/ui_primitives.dart';

// REGRESSION CONTRACT: UI-GLASS-001

void main() {
  testWidgets('top-bar action glass follows the active backdrop mode', (
    tester,
  ) async {
    for (final mode in BackgroundMode.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: SiteLensBackdrop(
            background: BackgroundSnapshot(mode: mode),
            child: SiteLensPageScaffold(
              title: '操作页',
              actions: [
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
              body: const SizedBox(),
            ),
          ),
        ),
      );
      final context = tester.element(find.byType(SiteLensTopBarActionGroup));
      final colors = SiteLensColors.of(context);
      final plan = SiteLensGlassPolicyScope.of(context)
          .resolve(context, role: SiteLensSurfaceRole.chrome);
      expect(plan.glassColor, colors.glassSurface.withValues(alpha: 0.55));
      expect(
        find.descendant(
          of: find.byType(SiteLensTopBarActionGroup),
          matching: find.byType(SiteLensGlassSurface),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SiteLensTopBarActionGroup),
          matching: find.byType(DecoratedBox),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('top-bar action glass follows the selected theme seed', (
    tester,
  ) async {
    Future<Color> pumpPreset(ThemePresetId preset) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(preset, Brightness.light),
          home: SiteLensBackdrop(
            background: const BackgroundSnapshot(
              mode: BackgroundMode.defaultGradient,
            ),
            child: SiteLensPageScaffold(
              title: '操作页',
              actions: [
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
              body: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return SiteLensColors.of(
        tester.element(find.byType(SiteLensTopBarActionGroup)),
      ).glassSurface;
    }

    final ocean = await pumpPreset(ThemePresetId.oceanBlue);
    final coral = await pumpPreset(ThemePresetId.sunsetCoral);
    expect(coral, equals(ocean));
  });

  testWidgets('top-bar keeps one continuous glass capsule for all actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: SiteLensPageScaffold(
          title: '操作页',
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz)),
          ],
          body: const SizedBox(),
        ),
      ),
    );

    final group = find.byType(SiteLensTopBarActionGroup);
    expect(group, findsOneWidget);
    expect(
      find.descendant(of: group, matching: find.byType(SiteLensGlassSurface)),
      findsNothing,
    );
    expect(
      find.descendant(of: group, matching: find.byType(DecoratedBox)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: group, matching: find.byType(SiteLensGlassControl)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('high-quality menu uses the shared menu glass surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: SiteLensGlassPolicyScope(
          strategy: const SiteLensGlassQualityStrategy(
            mode: SiteLensGlassQualityMode.high,
            adaptiveQualityOverride: GlassQuality.premium,
            lightweightShaderSupported: true,
          ),
          child: Scaffold(
            body: SiteLensMenuSelector<int>(
              label: '菜单',
              value: 0,
              options: [
                const SiteLensMenuOption(value: 0, label: '当前'),
                const SiteLensMenuOption(value: 1, label: '下一项'),
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('菜单'));
    await tester.pump();
    final menuGlass = tester.widget<SiteLensGlassSurface>(
      find.descendant(
        of: find.byType(SiteLensMenuSelector<int>),
        matching: find.byType(SiteLensGlassSurface),
      ),
    );
    expect(menuGlass.role, SiteLensSurfaceRole.menu);
    expect(find.byType(SiteLensGlassControl), findsNothing);
    expect(find.byType(MenuItemButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlapping menus do not share the page backdrop capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.dark),
        home: SiteLensGlassPolicyScope(
          strategy: const SiteLensGlassQualityStrategy(
            mode: SiteLensGlassQualityMode.high,
            backgroundMode: BackgroundMode.transparent,
          ),
          child: GlassBackdropGroup(
            child: Scaffold(
              body: SiteLensPanel(
                child: SiteLensMenuSelector<int>(
                  label: '菜单',
                  value: 0,
                  options: const [
                    SiteLensMenuOption(value: 0, label: '当前'),
                    SiteLensMenuOption(value: 1, label: '第一项'),
                    SiteLensMenuOption(value: 2, label: '第二项'),
                  ],
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      GlassBackdropGroup.keyOf(tester.element(find.byType(SiteLensPanel))),
      isNotNull,
    );
    await tester.tap(find.byTooltip('菜单'));
    await tester.pumpAndSettle();
    final menu = find.byWidgetPredicate(
      (w) => w is SiteLensGlassSurface && w.role == SiteLensSurfaceRole.menu,
    );
    expect(menu, findsOneWidget);
    expect(GlassBackdropGroup.keyOf(tester.element(menu)), isNull);
    expect(find.byType(MenuItemButton), findsNWidgets(2));
  });

  testWidgets('glass command menu stays compact and uses one menu surface', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.dark),
        home: SiteLensGlassPolicyScope(
          strategy: const SiteLensGlassQualityStrategy(
            mode: SiteLensGlassQualityMode.high,
            adaptiveQualityOverride: GlassQuality.premium,
            lightweightShaderSupported: true,
          ),
          child: Scaffold(
            body: SiteLensGlassMenuButton<String>(
              tooltip: '操作',
              icon: Icons.more_horiz,
              actions: [
                const SiteLensGlassMenuAction(
                  value: 'close',
                  label: '全部关闭',
                  icon: Icons.close,
                ),
              ],
              onSelected: (_) => selected = true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('操作'));
    await tester.pump();

    final panel = find.byType(SiteLensGlassSurface);
    expect(panel, findsOneWidget);
    expect(
      tester.widget<SiteLensGlassSurface>(panel).role,
      SiteLensSurfaceRole.menu,
    );
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(ColoredBox), findsNothing);
    expect(tester.getSize(panel).height, lessThan(80));
    await tester.tap(find.text('全部关闭'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
  });

  testWidgets(
    'command menu releases history and popup hold on dismissal and removal',
    (tester) async {
      final observer = SiteLensRouteObserver();
      late StateSetter rebuild;
      var visible = true;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return visible
                    ? SiteLensGlassMenuButton<int>(
                        tooltip: '操作',
                        icon: Icons.more_horiz,
                        actions: const [
                          SiteLensGlassMenuAction(value: 1, label: '操作一'),
                        ],
                        onSelected: (_) {},
                      )
                    : const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final route = observer.topRoute! as ModalRoute<dynamic>;
      expect(observer.allowsBrowserDock, isTrue);
      for (final dismissal in ['outside', 'escape', 'remove']) {
        await tester.tap(find.byTooltip('操作'));
        await tester.pumpAndSettle();
        expect(route.willHandlePopInternally, isTrue);
        expect(observer.allowsBrowserDock, isFalse);
        switch (dismissal) {
          case 'outside':
            await tester.tapAt(const Offset(700, 500));
          case 'escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'remove':
            rebuild(() => visible = false);
        }
        await tester.pumpAndSettle();
        expect(route.willHandlePopInternally, isFalse);
        expect(observer.allowsBrowserDock, isTrue);
        expect(find.byType(MenuItemButton), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      observer.dispose();
    },
  );

  for (final density in [VisualDensity.standard, VisualDensity.compact]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('command menu labels fit one line at $density / $scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(
              ThemePresetId.oceanBlue,
              Brightness.light,
            ).copyWith(visualDensity: density),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topRight,
                  child: SiteLensGlassMenuButton<String>(
                    tooltip: '操作',
                    icon: Icons.more_horiz,
                    actions: const [
                      SiteLensGlassMenuAction(
                        value: 'close',
                        label: '全部关闭',
                        icon: Icons.close,
                      ),
                    ],
                    onSelected: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('操作'));
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text('全部关闭'),
            matching: find.byType(RichText),
          ),
        );
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 4),
        );
        expect(
          boxes,
          hasLength(1),
          reason: 'the complete label must fit one line',
        );
        final row = find.byType(MenuItemButton);
        expect(tester.getSize(row).height, lessThanOrEqualTo(60));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('long descriptions use a foldable detail row', (tester) async {
    const description = '这是一段超过紧凑行阈值的完整描述，不应被截断后丢失';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: SiteLensExpandableRow(
          title: const Text('长描述设置'),
          description: description,
        ),
      ),
    );

    expect(find.text(description), findsNothing);
    expect(find.text('查看详情'), findsOneWidget);
    await tester.tap(find.text('长描述设置'));
    await tester.pumpAndSettle();
    expect(find.text(description), findsOneWidget);
  });

  testWidgets('long tappable descriptions keep the row action', (tester) async {
    var tapped = false;
    const description = '这是一个超过紧凑行阈值的可点击行完整说明文字';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: SiteLensCompactRow(
          title: const Text('可点击行'),
          subtitle: const Text(description),
          onTap: () => tapped = true,
        ),
      ),
    );

    expect(find.text(description), findsNothing);
    expect(find.byType(SiteLensCompactIconButton), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(SiteLensCompactIconButton),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(description), findsOneWidget);
    await tester.tap(find.text('可点击行'));
    expect(tapped, isTrue);
  });

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

  testWidgets('long switch descriptions fold without truncation', (
    tester,
  ) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: SizedBox(
          width: 220,
          child: StatefulBuilder(
            builder: (context, setState) => SiteLensSwitchRow(
              title: '这是一个很长的设置标题应该收敛',
              subtitle: '这是一个超过紧凑行阈值的完整说明文字应该放入可折叠详情',
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SiteLensRowText), findsNWidgets(2));
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('这是一个超过紧凑行阈值的完整说明文字应该放入可折叠详情'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    final quietTheme = tester.widget<Theme>(
      find
          .descendant(
            of: find.byType(SiteLensFoldable),
            matching: find.byType(Theme),
          )
          .last,
    );
    expect(quietTheme.data.highlightColor, Colors.transparent);
  });

  testWidgets('compact rows use the quiet global interaction token', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Scaffold(
          body: SiteLensCompactRow(title: const Text('媒体任务'), onTap: () {}),
        ),
      ),
    );

    final row = tester.widget<ListTile>(find.byType(ListTile));
    final colors = SiteLensColors.of(tester.element(find.byType(ListTile)));
    expect(row.enableFeedback, isFalse);
    expect(row.focusColor, colors.rowInteractionOverlay);
    expect(row.hoverColor, colors.rowInteractionOverlay);
    expect(row.splashColor, colors.rowInteractionOverlay);
    final rowTheme = tester.widget<Theme>(
      find
          .ancestor(of: find.byType(ListTile), matching: find.byType(Theme))
          .first,
    );
    expect(rowTheme.data.splashFactory, NoSplash.splashFactory);
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
