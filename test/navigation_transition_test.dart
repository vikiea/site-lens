import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_theme.dart';

void main() {
  testWidgets('route transitions complete immediately without old content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: const Scaffold(body: Text('首页')),
      ),
    );
    await tester.pump();

    final navigator = Navigator.of(tester.element(find.text('首页')));
    final pushed = navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('详情'))),
    );
    await tester.pump();

    expect(find.text('详情'), findsOneWidget);
    expect(find.text('首页'), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);

    navigator.pop();
    await tester.pump();
    await pushed;
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('详情'), findsNothing);
  });

  test('route transition durations are zero', () {
    const builder = SiteLensNoAnimationPageTransitionsBuilder();

    expect(builder.transitionDuration, Duration.zero);
    expect(builder.reverseTransitionDuration, Duration.zero);
  });

  testWidgets('first-level destination switch replaces the keyed body', (
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
            return KeyedSubtree(key: ValueKey(page), child: Text('页面$page'));
          },
        ),
      ),
    );
    await tester.pump();

    rebuild(() => page = 1);
    await tester.pump();

    expect(find.text('页面1'), findsOneWidget);
    expect(find.text('页面0'), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);
  });
}
