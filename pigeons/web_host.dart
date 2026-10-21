import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/web_host/web_host.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/dev/vikiea/site_lens/WebHost.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.vikiea.site_lens'),
    swiftOut: 'ios/Runner/WebHost.g.swift',
  ),
)
enum HostPurpose { browsing, discovery, verification }

class HostCapabilities {
  HostCapabilities({
    required this.platform,
    required this.isolatedScripts,
    required this.documentStart,
    required this.privateProbes,
    required this.reason,
  });
  String platform;
  bool isolatedScripts;
  bool documentStart;
  bool privateProbes;
  String reason;
}

/// A query failure is distinct from an unsupported capability. Null values in
/// a record mean that the passive query has no authoritative answer.
enum CapabilityState { supported, unsupported, unknown, notApplicable, error }

class CapabilityRecord {
  CapabilityRecord({
    required this.id,
    required this.state,
    required this.reason,
    required this.source,
    required this.capturedAtMs,
    this.configured,
    this.effective,
    this.observed,
    this.observedAtMs,
    this.detailsJson,
  });
  String id;
  CapabilityState state;
  bool? configured;
  bool? effective;
  String? observed;
  String reason;
  String source;
  int capturedAtMs;
  int? observedAtMs;
  String? detailsJson;
}

class CodecDescriptor {
  CodecDescriptor({
    required this.name,
    this.mimeType,
    required this.encoder,
    this.hardwareAccelerated,
    this.softwareOnly,
    this.vendor,
    this.profileLevelsJson,
    this.error,
  });
  String name;
  String? mimeType;
  bool encoder;
  bool? hardwareAccelerated;
  bool? softwareOnly;
  String? vendor;
  String? profileLevelsJson;
  String? error;
}

class DeviceDiagnosticsSnapshot {
  DeviceDiagnosticsSnapshot({
    required this.platform,
    required this.osVersion,
    required this.appVersion,
    required this.capturedAtMs,
    required this.capabilities,
    this.apiLevel,
    this.flutterVersion,
    this.webViewProvider,
  });
  String platform;
  String osVersion;
  int? apiLevel;
  String appVersion;
  String? flutterVersion;
  String? webViewProvider;
  int capturedAtMs;
  List<CapabilityRecord> capabilities;
}

/// Reads OS declarations and existing observations only. Implementations must
/// not create views/codecs, request access, probe the network or schedule work.
@HostApi()
abstract class DeviceDiagnosticsApi {
  @asyncCallback
  DeviceDiagnosticsSnapshot readSnapshot();
  @asyncCallback
  List<CodecDescriptor> readCodecInventory();
}

class ScriptRegistration {
  ScriptRegistration({
    required this.id,
    required this.revision,
    required this.privileged,
    required this.rulesJson,
    required this.source,
    required this.sourcePath,
  });
  String id;
  String revision;
  bool privileged;
  String rulesJson;
  String source;
  String sourcePath;
}

class PageSnapshot {
  PageSnapshot({
    required this.url,
    required this.title,
    required this.generation,
    required this.ready,
    required this.challenge,
    required this.interactionRequired,
    required this.links,
    required this.text,
    required this.error,
  });
  String url;
  String title;
  int generation;
  bool ready;
  bool challenge;
  bool interactionRequired;
  List<String> links;
  String text;
  String error;
}

class HostEvent {
  HostEvent({
    required this.hostId,
    required this.generation,
    required this.kind,
    required this.url,
    required this.detail,
  });
  int hostId;
  int generation;
  String kind;
  String url;
  String detail;
}

class GmRequest {
  GmRequest({
    required this.hostId,
    required this.generation,
    required this.scriptId,
    required this.revision,
    required this.documentUrl,
    required this.payload,
  });
  int hostId;
  int generation;
  // Set by the native per-world binding, never read from JavaScript payload.
  String scriptId;
  String revision;
  String documentUrl;
  String payload;
}

/// Per-host policy the Dart side owns; the host only enforces it.
class HostPreferences {
  HostPreferences({
    required this.followEntryRedirects,
    required this.pullToRefresh,
  });

  /// Allow the navigation the *app* started (opening a candidate/profile entry)
  /// to follow its own 301/302 chain and keep the lease on the landing, up to
  /// the first commit. Navigations a page starts on its own are not covered.
  bool followEntryRedirects;

  /// Android only: the swipe-to-refresh gesture on the browsing host. Off keeps
  /// the gesture for the page and its user scripts.
  bool pullToRefresh;
}

/// Immutable filtering data passed to a native host.  The native side never
/// reads the rules from disk or asks Dart during a WebView request callback;
/// it receives a complete snapshot before navigation starts.
class FilterSnapshotDto {
  FilterSnapshotDto({
    required this.id,
    required this.version,
    required this.sha256,
    required this.state,
    required this.rules,
  });
  String id;
  String version;
  String sha256;
  String state;
  String rules;
}

class FilterPolicyDto {
  FilterPolicyDto({
    required this.enabled,
    required this.pageFiltering,
    required this.domainExceptions,
    required this.blockedDomains,
  });
  bool enabled;
  bool pageFiltering;
  List<String> domainExceptions;
  List<String> blockedDomains;
}

class HostFilterContextDto {
  HostFilterContextDto({
    required this.hostId,
    required this.generation,
    required this.sourceUrl,
    required this.snapshotId,
  });
  int hostId;
  int generation;
  String sourceUrl;
  String snapshotId;
}

/// Candidate/task/cast DTOs deliberately contain no cookie, authorization,
/// Web Storage or native file path.  They are snapshots for UI/native calls;
/// Dart remains the authority for authorization and persistence.
class MediaCandidateDto {
  MediaCandidateDto({
    required this.id,
    required this.hostId,
    required this.generation,
    required this.sourceUrl,
    required this.mediaUrl,
    required this.title,
    required this.mime,
    required this.source,
    this.durationMs,
  });
  String id;
  int hostId;
  int generation;
  String sourceUrl;
  String mediaUrl;
  String title;
  String mime;
  String source;
  int? durationMs;
}

class MediaTaskDto {
  MediaTaskDto({
    required this.id,
    required this.candidateId,
    required this.hostId,
    required this.generation,
    required this.state,
    required this.cacheKey,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.errorCode,
  });
  String id;
  String candidateId;
  int hostId;
  int generation;
  String state;
  String cacheKey;
  int bytesDownloaded;
  int? totalBytes;
  String? errorCode;
}

class CastDeviceDto {
  CastDeviceDto({
    required this.id,
    required this.name,
    required this.address,
    required this.model,
    required this.supportsMp4,
    required this.supportsHls,
    required this.supportsSeek,
  });
  String id;
  String name;
  String address;
  String? model;
  bool supportsMp4;
  bool supportsHls;
  bool supportsSeek;
}

class CastSessionDto {
  CastSessionDto({
    required this.id,
    required this.deviceId,
    required this.mediaTaskId,
    required this.state,
    required this.errorCode,
  });
  String id;
  String deviceId;
  String mediaTaskId;
  String state;
  String? errorCode;
}

@HostApi()
abstract class WebHostApi {
  HostCapabilities create(
    int hostId,
    HostPurpose purpose,
    HostPreferences preferences,
  );
  void applyPreferences(int hostId, HostPreferences preferences);
  /// Returns false when the native host cannot enforce background media policy.
  bool setHostActivity(int hostId, bool isCurrent, bool visible, bool foreground, bool allowBackgroundPlayback);
  void registerScripts(int hostId, List<ScriptRegistration> scripts);
  /// Installs an immutable filter snapshot before the next document starts.
  /// Native request callbacks must use this in-memory snapshot only.
  void applyFilter(
    int hostId,
    HostFilterContextDto context,
    FilterPolicyDto policy,
    FilterSnapshotDto snapshot,
  );
  void navigate(int hostId, String url);
  void reload(int hostId);
  bool goBack(int hostId);
  bool goForward(int hostId);
  void stop(int hostId);
  void destroy(int hostId);
  void notify(int hostId, String title, String body);
  void openExternal(int hostId, String url);
  @asyncCallback
  PageSnapshot inspect(int hostId, String selector);
  @asyncCallback
  void invokeMenu(
    int hostId,
    String scriptId,
    String menuId,
    int expectedGeneration,
    String expectedRevision,
  );
}

@FlutterApi()
abstract class WebHostEvents {
  @asyncCallback
  void onEvent(HostEvent event);
  @asyncCallback
  List<ScriptRegistration> getScriptsForNavigation(
    int hostId,
    int generation,
    String url,
  );
  @asyncCallback
  String onGmRequest(GmRequest request);
}
