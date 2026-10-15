import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/ui_primitives.dart';

void main() {
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
    expect(find.byType(AdaptiveGlass), findsOneWidget);
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
