import '../domain/models.dart';
import '../domain/site_adapter.dart';

/// A configurable, network-free [SiteAdapter] used to drive the registry and,
/// later, real screens before a site's own protocol exists.
///
/// Everything it answers is configured through this object: the catalog, the
/// login page and verdict, the base stations and the health state. It performs
/// no I/O and reaches no site.
///
/// It lives under `lib/testing/` rather than `test/` so app code can compose
/// it; it is never referenced by a production code path.
class FakeSiteAdapter implements SiteAdapter {
  FakeSiteAdapter({
    this.id = adapterId,
    required this.profileId,
    required this.addresses,
  }) : _catalog = const [];

  /// Identity of every fake adapter; callers that need several distinct fakes
  /// pass their own [id].
  static const adapterId = 'fake';

  @override
  final String id;

  @override
  final int profileId;

  @override
  final List<Uri> addresses;

  /// Where the fake site logs in.
  Uri loginPage = Uri.parse('https://login.invalid/');

  /// What [loginVerdict] reports once [acceptSignIn] has been called.
  SiteCredential _credential = const SiteCredential.empty();

  /// Credential handed out by the next [refreshCredential].
  SiteCredential? _refreshed;

  /// Fields [signIn] accepts.
  Map<String, String> _acceptedSignIn = const {};

  /// Stations [liveStations] reports.
  // Uri.parse is not const, so this list cannot be a const literal.
  List<BaseStation> stations = [
    BaseStation(origin: Uri.parse('https://station.invalid/'), preferred: true),
  ];

  /// State [health] reports.
  ProfileHealthState healthState = ProfileHealthState.ok;

  /// A failure queued for the next content call, consumed once.
  SiteAdapterError? _nextFailure;

  List<FakeSeries> _catalog;

  /// Replaces the catalog this adapter serves.
  void configureCatalog(List<FakeSeries> catalog) {
    _catalog = List.unmodifiable(catalog);
  }

  /// Makes [signIn] succeed for exactly [fields].
  void acceptSignIn(Map<String, String> fields) {
    _acceptedSignIn = Map.unmodifiable(fields);
  }

  /// Makes the next [refreshCredential] return [credential].
  void refreshTo(SiteCredential credential) {
    _refreshed = credential;
  }

  /// Makes the next content call throw [kind] instead of answering. Used to
  /// exercise failure paths without a network.
  void failNextWith(SiteAdapterErrorKind kind, String message) {
    _nextFailure = SiteAdapterError(kind, message);
  }

  @override
  SiteCredential get credential => _credential;

  @override
  bool matchesAddress(Uri address) => addresses.any(
    (known) => known.host == address.host && known.port == address.port,
  );

  /// Throws the queued failure, if any, then honours cancellation.
  void _enter(CancellationSignal cancel) {
    final failure = _nextFailure;
    if (failure != null) {
      _nextFailure = null;
      throw failure;
    }
    cancel.throwIfCancelled();
  }

  @override
  Future<TheaterFeed> theater(CancellationSignal cancel) async {
    _enter(cancel);
    return TheaterFeed([
      for (final series in _catalog)
        SeriesSummary(
          seriesKey: series.seriesKey,
          title: series.title,
          episodeCount: series.episodes.length,
        ),
    ]);
  }

  @override
  Future<SeriesEpisodes> episodes(
    String seriesKey,
    CancellationSignal cancel,
  ) async {
    _enter(cancel);
    final series = _series(seriesKey);
    return SeriesEpisodes([
      for (final episode in series.episodes)
        EpisodeSummary(
          episodeNumber: episode.episodeNumber,
          title: episode.title,
          durationMs: episode.durationMs,
        ),
    ]);
  }

  @override
  Future<List<Line>> lines(
    String seriesKey,
    int episodeNumber,
    CancellationSignal cancel,
  ) async {
    _enter(cancel);
    final episode = _episode(seriesKey, episodeNumber);
    return [
      for (final line in episode.lines)
        Line(lineId: line.lineId, label: line.label, note: line.note),
    ];
  }

  @override
  Future<List<MediaCandidate>> candidates(
    Line line,
    CancellationSignal cancel,
  ) async {
    _enter(cancel);
    for (final series in _catalog) {
      for (final episode in series.episodes) {
        for (final known in episode.lines) {
          if (known.lineId != line.lineId) continue;
          return [
            for (final (rank, representation) in known.representations.indexed)
              MediaCandidate(
                id: candidateId(
                  seriesKey: series.seriesKey,
                  episodeNumber: episode.episodeNumber,
                  lineId: known.lineId,
                  representationRank: rank,
                ),
                hostId: profileId,
                generation: 1,
                sourceUrl: addresses.isEmpty
                    ? Uri.parse('https://fake.invalid/')
                    : addresses.first,
                mediaUrl: Uri.parse(representation.mediaUrl),
                title: '${series.title} ${episode.title}',
                mime: 'application/vnd.apple.mpegurl',
                source: MediaCandidateSource.registered,
                seriesKey: series.seriesKey,
                seriesTitle: series.title,
                episodeNumber: episode.episodeNumber,
                representationRank: rank,
                qualityLabel: representation.qualityLabel,
                audioLabel: representation.audioLabel,
              ),
          ];
        }
      }
    }
    throw SiteAdapterError(
      SiteAdapterErrorKind.notFound,
      '线路 ${line.lineId} 不在假目录里',
    );
  }

  /// Stable candidate identity for the fake catalog, so a durable task can be
  /// matched back to the representation it came from.
  static String candidateId({
    required String seriesKey,
    required int episodeNumber,
    required String lineId,
    required int representationRank,
  }) => '$adapterId:$seriesKey:$episodeNumber:$lineId:$representationRank';

  FakeSeries _series(String seriesKey) {
    for (final series in _catalog) {
      if (series.seriesKey == seriesKey) return series;
    }
    throw SiteAdapterError(
      SiteAdapterErrorKind.notFound,
      '剧集 $seriesKey 不在假目录里',
    );
  }

  FakeEpisode _episode(String seriesKey, int episodeNumber) {
    final series = _series(seriesKey);
    for (final episode in series.episodes) {
      if (episode.episodeNumber == episodeNumber) return episode;
    }
    throw SiteAdapterError(
      SiteAdapterErrorKind.notFound,
      '选集 $episodeNumber 不在剧集 $seriesKey 里',
    );
  }

  @override
  Future<LoginEntry> loginEntry(CancellationSignal cancel) async {
    _enter(cancel);
    return LoginEntry(url: loginPage);
  }

  @override
  Future<LoginVerdict> loginVerdict(CancellationSignal cancel) async {
    _enter(cancel);
    return LoginVerdict(
      loggedIn: _credential.isUsable,
      credential: _credential,
    );
  }

  @override
  Future<LoginVerdict> signIn(
    SiteCredentialUpdate update,
    CancellationSignal cancel,
  ) async {
    _enter(cancel);
    final expected = _acceptedSignIn;
    final accepted =
        expected.isNotEmpty &&
        expected.entries.every((e) => update.fields[e.key] == e.value);
    if (!accepted) {
      return _credential.isUsable
          ? LoginVerdict(loggedIn: true, credential: _credential)
          : LoginVerdict.loggedOut;
    }
    _credential = SiteCredential(
      accessToken: 'fake-access-token',
      refreshToken: 'fake-refresh-token',
      cookies: const {'sid': 'fake-session'},
      installationStamp: '$adapterId-install',
    );
    return LoginVerdict(loggedIn: true, credential: _credential);
  }

  @override
  Future<SiteCredential> refreshCredential(CancellationSignal cancel) async {
    _enter(cancel);
    final next = _refreshed;
    if (next != null) {
      _credential = next;
      return next;
    }
    if (!_credential.canRefresh) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unauthenticated,
        '没有可刷新的会话',
      );
    }
    _credential = SiteCredential(
      accessToken: '${_credential.accessToken}-refreshed',
      refreshToken: _credential.refreshToken,
      cookies: _credential.cookies,
      installationStamp: _credential.installationStamp,
      expiresAt: _credential.expiresAt,
    );
    return _credential;
  }

  @override
  Future<void> signOut(CancellationSignal cancel) async {
    _enter(cancel);
    _credential = const SiteCredential.empty();
  }

  @override
  Future<List<BaseStation>> liveStations(CancellationSignal cancel) async {
    _enter(cancel);
    return List.unmodifiable(stations);
  }

  @override
  Future<AdapterHealth> health(CancellationSignal cancel) async {
    _enter(cancel);
    return AdapterHealth(state: healthState);
  }
}

/// One series in the fake catalog.
class FakeSeries {
  const FakeSeries({
    required this.seriesKey,
    required this.title,
    required this.episodes,
  });
  final String seriesKey;
  final String title;
  final List<FakeEpisode> episodes;
}

/// One episode in the fake catalog.
class FakeEpisode {
  const FakeEpisode({
    required this.episodeNumber,
    required this.title,
    this.durationMs,
    this.lines = const [],
  });
  final int episodeNumber;
  final String title;
  final int? durationMs;
  final List<FakeLine> lines;
}

/// One line of an episode, with the representations it can yield.
class FakeLine {
  const FakeLine({
    required this.lineId,
    required this.label,
    this.note,
    this.representations = const [],
  });
  final String lineId;
  final String label;
  final String? note;
  final List<FakeRepresentation> representations;
}

/// One media candidate a [FakeLine] yields.
class FakeRepresentation {
  const FakeRepresentation({
    required this.mediaUrl,
    this.qualityLabel,
    this.audioLabel,
  });
  final String mediaUrl;
  final String? qualityLabel;
  final String? audioLabel;
}
