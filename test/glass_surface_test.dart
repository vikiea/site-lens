import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/background/background_snapshot.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';

Widget _backdropApp(
  BackgroundSnapshot background, {
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: buildSiteLensTheme(ThemePresetId.oceanBlue, brightness),
  home: SiteLensBackdrop(
    background: background,
    child: const SizedBox.expand(),
  ),
);

List<Color> _linearGradientColors(WidgetTester tester) {
  final boxes = tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .map((box) => box.decoration)
      .whereType<BoxDecoration>()
      .map((decoration) => decoration.gradient)
      .whereType<LinearGradient>();
  return boxes.first.colors;
}

void main() {
  testWidgets('background modes select different static sources', (
    tester,
  ) async {
    await tester.pumpWidget(
      _backdropApp(
        const BackgroundSnapshot(mode: BackgroundMode.defaultGradient),
      ),
    );
    final defaultColors = _linearGradientColors(tester);

    await tester.pumpWidget(
      _backdropApp(const BackgroundSnapshot(mode: BackgroundMode.themeBuiltIn)),
    );
    final themeColors = _linearGradientColors(tester);
    expect(themeColors, isNot(equals(defaultColors)));

    await tester.pumpWidget(
      _backdropApp(const BackgroundSnapshot(mode: BackgroundMode.transparent)),
    );
    expect(
      tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).gradient is LinearGradient,
          ),
      isEmpty,
    );
    expect(find.byType(Image), findsNothing);
    final backdropContext = tester.element(find.byType(SiteLensBackdrop));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox &&
            widget.color == SiteLensColors.of(backdropContext).backdropTop,
      ),
      findsOneWidget,
    );
  });

  testWidgets('dark transparent mode leaves the app-owned backdrop empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      _backdropApp(
        const BackgroundSnapshot(mode: BackgroundMode.transparent),
        brightness: Brightness.dark,
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(
      tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).gradient != null,
          ),
      isEmpty,
    );
    expect(find.byType(ColoredBox), findsNothing);
  });

  testWidgets('transparent mode ignores a previously uploaded image', (
    tester,
  ) async {
    await tester.pumpWidget(
      _backdropApp(
        const BackgroundSnapshot(
          mode: BackgroundMode.transparent,
          imagePath: '/site-lens/background.png',
        ),
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.byType(ColoredBox), findsOneWidget);
    expect(
      tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).gradient != null,
          ),
      isEmpty,
    );
  });

  testWidgets('custom image mode keeps the image above the default mask', (
    tester,
  ) async {
    await tester.pumpWidget(
      _backdropApp(
        const BackgroundSnapshot(
          mode: BackgroundMode.customImage,
          imagePath: '/site-lens/background.png',
        ),
      ),
    );

    expect(
      tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).gradient is RadialGradient,
          ),
      isEmpty,
    );
  });
}
