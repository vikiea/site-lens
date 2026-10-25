import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/double_back_exit.dart';

void main() {
  test('requires a second Android back within two seconds', () {
    final controller = DoubleBackExitController();
    final first = DateTime(2026, 10, 25, 12);
    expect(controller.handleBack(first), isFalse);
    expect(
      controller.handleBack(first.add(const Duration(seconds: 2))),
      isTrue,
    );
  });

  test('a late second back starts a new confirmation window', () {
    final controller = DoubleBackExitController();
    final first = DateTime(2026, 10, 25, 12);
    expect(controller.handleBack(first), isFalse);
    expect(
      controller.handleBack(first.add(const Duration(milliseconds: 2001))),
      isFalse,
    );
    expect(
      controller.handleBack(first.add(const Duration(milliseconds: 3000))),
      isTrue,
    );
  });

  test('reset discards the pending first back', () {
    final controller = DoubleBackExitController();
    final first = DateTime(2026, 10, 25, 12);
    expect(controller.handleBack(first), isFalse);
    controller.reset();
    expect(
      controller.handleBack(first.add(const Duration(milliseconds: 500))),
      isFalse,
    );
  });
}
