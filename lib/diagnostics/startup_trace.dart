import 'dart:convert';

import 'package:flutter/foundation.dart';

enum StartupPhase {
  appEntry,
  bindingReady,
  databaseOpen,
  pendingLogRecovery,
  nativeLogRecovery,
  firstFrameworkFrame,
  firstRasterFrame,
  mediaTasksRestore,
  mediaTasksReady,
  mediaLibraryRestore,
  mediaLibraryReady,
  nativeDownloadReconcile,
  storedMetadataRead,
  filterSourcesSeed,
  filterSourcesReady,
  filterBundleRebuild,
  preferencesRead,
  preferencesApply,
  hostFiltersApply,
  hostPreferencesApply,
  mediaPolicySync,
  persistentStateReady,
  savedTabsRestore,
  savedTabsReady,
  homeMetadataFrameworkFrame,
  resumeEntryFrameworkFrame,
  backgroundNotice,
  connectivitySetup,
  controllerReady,
}

/// Startup-only timings contain fixed phase names, counts and monotonic times.
/// No URL, tab title, database contents or exception text enters this stream.
class StartupTrace {
  StartupTrace({this.enabled = false, this.nowMicros, this.emit}) {
    _clock.start();
  }

  static final process = StartupTrace(
    enabled:
        kDebugMode || const bool.fromEnvironment('SITE_LENS_STARTUP_TRACE'),
    emit: (event) => debugPrint('SITE_LENS_STARTUP ${jsonEncode(event)}'),
  );

  final bool enabled;
  final _clock = Stopwatch();
  final int Function()? nowMicros;
  final void Function(Map<String, Object>)? emit;
  final _marks = <StartupPhase>{};

  int get _now => nowMicros?.call() ?? _clock.elapsedMicroseconds;

  bool needsMark(StartupPhase phase) => enabled && !_marks.contains(phase);

  void _record(Map<String, Object> event) {
    try {
      emit?.call(event);
    } catch (_) {
      // Observing startup must never change its success/failure behavior.
    }
  }

  void markOnce(StartupPhase phase, {int? itemCount}) {
    if (!enabled || !_marks.add(phase)) return;
    _record({
      'phase': phase.name,
      'kind': 'mark',
      'elapsedUs': _now,
      'itemCount': ?itemCount,
    });
  }

  Future<T> measure<T>(StartupPhase phase, Future<T> Function() action) {
    if (!enabled) return action();
    return _measure(phase, action);
  }

  void firstRasterFrame({
    required int buildUs,
    required int rasterUs,
    required int totalUs,
  }) {
    if (!enabled || !_marks.add(StartupPhase.firstRasterFrame)) return;
    _record({
      'phase': StartupPhase.firstRasterFrame.name,
      'kind': 'frameTiming',
      'reportedAtUs': _now,
      'buildUs': buildUs,
      'rasterUs': rasterUs,
      'totalUs': totalUs,
    });
  }

  T measureSync<T>(StartupPhase phase, T Function() action) {
    if (!enabled) return action();
    final start = _now;
    var succeeded = false;
    try {
      final value = action();
      succeeded = true;
      return value;
    } finally {
      final end = _now;
      _record({
        'phase': phase.name,
        'kind': 'span',
        'startUs': start,
        'elapsedUs': end,
        'durationUs': end - start,
        'succeeded': succeeded,
      });
    }
  }

  Future<T> _measure<T>(StartupPhase phase, Future<T> Function() action) async {
    final start = _now;
    var succeeded = false;
    try {
      final value = await action();
      succeeded = true;
      return value;
    } finally {
      final end = _now;
      _record({
        'phase': phase.name,
        'kind': 'span',
        'startUs': start,
        'elapsedUs': end,
        'durationUs': end - start,
        'succeeded': succeeded,
      });
    }
  }
}
