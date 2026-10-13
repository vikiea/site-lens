import 'dart:io';

import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../settings/settings_repository.dart';
import '../device/device_conditions.dart';
import '../discovery/health_checker.dart';

const healthTaskName = 'profileHealthCheck';
const healthUniqueName = 'site-lens-health-check';
const healthNoticeKey = 'health_notice_pending';

/// Runs the survival check inside the WorkManager isolate. The engine created
/// by the plugin registers the normal plugins, so path_provider and
/// connectivity_plus work here; no WebView host is ever created.
@pragma('vm:entry-point')
void healthCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != healthTaskName) return true;
    final db = await AppDatabase.open();
    try {
      final report = await runBackgroundHealthCheck(db);
      return report.outcome != HealthRunOutcome.skippedConditions;
    } catch (_) {
      return false;
    } finally {
      await db.close();
    }
  });
}

/// The shared background entry point. Charging + WiFi are enforced twice: as
/// WorkManager constraints and again here, so a manual trigger is gated too.
Future<HealthRunReport> runBackgroundHealthCheck(AppDatabase db) async {
  // A run enqueued before the user disabled the toggle must not execute.
  if (!(await SettingsRepository(db).read()).backgroundHealthCheck) {
    return const HealthRunReport(outcome: HealthRunOutcome.skippedDisabled);
  }
  final conditions = await const DeviceConditions().read();
  final checker = ProfileHealthChecker(
    db: db,
    probe: HttpReachabilityProbe(),
    conditions: conditions,
    now: DateTime.now,
    notify: (title, body) async {
      // A background isolate has no Activity to post from; record the notice so
      // the next foreground open can surface it as a system notification.
      await db.setSetting(healthNoticeKey, '$title\u0000$body');
    },
  );
  return checker.run();
}

/// Schedules/cancels the periodic survival check. No-op off Android.
class HealthScheduler {
  const HealthScheduler();

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    await Workmanager().initialize(healthCallbackDispatcher);
  }

  Future<void> apply(bool enabled) async {
    if (!Platform.isAndroid) return;
    if (enabled) {
      // Twice a day at most, and only while charging on an unmetered network.
      await Workmanager().registerPeriodicTask(
        healthUniqueName,
        healthTaskName,
        frequency: const Duration(hours: 12),
        constraints: Constraints(
          networkType: NetworkType.unmetered,
          requiresCharging: true,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } else {
      await Workmanager().cancelByUniqueName(healthUniqueName);
    }
  }
}
