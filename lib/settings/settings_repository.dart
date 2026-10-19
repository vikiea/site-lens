import 'dart:async';

import '../data/database.dart';
import 'app_settings.dart';

/// The only persistence boundary for user preferences, including background
/// isolates. Transactions merge patches against the current persisted record.
///
/// There is no legacy key migration: the stored record is always the current
/// format, and anything else is rejected rather than reinterpreted.
class SettingsRepository {
  SettingsRepository(this.db);
  final AppDatabase db;
  final _changes = StreamController<AppSettings>.broadcast();

  Stream<AppSettings> watch() async* {
    yield await read();
    yield* _changes.stream;
  }

  Future<void> dispose() => _changes.close();

  Future<AppSettings> read() async {
    final raw = await db.setting(AppPolicy.settingsKey);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.decode(raw);
    } on FormatException {
      // A stored record that is not the current format cannot be interpreted.
      // Defaults are the safe half of that: they keep the script kill switch
      // engaged, the way every other damaged security value behaves, instead of
      // silently re-enabling user scripts.
      return const AppSettings(scriptsDisabled: true);
    }
  }

  Future<AppSettings> update(Map<String, Object?> patch) async {
    final updated = await db.transaction(() async {
      final current = await read();
      final updated = current.patch(patch);
      await db.setSetting(AppPolicy.settingsKey, updated.encode());
      return updated;
    });
    if (!_changes.isClosed) _changes.add(updated);
    return updated;
  }

  Future<AppSettings> resetUserPreferences() async {
    final settings = await db.transaction(() async {
      final current = await read();
      final settings = AppSettings(scriptsDisabled: current.scriptsDisabled);
      await db.setSetting(AppPolicy.settingsKey, settings.encode());
      return settings;
    });
    if (!_changes.isClosed) _changes.add(settings);
    return settings;
  }

  Future<AppSettings> dismissNotice(String id) async {
    final updated = await db.transaction(() async {
      final current = await read();
      final next = current.patch({
        'dismissedNotices': {...current.dismissedNotices, id}.toList(),
        if (id == 'media.library') 'mediaLibraryNoticeDismissed': true,
        if (id == 'media.tasks') 'mediaTasksNoticeDismissed': true,
      });
      await db.setSetting(AppPolicy.settingsKey, next.encode());
      return next;
    });
    if (!_changes.isClosed) _changes.add(updated);
    return updated;
  }
}
