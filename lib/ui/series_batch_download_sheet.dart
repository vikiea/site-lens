import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/site_adapter.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'series_batch_download.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

/// 批量下载: pick several 选集 of one 剧集, watch the batch as a whole, and
/// repair only what failed.
///
/// The sheet is a view over [SeriesBatchDownloadStore]. It owns no download
/// state of its own: the selection, the rows and their phases live in the
/// store, so closing and reopening the sheet never loses a running batch, and
/// the detail page underneath refreshes from the same store.
///
/// Playback sits beside the batch and never inside it. The play action asks the
/// page to play one candidate; the download of that same episode keeps running
/// (ADR-0005: a download never switches the playing `MediaItem`).
class SeriesBatchDownloadSheet extends StatefulWidget {
  const SeriesBatchDownloadSheet({
    super.key,
    required this.store,
    required this.onPlay,
    required this.onChanged,
    this.onResniff,
    this.refreshInterval = const Duration(milliseconds: 400),
  });

  final SeriesBatchDownloadStore store;

  /// Plays one candidate of an episode. The batch is untouched.
  final Future<void> Function(MediaCandidate candidate) onPlay;

  /// Called after any store change the page may want to mirror.
  final VoidCallback? onChanged;

  final VoidCallback? onResniff;

  /// How often the sheet re-reads the durable tasks while it is open.
  final Duration refreshInterval;

  @override
  State<SeriesBatchDownloadSheet> createState() =>
      _SeriesBatchDownloadSheetState();
}

class _SeriesBatchDownloadSheetState extends State<SeriesBatchDownloadSheet> {
  Timer? _poller;
  bool _starting = false;

  SeriesBatchDownloadStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_storeChanged);
    _poller = Timer.periodic(widget.refreshInterval, (_) {
      if (mounted) _store.syncFromTasks();
    });
  }

  @override
  void didUpdateWidget(covariant SeriesBatchDownloadSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_storeChanged);
      widget.store.addListener(_storeChanged);
    }
  }

  @override
  void dispose() {
    // The poller is the sheet's only long-lived resource: cancel it before the
    // listener so a timer tick never reaches a disposed state.
    _poller?.cancel();
    _poller = null;
    _store.removeListener(_storeChanged);
    super.dispose();
  }

  void _storeChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _start() async {
    if (_starting || _store.selectedCount == 0) return;
    setState(() => _starting = true);
    final started = await _store.startSelection();
    if (!mounted) return;
    setState(() => _starting = false);
    final notice = started.notice;
    if (notice != null) showShortToast(context, notice);
  }

  @override
  Widget build(BuildContext context) {
    final job = _store.job;
    final height = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      child: SiteLensPanel(
        padding: EdgeInsets.zero,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(),
              const SiteLensPanelDivider(),
              if (job == null)
                Expanded(child: _selectionList())
              else
                Expanded(child: _batchList(job)),
              _footer(job),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final title = _store.episodes.isEmpty
        ? '按选集下载'
        : _store.episodes.first.title;
    return ListTile(
      title: SiteLensLeadingEllipsisText(title),
      subtitle: Text(_store.selectionLabel, key: const Key('batch-selection')),
      leading: const Icon(Icons.download_for_offline_outlined),
      trailing: widget.onResniff == null
          ? null
          : TextButton(onPressed: widget.onResniff, child: const Text('重新嗅探')),
    );
  }

  Widget _selectionList() {
    if (_store.episodes.isEmpty) {
      return const Center(child: Text('当前剧集没有可确认集数的选集'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: _store.episodes.length,
      separatorBuilder: (_, _) => const SiteLensPanelDivider(),
      itemBuilder: (context, index) {
        final episode = _store.episodes[index];
        final selected = _store.isSelected(episode.position);
        return Theme(
          data: siteLensQuietInteractionTheme(context),
          child: CheckboxListTile(
            key: ValueKey('batch-episode-${episode.position}'),
            value: selected,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: SiteLensLeadingEllipsisText(episode.title),
            subtitle: episode.durationMs == null
                ? null
                : Text(formatMediaDuration(episode.durationMs!)),
            onChanged: (_) => _store.toggle(episode),
          ),
        );
      },
    );
  }

  Widget _batchList(SeriesBatchDownloadJob job) {
    final rows = <Widget>[
      _progressCard(job),
      for (final item in job.items) ...[
        const SiteLensPanelDivider(),
        _itemRow(item),
      ],
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      children: rows,
    );
  }

  Widget _progressCard(SeriesBatchDownloadJob job) {
    final settled = job.total == 0 ? 0.0 : (job.done + job.failed) / job.total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SiteLensRowText(
            '整体进度 ${job.done + job.failed} / ${job.total} ${job.unit}',
            key: const Key('batch-progress'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: settled),
          ),
          const SizedBox(height: 6),
          Text(
            [
              '完成 ${job.done}',
              if (job.running > 0) '下载中 ${job.running}',
              if (job.queued > 0) '等待 ${job.queued}',
              if (job.failed > 0) '失败 ${job.failed}',
              if (job.bytesOnDisk > 0) '已占用 ${formatBytes(job.bytesOnDisk)}',
            ].join(' · '),
            key: const Key('batch-summary'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _itemRow(SeriesBatchDownloadItem item) {
    final failed = item.isFailed;
    return SiteLensCompactRow(
      key: ValueKey('batch-row-${item.position}'),
      leading: Icon(switch (item.phase) {
        SeriesBatchItemPhase.done => Icons.check_circle_outline,
        SeriesBatchItemPhase.failed => Icons.error_outline,
        SeriesBatchItemPhase.running => Icons.downloading,
        SeriesBatchItemPhase.queued => Icons.schedule,
      }, size: SiteLensMetrics.compactIconSize),
      title: Text(item.title),
      subtitle: Text(_itemCaption(item)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failed)
            IconButton(
              tooltip: '重试这一集',
              icon: const Icon(Icons.replay),
              onPressed: () => _store.retryItem(item.position),
            ),
          if (item.taskId != null)
            IconButton(
              tooltip: '删除这一集的下载',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(item),
            ),
          IconButton(
            tooltip: '播放这一集',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => _play(item),
          ),
        ],
      ),
    );
  }

  String _itemCaption(SeriesBatchDownloadItem item) {
    final message = item.message?.trim();
    if (message != null && message.isNotEmpty) return message;
    return switch (item.phase) {
      SeriesBatchItemPhase.done => '已完成',
      SeriesBatchItemPhase.failed => '失败',
      SeriesBatchItemPhase.running =>
        item.bytesOnDisk > 0 ? '下载中 · ${formatBytes(item.bytesOnDisk)}' : '下载中',
      SeriesBatchItemPhase.queued => '等待下载',
    };
  }

  /// Plays the episode's own candidate without touching its download.
  ///
  /// The candidate is resolved from the same line the batch used; nothing here
  /// pauses, cancels or re-points the transfer, so the remote play and the
  /// download of one episode run side by side.
  Future<void> _play(SeriesBatchDownloadItem item) async {
    final resolver = _store.resolver;
    if (resolver == null) {
      showShortToast(context, '这一集没有可播放的线路');
      return;
    }
    final cancel = CancellationSignal();
    try {
      final candidate = await resolver.candidateFor(item.episodeNumber, cancel);
      if (!mounted) return;
      if (candidate == null) {
        showShortToast(context, '这一集没有可播放的线路');
        return;
      }
      await widget.onPlay(candidate);
    } on SiteAdapterError catch (error) {
      if (mounted) showShortToast(context, error.message);
    } finally {
      cancel.cancel();
    }
  }

  Future<void> _confirmDelete(SeriesBatchDownloadItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SiteLensAlertDialog(
        title: const Text('删除这一集的下载'),
        content: Text('只删除「${item.title}」的下载，其他集不受影响。正在播放或导出时请先停止。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await _store.deleteEpisode(item.episodeNumber);
    if (!mounted) return;
    // 删不掉时要说出这一行自己的原因，不能吞成"没有可删除的下载"。
    final reason = _store.job?.items
        .firstWhere(
          (row) => row.episodeNumber == item.episodeNumber,
          orElse: () => item,
        )
        .message
        ?.trim();
    showShortToast(
      context,
      removed > 0
          ? '已删除这一集的下载'
          : (reason?.isNotEmpty ?? false)
          ? reason!
          : '这一集没有可删除的下载',
    );
  }

  Widget _footer(SeriesBatchDownloadJob? job) {
    final selected = _store.selectedCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          TextButton(
            onPressed: _store.episodes.isEmpty || _store.busy
                ? null
                : () => _store.selectAll(),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _store.busy ? null : _store.clearSelection,
            child: const Text('清空'),
          ),
          const Spacer(),
          FilledButton.icon(
            key: const Key('batch-start'),
            onPressed: selected == 0 || _starting || _store.busy
                ? null
                : _start,
            icon: const Icon(Icons.download),
            label: Text(
              job != null && !job.settled
                  ? '重新入队 $selected 集'
                  : '下载 $selected 集',
            ),
          ),
        ],
      ),
    );
  }
}
