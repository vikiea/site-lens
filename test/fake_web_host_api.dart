import 'package:site_lens/web_host/web_host.g.dart';

/// A [WebHostApi] that answers the calls the app makes while opening and moving
/// between tabs. It records what happened so tests can assert tab lifecycle
/// (which hosts were navigated, which were destroyed) without a device.
class FakeWebHostApi extends WebHostApi {
  FakeWebHostApi({
    this.isolatedScripts = true,
    this.playbackTitle,
    this.playbackDocumentTitle,
    this.playbackSnapshotUrl = 'https://example.test/video/1/',
  });

  final bool isolatedScripts;
  final String? playbackTitle;
  final String? playbackDocumentTitle;
  final String playbackSnapshotUrl;
  final created = <int>[];
  final destroyed = <int>[];
  final navigated = <int, List<String>>{};
  final reloaded = <int>[];
  final wentBack = <int>[];
  final wentForward = <int>[];
  final activity = <int, List<bool>>{};
  @override
  Future<bool> setHostActivity(
    int id,
    bool current,
    bool visible,
    bool foreground,
    bool background,
  ) async {
    activity[id] = [current, visible, foreground, background];
    return true;
  }

  /// Preferences each host was created with, and every later push, so tests can
  /// assert the switches reach the platform side.
  final createdWith = <int, HostPreferences>{};
  final applied = <HostPreferences>[];

  @override
  Future<HostCapabilities> create(
    int hostId,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async {
    created.add(hostId);
    createdWith[hostId] = preferences;
    return HostCapabilities(
      platform: 'Android WebView test',
      isolatedScripts: isolatedScripts,
      documentStart: true,
      privateProbes: true,
      reason: '',
    );
  }

  @override
  Future<void> registerScripts(
    int hostId,
    List<ScriptRegistration> scripts,
  ) async {}

  @override
  Future<PageSnapshot> inspect(int hostId, String selector) async {
    if (playbackTitle == null && playbackDocumentTitle == null) {
      return super.inspect(hostId, selector);
    }
    if (!selector.contains('.hg-play__slide.is-active .hg-play__title-text')) {
      throw StateError('unexpected playback title selector');
    }
    return PageSnapshot(
      url: playbackSnapshotUrl,
      title: playbackDocumentTitle ?? '',
      generation: 0,
      ready: true,
      challenge: false,
      interactionRequired: false,
      links: const [],
      text: playbackTitle ?? '',
      error: '',
    );
  }

  @override
  Future<void> navigate(int hostId, String url) async {
    navigated.putIfAbsent(hostId, () => []).add(url);
  }

  @override
  Future<void> applyPreferences(int hostId, HostPreferences preferences) async {
    applied.add(preferences);
  }

  @override
  Future<void> reload(int hostId) async {
    reloaded.add(hostId);
  }

  @override
  Future<bool> goBack(int hostId) async {
    wentBack.add(hostId);
    return true;
  }

  @override
  Future<bool> goForward(int hostId) async {
    wentForward.add(hostId);
    return true;
  }

  @override
  Future<void> destroy(int hostId) async {
    destroyed.add(hostId);
  }
}
