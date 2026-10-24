import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/glass_surface.dart';

void main() {
  testWidgets(
    'quality and fallback changes preserve content, focus and scroll',
    (tester) async {
      final policy = ValueNotifier(
        const SiteLensGlassQualityStrategy(
          mode: SiteLensGlassQualityMode.standard,
          lightweightShaderSupported: true,
        ),
      );
      addTearDown(policy.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder(
            valueListenable: policy,
            builder: (_, value, _) => SiteLensGlassPolicyScope(
              strategy: value,
              child: const Center(
                child: SizedBox(
                  width: 300,
                  height: 240,
                  child: SiteLensPanel(child: _ContentProbe()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = tester.state<_ContentProbeState>(
        find.byType(_ContentProbe),
      );
      await tester.enterText(find.byType(TextField), '保留输入与焦点');
      await tester.tap(find.byType(Checkbox));
      initial.focus.requestFocus();
      await tester.pump();
      initial.scroll.jumpTo(60);
      await tester.pump();
      for (final lightweightShaderSupported in [true, false, true]) {
        for (final mode in SiteLensGlassQualityMode.values) {
          policy.value = SiteLensGlassQualityStrategy(
            mode: mode,
            allSurfacesHighQuality: true,
            lightweightShaderSupported: lightweightShaderSupported,
          );
          // Check the first frame as well as asynchronous shader completion.
          await tester.pump();
          expect(tester.state(find.byType(_ContentProbe)), same(initial));
          expect(initial.controller.text, '保留输入与焦点');
          expect(initial.selected, isTrue);
          expect(initial.focus.hasFocus, isTrue);
          expect(initial.scroll.offset, 60);
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(_ContentProbe)), same(initial));
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _ContentProbe extends StatefulWidget {
  const _ContentProbe();
  @override
  State<_ContentProbe> createState() => _ContentProbeState();
}

class _ContentProbeState extends State<_ContentProbe> {
  final controller = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  bool selected = false;

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: scroll,
    child: Column(
      children: [
        TextField(controller: controller, focusNode: focus),
        Checkbox(
          value: selected,
          onChanged: (value) => setState(() => selected = value!),
        ),
        const SizedBox(height: 800),
      ],
    ),
  );
}
