import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/discovery/probe_coordinator.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

/// A host that finishes loading but never fills the ready selector. Used to
/// prove the verifier exits early instead of eating the whole budget.
class SlowEmptyApi extends WebHostApi {
  NativeHosts? hosts;
  @override
  Future<HostCapabilities> create(
    int hostId,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async => HostCapabilities(
    platform: 'fake',
    isolatedScripts: true,
    documentStart: true,
    privateProbes: true,
    reason: 'test',
  );
  @override
  Future<void> navigate(int hostId, String url) async {}
  @override
  Future<void> destroy(int hostId) async {}
  @override
  Future<PageSnapshot> inspect(int hostId, String selector) async {
    final h = hosts;
    final session = h?.sessions[hostId];
    if (h != null && session != null && !session.loaded) {
      await h.onEvent(
        HostEvent(
          hostId: hostId,
          generation: session.generation,
          kind: 'loaded',
          url: 'https://slow.example/',
          detail: '',
        ),
      );
    }
    return PageSnapshot(
      url: 'https://slow.example/',
      title: '',
      generation: session?.generation ?? 0,
      ready: false,
      challenge: false,
      interactionRequired: false,
      links: const [],
      text: '',
      error: '',
    );
  }
}

/// A host whose ready root already has text but is not "ready" yet for longer
/// than the grace window: the verifier must keep polling to the full budget.
class TextButNotReadyApi extends WebHostApi {
  TextButNotReadyApi(this.readyAfter);
  final int readyAfter;
  NativeHosts? hosts;
  int inspects = 0;
  @override
  Future<HostCapabilities> create(
    int hostId,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async => HostCapabilities(
    platform: 'fake',
    isolatedScripts: true,
    documentStart: true,
    privateProbes: true,
    reason: 'test',
  );
  @override
  Future<void> navigate(int hostId, String url) async {}
  @override
  Future<void> destroy(int hostId) async {}
  @override
  Future<PageSnapshot> inspect(int hostId, String selector) async {
    final h = hosts;
    final session = h?.sessions[hostId];
    if (h != null && session != null && !session.loaded) {
      await h.onEvent(
        HostEvent(
          hostId: hostId,
          generation: session.generation,
          kind: 'loaded',
          url: 'https://partial.example/',
          detail: '',
        ),
      );
    }
    inspects++;
    final ready = inspects >= readyAfter;
    return PageSnapshot(
      url: 'https://partial.example/',
      title: '',
      generation: session?.generation ?? 0,
      ready: ready,
      challenge: false,
      interactionRequired: false,
      links: const [],
      // Non-empty root text even while not ready.
      text: ready ? 'ready content here' : 'still rendering the page',
      error: '',
    );
  }
}

/// A host that finishes loading and only fills the ready selector after a few
/// inspections, proving the grace window does not reject slow hydration.
class LateReadyApi extends WebHostApi {
  LateReadyApi(this.readyAfter);
  final int readyAfter;
  NativeHosts? hosts;
  int inspects = 0;
  @override
  Future<HostCapabilities> create(
    int hostId,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async => HostCapabilities(
    platform: 'fake',
    isolatedScripts: true,
    documentStart: true,
    privateProbes: true,
    reason: 'test',
  );
  @override
  Future<void> navigate(int hostId, String url) async {}
  @override
  Future<void> destroy(int hostId) async {}
  @override
  Future<PageSnapshot> inspect(int hostId, String selector) async {
    final h = hosts;
    final session = h?.sessions[hostId];
    if (h != null && session != null && !session.loaded) {
      await h.onEvent(
        HostEvent(
          hostId: hostId,
          generation: session.generation,
          kind: 'loaded',
          url: 'https://late.example/',
          detail: '',
        ),
      );
    }
    inspects++;
    final ready = inspects >= readyAfter;
    return PageSnapshot(
      url: 'https://late.example/',
      title: '',
      generation: session?.generation ?? 0,
      ready: ready,
      challenge: false,
      interactionRequired: false,
      links: const [],
      text: ready ? 'ok' : '',
      error: '',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ProbeTiming picks the tighter WiFi bound and looser cellular bound',
    () {
      const timing = ProbeTiming();
      expect(timing.boundFor(NetworkClass.wifi), const Duration(seconds: 6));
      expect(
        timing.boundFor(NetworkClass.cellular),
        const Duration(seconds: 8),
      );
      expect(timing.boundFor(NetworkClass.other), const Duration(seconds: 6));
    },
  );

  test('verifier early-exits once loaded without ready content', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final http = ControlledHttp();
    final scripts = ScriptService(
      db,
      http,
      sourceDirectory: () async => Directory.systemTemp,
    );
    final api = SlowEmptyApi();
    final hosts = NativeHosts(db, scripts, http, api: api);
    api.hosts = hosts;
    final verifier = NativeHomepageVerifier(
      hosts,
      timing: const ProbeTiming(
        wifi: Duration(seconds: 6),
        loadedGrace: Duration(milliseconds: 150),
      ),
      networkClass: () async => NetworkClass.wifi,
    );
    final watch = Stopwatch()..start();
    final result = await verifier.verify(
      Candidate(id: 1, url: Uri.parse('https://slow.example/'), label: 'slow'),
      1,
      Cancellation(),
    );
    watch.stop();
    expect(result.status, ProbeStatus.unavailable);
    expect(result.reason, contains('提前判不可用'));
    // Far below the 6s WiFi bound: the early exit actually fired.
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test(
    'verifier still accepts a page that hydrates within the grace',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final http = ControlledHttp();
      final scripts = ScriptService(
        db,
        http,
        sourceDirectory: () async => Directory.systemTemp,
      );
      final api = LateReadyApi(5);
      final hosts = NativeHosts(db, scripts, http, api: api);
      api.hosts = hosts;
      final verifier = NativeHomepageVerifier(
        hosts,
        timing: const ProbeTiming(
          wifi: Duration(seconds: 6),
          loadedGrace: Duration(seconds: 3),
        ),
        networkClass: () async => NetworkClass.wifi,
      );
      final result = await verifier.verify(
        Candidate(
          id: 1,
          url: Uri.parse('https://late.example/'),
          label: 'late',
        ),
        1,
        Cancellation(),
      );
      expect(result.status, ProbeStatus.ready);
      expect(result.reason, contains('核心 DOM 就绪'));
    },
  );

  test(
    'a loaded page with non-empty root text is never early-exited',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final http = ControlledHttp();
      final scripts = ScriptService(
        db,
        http,
        sourceDirectory: () async => Directory.systemTemp,
      );
      // Ready only after ~30 inspections (~4.5s), far beyond the 1s grace.
      final api = TextButNotReadyApi(30);
      final hosts = NativeHosts(db, scripts, http, api: api);
      api.hosts = hosts;
      final verifier = NativeHomepageVerifier(
        hosts,
        timing: const ProbeTiming(
          wifi: Duration(seconds: 8),
          loadedGrace: Duration(seconds: 1),
        ),
        networkClass: () async => NetworkClass.wifi,
      );
      final result = await verifier.verify(
        Candidate(
          id: 1,
          url: Uri.parse('https://partial.example/'),
          label: 'partial',
        ),
        1,
        Cancellation(),
      );
      expect(result.status, ProbeStatus.ready);
      expect(api.inspects, greaterThan(10));
    },
  );
}
