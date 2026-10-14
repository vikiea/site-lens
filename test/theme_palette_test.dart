import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_theme.dart';

// CIE Lab distance catches near-identical generated primary colors even when
// seed swatches look different; this is a regression guard, not visual approval.
List<double> _lab(Color color) {
  double linear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(color.r), g = linear(color.g), b = linear(color.b);
  double curve(double v) =>
      v > 0.008856 ? math.pow(v, 1 / 3).toDouble() : 7.787 * v + 16 / 116;
  final x = curve((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047);
  final y = curve(0.2126729 * r + 0.7151522 * g + 0.0721750 * b);
  final z = curve((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883);
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
}

void main() {
  for (final brightness in Brightness.values) {
    test('twelve themes have distinct primary colors in $brightness', () {
      final presets = ThemePresetId.values;
      expect(presets, hasLength(12));
      for (var i = 0; i < presets.length; i++) {
        final a = _lab(
          buildSiteLensTheme(presets[i], brightness).colorScheme.primary,
        );
        for (final other in presets.skip(i + 1)) {
          final b = _lab(
            buildSiteLensTheme(other, brightness).colorScheme.primary,
          );
          final distance = math.sqrt(
            List.generate(
              3,
              (j) => math.pow(a[j] - b[j], 2).toDouble(),
            ).reduce((x, y) => x + y),
          );
          expect(
            distance,
            greaterThan(5.5),
            reason:
                '${presets[i].label} and ${other.label} are too similar ($distance)',
          );
        }
      }
      for (var i = 0; i < presets.length; i++) {
        final a = _lab(presets[i].seed);
        for (final other in presets.skip(i + 1)) {
          final b = _lab(other.seed);
          final distance = math.sqrt(
            List.generate(
              3,
              (j) => math.pow(a[j] - b[j], 2).toDouble(),
            ).reduce((x, y) => x + y),
          );
          expect(
            distance,
            greaterThan(5.5),
            reason:
                '${presets[i].label} and ${other.label} seeds are too similar ($distance)',
          );
        }
      }
    });
  }
}
