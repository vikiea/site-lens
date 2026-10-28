import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/discovery/probe_coordinator.dart';

class FakeHttp extends HttpProbe {
  int active = 0;
  int maxActive = 0;
  @override
  Future<ProbeResult> run(Candidate c, int round, Cancellation cancel) async {
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    return ProbeResult(
      round: round,
      candidateId: c.id,
      stage: ProbeStage.http,
      status: ProbeStatus.reachable,
      entryUrl: c.url,
      finalUrl: c.url,
      elapsed: Duration(milliseconds: c.id),
      checkedAt: DateTime.now(),
    );
  }
}

class FakeVerifier implements HomepageVerifier {
  final ids = <int>[];
  int active = 0;
  int maxActive = 0;
  final Completer<void>? gate;
  FakeVerifier({this.gate});
  @override
  Future<ProbeResult> verify(
    Candidate c,
    int round,
    Cancellation cancel,
  ) async {
    active++;
    if (active > maxActive) maxActive = active;
    ids.add(c.id);
    try {
      await gate?.future;
      return ProbeResult(
        round: round,
        candidateId: c.id,
        stage: ProbeStage.homepage,
        status: c.id == 1 ? ProbeStatus.challenge : ProbeStatus.ready,
        entryUrl: c.url,
        finalUrl: Uri.parse(
          'https://landing.example/${c.id < 4 ? 'same' : c.id}',
        ),
        elapsed: Duration(milliseconds: 100 - c.id),
        checkedAt: DateTime.now(),
      );
    } finally {
      active--;
    }
  }
}

class _HangingVerifier implements HomepageVerifier {
  @override
  Future<ProbeResult> verify(
    Candidate c,
    int round,
    Cancellation cancel,
  ) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return ProbeResult(
      round: round,
      candidateId: c.id,
      stage: ProbeStage.homepage,
      status: ProbeStatus.ready,
      entryUrl: c.url,
      finalUrl: c.url,
      elapsed: const Duration(seconds: 5),
      checkedAt: DateTime.now(),
    );
  }
}

class _CleanupAwareVerifier implements HomepageVerifier {
  bool cleanupFinished = false;

  @override
  Future<ProbeResult> verify(
    Candidate c,
    int round,
    Cancellation cancel,
  ) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return ProbeResult(
        round: round,
        candidateId: c.id,
        stage: ProbeStage.homepage,
        status: ProbeStatus.ready,
        entryUrl: c.url,
        finalUrl: c.url,
        elapsed: const Duration(milliseconds: 100),
        checkedAt: DateTime.now(),
      );
    } finally {
      cleanupFinished = true;
    }
  }
}

void main() {
  final sites = List.generate(
    8,
    (i) => Candidate(
      id: i + 1,
      url: Uri.parse('https://site${i + 1}.example/'),
      label: 's',
    ),
  );
  test(
    'default round verifies the top three serially and ready landings rank',
    () async {
      final http = FakeHttp();
      final verifier = FakeVerifier();
      final saved = <ProbeResult>[];
      final p = ProbeCoordinator(
        candidates: () async => sites,
        httpProbe: http,
        verifier: verifier,
        save: (r) async {
          saved.add(r);
        },
      );
      addTearDown(p.dispose);
      await p.run();
      expect(
        http.maxActive,
        lessThanOrEqualTo(ProbeCoordinator.maxConcurrentProbes),
      );
      expect(verifier.ids, [1, 2, 3]);
      // Default round is serial so its three timings are directly comparable.
      expect(verifier.maxActive, 1);
      expect(p.recommendations.length, 1);
      expect(p.recommendations.single.candidateId, 3);
      expect(p.results[4]!.verified, isFalse);
      expect(saved.length, 11);
    },
  );
  test(
    'full round is bounded-parallel (<=8) and covers every reachable landing',
    () async {
      final verifier = FakeVerifier();
      final p = ProbeCoordinator(
        candidates: () async => sites,
        httpProbe: FakeHttp(),
        verifier: verifier,
        save: (_) async {},
      );
      addTearDown(p.dispose);
      await p.run(all: true);
      expect(verifier.ids.toSet(), {1, 2, 3, 4, 5, 6, 7, 8});
      expect(
        verifier.maxActive,
        lessThanOrEqualTo(ProbeCoordinator.maxConcurrentProbes),
      );
      expect(verifier.maxActive, greaterThan(1)); // genuinely parallel
      expect(p.recommendations.first.candidateId, 8);
    },
  );
  test('late results cannot become recommendations after user selects or network changes', () async {
    final gate = Completer<void>();
    final verifier = FakeVerifier(gate: gate);
    final p = ProbeCoordinator(
      candidates: () async => sites,
      httpProbe: FakeHttp(),
      verifier: verifier,
      save: (_) async {},
    );
    addTearDown(p.dispose);
    final old = p.run();
    while (verifier.ids.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    p.cancel('user selected');
    gate.complete();
    await old;
    expect(p.recommendations, isEmpty);
    expect(p.running, isFalse);
    expect(p.notice, 'user selected');
  });

  test('homepage verification consumes the HTTP candidate budget', () async {
    final p = ProbeCoordinator(
      candidates: () async => [sites.first],
      httpProbe: _ElapsedHttp(const Duration(seconds: 5)),
      verifier: _HangingVerifier(),
      save: (_) async {},
    );
    addTearDown(p.dispose);

    await p.run(all: true);

    expect(p.results[1]?.status, ProbeStatus.timeout);
    expect(p.results[1]?.reason, contains('合计超过 5 秒'));
  });

  test(
    'homepage timeout waits for verifier cleanup before releasing worker',
    () async {
      final verifier = _CleanupAwareVerifier();
      final p = ProbeCoordinator(
        candidates: () async => [sites.first],
        httpProbe: _ElapsedHttp(const Duration(seconds: 4, milliseconds: 950)),
        verifier: verifier,
        save: (_) async {},
      );
      addTearDown(p.dispose);

      final watch = Stopwatch()..start();
      await p.run(all: true);

      expect(p.results[1]?.status, ProbeStatus.timeout);
      expect(verifier.cleanupFinished, isTrue);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 90)),
      );
    },
  );
}

class _ElapsedHttp extends HttpProbe {
  _ElapsedHttp(this.elapsed);

  final Duration elapsed;

  @override
  Future<ProbeResult> run(Candidate c, int round, Cancellation cancel) async =>
      ProbeResult(
        round: round,
        candidateId: c.id,
        stage: ProbeStage.http,
        status: ProbeStatus.reachable,
        entryUrl: c.url,
        finalUrl: c.url,
        elapsed: elapsed,
        checkedAt: DateTime.now(),
      );
}
