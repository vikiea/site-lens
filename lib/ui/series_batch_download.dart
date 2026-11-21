import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/site_adapter.dart';
import '../media/media_service.dart';
import 'app_controller.dart';
import 'series_batch_download_resolver.dart';
import 'ui_util.dart';

/// One 剧集 episode as the detail page's batch selection sees it.
///
/// The selection is keyed by [position] — the episode's place in the catalog —
/// because the detail page may list one episode number twice, while a line is
/// resolved per episode number. Two rows that share a number therefore stay
/// two independent selections instead of sharing one line lookup.
class SeriesBatchEpisode {
  const SeriesBatchEpisode({
    required this.position,
    required this.episodeNumber,
    required this.title,
    this.durationMs,
  });

  final int position;
  final int episodeNumber;
  final String title;
  final int? durationMs;
}

/// What one member of an enqueued batch is doing right now.
///
/// [queued] means the episode is selected but its task has not started yet, so
/// overall progress has a third count that is neither done nor failed.
enum SeriesBatchItemPhase { queued, running, failed, done }

/// One episode of a batch, with everything the sheet has to say about it.
class SeriesBatchDownloadItem {
  const SeriesBatchDownloadItem({
    required this.position,
    required this.episodeNumber,
    required this.title,
    required this.phase,
    this.taskId,
    this.message,
    this.bytesOnDisk = 0,
  });

  final int position;
  final int episodeNumber;
  final String title;
  final SeriesBatchItemPhase phase;

  /// Durable download task once one exists.
  final String? taskId;

  /// Why this row failed or was skipped. Null while it is fine.
  final String? message;

  final int bytesOnDisk;

  bool get isFailed => phase == SeriesBatchItemPhase.failed;

  SeriesBatchDownloadItem copyWith({
    SeriesBatchItemPhase? phase,
    String? taskId,
    String? message,
    int? bytesOnDisk,
    bool clearMessage = false,
  }) => SeriesBatchDownloadItem(
    position: position,
    episodeNumber: episodeNumber,
    title: title,
    phase: phase ?? this.phase,
    taskId: taskId ?? this.taskId,
    message: clearMessage ? null : message ?? this.message,
    bytesOnDisk: bytesOnDisk ?? this.bytesOnDisk,
  );
}

/// The observable state of the **current** batch on one series.
///
/// A new batch replaces the previous one; a single retry replaces only its own
/// row and keeps every other row, which is what “单独重试失败项” needs.
class SeriesBatchDownloadJob {
  SeriesBatchDownloadJob({
    required this.seriesKey,
    required this.adapterId,
    required this.batchDirectory,
    required List<SeriesBatchDownloadItem> items,
  }) : items = List.unmodifiable(items);

  final String seriesKey;
  final String adapterId;

  /// The task group every episode of this batch is downloaded into. Empty when
  /// the series could not be named; nothing is enqueued then.
  final String batchDirectory;

  final List<SeriesBatchDownloadItem> items;

  int get total => items.length;

  int get done =>
      items.where((item) => item.phase == SeriesBatchItemPhase.done).length;

  int get failed =>
      items.where((item) => item.phase == SeriesBatchItemPhase.failed).length;

  int get running =>
      items.where((item) => item.phase == SeriesBatchItemPhase.running).length;

  int get queued =>
      items.where((item) => item.phase == SeriesBatchItemPhase.queued).length;

  bool get settled => queued == 0 && running == 0;

  /// The unit every count above is expressed in: episodes, never files.
  String get unit => '集';

  int get bytesOnDisk => items.fold(0, (sum, item) => sum + item.bytesOnDisk);

  SeriesBatchDownloadItem? itemAt(int position) {
    for (final item in items) {
      if (item.position == position) return item;
    }
    return null;
  }

  SeriesBatchDownloadJob replacing(SeriesBatchDownloadItem item) =>
      SeriesBatchDownloadJob(
        seriesKey: seriesKey,
        adapterId: adapterId,
        batchDirectory: batchDirectory,
        items: [
          for (final row in items) row.position == item.position ? item : row,
        ],
      );

  SeriesBatchDownloadJob without(Iterable<int> positions) {
    final drop = positions.toSet();
    return SeriesBatchDownloadJob(
      seriesKey: seriesKey,
      adapterId: adapterId,
      batchDirectory: batchDirectory,
      items: [
        for (final row in items)
          if (!drop.contains(row.position)) row,
      ],
    );
  }
}

/// The batch that started, or why none did.
class SeriesBatchStart {
  const SeriesBatchStart(this.job, {this.notice});

  final SeriesBatchDownloadJob job;

  /// A problem with the batch as a whole — a nameless series, a selection with
  /// nothing left to enqueue. Row-level problems live on the rows.
  final String? notice;
}

/// 批量下载 for one 剧集: the selection model the detail page and its sheet both
/// read, and the executor that turns it into durable download tasks.
///
/// Two rules decide everything here.
///
/// **下载是独立动作.** Each episode becomes its own `MediaTask` with the batch
/// as its `batchDirectory`, so a batch is a set of independent downloads that
/// happen to share one folder. Playback never goes through this class: the
/// sheet only asks the page to play a candidate, which keeps ADR-0005's
/// “播放途中下载不切本地” intact. Reading a task's state here never pauses,
/// cancels or rewrites it, so a remote play and a download of the same episode
/// coexist: the play keeps its `MediaItem`, the download keeps its bytes.
///
/// **删一集只动一集.** [deleteEpisode] acts on the task rows whose episode
/// number matches, never on the shared directory, so neighbours and their bytes
/// stay where they are.
class SeriesBatchDownloadStore extends ChangeNotifier {
  SeriesBatchDownloadStore({
    required this.app,
    required this.seriesKey,
    required this.adapterId,
    this.resolver,
  });

  final AppController app;
  final String seriesKey;
  final String adapterId;

  /// Resolves episode → candidate and names the batch folder. A store without
  /// one reports every row as unresolvable instead of guessing.
  final SeriesBatchDownloadResolver? resolver;

  /// Starts one batch of prepared requests. Production uses
  /// `MediaDownloadService.startNativeBatch`; a test can replace the start so
  /// the enqueue, the folder and the per-row bookkeeping still run for real.
  Future<MediaBatchDownloadResult> Function(
    Iterable<MediaBatchDownloadRequest> requests,
  )?
  startBatch;

  Future<MediaBatchDownloadResult> _runStart(
    List<MediaBatchDownloadRequest> pending,
  ) => (startBatch ?? app.mediaDownloads.startNativeBatch)(pending);

  final Map<int, SeriesBatchDownloadItem> _selection = {};
  final Map<int, _BatchRow> _rows = {};

  SeriesBatchDownloadJob? _job;
  SeriesBatchDownloadJob? get job => _job;

  /// A problem with the last batch-level action, for the sheet's notice line.
  String? notice;

  /// The catalog this selection navigates; replaced whenever the page reloads
  /// the episodes.
  List<SeriesBatchEpisode> episodes = const [];

  int get selectedCount => _selection.length;

  bool isSelected(int position) => _selection.containsKey(position);

  /// “已选 N / 共 M 集” — N is the selection, M the catalog size.
  String get selectionLabel => '已选 $selectedCount / ${episodes.length} 集';

  List<SeriesBatchEpisode> get selectedEpisodes => [
    for (final entry in _rows.entries)
      if (_selection.containsKey(entry.key))
        SeriesBatchEpisode(
          position: entry.key,
          episodeNumber: entry.value.episodeNumber,
          title: entry.value.title,
          durationMs: entry.value.durationMs,
        ),
  ]..sort((left, right) => left.position.compareTo(right.position));

  /// Replaces the catalog. A selection keeps the episodes still listed and
  /// drops the ones that disappeared, so a reload never enqueues a row the
  /// sheet can no longer show.
  void setEpisodes(List<SeriesBatchEpisode> next) {
    episodes = List.unmodifiable(next);
    final byPosition = {for (final episode in next) episode.position: episode};
    for (final position in _rows.keys.toList()) {
      final episode = byPosition[position];
      if (episode == null) {
        _rows.remove(position);
        _selection.remove(position);
        continue;
      }
      _rows[position] = _rows[position]!.relabelled(episode);
    }
    notifyListeners();
  }

  void select(SeriesBatchEpisode episode) {
    _rows[episode.position] = _BatchRow(
      episodeNumber: episode.episodeNumber,
      title: episode.title,
      durationMs: episode.durationMs,
    );
    _selection[episode.position] = SeriesBatchDownloadItem(
      position: episode.position,
      episodeNumber: episode.episodeNumber,
      title: episode.title,
      phase: SeriesBatchItemPhase.queued,
    );
    notifyListeners();
  }

  void deselect(int position) {
    _selection.remove(position);
    notifyListeners();
  }

  void toggle(SeriesBatchEpisode episode) {
    if (_selection.containsKey(episode.position)) {
      deselect(episode.position);
    } else {
      select(episode);
    }
  }

  void selectAll() {
    for (final episode in List<SeriesBatchEpisode>.of(episodes)) {
      select(episode);
    }
  }

  void clearSelection() {
    _selection.clear();
    notifyListeners();
  }

  /// Queues the current selection as one batch and returns it.
  ///
  /// Lines and candidates are read only now: the sheet is opened from the
  /// detail page without touching the network, and a batch of thirty episodes
  /// must not make thirty line requests while the user is still picking.
  ///
  /// Every episode then takes the same three-step path a single download uses:
  /// `create` (a durable task in the batch directory) →
  /// `hasPlayableEpisodeInGroup` (an exported or finished file already answers
  /// it) → `startNativeBatch` (resume-aware start, shared scheduler). Rows that
  /// fail keep a reason instead of aborting the batch.
  Future<SeriesBatchStart> startSelection() async {
    final selection = selectedEpisodes;
    final resolver = this.resolver;
    if (selection.isEmpty) {
      return _batchFails(const [], '先选集再下载');
    }
    if (resolver == null) return _batchFails(selection, '没有可用的站点适配器');
    _opening = true;
    _clearNotice();
    final named = await _nameBatch(selection, resolver);
    if (named.batchDirectory == null) {
      _opening = false;
      return _batchFails(selection, '没有取到剧名，无法创建下载目录');
    }
    final directory = named.batchDirectory!;
    _job = SeriesBatchDownloadJob(
      seriesKey: seriesKey,
      adapterId: adapterId,
      batchDirectory: directory,
      items: [
        for (final episode in selection)
          _item(episode, SeriesBatchItemPhase.queued),
      ],
    );
    _notify();
    final pending = <MediaBatchDownloadRequest>[];
    final cancel = CancellationSignal();
    try {
      for (final episode in selection) {
        // 命名时已经解析过一次，这里直接用那一份：一次批量不该为同一集
        // 向适配器往返两次（三十集就是六十次页面读取）。
        final candidate = named.candidates[episode.position];
        if (candidate == null) {
          _fail(episode.position, '这条线路没有给出可下载的清晰度');
          continue;
        }
        final request = await _enqueue(episode.position, candidate, directory);
        if (request != null) pending.add(request);
      }
    } finally {
      cancel.cancel();
    }
    await _start(pending);
    _opening = false;
    return SeriesBatchStart(_job ?? _emptyJob(directory));
  }

  /// Retries one failed row without touching the others.
  ///
  /// The row is rebuilt from scratch — candidate, task, start — so a retry
  /// repairs a row whose failure happened before a task existed. Siblings keep
  /// their phase, their task and their bytes.
  Future<void> retryItem(int position) async {
    final resolver = this.resolver;
    final job = _job;
    final row = _rows[position];
    if (resolver == null || job == null || row == null) return;
    if (_busy.contains(position)) return;
    _busy.add(position);
    _job = job.replacing(
      job
              .itemAt(position)
              ?.copyWith(
                phase: SeriesBatchItemPhase.running,
                clearMessage: true,
              ) ??
          SeriesBatchDownloadItem(
            position: position,
            episodeNumber: row.episodeNumber,
            title: row.title,
            phase: SeriesBatchItemPhase.running,
          ),
    );
    _notify();
    final cancel = CancellationSignal();
    try {
      final candidate = await _resolve(
        resolver,
        SeriesBatchEpisode(
          position: position,
          episodeNumber: row.episodeNumber,
          title: row.title,
          durationMs: row.durationMs,
        ),
        cancel,
      );
      if (candidate == null) {
        _fail(position, '这条线路没有给出可下载的清晰度');
        return;
      }
      final request = await _enqueue(position, candidate, job.batchDirectory);
      if (request != null) await _start([request]);
    } finally {
      cancel.cancel();
      _busy.remove(position);
    }
  }

  /// Deletes the download of exactly one episode.
  ///
  /// Every task of this batch with that episode number is deleted through
  /// [AppController.deleteMediaTask], which holds the file leases and removes
  /// only that task's own cache. The shared batch directory is never deleted
  /// here: it still holds the neighbours, and a folder emptied by a user delete
  /// belongs to whoever exported into it.
  ///
  /// Returns how many task rows were removed.
  Future<int> deleteEpisode(int episodeNumber) async {
    final positions = _positionsForEpisode(episodeNumber);
    final targets = <String>{
      for (final position in positions) ?_job?.itemAt(position)?.taskId,
      for (final position in positions) ?_rows[position]?.taskId,
      // 行与 job 都还没来得及回填 taskId 时（例如启动批次还没回来），
      // 按「批次目录 + 集号」直接找那一集自己的任务，邻居不受影响。
      for (final task in app.mediaTasks.tasks)
        if (_job != null &&
            task.batchDirectory == _job!.batchDirectory &&
            task.episodeNumber == episodeNumber)
          task.id,
    };
    var removed = 0;
    for (final id in targets) {
      final task = app.mediaTasks.task(id);
      if (task == null) continue;
      if (!app.mediaTasks.canDelete(id)) {
        // 只有确实有引用或排他操作时才是"正在播放、导出或投屏"。
        _fail(
          _positionForTask(id) ?? positions.firstOrNull ?? 0,
          '这一集正在播放、导出或投屏，先停止再删除',
        );
        continue;
      }
      try {
        await app.deleteMediaTask(id);
        removed++;
      } catch (error) {
        // 失败要落到这一集自己的行上；原因原样保留，方便用户与日志定位。
        _fail(
          _positionForTask(id) ?? positions.firstOrNull ?? 0,
          friendlyError(error),
        );
      }
    }
    if (removed > 0) {
      for (final position in positions) {
        _selection.remove(position);
      }
      _job = _job?.without(positions);
      _notify();
    }
    return removed;
  }

  /// Re-reads the durable tasks and moves the rows to their current phase.
  ///
  /// The sheet calls this while it is open. Nothing here starts or stops a
  /// transfer: a completed row is finished, a failed row keeps its reason, and
  /// a downloading row keeps its bytes — the partial playback of that same
  /// episode is untouched by this poll.
  void syncFromTasks() {
    final job = _job;
    if (job == null) return;
    var next = job;
    var changed = false;
    for (final item in job.items) {
      final id = item.taskId;
      if (id == null) continue;
      final task = app.mediaTasks.task(id);
      if (task == null) continue;
      final phase = _phaseOf(task.state);
      if (phase == item.phase && task.bytesDownloaded == item.bytesOnDisk) {
        continue;
      }
      next = next.replacing(
        item.copyWith(
          phase: phase,
          bytesOnDisk: task.bytesDownloaded,
          message: phase == SeriesBatchItemPhase.failed
              ? task.errorReason ?? item.message
              : item.message,
          clearMessage: phase != SeriesBatchItemPhase.failed,
        ),
      );
      changed = true;
    }
    if (!changed) return;
    _job = next;
    _notify();
  }

  /// True while a batch is being resolved and enqueued. The sheet disables its
  /// buttons then instead of letting two batches race on one folder.
  bool get busy => _opening || _busy.isNotEmpty;

  bool _opening = false;
  final _busy = <int>{};

  static SeriesBatchItemPhase _phaseOf(MediaTaskState state) => switch (state) {
    MediaTaskState.completed ||
    MediaTaskState.playable => SeriesBatchItemPhase.done,
    MediaTaskState.failed ||
    MediaTaskState.reauthorize ||
    MediaTaskState.cancelled => SeriesBatchItemPhase.failed,
    MediaTaskState.queued => SeriesBatchItemPhase.queued,
    MediaTaskState.downloading ||
    MediaTaskState.paused => SeriesBatchItemPhase.running,
  };

  Future<
    ({
      String? batchDirectory,
      bool fallback,
      Map<int, MediaCandidate> candidates,
    })
  >
  _nameBatch(
    List<SeriesBatchEpisode> selection,
    SeriesBatchDownloadResolver resolver,
  ) async {
    final known = <MediaCandidate>[];
    final resolved = <int, MediaCandidate>{};
    final cancel = CancellationSignal();
    try {
      for (final episode in selection) {
        final candidate = await _resolve(resolver, episode, cancel);
        if (candidate == null) continue;
        known.add(candidate);
        // 按目录位置记账，和选集模型一致；一集解析失败只影响它自己那行。
        resolved[episode.position] = candidate;
      }
    } finally {
      cancel.cancel();
    }
    final named = await resolver.batchDirectoryFor(selection, known);
    return (
      batchDirectory: named.batchDirectory,
      fallback: named.fallback,
      candidates: resolved,
    );
  }

  Future<MediaCandidate?> _resolve(
    SeriesBatchDownloadResolver resolver,
    SeriesBatchEpisode episode,
    CancellationSignal cancel,
  ) async {
    try {
      return await resolver.candidateFor(episode.episodeNumber, cancel);
    } on SiteAdapterError catch (error) {
      _fail(episode.position, error.message);
      return null;
    }
  }

  /// Creates the durable task for one episode and returns the start request,
  /// or null when the row already failed and nothing should be started.
  Future<MediaBatchDownloadRequest?> _enqueue(
    int position,
    MediaCandidate candidate,
    String directory,
  ) async {
    try {
      if (await app.hasPlayableEpisodeInGroup(
        group: directory,
        candidate: candidate,
      )) {
        _fail(position, '这一集已有可播放文件，未重复下载', phase: SeriesBatchItemPhase.done);
        return null;
      }
      await app.mediaTasks.ready;
      // 直连出口的候选不是从页面授权来的，没有别的地方替它落库；
      // media_tasks.candidate_id 有外键，不先存就入不了队。
      await app.db.saveMediaCandidate(candidate);
      final created = await app.mediaTasks.create(
        candidate,
        batchDirectory: directory,
      );
      final task = app.mediaTasks.task(created.id) ?? created;
      if (task.state == MediaTaskState.failed) {
        _fail(position, task.errorReason ?? '下载任务失败', taskId: task.id);
        return null;
      }
      if (task.state == MediaTaskState.cancelled) {
        _fail(position, '下载任务已取消', taskId: task.id);
        return null;
      }
      _setTask(position, task.id);
      return MediaBatchDownloadRequest(task: task, candidate: candidate);
    } catch (error) {
      _fail(position, friendlyError(error));
      return null;
    }
  }

  Future<void> _start(List<MediaBatchDownloadRequest> pending) async {
    if (pending.isEmpty) {
      _notify();
      return;
    }
    final result = await _runStart(pending);
    for (final item in result.items) {
      final position = _positionForTask(item.request.task.id);
      if (position == null) continue;
      switch (item.outcome) {
        case MediaBatchDownloadOutcome.started:
        case MediaBatchDownloadOutcome.paused:
          _setPhase(position, SeriesBatchItemPhase.running, clearMessage: true);
        case MediaBatchDownloadOutcome.cancelled:
        case MediaBatchDownloadOutcome.failed:
        case MediaBatchDownloadOutcome.reauthorize:
          _fail(position, _outcomeMessage(item), taskId: item.request.task.id);
      }
    }
    _notify();
  }

  static String _outcomeMessage(MediaBatchDownloadItemResult item) =>
      switch (item.outcome) {
        MediaBatchDownloadOutcome.failed =>
          item.error == null ? '下载没有开始' : friendlyError(item.error!),
        MediaBatchDownloadOutcome.cancelled => '下载被取消',
        MediaBatchDownloadOutcome.reauthorize => '需回来源页重新授权',
        MediaBatchDownloadOutcome.paused => '下载已暂停',
        MediaBatchDownloadOutcome.started => '',
      };

  SeriesBatchStart _batchFails(
    List<SeriesBatchEpisode> selection,
    String notice,
  ) {
    final job = SeriesBatchDownloadJob(
      seriesKey: seriesKey,
      adapterId: adapterId,
      batchDirectory: '',
      items: [
        for (final episode in selection)
          _item(episode, SeriesBatchItemPhase.failed, message: notice),
      ],
    );
    _job = job;
    this.notice = notice;
    _notify();
    return SeriesBatchStart(job, notice: notice);
  }

  SeriesBatchDownloadJob _emptyJob(String directory) => SeriesBatchDownloadJob(
    seriesKey: seriesKey,
    adapterId: adapterId,
    batchDirectory: directory,
    items: const [],
  );

  void _clearNotice() {
    notice = null;
  }

  void _notify() => notifyListeners();

  void _setTask(int position, String taskId) {
    final row = _rows[position];
    if (row != null) _rows[position] = row.withTask(taskId);
    final item = _job?.itemAt(position);
    if (item == null) return;
    _job = _job?.replacing(item.copyWith(taskId: taskId));
  }

  void _setPhase(
    int position,
    SeriesBatchItemPhase phase, {
    String? message,
    bool clearMessage = false,
  }) {
    final item = _job?.itemAt(position);
    if (item == null) return;
    _job = _job?.replacing(
      item.copyWith(phase: phase, message: message, clearMessage: clearMessage),
    );
  }

  /// Marks one row with a reason. [phase] defaults to failed; a row that a
  /// finished artifact already answers is reported as [SeriesBatchItemPhase.done]
  /// with the same kind of explanation.
  void _fail(
    int position,
    String message, {
    String? taskId,
    SeriesBatchItemPhase phase = SeriesBatchItemPhase.failed,
  }) {
    final item = _job?.itemAt(position);
    if (item == null) {
      notice = message;
      _notify();
      return;
    }
    _job = _job?.replacing(
      item.copyWith(phase: phase, message: message, taskId: taskId),
    );
    _notify();
  }

  List<int> _positionsForEpisode(int episodeNumber) => [
    for (final entry in _rows.entries)
      if (entry.value.episodeNumber == episodeNumber) entry.key,
  ];

  int? _positionForTask(String taskId) {
    for (final entry in _rows.entries) {
      if (entry.value.taskId == taskId) return entry.key;
    }
    for (final item in _job?.items ?? const <SeriesBatchDownloadItem>[]) {
      if (item.taskId == taskId) return item.position;
    }
    return null;
  }

  SeriesBatchDownloadItem _item(
    SeriesBatchEpisode episode,
    SeriesBatchItemPhase phase, {
    String? message,
    String? taskId,
  }) => SeriesBatchDownloadItem(
    position: episode.position,
    episodeNumber: episode.episodeNumber,
    title: episode.title,
    phase: phase,
    message: message,
    taskId: taskId,
  );
}

class _BatchRow {
  const _BatchRow({
    required this.episodeNumber,
    required this.title,
    required this.durationMs,
    this.taskId,
  });

  final int episodeNumber;
  final String title;
  final int? durationMs;
  final String? taskId;

  _BatchRow withTask(String id) => _BatchRow(
    episodeNumber: episodeNumber,
    title: title,
    durationMs: durationMs,
    taskId: id,
  );

  _BatchRow relabelled(SeriesBatchEpisode episode) => _BatchRow(
    episodeNumber: episode.episodeNumber,
    title: episode.title,
    durationMs: episode.durationMs,
    taskId: taskId,
  );
}
