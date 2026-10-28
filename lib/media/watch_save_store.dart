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
  String? _lastFailureReason;

  List<WatchSave> get saves => List.unmodifiable(_items.values.toList());
  String? get lastFailureReason => _lastFailureReason;

  void _recordFailure(String reason) {
    if (_lastFailureReason == reason) return;
    _lastFailureReason = reason;
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() {
    if (_restored) return Future<void>.value();
    return _restoreRun ??= _restore();
  }

  /// Re-reads durable saves after an external database import or test fixture
  /// write. Normal startup should continue to use [restore] so it does not
  /// reopen the database on every rebuild.
  Future<void> reload() async {
    await flush();
    if (_disposed) return;
    _restored = false;
    _items.clear();
    await restore();
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
    if (evidence.sourceUrl == null) {
      _recordFailure('当前播放缺少有效媒体地址');
      return null;
    }
    if (!evidence.watchSaveEligible) {
      _recordFailure(evidence.reason ?? '当前播放缺少稳定的系列或集数信息');
      return null;
    }
    await restore();
    if (_disposed || isCurrent?.call() == false) {
      _recordFailure('播放页面已切换，已忽略陈旧播放事件');
      return null;
    }
    final next = WatchSave.fromEvidence(evidence, profileId: profileId);
    final previous = _items[next.ownerId];
    if (previous == null && !evidence.autoSaveEligible) {
      _recordFailure('当前播放状态尚未达到可保存条件');
      return null;
    }
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
            positionMs: next.positionMs,
            durationMs: next.durationMs,
            evidenceRevision: next.evidenceRevision,
          );
    if (isCurrent?.call() == false || _disposed) return null;
    var committed = false;
    final queued = _writes ?? Future<void>.value();
    final write = queued.then<void>((_) async {
      if (_disposed || isCurrent?.call() == false) return;
      final accepted = await db.saveWatchSave(save);
      if (accepted) {
        committed = true;
        _lastFailureReason = null;
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
