import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../backup/backup_service.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../data/database.dart';
import '../diagnostics/error_log.dart';
import '../browser/browser_session.dart';
import '../browser/browser_session_store.dart';
export '../browser/browser_session.dart'
    show ActiveBrowserSession, BrowserSessionState;
import '../data/profile_pack.dart';
import '../background/health_worker.dart';
import '../device/device_conditions.dart';
import '../discovery/health_checker.dart';
import '../discovery/probe_coordinator.dart';
import '../domain/models.dart';
import '../network/transport.dart';
import '../scripts/metadata.dart';
import '../scripts/script_service.dart';
import '../web_host/native_hosts.dart';
import '../web_host/web_host.g.dart';
import '../settings/settings_repository.dart';
import '../settings/app_settings.dart';
import '../filter/filter_service.dart';
import '../media/media_service.dart';
import '../media/media_library.dart';
import '../media/dlna_service.dart';
import '../media/native_download_runtime.dart';
import '../media/native_export_runtime.dart';
import '../media/media_network.dart';
import '../media/native_media_runtime.dart';
import 'glass_quality_cache.dart';
import 'ui_util.dart';

/// The user preferences travel as one versioned record (`AppPolicy.settingsKey`).
/// This key is retained for compatibility with older database fixtures only;
/// it is not read as an independent preference.

final databaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError('Database not initialized'),
);
final appControllerProvider = Provider<AppController>((ref) {
  final controller = AppController(ref.watch(databaseProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

const _filterSourceSeedSetting = 'filterSourceSeedVersion';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  /// [api] is the platform seam: production leaves it null (the generated Pigeon
  /// channel), tests pass a fake so tab lifecycle can be exercised without a
  /// device. Same seam [NativeHosts] already exposes.
  AppController(
    this.db, {
    WebHostApi? api,
    HttpProbe? httpProbe,
    HomepageVerifier? homepageVerifier,
    BrowserSessionStore? sessionStore,
  }) {
    settingsRepository = SettingsRepository(db);
    errorLogger = AppErrorLogger(db);
    glassQualityCacheRepository = SiteLensGlassQualityCacheRepository(db);
    this.sessionStore = sessionStore ?? BrowserSessionStore(db);
    scripts = ScriptService(db, ControlledHttp());
    hosts = NativeHosts(db, scripts, ControlledHttp(), api: api);
    filterSnapshots = FilterSnapshotStore();
    filterSources = FilterSourceManager(store: filterSnapshots, db: db);
    mediaTasks = MediaTaskStore(db: db);
    nativeDownloads = Platform.isAndroid ? NativeDownloadRuntime() : null;
    nativeExports = Platform.isAndroid ? NativeExportRuntime() : null;
    nativeMedia = NativeMediaRuntime();
    mediaDownloads = MediaDownloadService(
      tasks: mediaTasks,
      native: nativeDownloads,
      http: ControlledHttp(
        mediaRouteForAttempt: (uri, attempt) =>
            MediaNetwork().route(uri, attempt: attempt),
      ),
      authorize: _authorizeMediaDownload,
      tlsTransfer: Platform.isAndroid ? MediaNetwork().transferFile : null,
    );
    mediaExports = Mp4ExportService(tasks: mediaTasks, native: nativeExports);
    mediaLibrary = MediaLibrary(
      db: db,
      tasks: mediaTasks,
      native: nativeExports,
    );
    mediaLibrary.addListener(notifyMediaChanged);
    mediaDownloads.onCompleted = _autoConvertCompletedMedia;
    castSessions = CastSessionController(tasks: mediaTasks);
    mediaCast = DlnaCastController(
      castSessions,
      onTemporaryTaskFinished: cleanupTemporaryCastTask,
      onSessionFinished: _releaseCastCopy,
    );
    mediaPlayback = NativePlaybackController();
    hosts.onNewWindow = (hostId, url) {
      unawaited(_openLinkInNewTab(hostId, url));
    };
    hosts.onInvalidated = (host) {
      if (host.error != null) {
        AppErrorLogger.capture(
          host.error!,
          module: 'webview',
          context: 'host:${host.id}',
        );
      }
      for (final tab in browserTabs) {
        if (identical(tab.loadedHost, host)) {
          tab.invalidate(host.error ?? '网页进程已退出');
          if (identical(activeBrowser, tab)) error = '网页进程已退出；选择标签可重新加载';
        }
      }
      notifyListeners();
    };
    hosts.changed.addListener(_hostMetadataChanged);
    packs = ProfilePacks(db);
    probes = ProbeCoordinator(
      candidates: _enabledCandidates,
      httpProbe: httpProbe ?? HttpProbe(),
      verifier: homepageVerifier ?? NativeHomepageVerifier(hosts),
      save: db.saveProbe,
    )..addListener(notifyListeners);
  }
  final AppDatabase db;
  late final AppErrorLogger errorLogger;
  late final SettingsRepository settingsRepository;
  late final SiteLensGlassQualityCacheRepository glassQualityCacheRepository;
  late final BrowserSessionStore sessionStore;
  bool _restoredSessions = false;
  bool _restorationValid = false;
  bool _restoring = false;
  int _restorePolicyEpoch = 0;
  Future<void>? _shutdownFuture;
  Future<void> _glassQualityWrites = Future.value();
  Future<void>? _mediaPolicyRun;
  bool _mediaPolicyAgain = false;
  int _mediaPolicyEpoch = 0;
  bool _disposed = false;
  bool _browserVisible = false;
  bool _browserSurfaceActive = false;
  bool _browserStateNotificationScheduled = false;
  int _browserSurfaceLease = 0;
  final _browserSurfaces = <int, bool>{};
  bool _foreground = true;
  bool mediaSupported = false;
  bool get browserVisible => _browserVisible;
  set browserVisible(bool value) {
    if (_browserVisible == value) return;
    _browserVisible = value;
    _scheduleBrowserStateNotification();
  }

  /// True while a browsing route still owns a mounted native WebView surface.
  /// This is separate from [browserVisible]: a modal route can cover the
  /// browser while its PlatformView remains mounted underneath.
  bool get browserSurfaceActive => _browserSurfaceActive;
  set browserSurfaceActive(bool value) {
    if (_browserSurfaceActive == value) return;
    _browserSurfaceActive = value;
    _scheduleBrowserStateNotification();
  }

  /// Claims ownership of the native WebView surface for one mounted browser
  /// route. A stale route can finish disposing after its replacement has
  /// mounted; its release must not hide the replacement surface.
  int claimBrowserSurface({bool visible = true}) {
    final lease = ++_browserSurfaceLease;
    _browserSurfaces[lease] = visible;
    browserSurfaceActive = true;
    browserVisible = visible;
    return lease;
  }

  /// Saves each route's visibility, but only the newest mounted route can
  /// change global playback policy. Covered routes still receive app events.
  void setBrowserSurfaceVisible(int lease, bool visible) {
    if (!_browserSurfaces.containsKey(lease)) return;
    _browserSurfaces[lease] = visible;
    if (lease == _browserSurfaces.keys.last) browserVisible = visible;
  }

  /// Releases a mounted route and restores the previous route's state, if any.
  /// State fields update immediately, while the listener notification is
  /// deferred until synchronous work ends so widget disposal cannot rebuild a
  /// locked tree, including when no further frame has been scheduled.
  void releaseBrowserSurface(int lease) {
    if (_browserSurfaces.remove(lease) == null) return;
    browserVisible = _browserSurfaces.values.lastOrNull ?? false;
    browserSurfaceActive = _browserSurfaces.isNotEmpty;
  }

  void _scheduleBrowserStateNotification() {
    if (_disposed) return;
    if (_browserStateNotificationScheduled) return;
    _browserStateNotificationScheduled = true;
    scheduleMicrotask(() {
      _browserStateNotificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    unawaited(syncMediaPolicy());
  }

  Future<void> syncMediaPolicy() {
    if (_disposed) return Future<void>.value();
    _mediaPolicyEpoch++;
    _mediaPolicyAgain = true;
    final running = _mediaPolicyRun;
    if (running != null) return running;
    final run = _drainMediaPolicy();
    _mediaPolicyRun = run;
    run.whenComplete(() {
      if (identical(_mediaPolicyRun, run)) _mediaPolicyRun = null;
    });
    return run;
  }

  Future<void> _drainMediaPolicy() async {
    do {
      _mediaPolicyAgain = false;
      await _syncMediaPolicy(_mediaPolicyEpoch);
    } while (_mediaPolicyAgain && !_disposed);
  }

  Future<void> _syncMediaPolicy(int epoch) async {
    if (_disposed || epoch != _mediaPolicyEpoch) return;
    // Pause every inactive host first so switching never overlaps audible tabs.
    final sessions = hosts.sessions.values.where((h) => !h.disposed).toList();
    final current = activeBrowser?.loadedHost;
    sessions.sort(
      (a, b) => (identical(a, current) ? 1 : 0).compareTo(
        identical(b, current) ? 1 : 0,
      ),
    );
    for (final h in sessions) {
      if (h.disposed || _disposed || epoch != _mediaPolicyEpoch) return;
      try {
        if (identical(h, activeBrowser?.loadedHost) &&
            _browserVisible &&
            _foreground) {
          h.mediaWasVisible = true;
        }
        final supported = await hosts.api.setHostActivity(
          h.id,
          identical(h, activeBrowser?.loadedHost),
          _browserVisible,
          _foreground,
          allowBackgroundPlayback,
        );
        if (_disposed || epoch != _mediaPolicyEpoch) return;
        final selected = identical(h, activeBrowser?.loadedHost);
        if (selected) mediaSupported = supported;
        if (!supported &&
            h.mediaWasVisible &&
            h.capabilities.platform.startsWith('Android') &&
            (!selected || !_browserVisible || !_foreground)) {
          for (final tab in browserTabs.where(
            (t) => identical(t.loadedHost, h),
          )) {
            tab.invalidate('当前 WebView 无法暂停后台音频，网页已关闭；选择标签可重新加载');
          }
          await hosts.destroy(h);
        }
      } catch (e) {
        if (_disposed || epoch != _mediaPolicyEpoch) return;
        AppErrorLogger.capture(e, module: 'media.policy');
        if (!h.disposed && !_disposed) {
          error = '播放策略应用失败：${friendlyError(e)}';
        }
      }
    }
  }

  int _selectionEpoch = 0;
  Timer? _sessionSaveTimer;
  Future<void> _sessionWrites = Future.value();
  AppSettings settings = const AppSettings();
  SiteLensGlassQualityCache? glassQualityCache;
  GlassQuality effectiveGlassQuality = GlassQuality.standard;
  late final ScriptService scripts;
  late final ProfilePacks packs;
  late final NativeHosts hosts;
  late final FilterSnapshotStore filterSnapshots;
  late final FilterSourceManager filterSources;
  late final MediaTaskStore mediaTasks;
  late final MediaDownloadService mediaDownloads;
  late final Mp4ExportService mediaExports;
  late final MediaLibrary mediaLibrary;
  final _exportingMedia = <String, Future<MediaArtifact>>{};
  late final CastSessionController castSessions;
  late final DlnaCastController mediaCast;
  late final NativePlaybackController mediaPlayback;
  late final NativeMediaRuntime nativeMedia;
  late final NativeDownloadRuntime? nativeDownloads;
  late final NativeExportRuntime? nativeExports;
  late final ProbeCoordinator probes;
  List<Candidate> sites = [];
  List<PublishingSource> sources = [];
  List<SiteProfile> profiles = [];
  bool _persistentStateLoaded = false;

  /// True after the first persistent-state read has completed. An empty list
  /// before this point means startup is still hydrating, not that the user has
  /// no site profiles.
  bool get persistentStateLoaded => _persistentStateLoaded;

  List<ProfilePage> profilePages = [];
  List<ProfileHealth> profileHealth = [];
  List<ProfileScript> profileScriptLinks = [];
  List<InstalledScript> installed = [];
  List<ProbeResult> history = [];
  List<FilterSource> filterSourceList = [];
  Map<int, FilterPolicy> profileFilterPolicies = const {};
  HostCapabilities? capabilities;
  bool checkingHostCapabilities = false;
  String? hostCapabilityError;
  String? error;
  bool refreshing = false;
  bool scriptsDisabled = false;
  bool backgroundHealthCheck = true;
  ThemeModePreference themeModePreference = ThemeModePreference.system;
  ThemePresetId themePreset = ThemePresetId.sunsetCoral;
  bool restoreBrowserSessions = true;
  bool allowBackgroundPlayback = false;
  bool autoConvertToMp4 = false;
  String? mp4ExportDirectory;
  PlayerVerticalGestureMode playerVerticalGesture =
      PlayerVerticalGestureMode.brightnessVolume;
  FilterPolicy filterPolicy = const FilterPolicy();

  /// Entry redirects are always retained by product policy.
  bool get followEntryRedirects => true;

  /// Android browsing host: whether the swipe-to-refresh gesture belongs to the
  /// app. **Off by default**: the gesture is a page/script feature first, and the
  /// app only takes it over when the user asks for it. Off leaves the gesture to
  /// the page and the user scripts running in it.
  bool pullToRefresh = false;

  /// The policy the hosts enforce; also what a host created right now receives.
  HostPreferences get hostPreferences => HostPreferences(
    // Entry redirects are always retained so a mirror's 301/302 funnel does
    // not suspend the user's scripts. This is product policy, not a setting.
    followEntryRedirects: true,
    pullToRefresh: pullToRefresh,
  );
  HealthRunReport? lastHealthReport;

  /// Every open browsing tab, in strip order. Each tab owns its own native
  /// WebView so page state survives switching.
  final List<ActiveBrowserSession> browserTabs = [];
  ActiveBrowserSession? activeBrowser;
  final _pendingTabCreates = <Object>{};
  final _pendingOpens = <String, Future<ActiveBrowserSession>>{};
  int _tabLifecycleEpoch = 0;
  Cancellation _discovery = Cancellation();
  Cancellation _recon = Cancellation();
  StreamSubscription<List<ConnectivityResult>>? _network;
  Future<void> _applyBackgroundHealthSchedule() async {
    await HealthScheduler.waitForAppStartup();
    try {
      await const HealthScheduler().apply(backgroundHealthCheck);
    } catch (_) {
      // Scheduling is best effort and must not affect foreground startup.
    }
  }

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    await mediaTasks.restore();
    await mediaLibrary.restore();
    try {
      await mediaDownloads.reconcileNative();
    } catch (error) {
      AppErrorLogger.capture(error, module: 'media.reconcile');
    }
    // A damaged legacy row must not abort the first frame; load keeps every
    // successfully read collection and publishes the partial state together.
    await load(suppressCorruption: true);
    await restoreSavedSessions();
    // Schedule/cancel the periodic survival check in the background. It waits
    // for WorkManager's shared startup Future before registering, but never
    // blocks the first product screen on a slow device plugin initialization.
    unawaited(_applyBackgroundHealthSchedule());
    await drainBackgroundNotice();
    // Capabilities are observed on the first real host; cold-start restoration
    // must not construct an otherwise unused native WebView.
    try {
      var previous = (await Connectivity().checkConnectivity())
          .map((e) => e.name)
          .join(',');
      _network = Connectivity().onConnectivityChanged.listen((state) {
        final current = state.map((e) => e.name).join(',');
        if (current != previous) {
          previous = current;
          cancel('网络发生变化，请重新检测；旧结果不参与推荐');
        }
      });
    } catch (_) {
      // Connectivity is advisory. A plugin failure must not turn a successful
      // data restore into a startup error banner or snackbar.
    }
    // Startup restores metadata only; discovery runs on explicit user entry.
  }

  String get glassQualityFingerprint =>
      SiteLensGlassFingerprint.current(appVersion: _packageVersion);

  final String _packageVersion = const String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: 'dev',
  );

  GlassAdaptiveScopeConfig get glassAdaptiveConfig {
    final mode = settings.glassQualityMode;
    final androidWebViewSurface = Platform.isAndroid && browserSurfaceActive;
    final cached = glassQualityCache;
    final cachedQuality =
        cached != null && cached.matches(glassQualityFingerprint)
        ? cached.quality
        : null;
    final manualHigh = mode == SiteLensGlassQualityMode.high;
    final manualStandard = mode == SiteLensGlassQualityMode.standard;
    return GlassAdaptiveScopeConfig(
      // Manual modes are explicit locks. Automatic mode is the only mode that
      // may move between the standard floor and premium ceiling.
      minQuality: androidWebViewSurface
          ? GlassQuality.standard
          : manualHigh || manualStandard
          ? (manualHigh ? GlassQuality.premium : GlassQuality.standard)
          : GlassQuality.standard,
      maxQuality: androidWebViewSurface
          ? GlassQuality.standard
          : manualStandard
          ? GlassQuality.standard
          : GlassQuality.premium,
      initialQuality: androidWebViewSurface
          ? GlassQuality.standard
          : manualHigh
          ? GlassQuality.premium
          : manualStandard
          ? GlassQuality.standard
          : cachedQuality ?? GlassQuality.standard,
      allowStepUp: !androidWebViewSurface && !manualHigh && !manualStandard,
      onQualityChanged: (_, to) => effectiveGlassQuality = to,
      onDiagnostic: (diagnostic) =>
          unawaited(recordGlassQualityDiagnostic(diagnostic)),
    );
  }

  Future<void> recordGlassQualityDiagnostic(
    GlassAdaptiveDiagnostic diagnostic,
  ) {
    _glassQualityWrites = _glassQualityWrites.then((_) async {
      if (_disposed ||
          diagnostic.reason == GlassQualityChangeReason.restoredFromCache) {
        return;
      }
      final previous = glassQualityCache;
      final cache = SiteLensGlassQualityCache(
        // Persist the warm-up classification as the next cold-start hint.
        // Thermal changes update diagnostics without turning a transient
        // over-budget window into a permanent startup downgrade.
        quality: diagnostic.reason == GlassQualityChangeReason.warmupComplete
            ? diagnostic.to
            : previous?.quality ?? diagnostic.to,
        p75Ms: diagnostic.p75Ms ?? previous?.p75Ms,
        p95Ms: diagnostic.p95Ms ?? previous?.p95Ms,
        fingerprint: glassQualityFingerprint,
      );
      glassQualityCache = cache;
      effectiveGlassQuality = diagnostic.to;
      await glassQualityCacheRepository.write(cache);
      if (!_disposed) notifyListeners();
    });
    return _glassQualityWrites;
  }

  Future<void> _clearGlassQualityCache() async {
    glassQualityCache = null;
    effectiveGlassQuality = GlassQuality.standard;
    await glassQualityCacheRepository.clear();
  }

  Future<void> updateSettings(Map<String, Object?> patch) async {
    if (patch.containsKey('restoreBrowserSessions')) _restorePolicyEpoch++;
    settings = await settingsRepository.update(patch);
    if (patch.containsKey('glassQualityMode')) {
      await _clearGlassQualityCache();
      effectiveGlassQuality =
          settings.glassQualityMode == SiteLensGlassQualityMode.high
          ? GlassQuality.premium
          : GlassQuality.standard;
    }
    if (!settings.restoreBrowserSessions) await sessionStore.clear();
    _applySettings();
    await hosts.applyPreferences(hostPreferences);
    await syncMediaPolicy();
    notifyListeners();
  }

  Future<void> updateFilterPolicy(FilterPolicy next, {int? profileId}) async {
    await db.saveFilterPolicy(next, profileId: profileId);
    if (profileId == null) {
      filterPolicy = next;
    } else {
      profileFilterPolicies = {...profileFilterPolicies, profileId: next};
    }
    hosts.setFilterEngine(
      filterSnapshots.activeEngine,
      policy: filterPolicy,
      snapshot: filterSnapshots.activeSnapshot,
      profilePolicies: profileFilterPolicies,
    );
    notifyListeners();
  }

  /// Removes an explicit profile policy so the profile inherits the global
  /// policy again. The native hosts are updated immediately; the next
  /// navigation also receives the inherited policy through [setFilterEngine].
  Future<void> clearFilterPolicy({int? profileId}) async {
    await db.deleteFilterPolicy(profileId: profileId);
    if (profileId == null) {
      filterPolicy = const FilterPolicy();
    } else {
      final next = {...profileFilterPolicies}..remove(profileId);
      profileFilterPolicies = next;
    }
    hosts.setFilterEngine(
      filterSnapshots.activeEngine,
      policy: filterPolicy,
      snapshot: filterSnapshots.activeSnapshot,
      profilePolicies: profileFilterPolicies,
    );
    notifyListeners();
  }

  Future<void> _seedBuiltInFilterSources() async {
    final existing = await db.filterSources();
    final seedVersion = await db.setting(_filterSourceSeedSetting);
    final migratingBuiltIns = seedVersion != builtInFilterSourceSeedVersion;
    final specsByLabel = {
      for (final spec in builtInFilterSources) spec.label: spec,
    };
    for (final source in existing.where((item) => item.kind == 'builtin')) {
      final spec = specsByLabel[source.label];
      if (spec == null ||
          (source.url.toString() == spec.url &&
              !(migratingBuiltIns &&
                  source.status == FilterSourceStatus.failed))) {
        continue;
      }
      await db.saveFilterSource(
        FilterSource(
          id: source.id,
          label: source.label,
          url: webUri(spec.url),
          profileId: source.profileId,
          kind: source.kind,
          version: source.version,
          license: source.license,
          sha256: source.sha256,
          status: FilterSourceStatus.missing,
          fileRef: source.fileRef,
          refreshedAt: source.refreshedAt,
          error: null,
        ),
      );
    }
    if (!migratingBuiltIns) {
      return;
    }
    final existingUrls = (await db.filterSources())
        .map((source) => source.url.toString())
        .toSet();
    var nextId = await db.nextFilterSourceId();
    for (final spec in builtInFilterSources) {
      if (!existingUrls.add(spec.url)) continue;
      await db.saveFilterSource(
        FilterSource(
          id: nextId++,
          label: spec.label,
          url: webUri(spec.url),
          kind: 'builtin',
          license: spec.license,
        ),
      );
    }
    await db.setSetting(
      _filterSourceSeedSetting,
      builtInFilterSourceSeedVersion,
    );
  }

  Future<FilterSource> addFilterSource({
    required String label,
    required String url,
    String version = '',
    String license = '',
  }) async {
    final source = FilterSource(
      id: await db.nextFilterSourceId(),
      label: label.trim().isEmpty ? '自定义规则源' : label.trim(),
      url: userUri(url),
      version: version.trim(),
      license: license.trim(),
    );
    await db.saveFilterSource(source);
    filterSourceList = await db.filterSources();
    notifyListeners();
    return source;
  }

  Future<void> deleteFilterSource(int id) async {
    await db.deleteFilterSource(id);
    if (filterSnapshots.activeSnapshot?.sourceId == id) {
      filterSnapshots.clear();
    }
    final bundle = await filterSources.rebuildBundle();
    hosts.setFilterEngine(
      filterSnapshots.activeEngine,
      policy: filterPolicy,
      snapshot: bundle ?? filterSnapshots.activeSnapshot,
      profilePolicies: profileFilterPolicies,
    );
    filterSourceList = await db.filterSources();
    notifyListeners();
  }

  Future<FilterSnapshot> refreshFilterSource(FilterSource source) async {
    try {
      final snapshot = await filterSources.refresh(source);
      hosts.setFilterEngine(
        filterSnapshots.activeEngine,
        policy: filterPolicy,
        snapshot: filterSnapshots.activeSnapshot,
        profilePolicies: profileFilterPolicies,
      );
      return snapshot;
    } finally {
      // Refresh records downloading/failed states in Drift even when the
      // network or compiler rejects the source; keep the settings page honest.
      filterSourceList = await db.filterSources();
      notifyListeners();
    }
  }

  Future<FilterSnapshot> refreshFilterSourceById(int id) async {
    final source = filterSourceList.firstWhere(
      (item) => item.id == id,
      orElse: () => throw StateError('规则源不存在'),
    );
    return refreshFilterSource(source);
  }

  void _applySettings() {
    themeModePreference = settings.themeMode;
    themePreset = settings.themePreset;
    restoreBrowserSessions = settings.restoreBrowserSessions;
    allowBackgroundPlayback = settings.allowBackgroundPlayback;
    autoConvertToMp4 = settings.autoConvertToMp4;
    mp4ExportDirectory = settings.mp4ExportDirectory;
    playerVerticalGesture = settings.playerVerticalGesture;
    scriptsDisabled = settings.scriptsDisabled;
    pullToRefresh = settings.pullToRefresh;
    backgroundHealthCheck = settings.backgroundHealthCheck;
    browserControlsFraction = Offset(settings.controlsX, settings.controlsY);
  }

  Future<void> setThemeModePreference(ThemeModePreference value) =>
      updateSettings({'themeMode': value.name});
  Future<void> setThemePreset(ThemePresetId value) =>
      updateSettings({'themePreset': value.wireId});
  Future<void> setGlassQualityMode(SiteLensGlassQualityMode value) =>
      updateSettings({'glassQualityMode': value.name});
  Future<void> setHighQualityAllSurfaces(bool value) =>
      updateSettings({'highQualityAllSurfaces': value});
  Future<void> setRestoreBrowserSessions(bool value) async {
    await updateSettings({'restoreBrowserSessions': value});
    await _persistSessions();
  }

  Future<void> setAllowBackgroundPlayback(bool value) =>
      updateSettings({'allowBackgroundPlayback': value});

  Future<void> setAutoConvertToMp4(bool value) =>
      updateSettings({'autoConvertToMp4': value});

  Future<void> setMp4ExportDirectory(String? value) =>
      updateSettings({'mp4ExportDirectory': value});

  Future<void> setMediaLibraryNoticeDismissed(bool value) =>
      updateSettings({'mediaLibraryNoticeDismissed': value});

  Future<void> setMediaTasksNoticeDismissed(bool value) =>
      updateSettings({'mediaTasksNoticeDismissed': value});

  Future<void> dismissHelpNotice(String id) async {
    settings = await settingsRepository.dismissNotice(id);
    notifyListeners();
  }

  Future<void> setPlayerVerticalGesture(PlayerVerticalGestureMode value) =>
      updateSettings({'playerVerticalGesture': value.name});

  /// Retry with current document authorization instead of a captured row's URL.
  Future<MediaCandidate> mediaCandidateForRetry(MediaTask task) async {
    final session = hosts.sessions[task.hostId];
    final stored = await db.mediaCandidate(task.candidateId);
    if (session != null &&
        !session.disposed &&
        session.generation == task.generation &&
        session.url.isNotEmpty &&
        Uri.parse(session.url).removeFragment() ==
            task.sourceUrl.removeFragment() &&
        stored != null) {
      for (final candidate in hosts.mediaCandidatesForHost(
        task.hostId,
        generation: task.generation,
      )) {
        if (candidate.sourceUrl.removeFragment() !=
                task.sourceUrl.removeFragment() ||
            mediaCandidateAuthorizationKey(candidate.mediaUrl) !=
                mediaCandidateAuthorizationKey(stored.mediaUrl)) {
          continue;
        }
        final authorized = hosts.authorizeMediaCandidate(
          task.hostId,
          candidate.id,
        );
        await db.saveMediaCandidate(authorized);
        mediaTasks.rebindCandidate(
          task.id,
          authorized,
          allowAuthorizationRefresh: true,
        );
        return authorized;
      }
      throw StateError('媒体资源已变化，请返回播放页重新选择媒体');
    }
    if (task.state == MediaTaskState.reauthorize) {
      throw StateError('下载地址已失效或被拒绝，请返回播放页刷新并重新选择媒体后下载');
    }
    if (stored == null) {
      throw StateError('媒体候选已不存在，请返回播放页重新选择媒体');
    }
    return stored;
  }

  MediaCandidate _authorizeMediaDownload(
    MediaTask task,
    MediaCandidate candidate,
  ) {
    final requiresLiveAuthorization =
        task.state == MediaTaskState.reauthorize ||
        task.errorCode == MediaErrorCode.authorizationRequired;
    if (!requiresLiveAuthorization) return candidate;
    if (candidate.id != task.candidateId) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    final session = hosts.sessions[task.hostId];
    if (session == null || session.disposed) {
      throw StateError('下载地址已失效，请返回播放页重新选择媒体');
    }
    if (session.generation != task.generation ||
        session.url.isEmpty ||
        Uri.parse(session.url).removeFragment() !=
            task.sourceUrl.removeFragment()) {
      throw StateError('页面已更新，请返回播放页重新选择媒体');
    }
    final current = hosts.authorizeMediaCandidate(task.hostId, candidate.id);
    if (current.generation != task.generation ||
        current.sourceUrl.removeFragment() != task.sourceUrl.removeFragment() ||
        mediaCandidateAuthorizationKey(current.mediaUrl) !=
            mediaCandidateAuthorizationKey(candidate.mediaUrl)) {
      throw StateError('媒体资源已变化，请返回播放页重新选择媒体');
    }
    return current;
  }

  /// Refreshes surfaces that derive their content from the durable media task
  /// store after a foreground export completes.
  void notifyMediaChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _autoConvertCompletedMedia(MediaTask task) async {
    if (!autoConvertToMp4) return;
    final file = await mediaTasks.cachedFile(task.id);
    if (file == null || !file.path.toLowerCase().endsWith('.m3u8')) return;
    try {
      await exportMediaTask(task);
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.export',
        context: 'auto:${task.id}',
        stack: stack,
      );
    }
  }

  Future<MediaArtifact> exportMediaTask(
    MediaTask task, {
    bool deliverToConfiguredDirectory = true,
  }) async {
    final artifactFuture = _exportingMedia.putIfAbsent(
      task.id,
      () => _prepareMediaArtifact(task),
    );
    final artifact = await artifactFuture;
    if (!deliverToConfiguredDirectory) return artifact;
    await mediaTasks.withExclusive(task.id, () async {
      await mediaLibrary.deliver(task.id, mp4ExportDirectory);
    });
    return mediaLibrary.item(task.id) ?? artifact;
  }

  Future<MediaArtifact> _prepareMediaArtifact(MediaTask task) async {
    var retained = false;
    try {
      await Future<void>.value();
      mediaTasks.retain(task.id);
      retained = true;
      await mediaLibrary.restore();
      var artifact = mediaLibrary.item(task.id);
      if (artifact != null) {
        try {
          artifact = await mediaLibrary.inspect(task.id);
        } catch (error) {
          if (!isMissingMediaArtifactError(error)) rethrow;
          artifact = await mediaLibrary.recoverMissingArtifact(task.id);
          // If no private copy survived, the task's HLS cache remains
          // independent and can be exported again.
        }
      }
      if (artifact == null) {
        final file = await mediaTasks.cachedFile(task.id);
        if (file == null) {
          mediaTasks.markCacheMissing(task.id);
          throw StateError('文件缺失，请在媒体任务中重新下载');
        }
        String output;
        var artifactMime = 'video/mp4';
        var artifactName = mediaExportFileName(task);
        if (file.path.toLowerCase().endsWith('.m3u8')) {
          final input = await const HlsPlaylistParser().parseFile(file.uri);
          final result = await mediaExports.export(task.id, input);
          if (result.state != ExportState.deliverable ||
              result.outputPath == null) {
            throw StateError(result.errorCode ?? '导出失败');
          }
          output = result.outputPath!;
        } else {
          final metadata = nativeExports == null
              ? <String, Object?>{'mime': inferMediaMime(file.uri)}
              : await nativeExports!.inspect(file.path);
          final mime = metadata['mime'] as String? ?? '';
          if (mime.toLowerCase() != 'video/mp4') {
            throw StateError('当前格式暂不支持转 MP4');
          }
          artifactMime = mime;
          final baseName = mediaExportFileName(task)
              .replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '');
          final folder = task.batchDirectory == null
              ? 'direct_${DateTime.now().microsecondsSinceEpoch}'
              : mediaSeriesDirectoryName(task.batchDirectory!);
          final directory = Directory(
            '${(await mediaTasks.cacheRootDirectory()).parent.path}/media_exports/$folder/${task.cacheKey}',
          );
          await directory.create(recursive: true);
          final name = '$baseName.mp4';
          artifactName = name;
          final destination = File('${directory.path}/$name');
          final temporary = File('${destination.path}.part');
          try {
            await file.copy(temporary.path);
            if (await temporary.length() != await file.length()) {
              throw StateError('MP4 副本校验失败');
            }
            await temporary.rename(destination.path);
            output = destination.path;
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
        }
        artifact = await mediaLibrary.register(
          mediaTasks.task(task.id) ?? task,
          output,
          name: artifactName,
          mime: artifactMime,
        );
      }
      return artifact;
    } finally {
      if (retained) mediaTasks.release(task.id);
      _exportingMedia.remove(task.id);
      notifyMediaChanged();
    }
  }

  Future<void> deleteMediaArtifact(
    String taskId, {
    bool deleteTaskCache = false,
    bool deleteTask = false,
  }) async {
    if (deleteTaskCache) {
      await mediaDownloads.delete(
        taskId,
        deleteTask: deleteTask,
        beforeDelete: mediaLibrary.item(taskId) == null
            ? null
            : () => mediaLibrary.delete(taskId, exclusiveAlreadyHeld: true),
      );
    } else {
      await mediaLibrary.delete(taskId);
    }
    notifyMediaChanged();
  }

  Future<void> cleanupTemporaryCastTask(String taskId) async {
    final task = mediaTasks.task(taskId);
    if (task == null) return;
    if (mediaLibrary.item(taskId) != null) {
      await deleteMediaArtifact(
        taskId,
        deleteTaskCache: true,
        deleteTask: true,
      );
      return;
    }
    if (mediaTasks.canDelete(taskId)) {
      await mediaTasks.withExclusive(
        taskId,
        () => mediaTasks.delete(taskId, exclusiveAlreadyHeld: true),
      );
      notifyMediaChanged();
    }
  }

  Future<void> _releaseCastCopy(String taskId) async {
    try {
      await mediaLibrary.releaseMaterializedCopy(taskId);
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.cleanup',
        context: 'cast:$taskId',
        stack: stack,
      );
    }
  }

  Future<File?> mediaPlaybackFile(
    MediaTask task, {
    bool preferExported = true,
  }) async {
    if (preferExported) {
      File? libraryFile;
      try {
        libraryFile = await mediaLibrary.localFile(task.id);
      } on PlatformException catch (error, stack) {
        // A SAF export can disappear or be temporarily unavailable while the
        // original HLS cache is still valid. Keep playback and DLNA usable by
        // falling through to that cache; the diagnostic remains available in
        // the error log for the media page.
        AppErrorLogger.capture(
          error,
          module: 'media.playback',
          context: 'export-fallback:${task.id}',
          stack: stack,
        );
      }
      if (libraryFile != null) return libraryFile;
    }
    final cached = await mediaTasks.cachedFile(task.id);
    if (cached == null && task.localRef != null) {
      mediaTasks.markCacheMissing(task.id);
      notifyMediaChanged();
      throw StateError('文件缺失，请在媒体任务中重新下载');
    }
    return cached;
  }

  Future<void> restoreSavedSessions({bool force = false}) async {
    if (_restoredSessions && !force) return;
    _restoredSessions = true;
    if (!settings.restoreBrowserSessions || browserTabs.isNotEmpty) return;
    final lifecycle = _tabLifecycleEpoch;
    final selection = _selectionEpoch;
    final policy = _restorePolicyEpoch;
    _restoring = true;
    try {
      final saved = await sessionStore.read();
      if (_disposed ||
          lifecycle != _tabLifecycleEpoch ||
          selection != _selectionEpoch ||
          policy != _restorePolicyEpoch ||
          !settings.restoreBrowserSessions ||
          browserTabs.isNotEmpty ||
          _pendingTabCreates.isNotEmpty) {
        return;
      }
      _restorationValid = true;
      final ids = profiles.map((p) => p.id).toSet();
      for (final record in saved.tabs) {
        final profile = ids.contains(record.profileId)
            ? record.profileId
            : null;
        browserTabs.add(
          ActiveBrowserSession.restored(
            Candidate(
              id: 0,
              url: record.initialUrl,
              label: record.title,
              profileId: profile,
              readySelectorOverride: record.selectorOverride,
            ),
            record,
          ),
        );
      }
      activeBrowser =
          browserTabs.where((t) => t.id == saved.activeId).firstOrNull ??
          browserTabs.firstOrNull;
      // Invalid tab snapshots are disposable cache. They are intentionally
      // dropped without an error banner so a damaged cache cannot obscure the
      // restored site data.
    } on FormatException {
      // A corrupt snapshot is disposable cache, not business data. Clear it
      // and let the site list render without a stale startup error.
      try {
        await sessionStore.clear();
      } catch (_) {}
      if (!_disposed) error = null;
    } catch (e) {
      if (!_disposed) error = '上次标签记录无法读取：${friendlyError(e)}';
    } finally {
      _restoring = false;
    }
    notifyListeners();
  }

  void _hostMetadataChanged() {
    if (restoringData) return;
    var changed = false;
    for (final tab in browserTabs) {
      final current = tab.currentUrl;
      final title = tab.loadedHost?.title;
      if (current != tab.lastUrl) {
        tab.lastUrl = current;
        changed = true;
      }
      if (title != null && title.isNotEmpty && title != tab.title) {
        tab.title = title;
        changed = true;
      }
    }
    if (!changed || _disposed) return;
    if (!browserVisible) notifyListeners();
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(
        _persistSessions().catchError((Object e) {
          if (!_disposed) {
            error = '标签记录保存失败：${friendlyError(e)}';
            notifyListeners();
          }
        }),
      );
    });
  }

  Future<void> _persistSessions() {
    if (_disposed) return Future.value();
    final records = browserTabs.map((t) => t.toRecord()).toList();
    final selected = activeBrowser?.id;
    final restore = settings.restoreBrowserSessions;
    Future<void> write() async {
      if (restore) {
        await sessionStore.save(records, selected);
      } else {
        await sessionStore.clear();
      }
    }

    final save = _sessionWrites.then<void>((_) => write());
    // Return the real result to this caller, but keep a settled queue tail so
    // one handled failure cannot poison a later snapshot or shutdown.
    _sessionWrites = save.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return save;
  }

  Future<void> ensureTabLoaded(ActiveBrowserSession tab) async {
    if (!browserTabs.contains(tab)) throw const Cancelled();
    if (tab.loadedHost == null || tab.loadedHost!.disposed) {
      await _recoverTab(tab);
    }
  }

  /// Deletes a profile and removes its open browser tabs before deleting the
  /// database row. Owned candidates and compatibility source rows are removed
  /// in the same database transaction; profile pages, health state and script
  /// links cascade.
  Future<void> deleteProfile(int profileId) async {
    cancel('已删除站点档案，检测已停止');
    // Invalidate both already-open and still-creating tabs. A pending open may
    // otherwise finish after the database row is gone and resurrect a deleted
    // profile in browserSession_v1.
    _tabLifecycleEpoch++;
    _pendingTabCreates.clear();
    _pendingOpens.clear();
    for (final tab
        in browserTabs
            .where((tab) => tab.site.profileId == profileId)
            .toList()) {
      await closeTab(tab);
    }
    await db.deleteProfile(profileId);
    await load();
  }

  Future<void> load({bool suppressCorruption = false}) async {
    Future<T> read<T>(Future<T> Function() action, T fallback) async {
      if (!suppressCorruption) return action();
      try {
        return await action();
      } catch (_) {
        return fallback;
      }
    }

    if (suppressCorruption) error = null;
    sites = await read(db.candidates, sites);
    sources = await read(db.sources, sources);
    profiles = await read(db.profiles, profiles);
    profilePages = await read(db.profilePages, profilePages);
    profileHealth = await read(db.profileHealthAll, profileHealth);
    profileScriptLinks = await read(db.profileScripts, profileScriptLinks);
    installed = await read(db.scripts, installed);
    filterPolicy = await read(db.filterPolicy, filterPolicy);
    profileFilterPolicies = await read(
      db.explicitProfileFilterPolicies,
      profileFilterPolicies,
    );
    try {
      await _seedBuiltInFilterSources();
    } catch (_) {
      if (!suppressCorruption) rethrow;
    }
    filterSourceList = await read(db.filterSources, filterSourceList);
    final latestFilter = await read(db.latestFilterSnapshot, null);
    if (latestFilter != null) {
      try {
        if (latestFilter.sourceId == null) {
          await filterSnapshots.load(latestFilter);
        } else {
          await filterSources.rebuildBundle();
        }
      } catch (_) {
        // Keep browsing available with no active snapshot; diagnostics are
        // retained in Drift and the next manual refresh can recover it.
      }
    }
    history = await read(db.recentProbes, history);
    settings = await read(settingsRepository.read, settings);
    glassQualityCache = await read(
      glassQualityCacheRepository.read,
      glassQualityCache,
    );
    final cached = glassQualityCache;
    if (cached == null || !cached.matches(glassQualityFingerprint)) {
      glassQualityCache = null;
    }
    effectiveGlassQuality = switch (settings.glassQualityMode) {
      SiteLensGlassQualityMode.high => GlassQuality.premium,
      SiteLensGlassQualityMode.standard => GlassQuality.standard,
      SiteLensGlassQualityMode.automatic =>
        glassQualityCache?.quality ?? GlassQuality.standard,
    };
    _applySettings();
    hosts.setFilterEngine(
      filterSnapshots.activeEngine,
      policy: filterPolicy,
      snapshot: filterSnapshots.activeSnapshot,
      profilePolicies: profileFilterPolicies,
    );
    if (suppressCorruption) {
      try {
        await hosts.applyPreferences(hostPreferences);
      } catch (_) {}
    } else {
      await hosts.applyPreferences(hostPreferences);
    }
    await syncMediaPolicy();
    _persistentStateLoaded = true;
    notifyListeners();
  }

  /// Candidates curating [profileId], in stable insertion order.
  List<Candidate> sitesForProfile(int profileId) =>
      sites.where((c) => c.profileId == profileId).toList();

  /// How many bound profiles hold exactly this script content. 1 means unique.
  int sameContentCount(InstalledScript script) {
    final hash = scriptContentHash(script.source);
    return profileScriptLinks
        .where((l) => l.contentHash == hash)
        .map((l) => l.profileId)
        .toSet()
        .length;
  }

  /// Scripts explicitly bound to [profileId].
  List<InstalledScript> scriptsForProfile(int profileId) {
    final links = profileScriptLinks
        .where((l) => l.profileId == profileId)
        .toList();
    return installed
        .where((s) => links.any((link) => link.scriptId == s.id))
        .map((s) {
          final link = links.firstWhere((l) => l.scriptId == s.id);
          return InstalledScript(
            id: s.id,
            name: s.name,
            source: s.source,
            enabled: link.enabled,
            approvedDigest: link.approvedDigest,
          );
        })
        .toList();
  }

  /// Scripts with no profile binding: they stay globally active by @match.
  List<InstalledScript> get unboundScripts {
    final bound = profileScriptLinks.map((l) => l.scriptId).toSet();
    return installed.where((s) => !bound.contains(s.id)).toList();
  }

  ProfileHealth healthFor(int profileId) =>
      profileHealth.where((h) => h.profileId == profileId).firstOrNull ??
      ProfileHealth(profileId: profileId);

  /// This round's probe results for [profileId], cheapest landing first.
  List<ProbeResult> currentResultsFor(int profileId) {
    final ids = sitesForProfile(profileId).map((c) => c.id).toSet();
    return probes.results.values
        .where((r) => r.round == probes.round && ids.contains(r.candidateId))
        .toList()
      ..sort(compareProbeResults);
  }

  /// Ready landing from *this* round only. Used for persistence so a failed or
  /// superseded round can never record a stale success.
  ProbeResult? currentRoundReadyFor(int profileId) =>
      currentResultsFor(profileId).where((r) => r.verified).firstOrNull;

  /// The newest round that produced results for [profileId], with the results
  /// themselves, plus whether that round is still the live one.
  ///
  /// Entering a site supersedes the running round on purpose (a late result must
  /// never become a recommendation after the user has chosen), but the ledger the
  /// user just looked at has to survive that. Without this, every latency and
  /// status disappears from the panel the moment they step into a landing and
  /// come back.
  ({int round, bool live, List<ProbeResult> results}) probeLedgerFor(
    int profileId,
  ) {
    final ids = sitesForProfile(profileId).map((c) => c.id).toSet();
    final mine = probes.results.values
        .where((r) => ids.contains(r.candidateId))
        .toList();
    if (mine.isEmpty) {
      return (round: probes.round, live: true, results: const <ProbeResult>[]);
    }
    final newest = mine.map((r) => r.round).reduce((a, b) => a > b ? a : b);
    final results = mine.where((r) => r.round == newest).toList()
      ..sort(compareProbeResults);
    return (round: newest, live: newest == probes.round, results: results);
  }

  /// Best "首页已就绪" landing for [profileId]: this round first, else the most
  /// recent stored history that was ready.
  ProbeResult? latestReadyFor(int profileId) {
    final current = currentResultsFor(profileId)
        .where((r) => r.verified)
        .toList();
    if (current.isNotEmpty) return current.first;
    final ids = sitesForProfile(profileId).map((c) => c.id).toSet();
    return history
        .where((r) => ids.contains(r.candidateId) && r.verified)
        .firstOrNull;
  }

  /// The newest time this profile was probed, current round or history.
  DateTime? lastCheckedFor(int profileId) {
    final current = currentResultsFor(profileId);
    if (current.isNotEmpty) {
      return current
          .map((r) => r.checkedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
    }
    final ids = sitesForProfile(profileId).map((c) => c.id).toSet();
    for (final r in history) {
      if (ids.contains(r.candidateId)) return r.checkedAt;
    }
    return null;
  }

  /// Aborts an in-flight [recon] (e.g. the user dismissed the dialog).
  void cancelRecon() => _recon.cancel();

  /// Reconciles the ready selector for a page: prefer the first selector that
  /// is actually present, visible and non-empty, in descending specificity.
  static const readySelectorCandidates = <String>[
    'main',
    'article',
    '#content',
    '.content',
    '#app',
    '.player',
    'video',
    'body',
  ];

  /// "粘一个 URL → App 侦察": navigate once, read the latest-addresses region
  /// and infer a ready selector. Never writes anything; the user confirms.
  Future<ReconResult> recon(String input) async {
    final url = webUri(input);
    _recon.cancel();
    final token = _recon = Cancellation();
    token.check();
    final host = await hosts.create(HostPurpose.discovery);
    token.onCancel(() => unawaited(hosts.destroy(host)));
    try {
      await hosts.navigate(host, url);
      final watch = Stopwatch()..start();
      PageSnapshot? region;
      Uri? lastUrl;
      while (watch.elapsed < const Duration(seconds: 15)) {
        token.check();
        if (host.error != null) throw StateError(host.error!);
        final snapshot = await hosts.api
            .inspect(host.id, '@latest-addresses')
            .timeout(const Duration(seconds: 3));
        if (snapshot.url.startsWith('http')) lastUrl = webUri(snapshot.url);
        if (snapshot.error.isNotEmpty) throw StateError(snapshot.error);
        if (snapshot.challenge) {
          return ReconResult(
            url: url,
            finalUrl: lastUrl,
            title: snapshot.title,
            regionSelector: '@latest-addresses',
            regionFound: false,
            links: const [],
            inferredReadySelector: null,
            challenge: true,
            note: '检测到验证码/人机验证，请手动查看后再添加',
          );
        }
        if (snapshot.interactionRequired) {
          return ReconResult(
            url: url,
            finalUrl: lastUrl,
            title: snapshot.title,
            regionSelector: '@latest-addresses',
            regionFound: false,
            links: const [],
            inferredReadySelector: null,
            interactionRequired: true,
            note: '页面需要登录或交互，自动侦察不可靠',
          );
        }
        if (snapshot.ready) {
          region = snapshot;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final ready = await _inferReadySelector(host, token);
      final excludedPages = <String>{webPageKey(url)};
      if (lastUrl != null) excludedPages.add(webPageKey(lastUrl));
      final links = (region?.links ?? const <String>[])
          .map(Uri.tryParse)
          .whereType<Uri>()
          .where((u) => ['http', 'https'].contains(u.scheme))
          .where((u) => !excludedPages.contains(webPageKey(u)))
          .take(5)
          .toList();
      return ReconResult(
        url: url,
        finalUrl: lastUrl,
        title: region?.title ?? '',
        regionSelector: '@latest-addresses',
        regionFound: region != null,
        links: links,
        inferredReadySelector: ready,
        note: region == null ? '没有自动定位到「最新地址」区域，请在下方手填区域选择器（缓存会保留）' : null,
      );
    } on Cancelled {
      rethrow;
    } finally {
      await hosts.destroy(host);
    }
  }

  Future<String?> _inferReadySelector(
    HostSession host,
    Cancellation token,
  ) async {
    for (final selector in readySelectorCandidates) {
      token.check();
      try {
        final snapshot = await hosts.api
            .inspect(host.id, selector)
            .timeout(const Duration(seconds: 2));
        if (snapshot.ready) return selector;
      } catch (_) {
        /* try the next candidate */
      }
    }
    return null;
  }

  /// Re-runs publishing-page discovery for one profile only.
  Future<void> rescoutProfile(SiteProfile profile) async {
    final token = _discovery = Cancellation();
    error = null;
    try {
      refreshing = true;
      notifyListeners();
      await PublishingDiscovery(
        db,
        hosts,
      ).refresh(token, profileId: profile.id);
      await load();
    } on Cancelled {
      /* superseded */
    } catch (e) {
      error = friendlyError(e);
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  /// Snapshot of the profile's publishing config after a successful round, so
  /// "回退到上次成功配置" has something concrete to restore.
  Future<void> rememberProfileConfig(int profileId) async {
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null) return;
    final pages = await db.profilePages(profileId: profileId);
    await db.setSetting(
      'profile_config_$profileId',
      jsonEncode({
        'readySelector': profile.readySelector,
        'pages': pages
            .map((p) => {'url': p.url.toString(), 'region': p.regionSelector})
            .toList(),
      }),
    );
  }

  Future<bool> restoreProfileConfig(int profileId) async {
    final raw = await db.setting('profile_config_$profileId');
    if (raw == null) return false;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final pages = (json['pages'] as List).cast<Map<String, dynamic>>();
    final keep = pages.map((p) => p['url'] as String).toSet();
    await db.transaction(() async {
      await db.setProfileReadySelector(
        profileId,
        json['readySelector'] as String,
      );
      // A true rollback: drop pages that did not exist in the good snapshot.
      for (final page in await db.profilePages(profileId: profileId)) {
        if (!keep.contains(page.url.toString())) {
          await db.deleteProfilePage(page.id);
        }
      }
      for (final page in pages) {
        await db.addProfilePage(
          profileId,
          Uri.parse(page['url'] as String),
          page['region'] as String,
        );
      }
    });
    await load();
    return true;
  }

  void cancel([String reason = '用户已停止检测']) {
    _selectionEpoch++;
    _discovery.cancel();
    _recon.cancel();
    refreshing = false;
    probes.cancel(reason);
    notifyListeners();
  }

  Future<List<Candidate>> _enabledCandidates() async {
    final profiles = await db.profiles();
    final enabledProfiles = profiles
        .where((p) => p.enabled)
        .map((p) => p.id)
        .toSet();
    final candidates = await db.candidates();
    return candidates.where((candidate) {
      final profileId = candidate.profileId;
      return profileId == null || enabledProfiles.contains(profileId);
    }).toList();
  }

  Future<DetectionOutcome> detect({
    bool all = false,
    bool refreshSources = true,
    int? profileId,
  }) async {
    cancel('开始刷新与检测');
    final cancelToken = _discovery = Cancellation();
    error = null;
    try {
      if (refreshSources && profilePages.isNotEmpty) {
        refreshing = true;
        notifyListeners();
        await PublishingDiscovery(
          db,
          hosts,
        ).refresh(cancelToken, profileId: profileId);
        cancelToken.check();
        await load();
        refreshing = false;
        notifyListeners();
      }
      cancelToken.check();
      await probes.run(all: all, profileId: profileId);
      // A cancelled/superseded round returns normally from run(), so re-check
      // before persisting: only this round's real successes may be recorded.
      cancelToken.check();
      await load();
      cancelToken.check();
      for (final profile in profiles) {
        if (profileId != null && profile.id != profileId) continue;
        cancelToken.check();
        final ready = currentRoundReadyFor(profile.id);
        final landing = ready?.finalUrl;
        if (landing != null) {
          await db.setProfileLastLanding(profile.id, landing);
          await rememberProfileConfig(profile.id);
        }
      }
      await load();
      cancelToken.check();
      return DetectionOutcome.completed;
    } on Cancelled {
      /* User selection/network change wins. */
      return DetectionOutcome.cancelled;
    } catch (e) {
      if (!cancelToken.cancelled) {
        error = friendlyError(e);
        refreshing = false;
        notifyListeners();
      }
      return DetectionOutcome.failed;
    }
  }

  Future<void> setPullToRefresh(bool enabled) async {
    await updateSettings({'pullToRefresh': enabled});
  }

  Future<void> setBackgroundHealthCheck(bool enabled) async {
    await updateSettings({'backgroundHealthCheck': enabled});
    try {
      await const HealthScheduler().apply(enabled);
    } catch (_) {
      /* best effort */
    }
    notifyListeners();
  }

  /// Surfaces (and clears) a notice recorded by the background isolate. Called
  /// on cold start and on every resume, and only cleared once actually posted
  /// so a denied notification is retried instead of silently lost.
  Future<void> drainBackgroundNotice() async {
    final pending = await db.setting(healthNoticeKey);
    if (pending == null || pending.isEmpty) return;
    final parts = pending.split('\u0000');
    final title = parts.first;
    final body = parts.length > 1 ? parts[1] : '';
    lastHealthNotice = '$title：$body';
    var delivered = false;
    try {
      delivered = await const DeviceConditions().notify(title, body);
    } catch (_) {
      /* notification permission may be denied */
    }
    if (delivered) await db.setSetting(healthNoticeKey, '');
    notifyListeners();
  }

  /// Checks the native browser host once without opening a user tab or
  /// running the background HTTP health policy. The temporary host is destroyed
  /// immediately after its capabilities are captured.
  /// Compatibility API for existing background-check integration coverage.
  /// The settings page now uses [checkHostCapabilities] instead.
  Future<HealthRunReport> runHealthCheckOnce({
    HealthConditions? conditions,
  }) async {
    conditions ??= await const DeviceConditions().read();
    final checker = ProfileHealthChecker(
      db: db,
      probe: HttpReachabilityProbe(),
      conditions: conditions,
      now: DateTime.now,
      notify: (title, body) async {
        lastHealthNotice = '$title：$body';
      },
    );
    final report = await checker.run();
    lastHealthReport = report;
    await load();
    notifyListeners();
    return report;
  }

  Future<HostCapabilities> checkHostCapabilities() async {
    checkingHostCapabilities = true;
    hostCapabilityError = null;
    notifyListeners();
    HostSession? host;
    try {
      host = await hosts.create(HostPurpose.browsing);
      final result = host.capabilities;
      await hosts.destroy(host);
      capabilities = result;
      return result;
    } catch (_) {
      capabilities = null;
      hostCapabilityError = '检查未完成，请重试';
      throw StateError('检查未完成，请重试');
    } finally {
      checkingHostCapabilities = false;
      notifyListeners();
    }
  }

  String? lastHealthNotice;

  Future<void> disableAllScripts(bool disabled) async {
    await updateSettings({'scriptsDisabled': disabled});
    for (final session in hosts.sessions.values.toList().where(
      (h) => h.purpose == HostPurpose.browsing,
    )) {
      await hosts.configure(session);
      await hosts.api.reload(session.id);
    }
    await load();
  }

  Future<void> disableScript(String id) async {
    await scripts.disable(id);
    await reloadScripts();
    await load();
  }

  Future<void> setScriptNetworkMode(
    String id,
    ScriptNetworkMode mode, {
    String? reason,
    bool publicConfirmed = false,
  }) async {
    await scripts.setNetworkMode(
      id,
      mode,
      reason: reason,
      publicConfirmed: publicConfirmed,
    );
    await reloadScripts();
    await load();
  }

  /// Scripts the tab's host holds *and* whose `@match` covers its current
  /// document — the only scripts that can run there, so also the only ones that
  /// could have registered a menu command.
  List<InstalledScript> activeScriptsFor(ActiveBrowserSession tab) {
    if (tab.loadedHost == null || tab.loadedHost!.disposed) return const [];
    final current = Uri.tryParse(tab.host.url);
    if (current == null || current.host.isEmpty) return const [];
    final registered = tab.host.registered.keys.toSet();
    return installed
        .where((s) => registered.contains(s.id))
        .where((s) => ScriptMetadata.parse(s.source).matchesUrl(current))
        .toList();
  }

  /// In the user's terms, why the browser's "本次文档生效脚本" row is empty.
  ///
  /// That sheet is the only place reporting script state *inside* a browsing
  /// session, so a bare "没有脚本匹配当前页面" leaves the user guessing between
  /// "globally switched off", "nothing enabled", "approval invalidated" and
  /// "@match does not cover this address".
  String scriptActivityReason(ActiveBrowserSession tab) {
    if (scriptsDisabled) {
      return '全局「关闭全部脚本」已打开：所有脚本都停用了，回「脚本」页关掉它就恢复。';
    }
    if (installed.isEmpty) {
      return '还没有导入任何脚本：到「脚本」页粘贴或导入 .user.js。';
    }
    final enabled = installed.where((s) => s.enabled).toList();
    if (enabled.isEmpty && tab.host.registered.isEmpty) {
      return '没有已启用的脚本：到「脚本」页启用；被自动关闭的会在错误日志里写明原因。';
    }
    if (tab.loadedHost == null) return '选择标签加载后可查看生效脚本';
    if (tab.host.registered.isEmpty) {
      return '宿主里没有已注册脚本（共 ${enabled.length} 个已启用）：确认或依赖完整性可能已失效'
          '（看「脚本」页错误日志），也可能是本机不支持安全隔离（见页面上的提示）；'
          '页面刚打开时刷新一次再看。';
    }
    final active = activeScriptsFor(tab);
    if (active.isNotEmpty) {
      return '本次文档生效脚本：${active.map((s) => s.name).join('、')}';
    }
    final where = tab.host.url.isEmpty ? '当前地址' : tab.host.url;
    return '已启用 ${enabled.length} 个脚本（${enabled.map((s) => s.name).join('、')}），'
        '但它们的 @match 都不覆盖 $where；'
        '如果刚刚改过脚本/授权，用下面的「重新加载脚本并刷新页面」。';
  }

  /// Re-applies the current script set to every browsing host and reloads.
  /// The recovery path after the user changed scripts outside the browser.
  Future<void> reloadScripts() async {
    for (final session in hosts.sessions.values.toList().where(
      (h) => h.purpose == HostPurpose.browsing && !h.disposed,
    )) {
      await hosts.configure(session);
      await hosts.api.reload(session.id);
    }
  }

  /// Where the floating browser controls sit, as a fraction of the free space
  /// inside the browsing viewport: (0,0) top-left, (1,1) bottom-right.
  ///
  /// Default is bottom-center (the handle used to be pinned there). It is
  /// user-movable and persisted because pages — and the user scripts running in
  /// them — commonly put their own controls along the bottom edge, and only the
  /// user knows where they must not overlap.
  Offset browserControlsFraction = const Offset(0.5, 1);

  /// Moves the floating controls; [persist] is false while a drag is in flight
  /// so the database is written once at the end instead of on every frame.
  Future<void> setBrowserControlsFraction(
    Offset value, {
    bool persist = true,
  }) async {
    final clamped = Offset(value.dx.clamp(0.0, 1.0), value.dy.clamp(0.0, 1.0));
    if (clamped != browserControlsFraction) {
      browserControlsFraction = clamped;
      notifyListeners();
    }
    if (persist) {
      await updateSettings({'controlsX': clamped.dx, 'controlsY': clamped.dy});
    }
  }

  /// Dismisses the current panel-level error (TLS, detection, script integrity).
  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  /// A tab "is at" [url] when either its origin URL or its current (possibly
  /// redirected) URL matches, so a redirect cannot spawn a duplicate tab.
  bool _tabAt(ActiveBrowserSession tab, Uri url) {
    if (tab.site.url == url) return true;
    final current = tab.currentUrl.toString();
    if (current.isEmpty) return false;
    final parsed = Uri.tryParse(current);
    return parsed != null && parsed.removeFragment() == url.removeFragment();
  }

  /// Opens [url], reusing an identical tab when present and otherwise adding a
  /// new one.
  ///
  /// Switching mirror landings must not silently destroy the tab the user is
  /// reading: the old code replaced the active tab, so one profile could only
  /// ever hold one landing and the previous one (with its history, scroll
  /// position and page state) was gone. Tabs now only disappear when the user
  /// closes them; the strip is still bounded by [maxBrowserTabs].
  Future<ActiveBrowserSession> openUrl(
    Uri url, {
    String? label,
    int? profileId,
    Candidate? candidate,
    Cancellation? cancelToken,
  }) async {
    if (restoringData) throw StateError('正在恢复数据，请稍后打开标签');
    cancelToken?.check();
    final selection = ++_selectionEpoch;
    ActiveBrowserSession? existing = browserTabs
        .where((tab) => tab.site.profileId == profileId && _tabAt(tab, url))
        .firstOrNull;
    if (existing == null && settings.replaceSameSiteTabs && profileId != null) {
      existing = browserTabs
          .where((tab) => tab.site.profileId == profileId)
          .firstOrNull;
      if (existing != null) {
        await ensureTabLoaded(existing);
        cancelToken?.check();
        existing.updateNavigation(url, label: label, candidate: candidate);
        await hosts.navigate(existing.host, url);
        if (selection != _selectionEpoch || !browserTabs.contains(existing)) {
          return existing;
        }
        activeBrowser = existing;
        notifyListeners();
        await _persistSessions();
        return existing;
      }
    }
    if (existing != null) {
      await ensureTabLoaded(existing);
      cancelToken?.check();
      if (selection != _selectionEpoch || !browserTabs.contains(existing)) {
        return existing;
      }
      // Only notify when the visible tab actually changes: this path is also
      // reached from initState, and a synchronous notify there would mark the
      // home screen dirty in the middle of a build.
      if (!identical(activeBrowser, existing)) {
        activeBrowser = existing;
        notifyListeners();
      }
      await _persistSessions();
      return existing;
    }
    final key = '${profileId ?? "manual"}:${url.removeFragment()}';
    final pending = _pendingOpens[key];
    if (pending != null) {
      final tab = await pending;
      if (selection == _selectionEpoch && browserTabs.contains(tab)) {
        activeBrowser = tab;
        notifyListeners();
        await _persistSessions();
      }
      return tab;
    }
    final creation = _spawnTab(
      candidate ??
          Candidate(
            id: 0,
            url: url,
            label: label ?? url.host,
            enabled: true,
            profileId: profileId,
          ),
      cancelToken: cancelToken,
    );
    _pendingOpens[key] = creation;
    cancelToken?.onCancel(() {
      if (identical(_pendingOpens[key], creation)) _pendingOpens.remove(key);
    });
    try {
      final tab = await creation;
      if (selection == _selectionEpoch && browserTabs.contains(tab)) {
        activeBrowser = tab;
        notifyListeners();
      }
      await _persistSessions();
      return tab;
    } finally {
      if (identical(_pendingOpens[key], creation)) _pendingOpens.remove(key);
    }
  }

  /// Opens [site]. Reuses an already open tab with the same URL, otherwise adds
  /// a new tab.
  Future<ActiveBrowserSession> openBrowser(Candidate site) => openUrl(
    site.url,
    label: site.label,
    profileId: site.profileId,
    candidate: site,
  );

  /// The default entry path for a profile: use the last known landing as a fast
  /// path, then silently fall back to a fresh detection round. A failed tab is
  /// kept visible rather than being replaced.
  Future<ActiveBrowserSession?> enterProfile(SiteProfile profile) async {
    if (!profile.enabled) {
      error = '该站点档案已停用，请先在站点首页启用';
      notifyListeners();
      return null;
    }
    final landing = profile.lastLanding;
    if (landing != null) {
      final session = await openUrl(
        landing,
        label: profile.name,
        profileId: profile.id,
      );
      unawaited(_watchFastPath(profile, session));
      return session;
    }
    return _enterBestLanding(profile);
  }

  Future<ActiveBrowserSession?> _enterBestLanding(
    SiteProfile profile, {
    Uri? avoid,
  }) async {
    // Run a full round: refresh publishing pages first so the profile has fresh
    // candidates, then verify their landings.
    if (await detect(profileId: profile.id) != DetectionOutcome.completed) {
      return null;
    }
    Uri? target;
    for (final r in currentResultsFor(profile.id)) {
      final landing = r.finalUrl;
      if (r.verified && landing != null && landing != avoid) {
        target = landing;
        break;
      }
    }
    // History is only a fallback for the first entry, never for a failed tab:
    // re-entering a stale URL would defeat the point of the fallback.
    target ??= avoid == null ? latestReadyFor(profile.id)?.finalUrl : null;
    if (target == null) {
      error = avoid == null
          ? '这一轮没有「首页已就绪」的落点；请检查发布页与核心 DOM 选择器'
          : '快路径未就绪，且这一轮没有更优落点；失败的标签保留可手动查看';
      notifyListeners();
      return null;
    }
    return openUrl(
      target,
      label: profile.name,
      profileId: profile.id,
      cancelToken: _discovery,
    );
  }

  /// Watches a fast-path tab: success is "核心 DOM 就绪" within 6s; a network or
  /// certificate error, or an unready DOM, triggers the fallback.
  Future<void> _watchFastPath(
    SiteProfile profile,
    ActiveBrowserSession session,
  ) async {
    final selection = _selectionEpoch;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (selection != _selectionEpoch ||
          !identical(activeBrowser, session) ||
          session.loadedHost == null ||
          session.host.disposed) {
        return;
      }
      final host = session.host;
      if (host.errorKind != null) break;
      if (host.loaded) {
        try {
          final snapshot = await hosts.api
              .inspect(
                host.id,
                session.site.effectiveReadySelector(profile.readySelector),
              )
              .timeout(const Duration(seconds: 2));
          if (snapshot.ready ||
              snapshot.challenge ||
              snapshot.interactionRequired) {
            return;
          }
        } catch (_) {
          /* keep waiting until the deadline */
        }
      }
    }
    if (selection != _selectionEpoch ||
        !identical(activeBrowser, session) ||
        session.loadedHost == null ||
        session.host.disposed) {
      return;
    }
    // Never re-enter the URL that just failed, and never resurrect it from
    // history: only this round's fresh success counts as an improvement.
    await _enterBestLanding(profile, avoid: session.site.url);
  }

  static const maxBrowserTabs = AppPolicy.maxBrowserTabs;

  Future<ActiveBrowserSession> _spawnTab(
    Candidate site, {
    Cancellation? cancelToken,
  }) async {
    cancelToken?.check();
    if (browserTabs.length + _pendingTabCreates.length >= maxBrowserTabs) {
      throw StateError('最多同时打开 $maxBrowserTabs 个标签页；请到「浏览器」页关闭一个再进入');
    }
    final reservation = Object();
    _pendingTabCreates.add(reservation);
    final epoch = _tabLifecycleEpoch;
    HostSession? host;
    try {
      host = await hosts.create(
        HostPurpose.browsing,
        profileId: site.profileId,
      );
      capabilities = host.capabilities;
      cancelToken?.check();
      if (epoch != _tabLifecycleEpoch) {
        await hosts.destroy(host);
        throw StateError('标签创建已取消');
      }
      await hosts.configure(host);
      cancelToken?.check();
      if (epoch != _tabLifecycleEpoch || host.disposed) {
        throw StateError('标签创建已取消');
      }
      await hosts.navigate(host, site.url);
      cancelToken?.check();
      if (epoch != _tabLifecycleEpoch) {
        await hosts.destroy(host);
        throw StateError('标签创建已取消');
      }
      final session = ActiveBrowserSession(site, host);
      browserTabs.add(session);
      notifyListeners();
      return session;
    } catch (_) {
      if (host != null && !host.disposed) await hosts.destroy(host);
      rethrow;
    } finally {
      _pendingTabCreates.remove(reservation);
    }
  }

  /// Site-initiated `window.open` / `target="_blank"` navigations become tabs
  /// instead of real popup windows, which the platform view cannot host.
  Future<void> _openLinkInNewTab(int hostId, String url) async {
    final source = hosts.sessions[hostId];
    if (source == null || source.disposed) return;
    final Uri target;
    try {
      target = webUri(url);
    } on FormatException {
      return;
    }
    if (browserTabs.any((tab) => _tabAt(tab, target))) return;
    // A page can request popups in a loop; keep the strip bounded.
    if (browserTabs.length >= maxBrowserTabs) return;
    try {
      final owner = browserTabs
          .where((t) => t.loadedHost?.id == hostId)
          .firstOrNull;
      await openUrl(
        target,
        label: target.host,
        profileId: owner?.site.profileId,
      );
    } catch (e) {
      error = '打开新标签页失败：${friendlyError(e)}';
      notifyListeners();
    }
  }

  final _recoveries = <ActiveBrowserSession, Future<void>>{};

  Future<void> _recoverTab(ActiveBrowserSession tab) {
    return _recoveries.putIfAbsent(tab, () => _recreateHost(tab));
  }

  Future<void> _recreateHost(ActiveBrowserSession tab) async {
    final epoch = _tabLifecycleEpoch;
    tab.loading = true;
    notifyListeners();
    HostSession? host;
    try {
      host = await hosts.create(
        HostPurpose.browsing,
        profileId: tab.site.profileId,
      );
      capabilities = host.capabilities;
      if (!browserTabs.contains(tab) || epoch != _tabLifecycleEpoch) {
        throw const Cancelled();
      }
      await hosts.configure(host);
      if (!browserTabs.contains(tab) || epoch != _tabLifecycleEpoch) {
        throw const Cancelled();
      }
      await hosts.navigate(host, tab.currentUrl);
      if (!browserTabs.contains(tab) || epoch != _tabLifecycleEpoch) {
        throw const Cancelled();
      }
      tab.host = host;
      tab.loading = false;
      notifyListeners();
    } catch (e) {
      tab.failure = friendlyError(e);
      tab.loading = false;
      notifyListeners();
      if (host != null) await hosts.destroy(host);
      rethrow;
    } finally {
      tab.loading = false;
      _recoveries.remove(tab);
    }
  }

  Future<void> activateTab(ActiveBrowserSession tab) async {
    if (restoringData) throw StateError('正在恢复数据');
    if (!browserTabs.contains(tab)) return;
    final selection = ++_selectionEpoch;
    activeBrowser = tab;
    notifyListeners();
    await ensureTabLoaded(tab);
    if (selection != _selectionEpoch || !browserTabs.contains(tab)) return;
    await _persistSessions();
  }

  /// Closes one tab. Returns true while at least one tab is still open.
  Future<bool> closeTab(ActiveBrowserSession tab) async {
    final index = browserTabs.indexOf(tab);
    if (index < 0) return browserTabs.isNotEmpty;
    browserTabs.removeAt(index);
    _selectionEpoch++;
    if (identical(activeBrowser, tab)) {
      activeBrowser = browserTabs.isEmpty
          ? null
          : browserTabs[index.clamp(0, browserTabs.length - 1)];
    }
    final host = tab.loadedHost;
    // Rebuild the browser route before destroying the native host. This is the
    // first half of the platform-view teardown handshake.
    notifyListeners();
    // Commit the user's close independently of whether the next page loads.
    try {
      await _persistSessions();
    } catch (e) {
      if (!_disposed) {
        error = '标签记录保存失败：${friendlyError(e)}';
        notifyListeners();
      }
    } finally {
      if (host != null) await hosts.destroy(host);
    }
    if (browserVisible && activeBrowser != null) {
      try {
        await ensureTabLoaded(activeBrowser!);
      } catch (e) {
        if (!_disposed) error = '接替标签加载失败：${friendlyError(e)}';
      }
    }
    notifyListeners();
    return browserTabs.isNotEmpty;
  }

  Future<void> closeAllTabs({bool persist = true}) async {
    _selectionEpoch++;
    _tabLifecycleEpoch++;
    _pendingTabCreates.clear();
    _pendingOpens.clear();
    final open = browserTabs.toList();
    browserTabs.clear();
    activeBrowser = null;
    // Publish the removal so Flutter can release each platform-view element.
    // The native host waits for that release before destroying its WebView.
    notifyListeners();
    for (final tab in open) {
      if (tab.loadedHost != null) await hosts.destroy(tab.loadedHost!);
    }
    if (persist) await _persistSessions();
  }

  bool restoringData = false;
  Future<Uint8List> exportBackup() async {
    await _persistSessions();
    return BackupService(db).export();
  }

  Future<BackupSnapshot> inspectBackup(Uint8List bytes) =>
      BackupService(db).validate(bytes);
  Future<String> restoreBackup(BackupSnapshot snapshot) async {
    if (restoringData ||
        probes.running ||
        refreshing ||
        _pendingOpens.isNotEmpty ||
        _recoveries.isNotEmpty) {
      throw StateError('请等待当前操作完成，或先停止检测，再恢复备份');
    }
    restoringData = true;
    _sessionSaveTimer?.cancel();
    _selectionEpoch++;
    _tabLifecycleEpoch++;
    cancel('正在恢复备份');
    cancelRecon();
    try {
      final safety = await exportBackup();
      final folder = await getApplicationSupportDirectory();
      final file = File(
        '${folder.path}/before-restore-${DateTime.now().toUtc().microsecondsSinceEpoch}.zip',
      );
      await file.writeAsBytes(safety, flush: true);
      // Revoke all native/script ownership before data changes, preserving tab metadata on failure.
      for (final session in hosts.sessions.values.toList()) {
        for (final tab in browserTabs.where(
          (t) => identical(t.loadedHost, session),
        )) {
          tab.invalidate('数据已切换，选择标签重新加载');
        }
        await hosts.destroy(session);
      }
      await BackupService(db).restore(snapshot);
      browserTabs.clear();
      activeBrowser = null;
      _restoredSessions = false;
      _restorationValid = false;
      await load();
      await restoreSavedSessions();
      try {
        await const HealthScheduler().apply(backgroundHealthCheck);
      } catch (_) {
        error = '数据已恢复，后台检查暂未安排，稍后可在设置重试';
      }
      return file.path;
    } finally {
      restoringData = false;
      notifyListeners();
    }
  }

  Future<void> resetPreferences() async {
    final defaults = AppSettings(scriptsDisabled: scriptsDisabled).toJson()
      ..remove('version');
    await updateSettings(defaults);
    await const HealthScheduler().apply(backgroundHealthCheck);
    await _persistSessions();
  }

  @override
  void notifyListeners() {
    if (!_disposed) unawaited(syncMediaPolicy());
    if (!_disposed) super.notifyListeners();
  }

  /// Await this before closing the database. Flutter's synchronous disposal
  /// also starts it, while retaining already accepted metadata writes.
  Future<void> shutdown() {
    if (!_disposed) dispose();
    return _shutdownFuture ?? Future.value();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _sessionSaveTimer?.cancel();
    final flush = browserTabs.isNotEmpty || (_restorationValid && !_restoring)
        ? _persistSessions()
        : _sessionWrites;
    final mediaFlush = mediaTasks.flushAll();
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    hosts.changed.removeListener(_hostMetadataChanged);
    _network?.cancel();
    _discovery.cancel();
    _recon.cancel();
    probes.dispose();
    // Clear native ownership immediately, but do not overwrite the captured
    // snapshot during asynchronous destruction.
    final close = closeAllTabs(persist: false);
    final stopCast = castSessions.active == null
        ? Future<void>.value()
        : mediaCast.stop().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
    _shutdownFuture = Future.wait<void>([
      flush,
      mediaFlush,
      close,
      nativeMedia.dispose(),
      stopCast,
    ]).then<void>((_) {}).whenComplete(settingsRepository.dispose);
    unawaited(
      _shutdownFuture!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    mediaLibrary.removeListener(notifyMediaChanged);
    mediaLibrary.dispose();
    AppErrorLogger.detach(errorLogger);
    super.dispose();
  }
}
