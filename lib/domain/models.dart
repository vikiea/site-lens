import 'dart:convert';

enum ProbeStage { http, homepage }

enum DetectionOutcome { completed, cancelled, failed }

enum ProbeStatus {
  reachable,
  ready,
  unavailable,
  timeout,
  offline,
  certificateError,
  challenge,
  interactionRequired,
  unsupported,
  cancelled,
}

class Candidate {
  const Candidate({
    required this.id,
    required this.url,
    required this.label,
    this.enabled = true,
    this.sourceId,
    this.profileId,
    this.readySelector = 'main',
    this.readySelectorOverride,
  });
  final int id;
  final Uri url;
  final String label;
  final bool enabled;
  final int? sourceId;

  /// Owning [SiteProfile]. Null means the candidate sits in the fallback
  /// "未归类" bucket and has not been attached to a curated profile yet.
  final int? profileId;
  final String readySelector;

  /// Null means this candidate inherits the owning profile selector.
  final String? readySelectorOverride;
  String effectiveReadySelector(String? profileSelector) =>
      readySelectorOverride ?? profileSelector ?? readySelector;
  static const _unchangedOverride = Object();

  Candidate copyWith({
    bool? enabled,
    int? profileId,
    Object? readySelectorOverride = _unchangedOverride,
  }) => Candidate(
    id: id,
    url: url,
    label: label,
    enabled: enabled ?? this.enabled,
    sourceId: sourceId,
    profileId: profileId ?? this.profileId,
    readySelector: readySelector,
    readySelectorOverride: identical(readySelectorOverride, _unchangedOverride)
        ? this.readySelectorOverride
        : readySelectorOverride as String?,
  );
}

class PublishingSource {
  const PublishingSource({
    required this.id,
    required this.label,
    required this.url,
    required this.regionSelector,
    this.profileId,
    this.enabled = true,
    this.refreshedAt,
    this.error,
  });
  final int id;
  final String label;
  final Uri url;

  /// The profile this legacy row mirrors. Null only for rows that predate the
  /// v1 -> v2 migration and were never re-saved.
  final int? profileId;
  // An explicit selector for the "latest addresses" region; never whole-page links.
  final String regionSelector;
  final bool enabled;
  final DateTime? refreshedAt;
  final String? error;
}

class ProbeResult {
  const ProbeResult({
    required this.round,
    required this.candidateId,
    required this.stage,
    required this.status,
    required this.entryUrl,
    required this.checkedAt,
    this.finalUrl,
    this.elapsed,
    this.reason,
  });
  final int round;
  final int candidateId;
  final ProbeStage stage;
  final ProbeStatus status;
  final Uri entryUrl;
  final Uri? finalUrl;
  final Duration? elapsed;
  final DateTime checkedAt;
  final String? reason;
  bool get verified =>
      stage == ProbeStage.homepage && status == ProbeStatus.ready;
  Map<String, Object?> toJson() => {
    'round': round,
    'candidateId': candidateId,
    'stage': stage.name,
    'status': status.name,
    'entryUrl': entryUrl.toString(),
    'finalUrl': finalUrl?.toString(),
    'elapsedMs': elapsed?.inMilliseconds,
    'checkedAt': checkedAt.toIso8601String(),
    'reason': reason,
  };
  factory ProbeResult.fromJson(Map<String, dynamic> j) => ProbeResult(
    round: j['round'] as int,
    candidateId: j['candidateId'] as int,
    stage: ProbeStage.values.byName(j['stage'] as String),
    status: ProbeStatus.values.byName(j['status'] as String),
    entryUrl: Uri.parse(j['entryUrl'] as String),
    finalUrl: j['finalUrl'] == null ? null : Uri.parse(j['finalUrl'] as String),
    elapsed: j['elapsedMs'] == null
        ? null
        : Duration(milliseconds: j['elapsedMs'] as int),
    checkedAt: DateTime.parse(j['checkedAt'] as String),
    reason: j['reason'] as String?,
  );
}

/// Sorts probe results by whether the site is usable before considering speed.
/// Homepage-ready results are the strongest recommendation, HTTP-reachable
/// results are next, and failures remain visible after them for diagnosis.
int probeResultPriority(ProbeResult result) {
  if (result.verified) return 0;
  if (result.status == ProbeStatus.reachable) return 1;
  return 2;
}

int compareProbeResults(ProbeResult a, ProbeResult b) {
  final priority = probeResultPriority(a).compareTo(probeResultPriority(b));
  if (priority != 0) return priority;
  final elapsed = (a.elapsed ?? const Duration(days: 365)).compareTo(
    b.elapsed ?? const Duration(days: 365),
  );
  if (elapsed != 0) return elapsed;
  return a.candidateId.compareTo(b.candidateId);
}

class InstalledScript {
  const InstalledScript({
    required this.id,
    required this.name,
    required this.source,
    this.enabled = false,
    this.approvedDigest,
    this.networkMode = ScriptNetworkMode.declared,
    this.approvalReason,
    this.approvedAt,
    this.publicConfirmed = false,
  });
  final String id;
  final String name;
  final String source;
  final bool enabled;
  final String? approvedDigest;
  final ScriptNetworkMode networkMode;
  final String? approvalReason;
  final DateTime? approvedAt;
  final bool publicConfirmed;
}

enum ScriptNetworkMode { declared, public }

class PinnedDependency {
  const PinnedDependency({
    required this.url,
    required this.hash,
    required this.bytes,
  });
  final Uri url;
  final String hash;
  final List<int> bytes;
  String get text =>
      utf8.decode(bytes); // Invalid UTF-8 is a hard import error.
}

/// A `@resource` snapshot pinned at confirmation time. `GM_getResourceURL`
/// turns [bytes] into a `blob:` URL and never exposes [url].
class PinnedResource {
  const PinnedResource({
    required this.name,
    required this.url,
    required this.hash,
    required this.bytes,
  });
  final String name;
  final Uri url;
  final String hash;
  final List<int> bytes;
  String get text =>
      utf8.decode(bytes); // Invalid UTF-8 is a hard import error.
}

Uri webUri(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('请输入无账号密码的 HTTP(S) 地址');
  }
  return uri.removeFragment();
}

/// Parses an address the *user* typed, where the scheme is optional.
///
/// `example.com/play` becomes `https://example.com/play`; everything else keeps
/// the rules of [webUri] (http/https only, a real host, no credentials). Call
/// this for input fields, and keep [webUri] for URLs the app produced itself —
/// a missing scheme there is a bug, not a shortcut.
Uri userUri(String input) {
  final trimmed = input.trim();
  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(trimmed);
  try {
    return webUri(hasScheme ? trimmed : 'https://$trimmed');
  } on FormatException {
    throw const FormatException('请输入 HTTP(S) 地址；前缀可以省略');
  }
}

String landingKey(Uri uri) => uri.removeFragment().toString();

/// Stable page identity used when comparing browser URLs returned by WebView
/// with URLs entered by the user. WebView commonly adds `/` to an empty path;
/// fragments are navigation state, not a different publishing page.
String webPageKey(Uri uri) {
  final clean = uri.removeFragment();
  return Uri(
    scheme: clean.scheme.toLowerCase(),
    host: clean.host.toLowerCase(),
    port: clean.hasPort ? clean.port : null,
    path: clean.path.isEmpty ? '/' : clean.path,
    query: clean.query,
  ).toString();
}

/// The name reserved for candidates that do not belong to any curated profile.
/// Migration puts manual (source-less) candidates here so nothing is orphaned.
const unassignedProfileName = '未归类';

/// Health of a profile's landing reachability, updated only by the background
/// survival check. Never feeds ranking or recommendations.
enum ProfileHealthState { unknown, ok, failing }

/// A curated "site profile" — the first-class object of the product. One
/// profile groups a brand's publishing pages, its candidate landings, its
/// bound scripts and its health badge.
class SiteProfile {
  const SiteProfile({
    required this.id,
    required this.name,
    required this.createdAt,
    this.enabled = true,
    this.readySelector = 'main',
    this.lastLanding,
    this.lastLandingAt,
  });
  final int id;
  final String name;
  final bool enabled;
  final String readySelector;
  final Uri? lastLanding;
  final DateTime? lastLandingAt;
  final DateTime createdAt;
}

/// A publishing page (primary or backup) that a profile discovers candidates
/// from, together with the selector for its "latest addresses" region.
class ProfilePage {
  const ProfilePage({
    required this.id,
    required this.profileId,
    required this.url,
    required this.regionSelector,
    this.enabled = true,
    this.refreshedAt,
    this.error,
  });
  final int id;
  final int profileId;
  final Uri url;
  final String regionSelector;
  final bool enabled;
  final DateTime? refreshedAt;
  final String? error;
}

/// Background survival check state for one profile. Best-effort only.
class ProfileHealth {
  const ProfileHealth({
    required this.profileId,
    this.consecutiveFailures = 0,
    this.state = ProfileHealthState.unknown,
    this.lastCheckedAt,
    this.lastOkAt,
  });
  final int profileId;
  final int consecutiveFailures;
  final ProfileHealthState state;
  final DateTime? lastCheckedAt;
  final DateTime? lastOkAt;
  ProfileHealth copyWith({
    int? consecutiveFailures,
    ProfileHealthState? state,
    DateTime? lastCheckedAt,
    DateTime? lastOkAt,
  }) => ProfileHealth(
    profileId: profileId,
    consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
    state: state ?? this.state,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    lastOkAt: lastOkAt ?? this.lastOkAt,
  );
}

/// Binding of a script to a profile. The row carries the content fingerprint so
/// two profiles holding the same script can be detected and synced.
class ProfileScript {
  const ProfileScript({
    required this.profileId,
    required this.scriptId,
    required this.contentHash,
    this.enabled = false,
    this.approvedDigest,
  });
  final int profileId;
  final String scriptId;
  final String contentHash;
  final bool enabled;
  final String? approvedDigest;
}

/// Local "I already approved this pack fingerprint" memory. Never exported.
class PackApproval {
  const PackApproval({required this.fingerprint, required this.approvedAt});
  final String fingerprint;
  final DateTime approvedAt;
}

/// Outcome of "粘一个 URL → App 侦察" (plan §3.7). Nothing is persisted: the
/// user confirms before a profile is created.
class ReconResult {
  const ReconResult({
    required this.url,
    required this.finalUrl,
    required this.title,
    required this.regionSelector,
    required this.regionFound,
    required this.links,
    required this.inferredReadySelector,
    this.challenge = false,
    this.interactionRequired = false,
    this.note,
  });
  final Uri url;
  final Uri? finalUrl;
  final String title;

  /// The selector that produced [links]; `@latest-addresses` means the built-in
  /// heuristic matched, otherwise the user must supply one.
  final String regionSelector;
  final bool regionFound;
  final List<Uri> links;
  final String? inferredReadySelector;
  final bool challenge;
  final bool interactionRequired;
  final String? note;
}

/// Versioned filtering policy.  Policies contain user intent only; compiled
/// rules and response bodies live in the app-private filter store.
enum FilterSnapshotState {
  missing,
  downloading,
  compiling,
  valid,
  corrupt,
  failed,
  degraded,
}

enum FilterDecision { allow, block, unsupported }

enum FilterSourceStatus { missing, downloading, compiling, valid, failed }

/// Metadata for a rule source. Rule text and compiled output stay in the
/// application-private directory; this object is safe to persist or export.
class FilterSource {
  const FilterSource({
    required this.id,
    required this.label,
    required this.url,
    this.profileId,
    this.kind = 'list',
    this.version = '',
    this.license = '',
    this.sha256 = '',
    this.status = FilterSourceStatus.missing,
    this.fileRef,
    this.refreshedAt,
    this.error,
  });

  final int id;
  final String label;
  final Uri url;
  final int? profileId;
  final String kind;
  final String version;
  final String license;
  final String sha256;
  final FilterSourceStatus status;
  final String? fileRef;
  final DateTime? refreshedAt;
  final String? error;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'url': url.toString(),
    'profileId': profileId,
    'kind': kind,
    'version': version,
    'license': license,
    'sha256': sha256,
    'status': status.name,
    'fileRef': fileRef,
    'refreshedAt': refreshedAt?.toIso8601String(),
    'error': error,
  };

  factory FilterSource.fromJson(Map<String, dynamic> json) => FilterSource(
    id: (json['id'] as num).toInt(),
    label: json['label'] as String? ?? '',
    url: webUri(json['url'] as String),
    profileId: (json['profileId'] as num?)?.toInt(),
    kind: json['kind'] as String? ?? 'list',
    version: json['version'] as String? ?? '',
    license: json['license'] as String? ?? '',
    sha256: json['sha256'] as String? ?? '',
    status: FilterSourceStatus.values.byName(
      json['status'] as String? ?? FilterSourceStatus.missing.name,
    ),
    fileRef: json['fileRef'] as String?,
    refreshedAt: json['refreshedAt'] == null
        ? null
        : DateTime.parse(json['refreshedAt'] as String),
    error: json['error'] as String?,
  );
}

class FilterPolicy {
  const FilterPolicy({
    this.enabled = false,
    this.pageFiltering = true,
    this.domainExceptions = const <String>{},
    this.blockedDomains = const <String>{},
  });

  final bool enabled;
  final bool pageFiltering;
  final Set<String> domainExceptions;
  final Set<String> blockedDomains;

  bool get isDefault =>
      !enabled &&
      pageFiltering &&
      domainExceptions.isEmpty &&
      blockedDomains.isEmpty;

  FilterPolicy copyWith({
    bool? enabled,
    bool? pageFiltering,
    Set<String>? domainExceptions,
    Set<String>? blockedDomains,
  }) => FilterPolicy(
    enabled: enabled ?? this.enabled,
    pageFiltering: pageFiltering ?? this.pageFiltering,
    domainExceptions: domainExceptions ?? this.domainExceptions,
    blockedDomains: blockedDomains ?? this.blockedDomains,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'pageFiltering': pageFiltering,
    'domainExceptions': domainExceptions.toList()..sort(),
    'blockedDomains': blockedDomains.toList()..sort(),
  };

  factory FilterPolicy.fromJson(Map<String, dynamic> json) => FilterPolicy(
    enabled: json['enabled'] as bool? ?? false,
    pageFiltering: json['pageFiltering'] as bool? ?? true,
    domainExceptions: _stringSet(json['domainExceptions']),
    blockedDomains: _stringSet(json['blockedDomains']),
  );

  static Set<String> _stringSet(Object? value) => value is List
      ? value
            .whereType<String>()
            .map((v) => v.trim().toLowerCase())
            .where((v) => v.isNotEmpty)
            .toSet()
      : <String>{};
}

class FilterSnapshot {
  const FilterSnapshot({
    required this.id,
    required this.sourceId,
    required this.version,
    required this.sourceUrl,
    required this.sha256,
    required this.state,
    required this.createdAt,
    required this.fileRef,
    this.unsupportedRuleCount = 0,
    this.error,
  });

  final String id;
  final int? sourceId;
  final String version;
  final Uri sourceUrl;
  final String sha256;
  final FilterSnapshotState state;
  final DateTime createdAt;
  final String fileRef;
  final int unsupportedRuleCount;
  final String? error;

  Map<String, Object?> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'version': version,
    'sourceUrl': sourceUrl.toString(),
    'sha256': sha256,
    'state': state.name,
    'createdAt': createdAt.toIso8601String(),
    'fileRef': fileRef,
    'unsupportedRuleCount': unsupportedRuleCount,
    'error': error,
  };

  factory FilterSnapshot.fromJson(Map<String, dynamic> json) => FilterSnapshot(
    id: json['id'] as String,
    sourceId: json['sourceId'] as int?,
    version: json['version'] as String? ?? '',
    sourceUrl: webUri(json['sourceUrl'] as String),
    sha256: json['sha256'] as String,
    state: FilterSnapshotState.values.byName(json['state'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    fileRef: json['fileRef'] as String,
    unsupportedRuleCount: (json['unsupportedRuleCount'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );
}

/// Identity carried with every host-side filtering decision.
class HostFilterContext {
  const HostFilterContext({
    required this.hostId,
    required this.generation,
    required this.sourceUrl,
    required this.snapshotId,
    this.profileId,
  });

  final int hostId;
  final int generation;
  final Uri sourceUrl;
  final String snapshotId;
  final int? profileId;
}

enum MediaCandidateSource { dom, registered }

class MediaCandidate {
  const MediaCandidate({
    required this.id,
    required this.hostId,
    required this.generation,
    required this.sourceUrl,
    required this.mediaUrl,
    required this.title,
    required this.mime,
    required this.source,
    this.durationMs,
    this.createdAt,
  });

  final String id;
  final int hostId;
  final int generation;
  final Uri sourceUrl;
  final Uri mediaUrl;
  final String title;
  final String mime;
  final MediaCandidateSource source;
  final int? durationMs;
  final DateTime? createdAt;

  bool get playable =>
      ['http', 'https'].contains(mediaUrl.scheme) &&
      mediaUrl.host.isNotEmpty &&
      mediaUrl.userInfo.isEmpty &&
      !mediaUrl.toString().startsWith('blob:');

  Map<String, Object?> toJson() => {
    'id': id,
    'hostId': hostId,
    'generation': generation,
    'sourceUrl': sourceUrl.toString(),
    'mediaUrl': mediaUrl.toString(),
    'title': title,
    'mime': mime,
    'source': source.name,
    'durationMs': durationMs,
    'createdAt': createdAt?.toIso8601String(),
  };

  factory MediaCandidate.fromJson(Map<String, dynamic> json) {
    final source = webUri(json['sourceUrl'] as String);
    final media = webUri(json['mediaUrl'] as String);
    return MediaCandidate(
      id: json['id'] as String,
      hostId: (json['hostId'] as num).toInt(),
      generation: (json['generation'] as num).toInt(),
      sourceUrl: source,
      mediaUrl: media,
      title: (json['title'] as String? ?? '').substring(
        0,
        (json['title'] as String? ?? '').length.clamp(0, 512),
      ),
      mime: (json['mime'] as String? ?? '').substring(
        0,
        (json['mime'] as String? ?? '').length.clamp(0, 128),
      ),
      source: MediaCandidateSource.values.byName(json['source'] as String),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
    );
  }
}

enum MediaTaskState {
  queued,
  downloading,
  paused,
  completed,
  playable,
  cancelled,
  failed,
  reauthorize,
}

class MediaTask {
  const MediaTask({
    required this.id,
    required this.candidateId,
    required this.hostId,
    required this.generation,
    required this.sourceUrl,
    required this.cacheKey,
    required this.state,
    required this.updatedAt,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.errorCode,
    this.localRef,
  });

  final String id;
  final String candidateId;
  final int hostId;
  final int generation;
  final Uri sourceUrl;
  final String cacheKey;
  final MediaTaskState state;
  final DateTime updatedAt;
  final int bytesDownloaded;
  final int? totalBytes;
  final String? errorCode;
  final String? localRef;

  MediaTask copyWith({
    MediaTaskState? state,
    int? bytesDownloaded,
    Object? totalBytes = _unset,
    Object? errorCode = _unset,
    Object? localRef = _unset,
  }) => MediaTask(
    id: id,
    candidateId: candidateId,
    hostId: hostId,
    generation: generation,
    sourceUrl: sourceUrl,
    cacheKey: cacheKey,
    state: state ?? this.state,
    updatedAt: DateTime.now().toUtc(),
    bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
    totalBytes: identical(totalBytes, _unset)
        ? this.totalBytes
        : totalBytes as int?,
    errorCode: identical(errorCode, _unset)
        ? this.errorCode
        : errorCode as String?,
    localRef: identical(localRef, _unset) ? this.localRef : localRef as String?,
  );

  static const _unset = Object();

  Map<String, Object?> toJson() => {
    'id': id,
    'candidateId': candidateId,
    'hostId': hostId,
    'generation': generation,
    'sourceUrl': sourceUrl.toString(),
    'cacheKey': cacheKey,
    'state': state.name,
    'updatedAt': updatedAt.toIso8601String(),
    'bytesDownloaded': bytesDownloaded,
    'totalBytes': totalBytes,
    'errorCode': errorCode,
    'localRef': localRef,
  };

  factory MediaTask.fromJson(Map<String, dynamic> json) => MediaTask(
    id: json['id'] as String,
    candidateId: json['candidateId'] as String,
    hostId: (json['hostId'] as num).toInt(),
    generation: (json['generation'] as num).toInt(),
    sourceUrl: webUri(json['sourceUrl'] as String),
    cacheKey: json['cacheKey'] as String,
    state: MediaTaskState.values.byName(json['state'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    bytesDownloaded: (json['bytesDownloaded'] as num?)?.toInt() ?? 0,
    totalBytes: (json['totalBytes'] as num?)?.toInt(),
    errorCode: json['errorCode'] as String?,
    localRef: json['localRef'] as String?,
  );
}

class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.address,
    this.model,
    this.supportsMp4 = false,
    this.supportsHls = false,
    this.supportsSeek = false,
  });

  final String id;
  final String name;
  final Uri address;
  final String? model;
  final bool supportsMp4;
  final bool supportsHls;
  final bool supportsSeek;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'address': address.toString(),
    'model': model,
    'supportsMp4': supportsMp4,
    'supportsHls': supportsHls,
    'supportsSeek': supportsSeek,
  };

  factory CastDevice.fromJson(Map<String, dynamic> json) => CastDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    address: Uri.parse(json['address'] as String),
    model: json['model'] as String?,
    supportsMp4: json['supportsMp4'] as bool? ?? false,
    supportsHls: json['supportsHls'] as bool? ?? false,
    supportsSeek: json['supportsSeek'] as bool? ?? false,
  );
}

enum CastSessionState {
  discovering,
  connecting,
  settingMedia,
  playing,
  paused,
  stopped,
  failed,
}

class CastSession {
  const CastSession({
    required this.id,
    required this.deviceId,
    required this.mediaTaskId,
    required this.state,
    required this.createdAt,
    this.relayToken,
    this.errorCode,
  });

  final String id;
  final String deviceId;
  final String mediaTaskId;
  final CastSessionState state;
  final DateTime createdAt;
  final String? relayToken;
  final String? errorCode;

  Map<String, Object?> toJson() => {
    'id': id,
    'deviceId': deviceId,
    'mediaTaskId': mediaTaskId,
    'state': state.name,
    'createdAt': createdAt.toIso8601String(),
    'relayToken': relayToken,
    'errorCode': errorCode,
  };

  factory CastSession.fromJson(Map<String, dynamic> json) => CastSession(
    id: json['id'] as String,
    deviceId: json['deviceId'] as String,
    mediaTaskId: json['mediaTaskId'] as String,
    state: CastSessionState.values.byName(json['state'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    relayToken: json['relayToken'] as String?,
    errorCode: json['errorCode'] as String?,
  );
}
