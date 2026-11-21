import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/site_adapter.dart';
import '../theater/series_line_memory.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

/// 剧集详情: what one 剧集 offers, before anything is played.
///
/// The screen shows the series facts, the 选集 list, and the 线路 the current
/// episode can be obtained through. A line yields 媒体候选 (quality, audio
/// track) and the user picks a **line**, never a candidate — that distinction
/// is fixed by `GLOSSARY.md` and ADR-0002.
///
/// The line choice is remembered per episode through [lineMemory]: switching
/// quality, rebuilding the page or leaving it and coming back keeps the line
/// the user picked. Another episode never inherits it.
///
/// Scope stops at the hand-off. Tapping 播放 or an 选集 hands one 媒体候选 to
/// [onRequestPlay]; what happens next belongs to the player (T11), downloads
/// (T14) and credentials (T4), and none of it lives here.
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.adapter,
    required this.profile,
    required this.series,
    this.lineMemory,
    this.onRequestPlay,
  });

  /// The adapter that owns this series. Its [SiteAdapter.id] scopes the line
  /// memory, so two sites that happen to share a `seriesKey` stay independent.
  final SiteAdapter adapter;

  /// The 站点档案 this catalog came from; only used to name the source.
  final SiteProfile profile;

  /// What 剧场 handed over when the row was tapped.
  final SeriesSummary series;

  /// Where the per-episode line choice lives. Defaults to this page's own
  /// memory, which keeps a single visit consistent; callers that want the
  /// choice to survive leaving the page pass a longer-lived one.
  final SeriesLineMemory? lineMemory;

  /// 播放入口。给了它就「点开就播」：播放按钮进入选中的那一集，选集行直接
  /// 进入那一集。回调拿到的永远是一个**媒体候选**，而不是线路。
  final void Function(MediaCandidate candidate)? onRequestPlay;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  late final SeriesLineMemory _memory = widget.lineMemory ?? SeriesLineMemory();

  CancellationSignal _cancel = CancellationSignal();
  int _request = 0;

  bool _loadingEpisodes = false;
  SiteAdapterError? _episodesFailure;

  /// Catalog order, as the adapter answered. Empty until the adapter answers.
  List<EpisodeSummary> _episodes = const [];

  /// The episode the line area describes. Null until an episode is known.
  int? _episodeNumber;

  bool _loadingLines = false;
  SiteAdapterError? _linesFailure;
  List<Line> _lines = const [];
  String? _lineId;

  bool _loadingCandidates = false;
  SiteAdapterError? _candidatesFailure;
  List<MediaCandidate> _candidates = const [];
  String? _candidateId;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEpisodes());
  }

  @override
  void didUpdateWidget(covariant SeriesDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series.seriesKey != widget.series.seriesKey ||
        oldWidget.adapter.id != widget.adapter.id) {
      _cancel.cancel();
      _cancel = CancellationSignal();
      _episodes = const [];
      _episodeNumber = null;
      _lines = const [];
      _lineId = null;
      _candidates = const [];
      _candidateId = null;
      unawaited(_loadEpisodes());
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  /// 已更新到第几集: the highest episode number the catalog lists, not the
  /// number of entries, because a catalog may skip or reorder entries.
  int? get _latestEpisode {
    int? latest;
    for (final episode in _episodes) {
      if (latest == null || episode.episodeNumber > latest) {
        latest = episode.episodeNumber;
      }
    }
    return latest;
  }

  Future<void> _loadEpisodes() async {
    final ticket = ++_request;
    setState(() {
      _loadingEpisodes = true;
      _episodesFailure = null;
    });
    try {
      final result = await widget.adapter.episodes(
        widget.series.seriesKey,
        _cancel,
      );
      if (!mounted || ticket != _request) return;
      setState(() {
        _loadingEpisodes = false;
        _episodes = result.episodes;
        _episodeNumber = result.episodes.isEmpty
            ? null
            : result.episodes.first.episodeNumber;
      });
      final episode = _episodeNumber;
      if (episode != null) await _loadLines(episode);
    } on SiteAdapterError catch (error) {
      if (!mounted || ticket != _request) return;
      setState(() {
        _loadingEpisodes = false;
        _episodesFailure = error;
      });
    }
  }

  Future<void> _loadLines(int episodeNumber) async {
    final ticket = ++_request;
    setState(() {
      _loadingLines = true;
      _linesFailure = null;
      _lines = const [];
      _lineId = null;
      _candidates = const [];
      _candidateId = null;
    });
    try {
      final lines = await widget.adapter.lines(
        widget.series.seriesKey,
        episodeNumber,
        _cancel,
      );
      if (!mounted || ticket != _request) return;
      final remembered = _memory.resolved(
        widget.adapter.id,
        widget.series.seriesKey,
        episodeNumber,
        lines.map((line) => line.lineId),
      );
      final chosen = remembered ?? (lines.isEmpty ? null : lines.first.lineId);
      setState(() {
        _loadingLines = false;
        _lines = lines;
        _lineId = chosen;
      });
      if (chosen != null) await _loadCandidates(chosen);
    } on SiteAdapterError catch (error) {
      if (!mounted || ticket != _request) return;
      setState(() {
        _loadingLines = false;
        _linesFailure = error;
      });
    }
  }

  Future<void> _loadCandidates(String lineId) async {
    Line? line;
    for (final known in _lines) {
      if (known.lineId == lineId) line = known;
    }
    if (line == null) return;
    final ticket = ++_request;
    setState(() {
      _loadingCandidates = true;
      _candidatesFailure = null;
      _candidates = const [];
      _candidateId = null;
    });
    try {
      final candidates = await widget.adapter.candidates(line, _cancel);
      if (!mounted || ticket != _request) return;
      setState(() {
        _loadingCandidates = false;
        _candidates = candidates;
        _candidateId = candidates.isEmpty ? null : candidates.first.id;
      });
      _deliverPendingPlay();
    } on SiteAdapterError catch (error) {
      if (!mounted || ticket != _request) return;
      setState(() {
        _loadingCandidates = false;
        _candidatesFailure = error;
      });
    }
  }

  Line? get _selectedLine {
    final id = _lineId;
    if (id == null) return null;
    for (final line in _lines) {
      if (line.lineId == id) return line;
    }
    return null;
  }

  MediaCandidate? get _selectedCandidate {
    final id = _candidateId;
    if (id == null) return null;
    for (final candidate in _candidates) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  void _selectEpisode(int episodeNumber) {
    if (episodeNumber == _episodeNumber) return;
    setState(() => _episodeNumber = episodeNumber);
    unawaited(_loadLines(episodeNumber));
  }

  /// 点一集就播这一集：先让线路区跟上，再把这一集的候选交出去。
  ///
  /// 已经有选中的候选就立刻播；还没有（正在取线路）就等它落地再播，期间
  /// 只播一次——重复点同一集不会开两个会话。
  Future<void> _playEpisode(int episodeNumber) async {
    final onRequestPlay = widget.onRequestPlay;
    if (onRequestPlay == null) {
      _selectEpisode(episodeNumber);
      return;
    }
    final pending = _pendingPlay;
    if (pending == episodeNumber) return;
    if (episodeNumber == _episodeNumber) {
      final current = _selectedCandidate;
      if (current != null) {
        onRequestPlay(current);
        return;
      }
      _pendingPlay = episodeNumber;
      return;
    }
    _pendingPlay = episodeNumber;
    _selectEpisode(episodeNumber);
  }

  /// 这一集还没取到候选时记下「落地就要播」，候选一到就兑现。
  int? _pendingPlay;

  void _deliverPendingPlay() {
    final pending = _pendingPlay;
    if (pending == null || pending != _episodeNumber) return;
    final candidate = _selectedCandidate;
    if (candidate == null) return;
    _pendingPlay = null;
    widget.onRequestPlay?.call(candidate);
  }

  void _selectLine(String lineId) {
    final episode = _episodeNumber;
    if (episode == null || lineId == _lineId) return;
    // Remembered before the candidates land: the choice must survive a
    // candidate failure on the line the user just picked.
    _memory.remember(
      widget.adapter.id,
      widget.series.seriesKey,
      episode,
      lineId,
    );
    setState(() => _lineId = lineId);
    unawaited(_loadCandidates(lineId));
  }

  @override
  Widget build(BuildContext context) {
    final episodeCount = widget.series.episodeCount;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('剧集详情')),
      body: SafeArea(
        child: SiteLensGlassGroup(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  SiteLensMetrics.pagePadding,
                  8,
                  SiteLensMetrics.pagePadding,
                  0,
                ),
                sliver: SliverToBoxAdapter(child: _overview(episodeCount)),
              ),
              SliverToBoxAdapter(
                child: SiteLensSectionHeader(
                  title: '选集',
                  subtitle: _episodes.isEmpty
                      ? null
                      : '目录共有 ${_episodes.length} 集',
                ),
              ),
              _episodeList(),
              SliverToBoxAdapter(
                child: SiteLensSectionHeader(
                  title: '线路',
                  subtitle: _lines.isEmpty ? null : '先选线路，清晰度与音轨从这条线路取',
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SiteLensMetrics.pagePadding,
                ),
                sliver: SliverToBoxAdapter(child: _lineSection()),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 28)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overview(int? episodeCount) {
    final summary = widget.series.summary?.trim();
    final latest = _latestEpisode;
    final total = latest ?? episodeCount;
    return SiteLensPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SiteLensRowText(
            widget.series.title,
            style: Theme.of(context).textTheme.titleLarge,
            semanticsLabel: widget.series.title,
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (total != null) '共 $total 集',
              if (latest != null) '已更新到第 $latest 集',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: SiteLensMetrics.formGap),
            Text(summary, style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: SiteLensMetrics.formGap),
          _playEntry(),
        ],
      ),
    );
  }

  /// 播放入口。候选已经就绪时直接播；还在取候选时说清楚在等什么，而不是
  /// 假装已经可以播。
  Widget _playEntry() {
    final candidate = _selectedCandidate;
    final onRequestPlay = widget.onRequestPlay;
    final ready = candidate != null && onRequestPlay != null;
    final episode = _episodeNumber;
    final waiting =
        onRequestPlay != null &&
        !ready &&
        episode != null &&
        _episodesFailure == null &&
        _linesFailure == null &&
        _candidatesFailure == null &&
        (_loadingLines || _loadingCandidates);
    return Row(
      children: [
        FilledButton.icon(
          onPressed: ready
              ? () => onRequestPlay(candidate)
              : waiting
              ? () => unawaited(_playEpisode(episode))
              : () => ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('这一集还没有可播放的候选'))),
          icon: const Icon(Icons.play_arrow),
          label: const Text('播放'),
        ),
        const SizedBox(width: SiteLensMetrics.formGap),
        Flexible(
          child: Text(
            onRequestPlay == null
                ? '播放尚未接入'
                : ready
                ? '播放器拿的是候选'
                : '正在取这一集的候选',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _episodeList() {
    if (_loadingEpisodes && _episodes.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(SiteLensMetrics.pagePadding),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final failure = _episodesFailure;
    if (failure != null && _episodes.isEmpty) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(
          horizontal: SiteLensMetrics.pagePadding,
        ),
        sliver: SliverToBoxAdapter(child: _episodeNotice(failure)),
      );
    }
    if (_episodes.isEmpty) {
      return const SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: SiteLensMetrics.pagePadding),
        sliver: SliverToBoxAdapter(
          child: SiteLensPanel(
            child: SiteLensEmptyState(
              icon: Icons.playlist_remove,
              title: '目录里还没有选集',
              message: '站点没有给出这一部的选集，稍后刷新再看。',
            ),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: SiteLensMetrics.pagePadding,
      ),
      sliver: SliverList.separated(
        itemCount: _episodes.length,
        separatorBuilder: (_, _) =>
            const SizedBox(height: SiteLensMetrics.listGap),
        itemBuilder: (context, index) {
          final episode = _episodes[index];
          return SiteLensPanel(
            padding: EdgeInsets.zero,
            child: SiteLensCompactRow(
              leading: const Icon(
                Icons.subtitles_outlined,
                size: SiteLensMetrics.compactIconSize,
              ),
              title: Text(episode.title),
              subtitle: episode.durationMs == null
                  ? null
                  : Text(formatEpisodeDuration(episode.durationMs!)),
              trailing: episode.episodeNumber == _episodeNumber
                  ? Icon(
                      Icons.check_circle,
                      size: SiteLensMetrics.compactIconSize,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => unawaited(_playEpisode(episode.episodeNumber)),
            ),
          );
        },
      ),
    );
  }

  Widget _episodeNotice(SiteAdapterError failure) => SiteLensNotice(
    tone: SiteLensNoticeTone.warning,
    text: '「${widget.series.title}」的选集没有取到：${failure.message}',
    action: TextButton(onPressed: _loadEpisodes, child: const Text('重试')),
  );

  Widget _lineSection() {
    final episode = _episodeNumber;
    if (episode == null) {
      return const SiteLensPanel(child: Text('先选一集，再选线路。'));
    }
    if (_loadingLines && _lines.isEmpty) {
      return const SiteLensPanel(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final failure = _linesFailure;
    if (failure != null) {
      return _lineFailureNotice(episode, failure);
    }
    if (_lines.isEmpty) {
      return SiteLensPanel(
        child: SiteLensEmptyState(
          icon: Icons.alt_route,
          title: '这一集没有可用线路',
          message: '第 $episode 集在当前站点上没有线路，换一集或换一个站点再看。',
          action: TextButton(
            onPressed: () => _loadLines(episode),
            child: const Text('重试'),
          ),
        ),
      );
    }
    return SiteLensPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _lineRow(),
          if (_candidatesFailure != null) _candidateFailureNotice(),
          if (_candidatesFailure == null) _candidateSection(),
        ],
      ),
    );
  }

  /// A failure in the line area names the line, so the user can tell a dead
  /// line from a dead player.
  Widget _lineFailureNotice(int episode, SiteAdapterError failure) {
    final line = _selectedLine;
    final named = line == null ? null : '「${line.label}」';
    final text = switch (failure.kind) {
      SiteAdapterErrorKind.unavailable =>
        named == null
            ? '第 $episode 集的线路暂时不可用：${failure.message}'
            : '第 $episode 集的线路$named不可用（线路本身取不到，不是播放问题）：${failure.message}',
      SiteAdapterErrorKind.notFound =>
        named == null
            ? '第 $episode 集没有这条线路：${failure.message}'
            : '线路$named在第 $episode 集上不存在：${failure.message}',
      _ => '第 $episode 集的线路没有取到：${failure.message}',
    };
    return SiteLensNotice(
      tone: SiteLensNoticeTone.warning,
      text: text,
      action: TextButton(
        onPressed: () => _loadLines(episode),
        child: const Text('重试线路'),
      ),
    );
  }

  Widget _candidateFailureNotice() {
    final failure = _candidatesFailure!;
    final line = _selectedLine;
    final named = line == null ? '' : '「${line.label}」';
    final text = switch (failure.kind) {
      SiteAdapterErrorKind.unavailable =>
        '线路$named暂时不可用，取不到清晰度与音轨：${failure.message}',
      SiteAdapterErrorKind.notFound => '线路$named在这集上已经消失：${failure.message}',
      _ => '线路$named没有返回候选：${failure.message}',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SiteLensMetrics.compactRowHorizontalPadding,
        0,
        SiteLensMetrics.compactRowHorizontalPadding,
        SiteLensMetrics.panelPadding,
      ),
      child: SiteLensNotice(
        tone: SiteLensNoticeTone.warning,
        text: text,
        action: TextButton(
          onPressed: () {
            final id = _lineId;
            if (id != null) unawaited(_loadCandidates(id));
          },
          child: const Text('重试这条线路'),
        ),
      ),
    );
  }

  Widget _lineRow() {
    final selected = _selectedLine ?? _lines.first;
    final note = selected.note?.trim();
    return SiteLensCompactRow(
      leading: const Icon(
        Icons.alt_route,
        size: SiteLensMetrics.compactIconSize,
      ),
      title: Text(selected.label),
      subtitle: Text(note == null || note.isEmpty ? '当前线路' : '当前线路 · $note'),
      trailing: SiteLensMenuSelector<String>(
        label: '切换线路',
        value: selected.lineId,
        options: [
          for (final line in _lines)
            SiteLensMenuOption(value: line.lineId, label: line.label),
        ],
        onSelected: _selectLine,
      ),
    );
  }

  Widget _candidateSection() {
    if (_loadingCandidates && _candidates.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(SiteLensMetrics.panelPadding),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(SiteLensMetrics.panelPadding),
        child: Text(
          '这条线路没有给出清晰度或音轨。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final selected = _selectedCandidate ?? _candidates.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SiteLensMetrics.compactRowHorizontalPadding,
        0,
        SiteLensMetrics.compactRowHorizontalPadding,
        SiteLensMetrics.panelPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('清晰度与音轨', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: SiteLensMetrics.diagnosticRowGap),
          Row(
            children: [
              Expanded(
                child: Text(
                  candidateLabels(selected).join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SiteLensMenuSelector<String>(
                label: '切换清晰度',
                value: selected.id,
                options: [
                  for (final candidate in _candidates)
                    SiteLensMenuOption(
                      value: candidate.id,
                      label: candidateLabels(candidate).join(' · '),
                    ),
                ],
                onSelected: (id) => setState(() => _candidateId = id),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What one 媒体候选 is, in the user's words: quality and audio track. A
/// candidate without either still gets a label instead of a blank row.
List<String> candidateLabels(MediaCandidate candidate) {
  final quality = candidate.qualityLabel?.trim();
  final audio = candidate.audioLabel?.trim();
  return [
    if (quality != null && quality.isNotEmpty) quality else '默认清晰度',
    if (audio != null && audio.isNotEmpty) audio,
  ];
}

/// `m:ss`, or `h:mm:ss` past an hour. Null durations never reach here.
String formatEpisodeDuration(int durationMs) {
  final totalSeconds = durationMs ~/ 1000;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}
