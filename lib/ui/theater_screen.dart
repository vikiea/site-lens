import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/site_adapter.dart';
import '../theater/theater_catalog_store.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

/// One station on the 剧场 switch: the adapter that owns a site's 直连出口 and
/// the name the user knows it by. Only adapters that offer the direct route
/// appear, per ADR-0002.
class TheaterStation {
  const TheaterStation({required this.profile, required this.adapter});

  final SiteProfile profile;
  final SiteAdapter adapter;

  String get key => '${adapter.id}/#${profile.id}';
  String get name => profile.name;
}

/// 剧场: the home of 直连出口. The top line switches the station, the body is
/// that station's 目录 feed, and the strip below it is 我的追剧.
///
/// Read state comes from the adapter's catalog and the shared
/// [TheaterCatalogStore]; nothing here reaches a network, and switching a
/// station only changes which adapter is asked. This screen stops at "the
/// content is visible and clickable": series rows open [onOpenSeries] and no
/// player is involved.
class TheaterScreen extends StatefulWidget {
  const TheaterScreen({
    super.key,
    required this.stations,
    this.onOpenSeries,
    this.onAddSite,
    this.catalogStore,
    this.following,
  });

  /// Stations offering the direct route, in profile order.
  final List<TheaterStation> stations;

  final void Function(TheaterStation station, SeriesSummary series)?
  onOpenSeries;

  /// Shown when no station offers the direct route yet.
  final VoidCallback? onAddSite;

  /// Defaults to this screen's own store; tests may share one.
  final TheaterCatalogStore? catalogStore;

  /// 我的追剧. Callers that own durable 追剧记录 pass them in; null until
  /// such a store exists, which keeps the strip from claiming history the app
  /// does not have.
  final List<SeriesSummary>? following;

  @override
  State<TheaterScreen> createState() => _TheaterScreenState();
}

class _TheaterScreenState extends State<TheaterScreen> {
  late final TheaterCatalogStore _store =
      widget.catalogStore ?? TheaterCatalogStore();
  late final Map<String, List<SeriesSummary>> _seriesCache = {};

  /// The station the user picked, by [TheaterStation.key]. Kept as a key so a
  /// rebuilt station list does not silently point at another site.
  String? selectedKey;

  bool _loading = false;
  SiteAdapterError? _failure;
  List<SeriesSummary> _series = const [];
  String? _loadedStationKey;
  int _request = 0;

  TheaterStation? get _station {
    final key = selectedKey;
    if (key != null) {
      for (final station in widget.stations) {
        if (station.key == key) return station;
      }
    }
    return widget.stations.isEmpty ? null : widget.stations.first;
  }

  @override
  void initState() {
    super.initState();
    final station = _station;
    if (station != null) _load(station);
  }

  @override
  void didUpdateWidget(covariant TheaterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final station = _station;
    if (station == null) return;
    if (station.key != _loadedStationKey ||
        oldWidget.stations.length != widget.stations.length) {
      _load(station);
    }
  }

  Future<void> _load(TheaterStation station) async {
    final ticket = ++_request;
    // Whatever the user can see right now stays on screen until this station
    // answers, so a slow switch never blanks the feed.
    final remembered = _seriesCache[station.key] ?? _series;
    setState(() {
      _loading = true;
      _failure = null;
      _loadedStationKey = station.key;
      _series = remembered;
    });
    final snapshot = await _store.load(station.adapter, CancellationSignal());
    if (!mounted || ticket != _request) return;
    final series = snapshot.series;
    if (series.isNotEmpty) _seriesCache[station.key] = series;
    setState(() {
      _loading = false;
      _series = series;
      _failure = snapshot.failure;
    });
  }

  void _select(TheaterStation station) {
    if (station.key == _station?.key && !_loading) return;
    // Switch the cached station first so the feed and the switcher agree
    // immediately; the request only decides what fills it.
    setState(() => selectedKey = station.key);
    _load(station);
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) {
      return Center(
        child: SiteLensEmptyState(
          icon: Icons.theaters_outlined,
          title: '还没有可直连的站点',
          message: '剧场只显示提供了直连出口的站点档案。先在「站外浏览」里添加站点，再回来刷新。',
          action: widget.onAddSite == null
              ? null
              : FilledButton.icon(
                  onPressed: widget.onAddSite,
                  icon: const Icon(Icons.add_link),
                  label: const Text('添加站点'),
                ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(station),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              SiteLensMetrics.pagePadding,
              8,
              SiteLensMetrics.pagePadding,
              6,
            ),
            sliver: SliverToBoxAdapter(
              child: _StationSwitcher(
                stations: widget.stations,
                selected: station,
                onSelected: _select,
              ),
            ),
          ),
          if (_failure != null || (_loading && _series.isEmpty))
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                SiteLensMetrics.pagePadding,
                0,
                SiteLensMetrics.pagePadding,
                SiteLensMetrics.itemGap,
              ),
              sliver: SliverToBoxAdapter(child: _statusLine(station)),
            ),
          SliverToBoxAdapter(
            child: SiteLensSectionHeader(
              title: '开始观看',
              subtitle: _series.isEmpty ? null : '${_series.length} 部剧集',
            ),
          ),
          if (_series.isEmpty && !_loading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SiteLensMetrics.pagePadding,
                ),
                child: SiteLensPanel(
                  child: SiteLensEmptyState(
                    icon: Icons.video_library_outlined,
                    title: '这里还没有内容',
                    message: '站点没有返回目录，刷新后再看看。',
                    action: FilledButton.icon(
                      onPressed: () => _load(station),
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新剧场'),
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: SiteLensMetrics.pagePadding,
              ),
              sliver: SliverList.separated(
                itemCount: _series.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: SiteLensMetrics.listGap),
                itemBuilder: (context, index) {
                  final series = _series[index];
                  return SiteLensPanel(
                    padding: EdgeInsets.zero,
                    child: _SeriesRow(
                      series: series,
                      onTap: () => widget.onOpenSeries?.call(station, series),
                    ),
                  );
                },
              ),
            ),
          SliverToBoxAdapter(
            child: SiteLensSectionHeader(
              title: '我的追剧',
              // 追剧记录只记观看位置，所以这里从不回退到目录 feed：
              // 没有记录时横排显示空态，而不是把整份 feed 再抄一遍。
              subtitle: (widget.following ?? const <SeriesSummary>[]).isEmpty
                  ? null
                  : '继续看上次停下的那部',
            ),
          ),
          SliverToBoxAdapter(
            child: _FollowingStrip(
              series: widget.following ?? const <SeriesSummary>[],
              onTap: (series) => widget.onOpenSeries?.call(station, series),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 28)),
        ],
      ),
    );
  }

  Widget _statusLine(TheaterStation station) {
    final failure = _failure;
    if (failure == null) {
      return SiteLensNotice(
        tone: SiteLensNoticeTone.info,
        text: '正在读取「${station.name}」的目录…',
      );
    }
    final cached = _series.isNotEmpty;
    return SiteLensNotice(
      tone: SiteLensNoticeTone.warning,
      text: cached
          ? '「${station.name}」暂时不可用，下面显示的是已缓存的目录。'
          : '「${station.name}」暂时不可用：${failure.message}',
      action: TextButton(
        onPressed: () => _load(station),
        child: const Text('重试'),
      ),
    );
  }
}

/// The station switcher above the feed: one row naming the current station,
/// whose trailing menu lists the other stations. It never wraps.
class _StationSwitcher extends StatelessWidget {
  const _StationSwitcher({
    required this.stations,
    required this.selected,
    required this.onSelected,
  });

  final List<TheaterStation> stations;
  final TheaterStation selected;
  final ValueChanged<TheaterStation> onSelected;

  @override
  Widget build(BuildContext context) => SiteLensPanel(
    padding: EdgeInsets.zero,
    child: SiteLensCompactRow(
      leading: const Icon(Icons.theaters_outlined, size: 20),
      title: Text(selected.name),
      subtitle: Text(
        stations.length > 1
            ? '当前站点 · 共 ${stations.length} 个直连站点'
            : '当前站点 · 唯一的直连站点',
      ),
      trailing: SiteLensMenuSelector<String>(
        label: '切换站点',
        value: selected.key,
        // The selector asserts that exactly one option carries the current
        // value, so the trigger's own station stays in the list.
        options: [
          for (final station in stations)
            SiteLensMenuOption(value: station.key, label: station.name),
        ],
        onSelected: (key) {
          for (final station in stations) {
            if (station.key == key) {
              onSelected(station);
              return;
            }
          }
        },
      ),
    ),
  );
}

class _SeriesRow extends StatelessWidget {
  const _SeriesRow({required this.series, required this.onTap});

  final SeriesSummary series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final count = series.episodeCount;
    final summary = series.summary?.trim();
    final description = [
      if (count != null) '共 $count 集',
      if (summary != null && summary.isNotEmpty) summary,
    ].join(' · ');
    return SiteLensCompactRow(
      leading: const Icon(Icons.movie_outlined, size: 22),
      title: Text(series.title),
      subtitle: description.isEmpty ? null : Text(description),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 我的追剧: the horizontal strip under the feed. Each entry is browsable
/// content from the same catalog, so it is built from the loaded feed rather
/// than from a second request.
class _FollowingStrip extends StatelessWidget {
  const _FollowingStrip({required this.series, required this.onTap});

  final List<SeriesSummary> series;
  final ValueChanged<SeriesSummary> onTap;

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: SiteLensMetrics.pagePadding),
        child: SiteLensPanel(
          child: SiteLensEmptyState(
            icon: Icons.bookmark_border,
            title: '还没有追剧记录',
            message: '在剧场上选一部开始，看到的位置会记在这里。',
          ),
        ),
      );
    }
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: SiteLensMetrics.pagePadding,
        ),
        itemCount: series.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: SiteLensMetrics.itemGap),
        itemBuilder: (context, index) => _FollowingCard(
          series: series[index],
          onTap: () => onTap(series[index]),
        ),
      ),
    );
  }
}

class _FollowingCard extends StatelessWidget {
  const _FollowingCard({required this.series, required this.onTap});

  final SeriesSummary series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 112,
    child: Semantics(
      button: true,
      label: '继续观看 ${series.title}',
      child: SiteLensGlassSurface(
        radius: SiteLensMetrics.inputRadius,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  Icons.play_circle_outline,
                  size: 26,
                  color: Theme.of(context).colorScheme.primary,
                ),
                SiteLensRowText(
                  series.title,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxCharacters: null,
                ),
                Text(
                  series.episodeCount == null
                      ? '待续'
                      : '共 ${series.episodeCount} 集',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Stations that offer 直连出口. A profile without an adapter cannot be
/// browsed as a catalog, so it is not a station; 剧场 names its stations by
/// profile, never by an adapter with no profile behind it.
List<TheaterStation> directTheaterStations({
  required Iterable<SiteProfile> profiles,
  required SiteAdapter? Function(int profileId) resolveAdapter,
}) {
  final stations = <TheaterStation>[];
  for (final profile in profiles) {
    if (!profile.enabled) continue;
    final routes = profile.routes.isEmpty ? {SiteRoute.browse} : profile.routes;
    if (!routes.contains(SiteRoute.direct)) continue;
    final adapter = resolveAdapter(profile.id);
    if (adapter == null) continue;
    stations.add(TheaterStation(profile: profile, adapter: adapter));
  }
  return stations;
}
