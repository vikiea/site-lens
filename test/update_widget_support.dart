import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The update engine reads and writes real files, which the widget test's fake
/// clock does not drive. Transfers therefore run inside
/// [WidgetTester.runAsync], while widget assertions are made on a tree the test
/// renders explicitly afterwards.

/// Runs engine work on the real clock, then leaves a settle gap so the
/// controller's bookkeeping and notification have landed.
Future<void> runReal(
  WidgetTester tester,
  Future<void> Function() work, {
  Duration quietPeriod = const Duration(milliseconds: 100),
}) async {
  await tester.runAsync(() async {
    await work();
    await Future<void>.delayed(quietPeriod);
  });
  await tester.pump();
}

/// Waits for a controller condition on the real clock.
///
/// Returns whether the condition was met: failing inside `runAsync` would
/// unbalance the test's async guards.
Future<bool> realWait(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return true;
}

Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration quietPeriod = const Duration(milliseconds: 100),
}) async {
  final met = await tester.runAsync(() async {
    final result = await realWait(condition);
    await Future<void>.delayed(quietPeriod);
    return result;
  });
  await tester.pump();
  expect(
    met,
    isTrue,
    reason: 'the controller never reached the expected state',
  );
}

/// Renders the page again until [condition] holds.
///
/// Notifications delivered from real asynchronous work mark the page dirty
/// outside the fake clock's frames, so the tree is rebuilt explicitly.
Future<void> renderScreen(
  WidgetTester tester,
  Widget app,
  bool Function() condition, {
  int maxPumps = 20,
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt++) {
    if (condition()) return;
    await tester.pumpWidget(app);
    // Advance the clock: entrance animations must finish before a tap can
    // reach the control.
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: 'the screen never rendered the state');
}

/// Taps a control that may sit below the test viewport.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}
