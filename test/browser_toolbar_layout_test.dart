import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/browser_entry.dart';

/// The browser toolbar is a fixed single row. Its item count is a product
/// decision, so these tests pin the count and the equal-width arithmetic
/// instead of a width-dependent collapse.
void main() {
  test('the toolbar is one fixed row of seven equal controls', () {
    for (final screen in <double>[
      280,
      320,
      360,
      384,
      393,
      412,
      430,
      480,
      600,
      800,
    ]) {
      final width = browserToolbarItemWidth(screen);
      expect(browserToolbarItemCount, 7);
      expect(
        width * browserToolbarItemCount + 2 * SiteLensMetrics.toolbarInset,
        closeTo(screen, 0.001),
        reason: 'the seven cells plus the side inset fill the screen',
      );
      expect(width, greaterThan(0));
    }
  });

  test('the narrowest supported phone still shows all seven controls', () {
    // A 320dp screen keeps every control; the cells get narrower instead of
    // the toolbar folding into "更多".
    final width = browserToolbarItemWidth(320);
    expect(width, closeTo((320 - 2 * SiteLensMetrics.toolbarInset) / 7, 0.001));
    expect(width, greaterThan(40));
  });

  test('there is no collapse, wrap or horizontal scroll behaviour', () {
    // Narrower screens keep the same seven controls and only shrink cells.
    expect(
      browserToolbarItemWidth(240),
      lessThan(browserToolbarItemWidth(400)),
    );
    expect(browserToolbarItemCount, 7);
  });
}
