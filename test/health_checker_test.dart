import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/profile_panel.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/discovery/health_checker.dart';
import 'package:site_lens/domain/models.dart';

void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    profileId = await db.createProfile('站');
    await db.addCandidate(
      Uri.parse('https://a.example/'),
      profileId: profileId,
    );
  });
  tearDown(() => db.close());

  Future<HealthRunReport> run({
    required bool reachable,
    required bool charging,
    required bool wifi,
    required List<String> notes,
    DateTime? at,
    int maxPerDay = 2,
  }) => ProfileHealthChecker(
    db: db,
    probe: _FlagProbe(reachable),
    conditions: HealthConditions(charging: charging, wifi: wifi),
    now: () => at ?? DateTime(2026, 1, 1, 12),
    notify: (title, body) async => notes.add('$title|$body'),
    maxPerDay: maxPerDay,
  ).run();

  test(
    'resuming reloads durable health and stale success is not current evidence',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final app = AppController(db);
      addTearDown(app.dispose);
      final old = DateTime(2026, 1, 1);
      await db.saveProfileHealth(
        ProfileHealth(
          profileId: profileId,
          state: ProfileHealthState.ok,
          lastCheckedAt: old,
        ),
      );
      await app.refreshProfileHealth();
      expect(
        healthIsStale(
          app.healthFor(profileId),
          now: old.add(const Duration(hours: 25)),
        ),
        isTrue,
      );
      expect(
        healthIsStale(
          app.healthFor(profileId),
          now: old.add(const Duration(hours: 23)),
        ),
        isFalse,
      );
      await db.saveProfileHealth(
        ProfileHealth(
          profileId: profileId,
          state: ProfileHealthState.failing,
          consecutiveFailures: 2,
          lastCheckedAt: DateTime.now(),
          lastFailureCategory: 'tls_handshake',
        ),
      );
      app.didChangeAppLifecycleState(AppLifecycleState.resumed);
      for (
        var i = 0;
        i < 20 && app.healthFor(profileId).state != ProfileHealthState.failing;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(app.healthFor(profileId).state, ProfileHealthState.failing);
      expect(healthSummary(app.healthFor(profileId)), contains('TLS 握手失败'));
    },
  );

  test(
    'classified failures persist timestamp and recovery clears diagnostics',
    () async {
      final probe = _DetailedProbe();
      final at = DateTime(2026, 11, 5, 12);
      Future<HealthRunReport> check() => ProfileHealthChecker(
        db: db,
        probe: probe,
        conditions: const HealthConditions(charging: true, wifi: true),
        now: () => at,
        notify: (_, _) async {},
        maxPerDay: 10,
      ).run();
      await check();
      await check();
      final failed = await db.profileHealth(profileId);
      expect(failed.state, ProfileHealthState.failing);
      expect(failed.lastFailureCategory, 'tls_handshake');
      expect(failed.lastFailureRoute, isNull);
      expect(failed.lastCheckedAt, at);
      probe.ok = true;
      await check();
      final recovered = await db.profileHealth(profileId);
      expect(recovered.consecutiveFailures, 0);
      expect(recovered.lastFailureCategory, isNull);
      expect(recovered.lastFailureRoute, isNull);
      expect(recovered.lastOkAt, at);
    },
  );

  test('skips when not charging', () async {
    final notes = <String>[];
    final r = await run(
      reachable: false,
      charging: false,
      wifi: true,
      notes: notes,
    );
    expect(r.outcome, HealthRunOutcome.skippedConditions);
    expect(notes, isEmpty);
    expect((await db.profileHealth(profileId)).consecutiveFailures, 0);
  });

  test('skips when not on WiFi', () async {
    final notes = <String>[];
    final r = await run(
      reachable: true,
      charging: true,
      wifi: false,
      notes: notes,
    );
    expect(r.outcome, HealthRunOutcome.skippedConditions);
    expect(notes, isEmpty);
  });

  test('one failure does not notify', () async {
    final notes = <String>[];
    final r = await run(
      reachable: false,
      charging: true,
      wifi: true,
      notes: notes,
    );
    expect(r.outcome, HealthRunOutcome.ran);
    expect(notes, isEmpty);
    expect((await db.profileHealth(profileId)).consecutiveFailures, 1);
    expect(
      (await db.profileHealth(profileId)).state,
      isNot(ProfileHealthState.failing),
    );
  });

  test('two consecutive failures mark failing and notify once', () async {
    final notes = <String>[];
    await run(reachable: false, charging: true, wifi: true, notes: notes);
    final r = await run(
      reachable: false,
      charging: true,
      wifi: true,
      notes: notes,
      at: DateTime(2026, 1, 1, 18),
    );
    expect(r.failing, 1);
    expect(notes, hasLength(1));
    expect(notes.single, contains('站'));
    expect(
      (await db.profileHealth(profileId)).state,
      ProfileHealthState.failing,
    );
    expect((await db.profileHealth(profileId)).consecutiveFailures, 2);

    // A third failure is not a new transition, so no second notification.
    final r3 = await run(
      reachable: false,
      charging: true,
      wifi: true,
      notes: notes,
      at: DateTime(2026, 1, 2, 12),
    );
    expect(r3.outcome, HealthRunOutcome.ran);
    expect(notes, hasLength(1));
  });

  test('recovery clears the failure counter and the badge', () async {
    final notes = <String>[];
    await run(reachable: false, charging: true, wifi: true, notes: notes);
    await run(
      reachable: false,
      charging: true,
      wifi: true,
      notes: notes,
      at: DateTime(2026, 1, 1, 18),
    );
    expect(
      (await db.profileHealth(profileId)).state,
      ProfileHealthState.failing,
    );

    await run(
      reachable: true,
      charging: true,
      wifi: true,
      notes: notes,
      at: DateTime(2026, 1, 2, 12),
    );
    final health = await db.profileHealth(profileId);
    expect(health.consecutiveFailures, 0);
    expect(health.state, ProfileHealthState.ok);
    expect(health.lastOkAt, isNotNull);
    expect(notes, hasLength(1)); // recovery is silent
  });

  test('runs at most maxPerDay times per calendar day', () async {
    final notes = <String>[];
    expect(
      (await run(
        reachable: true,
        charging: true,
        wifi: true,
        notes: notes,
      )).outcome,
      HealthRunOutcome.ran,
    );
    expect(
      (await run(
        reachable: true,
        charging: true,
        wifi: true,
        notes: notes,
      )).outcome,
      HealthRunOutcome.ran,
    );
    expect(
      (await run(
        reachable: true,
        charging: true,
        wifi: true,
        notes: notes,
      )).outcome,
      HealthRunOutcome.skippedRateLimit,
    );
    // A new day resets the budget.
    expect(
      (await run(
        reachable: true,
        charging: true,
        wifi: true,
        notes: notes,
        at: DateTime(2026, 1, 2, 12),
      )).outcome,
      HealthRunOutcome.ran,
    );
  });
}

class _FlagProbe implements ReachabilityProbe {
  _FlagProbe(this.value);
  final bool value;
  @override
  Future<bool> reachable(Uri url) async => value;
}

class _DetailedProbe implements DetailedReachabilityProbe {
  bool ok = false;
  @override
  Future<bool> reachable(Uri url) async => ok;
  @override
  Future<HealthProbeResult> check(Uri url) async => HealthProbeResult(
    reachable: ok,
    failureCategory: ok ? null : 'tls_handshake',
  );
}
