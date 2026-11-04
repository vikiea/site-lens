import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../domain/models.dart';
import 'media_library.dart';
import 'media_service.dart';

enum MediaTaskAvailabilityEventKind {
  retained,
  released,
  exclusiveAcquired,
  exclusiveReleased,
}

class MediaTaskAvailabilityEvent {
  const MediaTaskAvailabilityEvent({
    required this.taskId,
    required this.kind,
    required this.referenceCount,
    required this.exclusive,
    required this.canDelete,
  });

  final String taskId;
  final MediaTaskAvailabilityEventKind kind;
  final int referenceCount;
  final bool exclusive;
  final bool canDelete;
}

/// Adds named availability events without changing the store's ownership rules.
class ExportNotifyingMediaTaskStore extends MediaTaskStore {
  ExportNotifyingMediaTaskStore({
    super.directoryProvider,
    super.db,
    super.resourceCoordinator,
    super.restoreBeforeUse,
  });

  final _events = StreamController<MediaTaskAvailabilityEvent>.broadcast(
    sync: true,
  );
  final _references = <String, int>{};
  Stream<MediaTaskAvailabilityEvent> get availabilityEvents => _events.stream;

  void _emit(String taskId, MediaTaskAvailabilityEventKind kind) {
    final id = resolveTaskId(taskId);
    _events.add(
      MediaTaskAvailabilityEvent(
        taskId: id,
        kind: kind,
        referenceCount: _references[id] ?? 0,
        exclusive: isExclusive(id),
        canDelete: canDelete(id),
      ),
    );
  }

  @override
  void retain(String taskId) {
    super.retain(taskId);
    final id = resolveTaskId(taskId);
    _references[id] = (_references[id] ?? 0) + 1;
    _emit(id, MediaTaskAvailabilityEventKind.retained);
  }

  @override
  void release(String taskId) {
    super.release(taskId);
    final id = resolveTaskId(taskId);
    final count = (_references[id] ?? 0) - 1;
    if (count <= 0) {
      _references.remove(id);
    } else {
      _references[id] = count;
    }
    _emit(id, MediaTaskAvailabilityEventKind.released);
  }

  @override
  void acquireExclusive(String taskId) {
    super.acquireExclusive(taskId);
    _emit(taskId, MediaTaskAvailabilityEventKind.exclusiveAcquired);
  }

  @override
  void releaseExclusive(String taskId) {
    super.releaseExclusive(taskId);
    _emit(taskId, MediaTaskAvailabilityEventKind.exclusiveReleased);
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

enum MediaExportJobState { queued, waiting, running, retrying, failed }

class MediaExportRequest {
  const MediaExportRequest({
    required this.task,
    required this.deliverToConfiguredDirectory,
    required this.forceRegenerate,
    this.preparedArtifact,
  });

  final MediaTask task;
  final bool deliverToConfiguredDirectory;
  final bool forceRegenerate;
  final MediaArtifact? preparedArtifact;
}

/// An expected ownership conflict, including one acquired during preparation.
/// No retry budget or error log is consumed while waiting for that owner.
class MediaExportDeferred implements Exception {
  const MediaExportDeferred({this.preparedArtifact});
  final MediaArtifact? preparedArtifact;
}

class MediaExportJobSnapshot {
  const MediaExportJobSnapshot(this.taskId, this.state, this.attempts);
  final String taskId;
  final MediaExportJobState state;
  final int attempts;
}

typedef MediaExportExecutor = Future<MediaArtifact> Function(
  MediaExportRequest request,
);

/// A single export worker, independent of the page that requested the export.
/// Only IDs, options and retry state are persisted; files and leases stay with
/// their existing owners. Successful jobs are removed, failed jobs stay inert
/// until an explicit manual retry.
class MediaExportQueue extends ChangeNotifier {
  MediaExportQueue({
    required this.tasks,
    required this.execute,
    this.db,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 4)],
    this.availabilityPollInterval = const Duration(seconds: 2),
    this.onError,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    tasks.addListener(wake);
    if (tasks is ExportNotifyingMediaTaskStore) {
      _availabilitySubscription = (tasks as ExportNotifyingMediaTaskStore)
          .availabilityEvents
          .listen((_) => wake());
    }
  }

  final MediaTaskStore tasks;
  final AppDatabase? db;
  final MediaExportExecutor execute;
  final List<Duration> retryDelays;
  final Duration availabilityPollInterval;
  final void Function(String taskId, Object error, StackTrace stack)? onError;
  final DateTime Function() _now;
  final _jobs = <String, _ExportJob>{};
  StreamSubscription<MediaTaskAvailabilityEvent>? _availabilitySubscription;
  Future<void>? _restoring;
  Future<void>? _running;
  final _accepting = <Future<void>>{};
  Timer? _timer;
  bool _restored = false;
  bool _closed = false;
  bool _wakeAgain = false;

  List<MediaExportJobSnapshot> get jobs => List.unmodifiable(
    _jobs.values.map(
      (job) => MediaExportJobSnapshot(job.taskId, job.state, job.attempts),
    ),
  );

  Future<void> restore() async {
    if (_closed || _restored) return;
    final current = _restoring;
    if (current != null) return current;
    final run = _restore();
    _restoring = run;
    try {
      await run;
    } finally {
      _restoring = null;
    }
  }

  Future<void> _restore() async {
    await tasks.ready;
    final rows = await db?.mediaExportJobs() ?? const [];
    if (_closed) return;
    for (final row in rows) {
      final id = row['task_id']! as String;
      if (tasks.task(id) == null) {
        await db?.deleteMediaExportJob(id);
        continue;
      }
      final job = _ExportJob(
        taskId: id,
        deliver: row['deliver_to_directory'] == 1,
        force: row['force_regenerate'] == 1,
        nextAttempt: DateTime.parse(row['next_attempt_at']! as String),
      )..attempts = row['attempts']! as int;
      if (row['state'] == MediaExportJobState.failed.name ||
          job.attempts > retryDelays.length) {
        job.state = MediaExportJobState.failed;
      }
      _jobs[id] = job;
    }
    _restored = true;
    _notify();
    wake();
  }

  /// Completion callbacks only wait for durable acceptance, never playback.
  Future<void> enqueueAutomatic(String taskId) => _accept(
    taskId,
    deliver: true,
    force: false,
    manual: false,
  ).then<void>((_) {});

  Future<MediaArtifact> export(
    String taskId, {
    bool deliverToConfiguredDirectory = true,
    bool forceRegenerate = false,
  }) async {
    final job = await _accept(
      taskId,
      deliver: deliverToConfiguredDirectory,
      force: forceRegenerate,
      manual: true,
    );
    return job.result.future;
  }

  Future<_ExportJob> _accept(
    String taskId, {
    required bool deliver,
    required bool force,
    required bool manual,
  }) async {
    final accepted = Completer<void>();
    _accepting.add(accepted.future);
    try {
      await restore();
      if (_closed) throw StateError('媒体导出队列已关闭');
      await tasks.ready;
      await tasks.flush(taskId);
      if (_closed) throw StateError('媒体导出队列已关闭');
      final id = tasks.resolveTaskId(taskId);
      if (tasks.task(id) == null) throw StateError('媒体任务不存在');
      var job = _jobs[id];
      if (job == null || (manual && job.state == MediaExportJobState.failed)) {
        job = _ExportJob(
          taskId: id,
          deliver: deliver,
          force: force,
          nextAttempt: _now(),
        );
        _jobs[id] = job;
      } else {
        if (force && !job.force) job.preparedArtifact = null;
        job.deliver |= deliver;
        job.force |= force;
      }
      // Serialization through the worker is not needed for the in-memory
      // merge: it occurs before the first await. Persist the merged options.
      await _persist(job);
      _notify();
      wake();
      return job;
    } finally {
      accepted.complete();
      _accepting.remove(accepted.future);
    }
  }

  void wake() {
    if (_closed || !_restored) return;
    _timer?.cancel();
    _timer = null;
    if (_running != null) {
      _wakeAgain = true;
      return;
    }
    // A microtask prevents a release callback from re-entering its owner.
    _running = Future<void>.microtask(_drain).whenComplete(() {
      _running = null;
      if (_closed) return;
      if (_wakeAgain) {
        _wakeAgain = false;
        wake();
      } else {
        _schedule();
      }
    });
    unawaited(
      _running!.catchError((Object error, StackTrace stack) {
        onError?.call('queue', error, stack);
      }),
    );
  }

  Future<void> _drain() async {
    for (final job in _jobs.values.toList()) {
      if (_closed) return;
      if (job.state == MediaExportJobState.failed ||
          job.nextAttempt.isAfter(_now())) {
        continue;
      }
      final task = tasks.task(job.taskId);
      if (task == null) {
        await db?.deleteMediaExportJob(job.taskId);
        _jobs.remove(job.taskId);
        if (!job.result.isCompleted) {
          job.result.completeError(StateError('媒体任务不存在'));
        }
        _notify();
        continue;
      }
      if (!tasks.available || !tasks.canDelete(job.taskId)) {
        job.state = MediaExportJobState.waiting;
        await _persist(job);
        _notify();
        continue;
      }
      final deliver = job.deliver;
      final force = job.force;
      job.state = MediaExportJobState.running;
      job.attempts++;
      await _persist(job);
      _notify();
      try {
        final artifact = await execute(
          MediaExportRequest(
            task: task,
            deliverToConfiguredDirectory: deliver,
            forceRegenerate: force,
            preparedArtifact: job.preparedArtifact,
          ),
        );
        // A stronger request arriving during a run joins the same result.
        if (job.force != force || job.deliver != deliver) {
          job.preparedArtifact = job.force != force ? null : artifact;
          job.state = MediaExportJobState.queued;
          job.attempts--;
          await _persist(job);
          _wakeAgain = true;
          continue;
        }
        await db?.deleteMediaExportJob(job.taskId);
        _jobs.remove(job.taskId);
        if (!job.result.isCompleted) job.result.complete(artifact);
      } on MediaExportDeferred catch (deferred) {
        job.attempts--;
        job.state = MediaExportJobState.waiting;
        job.preparedArtifact = deferred.preparedArtifact;
        await _persist(job);
      } catch (error, stack) {
        final terminal = job.attempts > retryDelays.length;
        job.state = terminal
            ? MediaExportJobState.failed
            : MediaExportJobState.retrying;
        if (!terminal) {
          job.nextAttempt = _now().add(retryDelays[job.attempts - 1]);
        }
        // Exception text can contain paths or signed URLs; persist a code.
        await _persist(job, lastError: 'export_failed');
        if (terminal) {
          if (!job.result.isCompleted) job.result.completeError(error, stack);
          onError?.call(job.taskId, error, stack);
        }
      }
      _notify();
    }
  }

  Future<void> _persist(_ExportJob job, {String? lastError}) async {
    await db?.saveMediaExportJob(
      taskId: job.taskId,
      deliverToDirectory: job.deliver,
      forceRegenerate: job.force,
      attempts: job.attempts,
      state: job.state.name,
      nextAttemptAt: job.nextAttempt,
      lastError: lastError,
    );
  }

  void _schedule() {
    Duration? delay;
    for (final job in _jobs.values) {
      if (job.state == MediaExportJobState.failed) continue;
      var next = job.nextAttempt.difference(_now());
      if (next.isNegative || next == Duration.zero) {
        next = availabilityPollInterval;
      }
      if (delay == null || next < delay) delay = next;
    }
    if (delay != null) _timer = Timer(delay, wake);
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  /// Stops scheduling and waits for an active writer. Pending rows remain
  /// durable; only this process's waiting callers are cancelled.
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _timer?.cancel();
      tasks.removeListener(wake);
      await _availabilitySubscription?.cancel();
      for (final job in _jobs.values) {
        if (!job.result.isCompleted) {
          job.result.completeError(StateError('媒体导出队列已关闭，作业已保留'));
        }
      }
    }
    await _restoring;
    await Future.wait(_accepting.toList());
    await _running;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

class _ExportJob {
  _ExportJob({
    required this.taskId,
    required this.deliver,
    required this.force,
    required this.nextAttempt,
  }) {
    // Automatic jobs have no caller waiting for completion.
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final String taskId;
  bool deliver;
  bool force;
  int attempts = 0;
  DateTime nextAttempt;
  MediaExportJobState state = MediaExportJobState.queued;
  MediaArtifact? preparedArtifact;
  final result = Completer<MediaArtifact>();
}
