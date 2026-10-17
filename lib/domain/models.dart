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
  });
  final String id;
  final String name;
  final String source;
  final bool enabled;
  final String? approvedDigest;
}

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
  });
  final int profileId;
  final String scriptId;
  final String contentHash;
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
