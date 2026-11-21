/// Value objects and the contract that sit between a [SiteProfile] and the
/// site's own interface. The boundary is fixed by ADR-0004: site-specific
/// mechanics stop at an adapter, and the signatures here name none of them.
///
/// Terminology follows `GLOSSARY.md`: 剧场 / 目录 / 剧集 / 选集 / 线路 /
/// 媒体候选 / 站点凭证 / 基站.
library;

import 'models.dart';

/// The account slot a [SiteCredential] belongs to. Reserved now so adding
/// multiple accounts later does not have to change the credential table, the
/// injection path and the UI at once (ADR-0007).
class SiteAccount {
  const SiteAccount({this.id = 'default'});
  final String id;
}

/// The login state the application holds for one site profile (ADR-0007).
///
/// The refresh token and the device identity are optional; the access token and
/// the cookies are not, because segments and CDNs usually honour only cookies.
///
/// Persistence and backup isolation for this value are a separate ticket. Until
/// then a credential is either [empty] or [present]; nothing here is exported.
class SiteCredential {
  const SiteCredential({
    required this.accessToken,
    required this.cookies,
    this.account = const SiteAccount(),
    this.refreshToken,
    this.installationStamp,
    this.expiresAt,
  });

  /// No session has been established yet: every credential field is absent.
  ///
  /// If a site issues cookies but no access token, flip [hasAccessToken] with
  /// the real site. The fake adapter keeps this invariant without a site to
  /// ask, so do not read it as a product decision.
  const SiteCredential.empty()
    : accessToken = null,
      cookies = const {},
      account = const SiteAccount(),
      refreshToken = null,
      installationStamp = null,
      expiresAt = null;

  final SiteAccount account;
  final String? accessToken;
  final String? refreshToken;
  final Map<String, String> cookies;

  /// An opaque value the site uses to recognise this installation. The app
  /// never interprets it; producing it is adapter-internal (ADR-0004), storing
  /// it belongs with the credential (ADR-0007).
  final String? installationStamp;
  final DateTime? expiresAt;

  bool get hasInstallationStamp => (installationStamp ?? '').trim().isNotEmpty;
  bool get hasAccessToken => (accessToken ?? '').trim().isNotEmpty;
  bool get hasRefreshToken => (refreshToken ?? '').trim().isNotEmpty;
  bool get hasCookies => cookies.isNotEmpty;

  /// True only when both the access token and the cookies are present.
  bool get isUsable => hasAccessToken && hasCookies;

  /// True when the session can be renewed instead of asking the user to log in
  /// again; see 凭证刷新 in `GLOSSARY.md`.
  bool get canRefresh => isUsable && hasRefreshToken;

  /// A session with no token and no cookies is the same as no session at all.
  /// A timestamp alone must not count as credentials.
  bool get isEmpty => !hasAccessToken && !hasCookies && !hasRefreshToken;

  /// Whether the credential looks expired at [now]. A missing [expiresAt] means
  /// the site gave no hint, not that the session is fresh.
  bool expiredAt(DateTime now) {
    final at = expiresAt;
    return at != null && !now.isBefore(at);
  }
}

/// What the user typed on the site's own login page, handed back to the
/// adapter. Plain data: how these values reach the site is adapter-internal.
class SiteCredentialUpdate {
  const SiteCredentialUpdate({required this.fields});
  final Map<String, String> fields;

  bool get isEmpty => fields.isEmpty;
}

/// One unit the catalog can be browsed and watched through.
///
/// Its identity is defined by the adapter that owns the catalog; the app never
/// merges series across sites (see 剧集 in `GLOSSARY.md`).
class SeriesSummary {
  const SeriesSummary({
    required this.seriesKey,
    required this.title,
    this.coverUrl,
    this.summary,
    this.episodeCount,
  });

  /// Identity scoped to the owning adapter. Never compared across adapters.
  final String seriesKey;
  final String title;
  final Uri? coverUrl;
  final String? summary;

  /// Episodes the catalog claims; null when it never says.
  final int? episodeCount;
}

/// The theater feed: what the direct route shows as its browsable home.
class TheaterFeed {
  TheaterFeed(List<SeriesSummary> series) : series = List.unmodifiable(series);
  final List<SeriesSummary> series;
  bool get isEmpty => series.isEmpty;
}

/// The episodes of one series, in catalog order.
class SeriesEpisodes {
  SeriesEpisodes(List<EpisodeSummary> episodes)
    : episodes = List.unmodifiable(episodes);
  final List<EpisodeSummary> episodes;
}

/// A playable entry inside a series. It is the source of media candidates and
/// is not itself a task (see 选集 in `GLOSSARY.md`).
class EpisodeSummary {
  const EpisodeSummary({
    required this.episodeNumber,
    required this.title,
    this.durationMs,
  });
  final int episodeNumber;
  final String title;
  final int? durationMs;
}

/// One way to obtain an episode: the path the user actually picks. A line can
/// yield several media candidates (quality, audio track); the player is given
/// a candidate, never a line (see 线路 in `GLOSSARY.md`).
class Line {
  const Line({
    required this.lineId,
    required this.label,
    this.note,
    this.episodeNumber,
  });
  final String lineId;
  final String label;

  /// Site-stated remark, such as availability. Optional and never parsed.
  final String? note;

  /// 这条线路属于哪一集。同一个 lineId 在不同集下可以产出不同候选，所以
  /// `candidates(line)` 必须知道上下文；缺省表示调用方没有这个上下文。
  final int? episodeNumber;
}

/// Where the user logs in, and how the app tells that logging in worked.
class LoginEntry {
  const LoginEntry({required this.url});
  final Uri url;
}

/// The outcome of asking "is this session logged in?".
class LoginVerdict {
  const LoginVerdict({required this.loggedIn, required this.credential});
  final bool loggedIn;
  final SiteCredential credential;

  static const loggedOut = LoginVerdict(
    loggedIn: false,
    credential: SiteCredential.empty(),
  );
}

/// A base station: the address the app should currently talk to.
///
/// Discovery of these stays inside the adapter and reuses the profile's
/// publishing pages; the shape of a site's domain pool never reaches here
/// (ADR-0004).
class BaseStation {
  const BaseStation({
    required this.origin,
    this.preferred = false,
    this.latency,
  });
  final Uri origin;
  final bool preferred;
  final Duration? latency;

  /// Station identity used for de-duplication and for reporting which station
  /// failed. Compared by [webPageKey] so a trailing slash is not a difference.
  String get stationKey => webPageKey(origin);
}

/// Per-route health (ADR-0006). The profile badge is the aggregate of these;
/// a single entry here only describes the direct route.
class AdapterHealth {
  const AdapterHealth({
    required this.state,
    this.checkedAt,
    this.failureReason,
    this.stationKey,
  });

  const AdapterHealth.unknown() : this(state: ProfileHealthState.unknown);

  final ProfileHealthState state;
  final DateTime? checkedAt;

  /// Why the last check failed, in the adapter's own words. Reporting only:
  /// nothing branches on this text.
  final String? failureReason;

  /// Which base station the observation was made at, when one was involved.
  final String? stationKey;

  bool get isUsable => state == ProfileHealthState.ok;
}

/// Cooperative cancellation. Passing it across the adapter boundary keeps an
/// abort from looking like a failure, without exposing any transport detail.
class CancellationSignal {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Marks the signal; safe to call more than once.
  void cancel() => _cancelled = true;

  /// Throws [SiteAdapterError.kind] `cancelled` once cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw SiteAdapterError.cancelled();
  }
}

enum SiteAdapterErrorKind {
  cancelled,
  unavailable,
  credentialRejected,
  unauthenticated,
  notFound,
  malformedContent,
}

/// The one failure type that crosses the adapter boundary. Messages stay short
/// and site-neutral so a caller can show them without translating site jargon.
class SiteAdapterError implements Exception {
  const SiteAdapterError(this.kind, this.message);

  SiteAdapterError.cancelled() : this(SiteAdapterErrorKind.cancelled, '已取消');

  final SiteAdapterErrorKind kind;
  final String message;

  @override
  String toString() => 'SiteAdapterError(${kind.name}): $message';
}

/// The single entry point through which the app knows a site's direct route.
///
/// An adapter is bound to one [SiteProfile] and does not replace it (ADR-0004).
/// Everything site-specific — transport envelope, encryption, signing, device
/// identity, domain fallback, credential refresh protocol, catalog parsing —
/// lives behind this interface.
///
/// Exposed: the catalog, lines and their media candidates, the site credential,
/// the login page and its verdict, the live base stations, and a health check.
/// Not exposed: encryption schemes, signing parameters, the shape of a site's
/// domain pool, the underlying HTTP client, and retry policy.
abstract interface class SiteAdapter {
  /// Stable identity of the adapter implementation, used by the registry for
  /// diagnostics. Not a site concept.
  String get id;

  /// The profile this adapter is bound to.
  int get profileId;

  /// The addresses this adapter claims. Matching rules are its own; the
  /// registry only asks [matchesAddress].
  List<Uri> get addresses;

  /// The session currently held for this profile.
  SiteCredential get credential;

  /// Whether [address] belongs to this site, comparing [Uri.host] and
  /// [Uri.port] only: a path, a query or a trailing slash never decide
  /// ownership.
  bool matchesAddress(Uri address);

  /// The theater feed, i.e. the catalog's browsable home.
  Future<TheaterFeed> theater(CancellationSignal cancel);

  /// The episodes of [seriesKey] in catalog order.
  Future<SeriesEpisodes> episodes(String seriesKey, CancellationSignal cancel);

  /// The lines through which episode [episodeNumber] of [seriesKey] is played.
  Future<List<Line>> lines(
    String seriesKey,
    int episodeNumber,
    CancellationSignal cancel,
  );

  /// The media candidates [line] yields. Downstream consumes only these
  /// (ADR-0002).
  Future<List<MediaCandidate>> candidates(Line line, CancellationSignal cancel);

  /// Where the user signs in for this site.
  Future<LoginEntry> loginEntry(CancellationSignal cancel);

  /// Whether the current session counts as signed in.
  Future<LoginVerdict> loginVerdict(CancellationSignal cancel);

  /// Submits what the user typed on the login page and reports the verdict.
  Future<LoginVerdict> signIn(
    SiteCredentialUpdate update,
    CancellationSignal cancel,
  );

  /// Exchanges the held refresh token for a fresh session (凭证刷新).
  Future<SiteCredential> refreshCredential(CancellationSignal cancel);

  /// Drops the held session.
  Future<void> signOut(CancellationSignal cancel);

  /// The base stations usable right now, best first.
  Future<List<BaseStation>> liveStations(CancellationSignal cancel);

  /// Best-effort health of this route.
  Future<AdapterHealth> health(CancellationSignal cancel);
}

/// A resolved adapter for one address.
class SiteAdapterMatch {
  const SiteAdapterMatch({required this.adapter, required this.address});
  final SiteAdapter adapter;

  /// The address that was resolved, kept so a caller can report which URL
  /// landed where.
  final Uri address;
}

/// A resolved adapter for one profile.
class SiteAdapterBinding {
  const SiteAdapterBinding({required this.adapter, required this.profileId});
  final SiteAdapter adapter;
  final int profileId;
}

/// There is no adapter for this address or profile. This is an answer, not a
/// failure: the app says "暂无适配器" instead of surfacing an error.
class NoSiteAdapter {
  const NoSiteAdapter.address(
    this.requestedAddress, {
    required this.adapterCount,
  }) : requestedProfileId = null;

  const NoSiteAdapter.profile(
    this.requestedProfileId, {
    required this.adapterCount,
  }) : requestedAddress = null;

  final Uri? requestedAddress;
  final int? requestedProfileId;

  /// How many adapters were consulted, so a caller can explain the miss
  /// without inspecting the registry.
  final int adapterCount;

  bool get byAddress => requestedAddress != null;
}

/// A site adapter could not be registered.
class SiteAdapterRegistrationError implements Exception {
  const SiteAdapterRegistrationError(this.code, this.message);
  final SiteAdapterRegistrationErrorCode code;
  final String message;

  @override
  String toString() => 'SiteAdapterRegistrationError(${code.name}): $message';
}

enum SiteAdapterRegistrationErrorCode {
  duplicateId,
  duplicateProfile,
  duplicateAddress,
  emptyAddress,
}

/// A registry instance cannot be changed: every edit returns a new registry,
/// so a caller that captured one keeps seeing the adapters it knew about.
abstract interface class SiteAdapterRegistry {
  /// An empty registry. Callers add adapters with [withAdapter].
  const factory SiteAdapterRegistry.empty() = _EmptyRegistry;

  /// A registry holding [adapters] in the given order.
  factory SiteAdapterRegistry(Iterable<SiteAdapter> adapters) =>
      _AdapterRegistry._build(adapters);

  /// Every registered adapter, in registration order.
  List<SiteAdapter> get adapters;

  /// Returns a new registry with [adapter] appended. The receiver is untouched,
  /// which is how callers gain adapters without changing anything that already
  /// resolved an adapter.
  SiteAdapterRegistry withAdapter(SiteAdapter adapter);

  /// The adapter that owns [address], or a [NoSiteAdapter] answer.
  SiteAdapterMatch? resolveAddress(Uri address);

  /// The adapter bound to the profile with [profileId], or a
  /// [NoSiteAdapter] answer.
  SiteAdapterBinding? resolveProfile(int profileId);

  /// Resolves [address] to an adapter, reporting the miss explicitly.
  Future<SiteAdapterResolution> byAddress(Uri address);

  /// Resolves a stored profile to its adapter, reporting the miss explicitly.
  Future<SiteAdapterResolution> byProfile(SiteProfile profile);
}

/// The outcome of resolving an address or a profile: either an adapter or the
/// explicit "no adapter" answer. Never an exception for an ordinary miss.
sealed class SiteAdapterResolution {
  const SiteAdapterResolution();

  /// The adapter when one was found, otherwise null. Callers that treat a miss
  /// as "just no adapter here" use this; callers that must explain the miss
  /// switch on the concrete subtype.
  SiteAdapter? get adapterOrNull;
}

class SiteAdapterFound extends SiteAdapterResolution {
  const SiteAdapterFound(this.adapter);
  final SiteAdapter adapter;

  @override
  SiteAdapter get adapterOrNull => adapter;
}

class SiteAdapterMissing extends SiteAdapterResolution {
  const SiteAdapterMissing(this.noAdapter);
  final NoSiteAdapter noAdapter;

  @override
  SiteAdapter? get adapterOrNull => null;
}

class _EmptyRegistry implements SiteAdapterRegistry {
  const _EmptyRegistry();

  @override
  List<SiteAdapter> get adapters => const [];

  @override
  SiteAdapterRegistry withAdapter(SiteAdapter adapter) =>
      _AdapterRegistry._build([adapter]);

  @override
  SiteAdapterMatch? resolveAddress(Uri address) => null;

  @override
  SiteAdapterBinding? resolveProfile(int profileId) => null;

  @override
  Future<SiteAdapterResolution> byAddress(Uri address) async =>
      SiteAdapterMissing(NoSiteAdapter.address(address, adapterCount: 0));

  @override
  Future<SiteAdapterResolution> byProfile(SiteProfile profile) async =>
      SiteAdapterMissing(NoSiteAdapter.profile(profile.id, adapterCount: 0));
}

class _AdapterRegistry implements SiteAdapterRegistry {
  _AdapterRegistry._(this.adapters);

  static _AdapterRegistry _build(Iterable<SiteAdapter> adapters) {
    final list = <SiteAdapter>[];
    for (final adapter in adapters) {
      _checkRegistration(list, adapter);
      list.add(adapter);
    }
    return _AdapterRegistry._(List.unmodifiable(list));
  }

  static void _checkRegistration(List<SiteAdapter> existing, SiteAdapter next) {
    if (next.id.trim().isEmpty) {
      throw const SiteAdapterRegistrationError(
        SiteAdapterRegistrationErrorCode.duplicateId,
        '适配器必须带一个非空 id',
      );
    }
    for (final known in existing) {
      if (known.id == next.id) {
        throw SiteAdapterRegistrationError(
          SiteAdapterRegistrationErrorCode.duplicateId,
          '适配器 id 重复：${next.id}',
        );
      }
      if (known.profileId == next.profileId) {
        throw SiteAdapterRegistrationError(
          SiteAdapterRegistrationErrorCode.duplicateProfile,
          '档案 ${next.profileId} 已绑定适配器 ${known.id}',
        );
      }
    }
  }

  @override
  final List<SiteAdapter> adapters;

  @override
  SiteAdapterRegistry withAdapter(SiteAdapter adapter) =>
      _AdapterRegistry._build([...adapters, adapter]);

  @override
  SiteAdapterMatch? resolveAddress(Uri address) {
    for (final adapter in adapters) {
      if (adapter.matchesAddress(address)) {
        return SiteAdapterMatch(adapter: adapter, address: address);
      }
    }
    return null;
  }

  @override
  SiteAdapterBinding? resolveProfile(int profileId) {
    for (final adapter in adapters) {
      if (adapter.profileId == profileId) {
        return SiteAdapterBinding(adapter: adapter, profileId: profileId);
      }
    }
    return null;
  }

  @override
  Future<SiteAdapterResolution> byAddress(Uri address) async {
    final match = resolveAddress(address);
    if (match != null) return SiteAdapterFound(match.adapter);
    return SiteAdapterMissing(
      NoSiteAdapter.address(address, adapterCount: adapters.length),
    );
  }

  @override
  Future<SiteAdapterResolution> byProfile(SiteProfile profile) async {
    final binding = resolveProfile(profile.id);
    if (binding != null) return SiteAdapterFound(binding.adapter);
    return SiteAdapterMissing(
      NoSiteAdapter.profile(profile.id, adapterCount: adapters.length),
    );
  }
}
