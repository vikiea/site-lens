import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/diagnostics/startup_trace.dart';

void main() {
  test('async spans separate duration from elapsed startup time', () async {
    var now = 100;
    final events = <Map<String, Object>>[];
    final trace = StartupTrace(
      enabled: true,
      nowMicros: () => now,
      emit: events.add,
    );
    final value = await trace.measure(
      StartupPhase.filterBundleRebuild,
      () async {
        now = 160;
        return 42;
      },
    );
    expect(value, 42);
    expect(events.single, {
      'phase': 'filterBundleRebuild',
      'kind': 'span',
      'startUs': 100,
      'elapsedUs': 160,
      'durationUs': 60,
      'succeeded': true,
    });
  });

  test(
    'failure records only the fixed phase and preserves the original error',
    () async {
      final events = <Map<String, Object>>[];
      final trace = StartupTrace(enabled: true, emit: events.add);
      final failure = StateError(
        'private URL or database content must not be logged',
      );
      await expectLater(
        trace.measure(
          StartupPhase.databaseOpen,
          () => Future<void>.error(failure),
        ),
        throwsA(same(failure)),
      );
      expect(events.single['succeeded'], false);
      expect(events.toString(), isNot(contains(failure.message)));
    },
  );

  test(
    'disabled observation and failing sinks do not alter startup behavior',
    () async {
      final disabled = StartupTrace(emit: (_) => fail('disabled sink'));
      disabled.markOnce(StartupPhase.appEntry);
      expect(
        await disabled.measure(StartupPhase.databaseOpen, () async => 7),
        7,
      );
      final broken = StartupTrace(
        enabled: true,
        emit: (_) => throw StateError('sink'),
      );
      expect(broken.measureSync(StartupPhase.preferencesApply, () => 8), 8);
      expect(await broken.measure(StartupPhase.databaseOpen, () async => 9), 9);
    },
  );

  test('frame and metadata marks are once-only and remain distinct', () {
    final events = <Map<String, Object>>[];
    final trace = StartupTrace(enabled: true, emit: events.add);
    for (var i = 0; i < 2; i++) {
      trace.markOnce(StartupPhase.homeMetadataFrameworkFrame, itemCount: 2);
      trace.firstRasterFrame(buildUs: 1, rasterUs: 2, totalUs: 3);
    }
    expect(events, hasLength(2));
    expect(events[0]['kind'], 'mark');
    expect(events[0]['itemCount'], 2);
    expect(events[1]['kind'], 'frameTiming');
    expect(events[1]['rasterUs'], 2);
  });
}
