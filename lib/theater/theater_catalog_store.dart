import '../domain/site_adapter.dart';

/// The most recent 剧场 catalog an adapter answered with.
///
/// The cache is a bypass, not a second source of truth: the adapter stays the
/// only thing that can produce a catalog, and this snapshot is what the screen
/// falls back to when the interface stops answering.
class TheaterCatalogSnapshot {
  TheaterCatalogSnapshot._({
    required this.series,
    required this.fromCache,
    this.failure,
  });

  /// The series to show, in catalog order.
  final List<SeriesSummary> series;

  /// Whether [series] came from the cache instead of a fresh answer.
  final bool fromCache;

  /// Why the interface did not answer, when it did not. A cached answer keeps
  /// this so the screen can say "这是缓存内容" without pretending all is well.
  /// A cancelled request is not a failure and leaves this null.
  final SiteAdapterError? failure;

  bool get isEmpty => series.isEmpty;
}

/// Remembers the last non-empty 剧场 catalog per adapter.
///
/// Deliberately small: one feed per adapter identity, in memory, replaced on
/// every successful answer. A failure — or an empty answer — falls back to the
/// remembered feed. Nothing here retries, persists, or merges catalogs across
/// sites; series identity is scoped to the adapter that owns it.
class TheaterCatalogStore {
  final Map<String, List<SeriesSummary>> _feeds = {};

  /// The remembered catalog for [adapter], or null when it has none.
  List<SeriesSummary>? remembered(SiteAdapter adapter) => _feeds[adapter.id];

  /// Asks [adapter] for its catalog, falling back to the remembered one when
  /// the interface fails or answers with nothing.
  Future<TheaterCatalogSnapshot> load(
    SiteAdapter adapter,
    CancellationSignal cancel,
  ) async {
    final remembered = _feeds[adapter.id];
    try {
      final feed = await adapter.theater(cancel);
      if (feed.series.isNotEmpty) {
        final series = List<SeriesSummary>.unmodifiable(feed.series);
        _feeds[adapter.id] = series;
        return TheaterCatalogSnapshot._(series: series, fromCache: false);
      }
      // An empty answer says nothing about the catalog; it is not proof the
      // site has no series. Keep the last known content instead of blanking
      // the screen.
      if (remembered != null) {
        return TheaterCatalogSnapshot._(series: remembered, fromCache: true);
      }
      return TheaterCatalogSnapshot._(series: const [], fromCache: false);
    } on SiteAdapterError catch (error) {
      if (remembered != null) {
        return TheaterCatalogSnapshot._(
          series: remembered,
          fromCache: true,
          failure: error.kind == SiteAdapterErrorKind.cancelled ? null : error,
        );
      }
      return TheaterCatalogSnapshot._(
        series: const [],
        fromCache: false,
        failure: error,
      );
    }
  }
}
