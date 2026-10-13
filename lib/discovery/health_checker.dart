import 'dart:math';

import 'package:drift/drift.dart';

import '../data/database.dart';
import '../domain/models.dart';
import '../network/transport.dart';

/// Snapshot of the two "should we run at all" conditions. Background survival
/// checks are best-effort: charging AND WiFi, at most [ProfileHealthChecker.maxPerDay]
/// times per calendar day.
class HealthConditions {
  const HealthConditions({required this.charging, required this.wifi});
  final bool charging;
  final bool wifi;
}

enum HealthRunOutcome {
  skippedConditions,
  skippedRateLimit,
  skippedDisabled,
  ran,
}

class HealthRunReport {
  const HealthRunReport({
    required this.outcome,
    this.checked = 0,
    this.failing = 0,
    this.notifications = const [],
  });
  final HealthRunOutcome outcome;
  final int checked;
  final int failing;
  final List<String> notifications;
}

/// HTTP-only reachability. Deliberately does NOT touch the WebView host: a
/// background check must never spin up a renderer.
abstract interface class ReachabilityProbe {
  Future<bool> reachable(Uri url);
}

class HttpReachabilityProbe implements ReachabilityProbe {
  HttpReachabilityProbe({HttpProbe? probe, this.allowLocal = false})
    : _probe = probe ?? HttpProbe();
  final HttpProbe _probe;
  final bool allowLocal;
  @override
  Future<bool> reachable(Uri url) async {
    final result = await _probe.run(
      Candidate(id: 0, url: url, label: url.host),
      0,
      Cancellation(),
    );
    return result.status == ProbeStatus.reachable;
  }
}

/// Updates `profile_health` only. Never writes a recommendation, never touches
/// ranking, and only notifies on the two-failures transition.
class ProfileHealthChecker {
  ProfileHealthChecker({
    required this.db,
    required this.probe,
    required this.conditions,
    required this.now,
    required this.notify,
    this.maxPerDay = 2,
  });
  final AppDatabase db;
  final ReachabilityProbe probe;
  final HealthConditions conditions;
  final DateTime Function() now;
  final Future<void> Function(String title, String body) notify;
  final int maxPerDay;

  static const failuresBeforeAlert = 2;

  Future<HealthRunReport> run() async {
    if (!conditions.charging || !conditions.wifi) {
      return const HealthRunReport(outcome: HealthRunOutcome.skippedConditions);
    }
    final started = now();
    final stamp = _dateKey(started);
    final owner =
        '${started.microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final claimed = await db.transaction(() async {
      final lease = await db
          .customSelect(
            'INSERT INTO health_run_leases(name,owner,expires_at) VALUES(?,?,?) '
            'ON CONFLICT(name) DO UPDATE SET owner=excluded.owner,expires_at=excluded.expires_at '
            'WHERE health_run_leases.expires_at < ? RETURNING owner',
            variables: [
              Variable('survival'),
              Variable(owner),
              Variable(
                started.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
              ),
              Variable(started.millisecondsSinceEpoch),
            ],
          )
          .getSingleOrNull();
      if (lease == null) return false;
      final key = 'health_runs_$stamp';
      final used = int.tryParse(await db.setting(key) ?? '0') ?? 0;
      if (used >= maxPerDay) {
        await db.customStatement(
          'DELETE FROM health_run_leases WHERE owner=?',
          [owner],
        );
        return false;
      }
      await db.setSetting(key, '${used + 1}');
      return true;
    });
    if (!claimed) {
      return const HealthRunReport(outcome: HealthRunOutcome.skippedRateLimit);
    }
    try {
      var checked = 0;
      var failing = 0;
      final notifications = <String>[];
      for (final profile in await db.profiles()) {
        if (!profile.enabled) continue;
        final url = await _targetUrl(profile.id);
        if (url == null) continue;
        final reachable = await probe.reachable(url);
        final renewed = await db
            .customSelect(
              'UPDATE health_run_leases SET expires_at=? WHERE owner=? RETURNING owner',
              variables: [
                Variable(
                  now().add(const Duration(minutes: 15)).millisecondsSinceEpoch,
                ),
                Variable(owner),
              ],
            )
            .getSingleOrNull();
        if (renewed == null) throw const Cancelled();
        final previous = await db.profileHealth(profile.id);
        final at = now();
        if (reachable) {
          await db.saveProfileHealth(
            ProfileHealth(
              profileId: profile.id,
              consecutiveFailures: 0,
              state: ProfileHealthState.ok,
              lastCheckedAt: at,
              lastOkAt: at,
            ),
          );
        } else {
          final failures = previous.consecutiveFailures + 1;
          final alert =
              failures >= failuresBeforeAlert &&
              previous.state != ProfileHealthState.failing;
          await db.saveProfileHealth(
            ProfileHealth(
              profileId: profile.id,
              consecutiveFailures: failures,
              state: failures >= failuresBeforeAlert
                  ? ProfileHealthState.failing
                  : previous.state,
              lastCheckedAt: at,
              lastOkAt: previous.lastOkAt,
            ),
          );
          if (failures >= failuresBeforeAlert) failing++;
          if (alert) {
            notifications.add(profile.name);
            await notify('站点可能不可达', '${profile.name} 连续 $failures 轮不可达');
          }
        }
        checked++;
      }
      return HealthRunReport(
        outcome: HealthRunOutcome.ran,
        checked: checked,
        failing: failing,
        notifications: notifications,
      );
    } finally {
      await db.customStatement('DELETE FROM health_run_leases WHERE owner=?', [
        owner,
      ]);
    }
  }

  /// Prefer the most recent ready landing; fall back to the newest candidate,
  /// then the publishing page. Background checks need a URL, not a profile.
  Future<Uri?> _targetUrl(int profileId) async {
    final candidates = await db.candidates(profileId: profileId);
    final ids = candidates.map((c) => c.id).toSet();
    final ready = (await db.recentProbes()).where(
      (r) => ids.contains(r.candidateId) && r.verified && r.finalUrl != null,
    );
    if (ready.isNotEmpty) return ready.first.finalUrl;
    if (candidates.isNotEmpty) {
      final enabled = candidates.where((c) => c.enabled);
      return (enabled.isEmpty ? candidates.first : enabled.first).url;
    }
    final pages = await db.profilePages(profileId: profileId);
    return pages.isEmpty ? null : pages.first.url;
  }

  String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
