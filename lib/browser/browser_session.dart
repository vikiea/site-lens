import '../domain/models.dart';
import '../web_host/native_hosts.dart';
import 'browser_session_store.dart';

enum BrowserSessionState { unloaded, loading, ready, failed }

/// Stable tab identity and navigation metadata outlive a native WebView.
/// The compatibility [host] getter is only for operations after ensure-loaded;
/// UI and metadata readers use [loadedHost] without creating a native view.
class ActiveBrowserSession {
  ActiveBrowserSession(this.site, HostSession host)
    : _host = host,
      id = _newId(),
      lastUrl = site.url,
      title = site.label;

  ActiveBrowserSession.restored(this.site, SavedBrowserTab saved)
    : id = saved.id,
      _host = null,
      lastUrl = saved.currentUrl,
      title = saved.title;

  static int _sequence = 0;
  static String _newId() =>
      'tab_${DateTime.now().microsecondsSinceEpoch}_${++_sequence}';
  final String id;
  Candidate site;
  HostSession? _host;
  HostSession? get loadedHost => _host;
  HostSession get host => _host ?? (throw StateError('标签尚未加载'));
  set host(HostSession value) {
    _host = value;
    failure = null;
  }

  Uri lastUrl;
  String title;
  String? failure;
  bool loading = false;

  Uri get currentUrl {
    final uri = Uri.tryParse(_host?.url ?? '');
    return uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : lastUrl;
  }

  void updateNavigation(Uri url, {String? label, Candidate? candidate}) {
    site =
        candidate ??
        Candidate(
          id: site.id,
          url: url,
          label: label ?? site.label,
          enabled: site.enabled,
          sourceId: site.sourceId,
          profileId: site.profileId,
          readySelector: site.readySelector,
          readySelectorOverride: site.readySelectorOverride,
        );
    lastUrl = url;
    title = label ?? site.label;
    failure = null;
  }

  BrowserSessionState get state {
    if (loading) return BrowserSessionState.loading;
    if (failure != null || _host?.disposed == true) {
      return BrowserSessionState.failed;
    }
    if (_host == null) return BrowserSessionState.unloaded;
    return _host!.loaded
        ? BrowserSessionState.ready
        : BrowserSessionState.loading;
  }

  void invalidate(String reason) {
    lastUrl = currentUrl;
    failure = reason;
    _host = null;
    loading = false;
  }

  SavedBrowserTab toRecord() => SavedBrowserTab(
    id: id,
    initialUrl: site.url,
    currentUrl: currentUrl,
    title: title,
    profileId: site.profileId,
    selectorOverride: site.readySelectorOverride,
  );
}
