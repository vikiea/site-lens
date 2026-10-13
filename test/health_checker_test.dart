import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
