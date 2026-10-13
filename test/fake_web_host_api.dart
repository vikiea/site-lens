import 'package:site_lens/web_host/web_host.g.dart';

/// A [WebHostApi] that answers the calls the app makes while opening and moving
/// between tabs. It records what happened so tests can assert tab lifecycle
/// (which hosts were navigated, which were destroyed) without a device.
class FakeWebHostApi extends WebHostApi {
  FakeWebHostApi({this.isolatedScripts = true});

  final bool isolatedScripts;
  final created = <int>[];
  final destroyed = <int>[];
  final navigated = <int, List<String>>{};
  final reloaded = <int>[];
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
  Future<void> destroy(int hostId) async {
    destroyed.add(hostId);
  }
}
