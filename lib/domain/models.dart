import 'dart:convert';

import 'package:crypto/crypto.dart';

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

enum FilterSourceStatus {
  missing,
  downloading,
  compiling,
  valid,
  degraded,
  failed,
}

/// Metadata for a rule source. Rule text and compiled output stay in the
/// application-private directory; this object is safe to persist or export.
class FilterSource {
  const FilterSource({
    required this.id,
    required this.label,
    required this.url,
    this.profileId,
    this.kind = 'list',
    this.enabled = true,
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
  final bool enabled;
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
    'enabled': enabled,
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
    enabled: json['enabled'] as bool? ?? true,
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

enum PlaybackEvidenceState { idle, playing, paused, ended, unknown }

/// A document-scoped observation of the media that the page is actually using.
///
/// This is deliberately separate from [MediaCandidate]. A candidate is an
/// authorized resource the page exposed; evidence additionally proves which
/// frame/document/epoch was playing it. A watch-save owner may only be created
/// after [confirmed] is true and [state] is [PlaybackEvidenceState.playing].
class PlaybackEvidence {
  const PlaybackEvidence({
    required this.hostId,
    required this.generation,
    required this.frame,
    required this.document,
    required this.epoch,
    required this.pageUrl,
    required this.sourceUrl,
    required this.sourceKey,
    required this.seriesKey,
    required this.episodeNumber,
    required this.title,
    required this.state,
    required this.confirmed,
    required this.reason,
    required this.observedAt,
    this.mediaElementId = '',
    this.snapshot = 0,
    this.eventSequence = 0,
    this.positionMs = 0,
    this.durationMs,
    this.sourceRevision = '',
  });

  final int hostId;
  final int generation;
  final String frame;
  final String document;
  final int epoch;
  final Uri pageUrl;
  final Uri? sourceUrl;
  final String sourceKey;
  final String? seriesKey;
  final int? episodeNumber;
  final String title;
  final PlaybackEvidenceState state;
  final bool confirmed;
  final String? reason;
  final DateTime observedAt;
  final String mediaElementId;
  final int snapshot;
  final int eventSequence;
  final int positionMs;
  final int? durationMs;
  final String sourceRevision;

  bool get isPlaying => state == PlaybackEvidenceState.playing;
  bool get hasStableIdentity => confirmed && sourceKey.isNotEmpty;

  /// The complete precondition for automatic viewing-save creation. Sites
  /// without an explicit series/episode identity remain visible for manual
  /// selection and are never guessed here.
  bool get autoSaveEligible =>
      hasStableIdentity &&
      isPlaying &&
      seriesKey != null &&
      episodeNumber != null;

  /// A non-idle observation may update an existing watch owner. Creation is
  /// intentionally stricter and remains limited to [autoSaveEligible].
  bool get watchSaveEligible =>
      hasStableIdentity &&
      state != PlaybackEvidenceState.idle &&
      seriesKey != null &&
      episodeNumber != null;

  String get identityKey => [
    seriesKey ?? '',
    sourceKey,
    episodeNumber?.toString() ?? '?',
  ].join('\u0000');

  factory PlaybackEvidence.fromWire({
    required int hostId,
    required int generation,
    required Map<String, dynamic> raw,
    DateTime? observedAt,
  }) {
    final frame = (raw['frame'] as String? ?? '').trim();
    final document = (raw['document'] as String? ?? '').trim();
    if (frame.isEmpty || document.isEmpty) {
      throw const FormatException('播放证据缺少 frame/document');
    }
    final pageUrl = webUri(raw['pageUrl'] as String? ?? '');
    final sourceUrl = optionalMediaUri(raw['sourceUrl'] as String?);
    final suppliedSourceKey = (raw['sourceKey'] as String? ?? '').trim();
    final sourceKey = sourceUrl == null
        ? suppliedSourceKey
        : mediaCandidateAuthorizationKey(sourceUrl);
    if (sourceUrl != null && suppliedSourceKey.isNotEmpty) {
      final suppliedUrl = Uri.tryParse(suppliedSourceKey);
      if (suppliedUrl == null ||
          mediaCandidateAuthorizationKey(suppliedUrl) != sourceKey) {
        throw const FormatException('播放证据 sourceKey 与 sourceUrl 不一致');
      }
    }
    if (sourceKey.length > 4096) {
      throw const FormatException('播放证据 sourceKey 过长');
    }
    final rawSeries = (raw['seriesKey'] as String? ?? '').trim();
    final rawTitle = (raw['title'] as String? ?? '').trim();
    final rawElement = (raw['mediaElementId'] as String? ?? '').trim();
    final position = (raw['positionMs'] as num?)?.toInt() ?? 0;
    final duration = (raw['durationMs'] as num?)?.toInt();
    final episode = (raw['episodeNumber'] as num?)?.toInt();
    final parsedEpisode = episode != null && episode > 0 && episode < 100000
        ? episode
        : null;
    final rawState = (raw['state'] as String? ?? '').trim();
    final state = switch (rawState) {
      'idle' => PlaybackEvidenceState.idle,
      'playing' => PlaybackEvidenceState.playing,
      'paused' => PlaybackEvidenceState.paused,
      'ended' => PlaybackEvidenceState.ended,
      _ => PlaybackEvidenceState.unknown,
    };
    return PlaybackEvidence(
      hostId: hostId,
      generation: generation,
      frame: frame,
      document: document,
      epoch: (raw['epoch'] as num?)?.toInt() ?? -1,
      pageUrl: pageUrl,
      sourceUrl: sourceUrl,
      sourceKey: sourceKey,
      seriesKey: rawSeries.isEmpty ? null : rawSeries,
      episodeNumber: parsedEpisode,
      title: rawTitle.substring(0, rawTitle.length.clamp(0, 512)),
      state: state,
      confirmed: false,
      reason: null,
      observedAt: observedAt ?? DateTime.now().toUtc(),
      mediaElementId: rawElement,
      snapshot: (raw['snapshot'] as num?)?.toInt() ?? 0,
      eventSequence: (raw['eventSequence'] as num?)?.toInt() ?? 0,
      positionMs: position < 0 ? 0 : position,
      durationMs: duration != null && duration >= 0 ? duration : null,
      sourceRevision: (raw['sourceRevision'] as String? ?? '').trim(),
    );
  }

  PlaybackEvidence withConfirmation({
    required bool confirmed,
    String? reason,
  }) => PlaybackEvidence(
    hostId: hostId,
    generation: generation,
    frame: frame,
    document: document,
    epoch: epoch,
    pageUrl: pageUrl,
    sourceUrl: sourceUrl,
    sourceKey: sourceKey,
    seriesKey: seriesKey,
    episodeNumber: episodeNumber,
    title: title,
    state: state,
    confirmed: confirmed,
    reason: reason,
    observedAt: observedAt,
    mediaElementId: mediaElementId,
    snapshot: snapshot,
    eventSequence: eventSequence,
    positionMs: positionMs,
    durationMs: durationMs,
    sourceRevision: sourceRevision,
  );
}

enum WatchSaveState { playing, paused, ended, unknown }

/// A durable automatic viewing-save owner. This is intentionally separate
/// from [MediaTask]: observing playback does not enqueue a download or claim
/// the task/cache ownership used by manual media actions.
class WatchSave {
  const WatchSave({
    required this.ownerId,
    required this.sourceKey,
    required this.sourceUrl,
    required this.seriesKey,
    required this.episodeNumber,
    required this.title,
    required this.pageUrl,
    required this.hostId,
    required this.generation,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.profileId,
    this.positionMs = 0,
    this.durationMs,
    this.evidenceRevision = '',
  });

  final String ownerId;
  final String sourceKey;
  final Uri sourceUrl;
  final String seriesKey;
  final int episodeNumber;
  final String title;
  final Uri pageUrl;
  final int hostId;
  final int generation;
  final WatchSaveState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? profileId;
  final int positionMs;
  final int? durationMs;
  final String evidenceRevision;

  static String ownerIdFor(PlaybackEvidence evidence) =>
      'watch:${base64Url.encode(utf8.encode(evidence.identityKey))}';

  factory WatchSave.fromEvidence(
    PlaybackEvidence evidence, {
    int? profileId,
    DateTime? now,
  }) {
    if (!evidence.watchSaveEligible || evidence.sourceUrl == null) {
      throw StateError('播放证据不满足自动保存条件');
    }
    final timestamp = now ?? evidence.observedAt;
    return WatchSave(
      ownerId: ownerIdFor(evidence),
      sourceKey: evidence.sourceKey,
      sourceUrl: evidence.sourceUrl!,
      seriesKey: evidence.seriesKey!,
      episodeNumber: evidence.episodeNumber!,
      title: evidence.title,
      pageUrl: evidence.pageUrl,
      hostId: evidence.hostId,
      generation: evidence.generation,
      state: switch (evidence.state) {
        PlaybackEvidenceState.playing => WatchSaveState.playing,
        PlaybackEvidenceState.paused => WatchSaveState.paused,
        PlaybackEvidenceState.ended => WatchSaveState.ended,
        _ => WatchSaveState.unknown,
      },
      createdAt: timestamp,
      updatedAt: timestamp,
      profileId: profileId,
      positionMs: evidence.positionMs,
      durationMs: evidence.durationMs,
      evidenceRevision: _evidenceRevision(evidence),
    );
  }

  WatchSave copyWith({
    String? title,
    Uri? pageUrl,
    int? hostId,
    int? generation,
    WatchSaveState? state,
    DateTime? updatedAt,
    Object? profileId = _unset,
    int? positionMs,
    Object? durationMs = _unset,
    String? evidenceRevision,
  }) => WatchSave(
    ownerId: ownerId,
    sourceKey: sourceKey,
    sourceUrl: sourceUrl,
    seriesKey: seriesKey,
    episodeNumber: episodeNumber,
    title: title ?? this.title,
    pageUrl: pageUrl ?? this.pageUrl,
    hostId: hostId ?? this.hostId,
    generation: generation ?? this.generation,
    state: state ?? this.state,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    profileId: identical(profileId, _unset)
        ? this.profileId
        : profileId as int?,
    positionMs: positionMs ?? this.positionMs,
    durationMs: identical(durationMs, _unset)
        ? this.durationMs
        : durationMs as int?,
    evidenceRevision: evidenceRevision ?? this.evidenceRevision,
  );

  static const _unset = Object();
}

String _evidenceRevision(PlaybackEvidence evidence) => [
  _revisionPart(evidence.generation),
  _revisionPart(evidence.epoch),
  _revisionPart(evidence.snapshot),
  _revisionPart(evidence.eventSequence),
  evidence.sourceRevision,
].join(':');

String _revisionPart(int value) =>
    value.clamp(0, 9999999999).toString().padLeft(10, '0');

/// Infers a transport MIME from a media URL when a page did not expose a
/// `type` attribute.  A URL is only metadata here; the native player still
/// validates and opens the original address selected by the user.
String inferMediaMime(Uri url) {
  final path = url.path.toLowerCase();
  if (path.endsWith('.m3u8') || path.endsWith('.m3u')) {
    return 'application/vnd.apple.mpegurl';
  }
  if (path.endsWith('.mpd')) return 'application/dash+xml';
  if (path.endsWith('.mp4') || path.endsWith('.m4v')) return 'video/mp4';
  if (path.endsWith('.webm')) return 'video/webm';
  if (path.endsWith('.mov')) return 'video/quicktime';
  if (path.endsWith('.mkv')) return 'video/x-matroska';
  if (path.endsWith('.ts')) return 'video/mp2t';
  if (path.endsWith('.ogv')) return 'video/ogg';
  if (path.endsWith('.mp3')) return 'audio/mpeg';
  if (path.endsWith('.m4a')) return 'audio/mp4';
  if (path.endsWith('.oga') || path.endsWith('.ogg')) return 'audio/ogg';
  if (path.endsWith('.wav')) return 'audio/wav';
  return '';
}

/// HLS and signed player URLs often differ only in short-lived authorization
/// parameters.  Keep the full URL for playback, but use this stable identity
/// to collapse repeated DOM/resource observations into one candidate.
String mediaCandidateKey(Uri url) {
  final clean = url.removeFragment();
  if (clean.queryParameters.isEmpty) return clean.toString();
  const volatile = {
    'auth',
    'auth_key',
    'expires',
    'expire',
    'exp',
    'hmac',
    'sig',
    'sign',
    'signature',
    't',
    'time',
    'timestamp',
    'via',
    'via_bm',
  };
  final retained = <String, String>{};
  for (final entry in clean.queryParameters.entries) {
    if (!volatile.contains(entry.key.toLowerCase())) {
      retained[entry.key] = entry.value;
    }
  }
  return clean.replace(queryParameters: retained).toString();
}

/// Identity used only while refreshing an expired authorization URL for an
/// existing task. Content selection parameters remain part of this key;
/// `token` is ignored only because the reauthorization flow already requires
/// the same page, host, generation and media candidate context.
String mediaCandidateAuthorizationKey(Uri url) {
  final clean = url.removeFragment();
  if (clean.queryParameters.isEmpty) return clean.toString();
  const volatile = {
    'auth',
    'auth_key',
    'expires',
    'expire',
    'exp',
    'hmac',
    'sig',
    'sign',
    'signature',
    't',
    'time',
    'timestamp',
    'via',
    'via_bm',
    'token',
  };
  final retained = <String, String>{};
  for (final entry in clean.queryParameters.entries) {
    if (!volatile.contains(entry.key.toLowerCase())) {
      retained[entry.key] = entry.value;
    }
  }
  return clean.replace(queryParameters: retained).toString();
}

/// UI/session identity for a media resource. HLS providers frequently put a
/// fresh signature on every observation; all signed variants of one playlist
/// still represent the same selectable stream, while the full URL remains on
/// the chosen candidate for authorization.
String mediaCandidateGroupKey(Uri url) {
  final clean = url.removeFragment();
  return mediaCandidateKey(clean);
}

/// User-facing and on-disk name for folders created by the legacy batch
/// downloader. The suffix is transport metadata, not part of the series name.
String mediaFolderDisplayName(String name) =>
    name.replaceFirst(RegExp(r' - 批次\d{16}$'), '');

/// Stable, filesystem-safe directory name for a media series. Episode
/// markers are removed so all episodes in one title share a parent folder.
String mediaSeriesDirectoryName(String title) {
  var value = title.trim().replaceAll(RegExp(r'\s+'), ' ');
  value = value.replaceAll(
    RegExp(
      r'(?:\s*[-|_·:/]?\s*(?:第\s*\d+\s*[集话期]|(?:episode|ep|e)\s*[:=_-]?\s*\d+))\s*$',
      caseSensitive: false,
    ),
    '',
  );
  value = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (value.isEmpty) return '未命名媒体';
  final runes = value.runes.toList();
  return String.fromCharCodes(runes.take(80));
}

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
    this.thumbnailUrl,
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
  final Uri? thumbnailUrl;
  final int? durationMs;
  final DateTime? createdAt;

  String get effectiveMime => mime.trim().isEmpty
      ? inferMediaMime(mediaUrl)
      : mime.trim().toLowerCase();

  bool get isHls =>
      effectiveMime.contains('mpegurl') ||
      mediaUrl.path.toLowerCase().endsWith('.m3u8') ||
      mediaUrl.path.toLowerCase().endsWith('.m3u');

  /// A transport segment reported by resource timing is not a selectable
  /// media item. It usually carries a short-lived signature and cannot be
  /// decoded without the HLS manifest that references it.
  bool get isLikelyTransportSegment {
    if (isHls) return false;
    final path = mediaUrl.path.toLowerCase();
    return path.endsWith('.ts') || effectiveMime == 'video/mp2t';
  }

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
    'thumbnailUrl': thumbnailUrl?.toString(),
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
      thumbnailUrl: optionalMediaUri(json['thumbnailUrl'] as String?),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
    );
  }
}

/// Stable content/representation identity shared across observations of one
/// stream. Host and document generations remain authorization context and are
/// deliberately excluded so a later page observation can join the same
/// resource without reusing the signed URL itself.
String mediaResourceKeyForCandidate(MediaCandidate candidate) {
  final input = [
    candidate.effectiveMime,
    mediaCandidateGroupKey(candidate.mediaUrl),
  ].join('|');
  return sha256.convert(utf8.encode(input)).toString();
}

/// Picks one human-readable directory for a user-triggered batch. Generic
/// active-player labels must not win over explicit episode titles; when every
/// candidate is generic, the caller can use a neutral batch fallback.
String? mediaBatchDirectoryName(Iterable<MediaCandidate> candidates) {
  final counts = <String, int>{};
  final firstSeen = <String, int>{};
  var order = 0;
  for (final candidate in candidates) {
    final title = candidate.title.trim();
    final lower = title.toLowerCase();
    if (title.isEmpty ||
        {'媒体', 'video', 'media'}.contains(lower) ||
        lower.contains('集数未确认')) {
      order++;
      continue;
    }
    final directory = mediaSeriesDirectoryName(title);
    if (directory == '未命名媒体') {
      order++;
      continue;
    }
    counts[directory] = (counts[directory] ?? 0) + 1;
    firstSeen.putIfAbsent(directory, () => order);
    order++;
  }
  if (counts.isEmpty) return null;
  // A single batch directory must never be named after only the most common
  // series when the selection contains multiple explicit series. Keep the
  // caller's neutral "批量媒体" fallback so the folder remains truthful.
  if (counts.length > 1) return null;
  final entries = counts.entries.toList()
    ..sort((left, right) {
      final count = right.value.compareTo(left.value);
      return count == 0
          ? firstSeen[left.key]!.compareTo(firstSeen[right.key]!)
          : count;
    });
  return entries.first.key;
}

Uri? optionalMediaUri(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.removeFragment();
}

/// A display/session identity for one media stream. Pages commonly report the
/// same media URL from several video elements while rotating a short-lived
/// token or signature. Keep content-selection parameters such as quality and
/// audio in the key, but collapse authorization rotation for the candidate
/// picker. The selected candidate still keeps its complete URL for playback;
/// task/cache identity continues to use [mediaCandidateGroupKey].
String mediaCandidateDisplayGroupKey(MediaCandidate candidate) {
  final clean = candidate.mediaUrl.removeFragment();
  // Keep content-selection parameters such as `line`; only authorization
  // rotation may collapse into the same display item.
  return mediaCandidateAuthorizationKey(clean);
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
    this.resourceKey = '',
    required this.state,
    required this.updatedAt,
    this.displayTitle = '',
    this.batchDirectory,
    this.episodeLabel,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.errorCode,
    this.errorReason,
    this.localRef,
  });

  final String id;
  final String candidateId;
  final int hostId;
  final int generation;
  final Uri sourceUrl;
  final String cacheKey;
  final String resourceKey;
  final MediaTaskState state;
  final DateTime updatedAt;
  final String displayTitle;

  /// Optional directory shared by one user initiated batch.
  ///
  /// Older rows omit this field and continue to use the series directory.
  final String? batchDirectory;
  final String? episodeLabel;
  final int bytesDownloaded;
  final int? totalBytes;
  final String? errorCode;
  final String? errorReason;
  final String? localRef;

  String get displayName {
    var title = displayTitle.trim();
    final episode = episodeLabel?.trim() ?? '';
    if (title.isEmpty ||
        {'媒体', 'video', 'media'}.contains(title.toLowerCase())) {
      title =
          sourceUrl.pathSegments.where((v) => v.isNotEmpty).lastOrNull ??
          sourceUrl.host;
    }
    if (episode.isEmpty) return title;
    title = title
        .replaceAll(
          RegExp(
            r'\s*[-–—|]?\s*(?:第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b)',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    if (title.isEmpty) return episode;
    return '$title - $episode';
  }

  String get seriesDirectoryName => mediaSeriesDirectoryName(displayTitle);

  /// The directory name used by older builds before batch suffix cleanup.
  String get legacyStorageDirectoryName =>
      batchDirectory == null || batchDirectory!.trim().isEmpty
      ? seriesDirectoryName
      : mediaSeriesDirectoryName(batchDirectory!);

  String get storageDirectoryName =>
      batchDirectory == null || batchDirectory!.trim().isEmpty
      ? seriesDirectoryName
      : mediaSeriesDirectoryName(mediaFolderDisplayName(batchDirectory!));

  MediaTask copyWith({
    String? id,
    String? candidateId,
    MediaTaskState? state,
    DateTime? updatedAt,
    String? resourceKey,
    String? displayTitle,
    Object? batchDirectory = _unset,
    Object? episodeLabel = _unset,
    int? bytesDownloaded,
    Object? totalBytes = _unset,
    Object? errorCode = _unset,
    Object? errorReason = _unset,
    Object? localRef = _unset,
  }) => MediaTask(
    id: id ?? this.id,
    candidateId: candidateId ?? this.candidateId,
    hostId: hostId,
    generation: generation,
    sourceUrl: sourceUrl,
    cacheKey: cacheKey,
    resourceKey: resourceKey ?? this.resourceKey,
    state: state ?? this.state,
    updatedAt: updatedAt ?? DateTime.now().toUtc(),
    displayTitle: displayTitle ?? this.displayTitle,
    batchDirectory: identical(batchDirectory, _unset)
        ? this.batchDirectory
        : batchDirectory as String?,
    episodeLabel: identical(episodeLabel, _unset)
        ? this.episodeLabel
        : episodeLabel as String?,
    bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
    totalBytes: identical(totalBytes, _unset)
        ? this.totalBytes
        : totalBytes as int?,
    errorCode: identical(errorCode, _unset)
        ? this.errorCode
        : errorCode as String?,
    errorReason: identical(errorReason, _unset)
        ? this.errorReason
        : errorReason as String?,
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
    'resourceKey': resourceKey,
    'state': state.name,
    'updatedAt': updatedAt.toIso8601String(),
    'displayTitle': displayTitle,
    'batchDirectory': batchDirectory,
    'episodeLabel': episodeLabel,
    'bytesDownloaded': bytesDownloaded,
    'totalBytes': totalBytes,
    'errorCode': errorCode,
    'errorReason': errorReason,
    'localRef': localRef,
  };

  factory MediaTask.fromJson(Map<String, dynamic> json) => MediaTask(
    id: json['id'] as String,
    candidateId: json['candidateId'] as String,
    hostId: (json['hostId'] as num).toInt(),
    generation: (json['generation'] as num).toInt(),
    sourceUrl: webUri(json['sourceUrl'] as String),
    cacheKey: json['cacheKey'] as String,
    resourceKey: json['resourceKey'] as String? ?? '',
    state: MediaTaskState.values.byName(json['state'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    displayTitle: json['displayTitle'] as String? ?? '',
    batchDirectory: json['batchDirectory'] as String?,
    episodeLabel: json['episodeLabel'] as String?,
    bytesDownloaded: (json['bytesDownloaded'] as num?)?.toInt() ?? 0,
    totalBytes: (json['totalBytes'] as num?)?.toInt(),
    errorCode: json['errorCode'] as String?,
    errorReason: json['errorReason'] as String?,
    localRef: json['localRef'] as String?,
  );
}

class AppErrorLog {
  const AppErrorLog({
    required this.id,
    required this.happenedAt,
    required this.level,
    required this.module,
    required this.message,
    required this.details,
    this.context,
  });

  final int id;
  final DateTime happenedAt;
  final String level;
  final String module;
  final String message;
  final String details;
  final String? context;
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
