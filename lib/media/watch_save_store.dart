import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../domain/models.dart';

/// Persists automatic viewing-save owners without creating a download task.
/// The store accepts only document-scoped, candidate-confirmed playback
/// evidence and rechecks the caller's current-tab fence before committing.
class WatchSaveStore extends ChangeNotifier {
  WatchSaveStore(this.db);

  final AppDatabase db;
  final _items = <String, WatchSave>{};
  Future<void>? _restoreRun;
  Future<void>? _writes;
  bool _restored = false;
  bool _disposed = false;

  List<WatchSave> get saves => List.unmodifiable(_items.values.toList());

  Future<void> restore() {
    if (_restored) return Future<void>.value();
    return _restoreRun ??= _restore();
  }

  Future<void> _restore() async {
    try {
      final rows = await db.watchSaves();
      if (_disposed) return;
      _items
        ..clear()
        ..addEntries(rows.map((save) => MapEntry(save.ownerId, save)));
      _restored = true;
      notifyListeners();
    } finally {
      _restoreRun = null;
    }
  }

  Future<WatchSave?> observe(
    PlaybackEvidence evidence, {
    required int? profileId,
    bool Function()? isCurrent,
  }) async {
    if (!evidence.autoSaveEligible || evidence.sourceUrl == null) return null;
    await restore();
    if (_disposed || isCurrent?.call() == false) return null;
    final next = WatchSave.fromEvidence(evidence, profileId: profileId);
    final previous = _items[next.ownerId];
    final save = previous == null
        ? next
        : previous.copyWith(
            title: next.title,
            pageUrl: next.pageUrl,
            hostId: next.hostId,
            generation: next.generation,
            state: next.state,
            updatedAt: next.updatedAt,
            profileId: next.profileId,
          );
    if (isCurrent?.call() == false || _disposed) return null;
    var committed = false;
    final queued = _writes ?? Future<void>.value();
    final write = queued.then<void>((_) async {
      if (_disposed || isCurrent?.call() == false) return;
      final accepted = await db.saveWatchSave(save);
      if (accepted) {
        committed = true;
        if (!_disposed) {
          _items[save.ownerId] = save;
          notifyListeners();
        }
      } else {
        final current = await db.watchSave(save.ownerId);
        if (current != null && !_disposed) {
          _items[save.ownerId] = current;
          notifyListeners();
        }
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await write;
    return committed ? save : null;
  }

  Future<void> flush() async {
    await _restoreRun;
    final writes = _writes;
    if (writes != null) await writes;
  }

  Future<void> delete(String ownerId) async {
    await restore();
    final queued = _writes ?? Future<void>.value();
    final write = queued.then<void>((_) async {
      await db.deleteWatchSave(ownerId);
      _items.remove(ownerId);
      if (!_disposed) notifyListeners();
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await write;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
