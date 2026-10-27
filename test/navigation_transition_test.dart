import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/ui_primitives.dart';

void main() {
  testWidgets('route transition uses slide motion without fade', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: const Scaffold(body: Text('首页')),
      ),
    );
    await tester.pump();

    Navigator.of(tester.element(find.text('首页'))).push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('详情'))),
    );
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(SlideTransition), findsAtLeastNWidgets(1));
    expect(find.byType(SiteLensTransitionScrim), findsOneWidget);
    expect(find.byType(FadeTransition), findsNothing);
  });

  testWidgets('first-level destination switch uses slide motion', (
    tester,
  ) async {
    var page = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SiteLensPageSwitcher(
              direction: 1,
              child: KeyedSubtree(key: ValueKey(page), child: Text('页面$page')),
            );
          },
        ),
      ),
    );
    await tester.pump();
    rebuild(() => page = 1);
    await tester.pump(const Duration(milliseconds: 80));

    expect(
      find.descendant(
        of: find.byType(SiteLensPageSwitcher),
        matching: find.byType(SlideTransition),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SiteLensPageSwitcher),
        matching: find.byType(SiteLensTransitionScrim),
      ),
      findsOneWidget,
    );
    expect(find.byType(FadeTransition), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('页面1'), findsOneWidget);
  });
}
