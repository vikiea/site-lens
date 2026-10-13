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
