/// 出口级健康 (ADR-0006): one availability record per 出口, and per publishing
/// page inside that 出口. The profile badge is the [aggregate] of these.
///
/// Two rules hold for everything in this file:
///
/// * Health is best-effort and never participates in ranking or
///   recommendation ([routeHealthFeedsRanking] stays `false`).
/// * "Not checked yet" is not "unusable". Only an observed failure is a
///   failure; an unknown route never turns a profile into a failing one.
library;

import 'models.dart';
import 'site_adapter.dart' show BaseStation;

/// Availability of one publishing page of one 出口.
///
/// It is read from the existing `profile_pages.refreshed_at / error` columns,
/// so a page-level result has one home rather than a second table.
enum PageHealthState {
  unknown,
  ok,
  failing;

  ProfileHealthState get profileState => switch (this) {
    PageHealthState.unknown => ProfileHealthState.unknown,
    PageHealthState.ok => ProfileHealthState.ok,
    PageHealthState.failing => ProfileHealthState.failing,
  };
}

/// One publishing page's outcome, stamped with the 出口 it belongs to.
class SitePageObservation {
  const SitePageObservation({
    required this.pageId,
    required this.url,
    required this.route,
    required this.state,
    this.refreshedAt,
    this.failureCategory,
    this.failureDetail,
  });

  final int pageId;
  final Uri url;
  final SiteRoute route;
  final PageHealthState state;

  /// `profile_pages.refreshed_at`: when this page last answered.
  final DateTime? refreshedAt;

  /// Classification of the stored `profile_pages.error`, when it is a failure.
  final String? failureCategory;

  /// The stored `profile_pages.error` verbatim, for the detail screen.
  final String? failureDetail;

  /// The station key the page is reached at, so a 出口 that reports
  /// observations per page can still say which address failed.
  String get stationKey => webPageKey(url);

  /// The host a user recognises the page by.
  String get host => url.host.isEmpty ? url.toString() : url.host;
}

/// Availability of one 出口.
class RouteObservation {
  RouteObservation({
    required this.route,
    this.state = RouteHealthState.unknown,
    this.checkedAt,
    this.failureCategory,
    this.failureDetail,
    this.stationKey,
    List<SitePageObservation> pages = const [],
  }) : pages = List.unmodifiable(pages);

  final SiteRoute route;

  /// What the last check that observed *this route as a whole* concluded.
  /// [RouteHealthState.unknown] means no such check ran, which lets the pages
  /// decide instead.
  final RouteHealthState state;
  final DateTime? checkedAt;
  final String? failureCategory;
  final String? failureDetail;

  /// Which base station was observed, when one was involved. When the route
  /// has no station of its own, the station the page result came from stands
  /// in, so the detail panel can always name an address for a failure.
  final String? stationKey;
  final List<SitePageObservation> pages;

  /// The state a reader should trust.
  ///
  /// The 出口 is a set of pages, so a single usable page makes it usable: a
  /// quiet mirror next to a working one is not a broken route. The stored
  /// route-wide verdict is consulted only when no page has an opinion — it
  /// is coarser evidence and must never outvote a page that answered since.
  RouteHealthState get effectiveState {
    if (pages.any((page) => page.state == PageHealthState.ok)) {
      return RouteHealthState.ok;
    }
    if (pages.any((page) => page.state == PageHealthState.failing)) {
      return state == RouteHealthState.ok
          ? RouteHealthState.ok
          : RouteHealthState.failing;
    }
    return state;
  }

  bool get isUsable => effectiveState == RouteHealthState.ok;

  /// The station this 出口 was observed at: its own, else the failing page's.
  String? get effectiveStationKey {
    final own = stationKey;
    if (own != null && own.isNotEmpty) return own;
    if (pages.length == 1) return pages.single.stationKey;
    return failedPage?.stationKey;
  }

  /// The page the failure should be attributed to, if any: the first failing
  /// page, so the sentence names a host rather than the whole site.
  SitePageObservation? get failedPage =>
      pages.where((page) => page.state == PageHealthState.failing).firstOrNull;

  /// The category to show: an explicit route verdict first, then its worst
  /// failing page.
  String? get effectiveCategory {
    final own = failureCategory;
    if (own != null && own.isNotEmpty) return own;
    return pages
        .where((page) => page.state == PageHealthState.failing)
        .map((page) => page.failureCategory)
        .whereType<String>()
        .where((category) => category.isNotEmpty)
        .firstOrNull;
  }
}

enum RouteHealthState {
  unknown,
  ok,
  failing;

  ProfileHealthState get profileState => switch (this) {
    RouteHealthState.unknown => ProfileHealthState.unknown,
    RouteHealthState.ok => ProfileHealthState.ok,
    RouteHealthState.failing => ProfileHealthState.failing,
  };
}

/// Every 出口 record of one 站点档案, plus the aggregate badge.
class RouteHealthRecord {
  RouteHealthRecord({
    required this.profileId,
    List<RouteObservation> routes = const [],
    this.observations = const [],
  }) : routes = List.unmodifiable(
         _sorted(routes.isEmpty ? observations : routes),
       );

  /// Builds the record from what was stored, keeping only the 出口 the profile
  /// actually offers: a record left over from a route the user removed must
  /// not keep the badge alive.
  factory RouteHealthRecord.forProfile({
    required int profileId,
    required Set<SiteRoute> routes,
    List<RouteObservation> observations = const [],
    List<SitePageObservation> pages = const [],
  }) {
    // No declared route set means "whatever was observed": a caller that did
    // not tell us which 出口 exist must not have the direct route dropped.
    final wanted = routes.isNotEmpty
        ? routes
        : {
            for (final observation in observations) observation.route,
            if (observations.isEmpty) SiteRoute.browse,
          };
    final byRoute = <SiteRoute, RouteObservation>{
      for (final observation in observations)
        if (wanted.contains(observation.route)) observation.route: observation,
    };
    for (final route in wanted) {
      final known = byRoute[route];
      final own = pages.where((page) => page.route == route).toList();
      byRoute[route] = own.isEmpty
          ? (known ?? RouteObservation(route: route))
          : RouteObservation(
              route: route,
              state: known?.state ?? RouteHealthState.unknown,
              checkedAt: known?.checkedAt,
              failureCategory: known?.failureCategory,
              failureDetail: known?.failureDetail,
              stationKey: known?.stationKey,
              pages: _dedupePages([...?known?.pages, ...own]),
            );
    }
    return RouteHealthRecord(
      profileId: profileId,
      routes: byRoute.values.toList(),
    );
  }

  final int profileId;

  /// One entry per 出口 the profile offers, in [SiteRoute.values] order.
  ///
  /// Use [routeFor] rather than this list to read a verdict: a raw
  /// observation's [RouteObservation.state] is an input, and the answer a
  /// caller wants is [RouteObservation.effectiveState].
  final List<RouteObservation> routes;

  /// Raw observations, kept so a caller can rebuild with a narrower route set.
  final List<RouteObservation> observations;

  RouteObservation? routeFor(SiteRoute route) =>
      routes.where((entry) => entry.route == route).firstOrNull;

  /// The 出口 that cannot be used right now, whether or not another one still
  /// works.
  ///
  /// A page failure inside a route that is otherwise usable is *not* here: the
  /// route works, and calling it failed would tell the user to avoid something
  /// they can use. Those pages stay on [RouteObservation.pages] for the
  /// detail panel.
  Set<SiteRoute> get failedRoutes => {
    for (final entry in routes)
      if (!entry.isUsable && entry.effectiveState == RouteHealthState.failing)
        entry.route,
  };

  /// 任一出口可用即档案可用；只有全部出口都失败才报故障。
  ProfileHealthState get state {
    if (routes.isEmpty) return ProfileHealthState.unknown;
    if (routes.any((entry) => entry.isUsable)) return ProfileHealthState.ok;
    if (routes.every(
      (entry) => entry.effectiveState == RouteHealthState.failing,
    )) {
      return ProfileHealthState.failing;
    }
    return ProfileHealthState.unknown;
  }

  bool get isUsable => state == ProfileHealthState.ok;

  /// The latest observation across 出口; null when nothing was ever checked.
  DateTime? get checkedAt => _latest(routes.map((entry) => entry.checkedAt));

  /// One sentence a user can act on, naming the 出口 that failed.
  String get summary {
    final failure = routeFailureSentence(this);
    final at = checkedAt;
    final parts = <String>[
      ?failure,
      at == null ? '后台存活检查 · 未检查' : '后台存活检查 · ${_clock(at)}',
    ];
    return parts.join(' · ');
  }

  static List<RouteObservation> _sorted(List<RouteObservation> routes) {
    final order = {
      for (final (index, route) in SiteRoute.values.indexed) route: index,
    };
    return [...routes]
      ..sort((a, b) => (order[a.route] ?? 0).compareTo(order[b.route] ?? 0));
  }

  /// One entry per page, the later observation winning: the same page must
  /// never count twice, because a duplicated failing page would outvote a
  /// failing-then-recovered one.
  static List<SitePageObservation> _dedupePages(
    List<SitePageObservation> pages,
  ) {
    final byId = <int, SitePageObservation>{};
    for (final page in pages) {
      byId[page.pageId] = page;
    }
    return byId.values.toList();
  }

  static DateTime? _latest(Iterable<DateTime?> values) {
    DateTime? latest;
    for (final value in values) {
      if (value == null) continue;
      if (latest == null || value.isAfter(latest)) latest = value;
    }
    return latest;
  }
}

/// 「哪条出口失败」, or null when every 出口 the profile offers is usable.
///
/// The sentence is the whole point of measuring per 出口 (ADR-0006): a badge
/// that only says "站点故障" hides that the mirror still works. An 出口 is
/// reported only when it is *currently* unusable, and the reason names the
/// page and the category, so a user can act on it. Failures on a route that
/// still works stay in [RouteObservation.pages] for the detail panel instead
/// of turning the badge into a complaint.
String? routeFailureSentence(RouteHealthRecord record) {
  final failed = record.failedRoutes.toList()
    ..sort(
      (a, b) =>
          SiteRoute.values.indexOf(a).compareTo(SiteRoute.values.indexOf(b)),
    );
  if (failed.isEmpty) return null;
  final everyRouteFailed =
      record.routes.isNotEmpty &&
      record.routes.every((entry) => !entry.isUsable) &&
      record.state == ProfileHealthState.failing;
  final clause = failed
      .map((route) {
        final entry = record.routeFor(route);
        final reason = _pageFailure(entry);
        return reason == null
            ? '${routeLabel(route)}不可用'
            : '${routeLabel(route)}不可用（$reason）';
      })
      .join('，');
  return everyRouteFailed ? '$clause，两条出口都不可用' : clause;
}

/// Human wording for one 出口 (GLOSSARY「直连出口 / 浏览出口」).
String routeLabel(SiteRoute route) => switch (route) {
  SiteRoute.direct => '直连出口',
  SiteRoute.browse => '浏览出口',
};

/// Human wording for a stored failure category. Shared with the profile badge
/// so one category never reads two ways.
String? routeFailureCategoryLabel(String? category) => switch (category) {
  'dns' => 'DNS 解析失败',
  'proxy_connect' || 'proxy_connect_status' => '代理连接失败',
  'tls_handshake' => 'TLS 握手失败',
  'tls_protocol' => 'TLS 协议或加密套件被拒',
  'tls_reset' => 'TLS 握手期间连接被重置',
  'certificate' || 'hostname' => '证书验证失败',
  'timeout' => '探测超时',
  'http_401' || 'http_403' => '站点要求授权',
  'http_5xx' => '站点服务异常',
  'unreachable' => '没有响应',
  'selector' => '最新地址区域解析失败',
  null => null,
  '' => null,
  _ => '网络请求失败',
};

/// The detail a user needs when a 出口 fails: which host was tried and why.
String? _pageFailure(RouteObservation? entry) {
  if (entry == null) return null;
  final category = routeFailureCategoryLabel(entry.effectiveCategory);
  final page = entry.failedPage;
  final host = page?.host;
  if (category == null && host == null) {
    final detail = entry.failureDetail;
    return detail != null && detail.trim().isNotEmpty ? detail.trim() : null;
  }
  if (host == null) return category;
  return category == null ? host : '$host · $category';
}

/// What the site detail page shows: the stations usable right now, and the
/// 出口 that were tried.
class RouteDetailView {
  RouteDetailView({
    required this.record,
    List<BaseStation> liveStations = const [],
  }) : liveStations = List.unmodifiable(liveStations);

  final RouteHealthRecord record;
  final List<BaseStation> liveStations;

  /// Stations as the adapter reported them, best first. The adapter's order is
  /// the site's own ranking; the app does not re-sort it.
  List<BaseStation> get currentStations => liveStations;

  bool get hasStations => liveStations.isNotEmpty;

  /// Every 出口 the app tried, direct first. Always both: the point is that
  /// the user can see what was attempted, including the route that worked.
  List<SiteRoute> get attemptedRoutes {
    final tried =
        {
          for (final entry in record.routes) entry.route,
          SiteRoute.direct,
          SiteRoute.browse,
        }.toList()..sort(
          (a, b) => SiteRoute.values
              .indexOf(a)
              .compareTo(SiteRoute.values.indexOf(b)),
        );
    return tried;
  }

  RouteObservation? observationFor(SiteRoute route) => record.routeFor(route);

  /// The stations to offer the user for [route], or empty when the route is
  /// not usable. Only the direct route has stations of its own; the browse
  /// route's addresses are publishing pages, which the panel lists separately.
  List<BaseStation> stationsFor(SiteRoute route) =>
      route == SiteRoute.direct && (record.routeFor(route)?.isUsable ?? false)
      ? liveStations
      : const [];
}

/// Reads the stored state into one record: the per-出口 verdicts, plus each
/// publishing page's own result, classified from its stored `error` text.
///
/// [pages] is what `profile_pages` holds and [verdicts] is what
/// `site_profile_health` holds. Neither outranks the other by type: a page
/// result is finer-grained evidence, so [RouteObservation.effectiveState]
/// reads it first and falls back to the route-wide verdict.
RouteHealthRecord routeHealthFromStored({
  required int profileId,
  required Set<SiteRoute> routes,
  required List<ProfilePage> pages,
  required Map<SiteRoute, ProfileHealth> verdicts,
}) => RouteHealthRecord.forProfile(
  profileId: profileId,
  routes: routes,
  observations: [
    for (final MapEntry(key: route, value: verdict) in verdicts.entries)
      RouteObservation(
        route: route,
        state: switch (verdict.state) {
          ProfileHealthState.ok => RouteHealthState.ok,
          ProfileHealthState.failing => RouteHealthState.failing,
          ProfileHealthState.unknown => RouteHealthState.unknown,
        },
        checkedAt: verdict.lastCheckedAt,
        failureCategory: verdict.lastFailureCategory,
      ),
  ],
  pages: [
    for (final page in pages)
      SitePageObservation(
        pageId: page.id,
        url: page.url,
        route: page.route,
        state: page.error == null
            ? (page.refreshedAt == null
                  ? PageHealthState.unknown
                  : PageHealthState.ok)
            : PageHealthState.failing,
        refreshedAt: page.refreshedAt,
        failureCategory: page.error == null
            ? null
            : pageFailureCategory(page.error!),
        failureDetail: page.error,
      ),
  ],
);

/// Classifies a stored `profile_pages.error` string.
///
/// The column is free text written by whichever refresh path failed, so this
/// matches the few shapes the app itself writes and never invents a category
/// for an unrecognised message.
String pageFailureCategory(String error) {
  final text = error.toLowerCase();
  if (text.contains('dns')) return 'dns';
  if (text.contains('tls 握手') || text.contains('tls_handshake')) {
    return 'tls_handshake';
  }
  if (text.contains('证书') || text.contains('certificate')) {
    return 'certificate';
  }
  if (text.contains('代理')) return 'proxy_connect';
  if (text.contains('超时') || text.contains('timeout')) return 'timeout';
  if (text.contains('取消')) return 'cancelled';
  if (text.contains('选择器') || text.contains('最新地址区域')) {
    return 'selector';
  }
  return 'unreachable';
}

/// Health never feeds ranking or recommendation (ADR-0006). It is a constant
/// so the constraint is asserted in one place instead of being remembered.
const bool routeHealthFeedsRanking = false;

String _clock(DateTime? at) {
  if (at == null) return '未检查';
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
