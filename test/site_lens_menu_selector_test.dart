import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/ui_primitives.dart';

const _options = [
  SiteLensMenuOption(value: 0, label: '亮度 / 音量'),
  SiteLensMenuOption(value: 1, label: '上一集 / 下一集'),
  SiteLensMenuOption(value: 2, label: '不可用操作', enabled: false),
];

Finder get _trigger => find.descendant(
  of: find.byTooltip('选择上下滑动操作'),
  matching: find.byType(TextButton),
);

Finder _item(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(MenuItemButton));

Material _buttonMaterial(WidgetTester tester, Finder button) =>
    tester.widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first,
    );

Widget _harness({
  ThemeData? theme,
  ValueChanged<int>? onSelected,
  List<SiteLensMenuOption<int>> options = _options,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
  double? width,
}) => MaterialApp(
  theme: theme ?? buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: Scaffold(
    body: Align(
      alignment: AlignmentDirectional.topStart,
      child: SizedBox(
        width: width,
        child: SiteLensMenuSelector<int>(
          label: '选择上下滑动操作',
          value: 0,
          options: options,
          onSelected: onSelected,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('disabling an open menu closes it without selecting', (
    tester,
  ) async {
    var enabled = true;
    int? selection;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Align(
                alignment: Alignment.topLeft,
                child: SiteLensMenuSelector<int>(
                  label: '选择上下滑动操作',
                  value: 0,
                  options: _options,
                  onSelected: enabled ? (value) => selection = value : null,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(_trigger);
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    rebuild(() => enabled = false);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(selection, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one tap opens immediately and selection closes the menu', (
    tester,
  ) async {
    int? selection;
    await tester.pumpWidget(_harness(onSelected: (value) => selection = value));
    expect(find.byType(MenuItemButton), findsNothing);
    expect(find.byType(InputDecorator), findsNothing);

    await tester.tap(_trigger);
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    for (final item in find.byType(MenuItemButton).evaluate()) {
      expect(
        tester.getSize(find.byWidget(item.widget)).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
    }
    await tester.tap(_item('上一集 / 下一集'));
    await tester.pump();
    expect(selection, 1);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'width follows the longest label and stays stable after selection',
    (tester) async {
      var value = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return SiteLensMenuSelector<int>(
                    label: '选择上下滑动操作',
                    value: value,
                    options: _options,
                    onSelected: (next) => rebuild(() => value = next),
                  );
                },
              ),
            ),
          ),
        ),
      );
      final context = tester.element(_trigger);
      final painter = TextPainter(
        text: TextSpan(
          text: '上一集 / 下一集',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final before = tester.getSize(_trigger);
      expect(before.width, greaterThan(painter.width));
      expect(before.width - painter.width, lessThan(60));
      expect(before.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      painter.dispose();

      await tester.tap(_trigger);
      await tester.pump();
      final menuWidth = tester.getSize(_item('上一集 / 下一集')).width;
      expect(menuWidth, closeTo(before.width, 1));
      await tester.tap(_item('上一集 / 下一集'));
      await tester.pumpAndSettle();
      expect(value, 1);
      expect(tester.getSize(_trigger).width, before.width);
      expect(find.text('上一集 / 下一集'), findsOneWidget);
    },
  );

  testWidgets(
    'keyboard keeps visible outlines, traversal, selection and escape',
    (tester) async {
      int? selection;
      final theme = buildSiteLensTheme(ThemePresetId.mistPine, Brightness.dark);
      await tester.pumpWidget(
        _harness(theme: theme, onSelected: (value) => selection = value),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final trigger = tester.widget<TextButton>(_trigger);
      expect(trigger.focusNode!.hasFocus, isTrue);
      expect(
        (_buttonMaterial(tester, _trigger).shape! as OutlinedBorder).side.color,
        theme.colorScheme.primary,
      );
      expect(
        trigger.style!.side!.resolve({WidgetState.focused})!.color,
        theme.colorScheme.primary,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        (_buttonMaterial(tester, _item('亮度 / 音量')).shape! as OutlinedBorder)
            .side
            .color,
        theme.colorScheme.primary,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selection, 1);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(trigger.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(trigger.focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled trigger and options cannot activate', (tester) async {
    await tester.pumpWidget(_harness());
    expect(tester.widget<TextButton>(_trigger).onPressed, isNull);
    await tester.tap(_trigger);
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(tester.widget<TextButton>(_trigger).focusNode!.hasFocus, isFalse);

    int? selection;
    await tester.pumpWidget(_harness(onSelected: (value) => selection = value));
    await tester.tap(_trigger);
    await tester.pump();
    expect(tester.widget<MenuItemButton>(_item('不可用操作')).onPressed, isNull);
    await tester.tap(_item('不可用操作'));
    await tester.pump();
    expect(selection, isNull);
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(find.byType(MenuItemButton), findsNothing);

    await tester.pumpWidget(
      _harness(
        options: const [
          SiteLensMenuOption(value: 0, label: '不可用', enabled: false),
        ],
        onSelected: (value) => selection = value,
      ),
    );
    expect(tester.widget<TextButton>(_trigger).onPressed, isNull);
  });

  testWidgets(
    'semantics preserve label, full value, selection and disabled state',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_harness(onSelected: (_) {}));
        expect(
          tester.getSemantics(_trigger),
          isSemantics(
            label: '选择上下滑动操作',
            value: '亮度 / 音量',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
            hasExpandedState: true,
            isExpanded: false,
          ),
        );
        await tester.tap(_trigger);
        await tester.pump();
        expect(tester.getSemantics(_trigger), isSemantics(isExpanded: true));
        expect(
          tester.getSemantics(_item('亮度 / 音量')),
          isSemantics(label: '亮度 / 音量', isSelected: true),
        );
        expect(
          tester.getSemantics(_item('不可用操作')),
          isSemantics(label: '不可用操作', hasEnabledState: true, isEnabled: false),
        );
        await tester.pumpWidget(_harness());
        expect(
          tester.getSemantics(_trigger),
          isSemantics(
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final brightness in Brightness.values) {
    for (final preset in [ThemePresetId.oceanBlue, ThemePresetId.mistPine]) {
      testWidgets('stable themed fill and outlines for $brightness / $preset', (
        tester,
      ) async {
        final theme = buildSiteLensTheme(preset, brightness);
        await tester.pumpWidget(_harness(theme: theme, onSelected: (_) {}));
        final trigger = tester.widget<TextButton>(_trigger);
        final colors = SiteLensColors.of(tester.element(_trigger));
        for (final state in [
          WidgetState.pressed,
          WidgetState.focused,
          WidgetState.hovered,
        ]) {
          expect(
            trigger.style!.overlayColor!.resolve({state}),
            Colors.transparent,
          );
          expect(
            trigger.style!.backgroundColor!.resolve({state}),
            colors.wellTint,
          );
        }
        expect(trigger.style!.splashFactory, NoSplash.splashFactory);
        expect(trigger.style!.animationDuration, Duration.zero);
        final press = await tester.startGesture(tester.getCenter(_trigger));
        await tester.pump(const Duration(milliseconds: 100));
        final ink = tester.widget<InkWell>(
          find.descendant(of: _trigger, matching: find.byType(InkWell)),
        );
        expect(
          ink.overlayColor!.resolve({WidgetState.pressed}),
          Colors.transparent,
        );
        await press.up();
        await tester.pump();
        final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
        expect(
          anchor.style!.backgroundColor!.resolve({}),
          colors.surfaceOpaque,
        );
        expect(anchor.style!.elevation!.resolve({}), 0);
        for (final button in tester.widgetList<MenuItemButton>(
          find.byType(MenuItemButton),
        )) {
          expect(
            button.style!.overlayColor!.resolve({WidgetState.focused}),
            Colors.transparent,
          );
          expect(
            button.style!.side!.resolve({WidgetState.focused})!.color,
            theme.colorScheme.primary,
          );
          expect(button.style!.animationDuration, Duration.zero);
          expect(button.style!.splashFactory, NoSplash.splashFactory);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final direction in TextDirection.values) {
    testWidgets('narrow viewport wraps large labels in $direction', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(280, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const longLabel = '很长的中文菜单选项需要完整显示和自动换行';
      await tester.pumpWidget(
        _harness(
          scale: 2.5,
          width: 130,
          direction: direction,
          options: const [
            SiteLensMenuOption(value: 0, label: '短选项'),
            SiteLensMenuOption(value: 1, label: longLabel),
          ],
          onSelected: (_) {},
        ),
      );
      expect(tester.getSize(_trigger).width, 130);
      await tester.tap(_trigger);
      await tester.pump();
      final item = tester.getRect(_item(longLabel));
      expect(item.left, greaterThanOrEqualTo(0));
      expect(item.right, lessThanOrEqualTo(280));
      expect(item.height, greaterThan(kMinInteractiveDimension));
      expect(tester.widget<Text>(find.text(longLabel)).maxLines, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
