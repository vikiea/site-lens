import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../adapters/direct_route.dart';
import '../backup/backup_service.dart';
import '../background/background_asset_store.dart';
import '../background/background_snapshot.dart';
import '../cache/transient_cache_service.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../data/database.dart';
import '../diagnostics/error_log.dart';
import '../diagnostics/device_diagnostics.dart';
import '../diagnostics/startup_trace.dart';
import '../browser/browser_session.dart';
import '../browser/browser_session_store.dart';
export '../browser/browser_session.dart'
    show ActiveBrowserSession, BrowserSessionState;
import '../data/profile_pack.dart';
import '../background/health_worker.dart';
import '../background/native_health_probe.dart';
import '../device/device_conditions.dart';
import '../discovery/health_checker.dart';
import '../discovery/probe_coordinator.dart';
import '../domain/models.dart';
import '../domain/route_health.dart';
import '../domain/site_adapter.dart';
import '../media/native_credential_push.dart';
import '../media/remote_episode_source.dart';
import '../media/remote_playback_controller.dart';
import '../media/remote_playback_failure.dart';
import '../media/site_credential_handoff.dart';
import '../site_credentials/site_credential_store.dart';
import '../theater/series_line_memory.dart';
import '../domain/web_page_origin.dart';
import '../network/transport.dart';
import '../network/native_system_http.dart';
import '../network/secure_dns_resolver.dart';
import '../scripts/metadata.dart';
import '../scripts/script_service.dart';
import '../web_host/native_hosts.dart';
import '../web_host/web_host.g.dart';
import '../settings/settings_repository.dart';
import '../settings/app_settings.dart';
import '../filter/filter_service.dart';
import '../media/media_service.dart';
import '../media/media_export_queue.dart';
import '../media/media_library.dart';
import '../media/media_storage.dart';
import '../media/dlna_service.dart';
import '../media/native_download_runtime.dart';
import '../media/native_export_runtime.dart';
import '../media/media_storage_mode.dart';
import '../media/media_operation_runner.dart';
import '../media/media_network.dart';
import '../media/media_resource_coordinator.dart';
import '../media/native_media_runtime.dart';
import '../media/native_media_auth_refresh.dart';
import '../media/native_playback_store.dart';
import '../media/watch_save_store.dart';
import 'glass_quality_cache.dart';
import 'ui_util.dart';

/// The user preferences travel as one versioned record (`AppPolicy.settingsKey`).
/// This key is retained for compatibility with older database fixtures only;
/// it is not read as an independent preference.

final databaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError('Database not initialized'),
);
final appBootstrapProvider = Provider<AppBootstrapSnapshot?>((ref) => null);

class AppBootstrapSnapshot {
  const AppBootstrapSnapshot({
    required this.settings,
    required this.background,
    required this.glassQualityCache,
  });

  final AppSettings settings;
  final BackgroundSnapshot background;
  final SiteLensGlassQualityCache? glassQualityCache;
}

Future<AppBootstrapSnapshot> readAppBootstrap(AppDatabase db) async {
  var settings = const AppSettings();
  var background = const BackgroundSnapshot();
  SiteLensGlassQualityCache? glassQualityCache;
  try {
    final repository = SettingsRepository(db);
    settings = await repository.read();
    await repository.dispose();
  } catch (error, stack) {
    AppErrorLogger.capture(error, module: 'startup.preferences', stack: stack);
  }
  try {
    final assets = BackgroundAssetStore();
    final file = await assets.fileFor(settings.backgroundAssetId);
    background = BackgroundSnapshot(
      mode: settings.backgroundMode,
      imagePath: file?.path,
      assetMissing: settings.backgroundAssetId != null && file == null,
    );
  } catch (error, stack) {
    AppErrorLogger.capture(error, module: 'startup.preferences', stack: stack);
  }
  try {
    glassQualityCache = await SiteLensGlassQualityCacheRepository(db).read();
  } catch (error, stack) {
    AppErrorLogger.capture(error, module: 'startup.preferences', stack: stack);
  }
  return AppBootstrapSnapshot(
    settings: settings,
    background: background,
    glassQualityCache: glassQualityCache,
  );
}

final appControllerProvider = Provider<AppController>((ref) {
  final controller = AppController(
    ref.watch(databaseProvider),
    bootstrap: ref.watch(appBootstrapProvider),
    startupTrace: StartupTrace.process,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

const _filterSourceSeedSetting = 'filterSourceSeedVersion';

/// What a retry attempt produced, in the vocabulary of GLOSSARY.md.
///
/// The three refresh states lead to different next steps, so the UI needs the
/// kind and not only a sentence: retrying again is pointless for [unchanged]
/// and [requiresPage], which are the two outcomes that offer the source page.
enum MediaRetryOutcomeKind {
  /// The transfer was accepted and is running again.
  resumed,

  /// The source page answered, but the authorization did not change.
  unchanged,

  /// Only a fresh visit to the source page can recover authorization.
  requiresPage,

  /// The platform is waiting for its own window to allow the refresh.
  waiting,
}

/// The kind carried by [MediaAuthorizationRefreshResult].
MediaRetryOutcomeKind mediaRefreshFailureKind(
  MediaAuthorizationRefreshResult result,
) {
  if (result.waitingExecution) return MediaRetryOutcomeKind.waiting;
  if (result.requiresPage) return MediaRetryOutcomeKind.requiresPage;
  return MediaRetryOutcomeKind.unchanged;
}

/// Confirmation shown when a retry was accepted, single or batch.
const mediaRetryResumedMessage = '已开始续传';

/// Convenience: the command word for every outcome that cannot continue
/// without the source page.
bool mediaRetryOffersSourcePage(MediaRetryOutcomeKind kind) =>
    kind == MediaRetryOutcomeKind.unchanged ||
    kind == MediaRetryOutcomeKind.requiresPage;

/// Result of [AppController.retryMediaTaskResult] and of one member of
/// [AppController.retryMediaTasks].
class MediaRetryOutcome {
  const MediaRetryOutcome({
    required this.taskId,
    required this.kind,
    required this.message,
    this.task,
  });

  final String taskId;
  final MediaRetryOutcomeKind kind;

  /// Copy ready for the transient message, in the glossary's wording.
  final String message;

  /// The task after a successful resume; `null` for every other kind, which is
  /// also the guarantee that the task was left exactly as it was.
  final MediaTask? task;

  bool get resumed => kind == MediaRetryOutcomeKind.resumed;

  /// True when the message must carry the 打开来源页 action.
  bool get offersSourcePage => mediaRetryOffersSourcePage(kind);
}

/// Internal signal: the refresh answered, but without a usable address.
class _MediaRefreshFailure implements Exception {
  const _MediaRefreshFailure(this.result, {this.message, this.kind});

  /// The refresh answer, when there was one.
  final MediaAuthorizationRefreshResult? result;

  /// Overrides the wording derived from [result].
  final String? message;

  /// Overrides the kind derived from [result]. An adopted address that fails a
  /// gate is a page-required outcome, never "the authorization did not
  /// change": the refresh did succeed, the page simply has to hand the media
  /// over again.
  final MediaRetryOutcomeKind? kind;
}

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  /// [api] is the platform seam: production leaves it null (the generated Pigeon
  /// channel), tests pass a fake so tab lifecycle can be exercised without a
  /// device. Same seam [NativeHosts] already exposes.
  AppController(
    this.db, {
    AppBootstrapSnapshot? bootstrap,
    WebHostApi? api,
    HttpProbe? httpProbe,
    HomepageVerifier? homepageVerifier,
    BrowserSessionStore? sessionStore,
    DeviceDiagnosticsService? diagnostics,
    StartupTrace? startupTrace,
    Future<Directory> Function()? mediaDirectoryProvider,
    NativeMediaAuthRefresh? nativeMediaAuthRefresh,
    NativeDownloadRuntime? nativeDownloads,
    NativeTlsTransferWithPolicy? mediaPolicyTransfer,
    NativeSystemHttpTransport? systemHttpTransport,
    Uint8List? directRouteSecret,
  }) : startupTrace = startupTrace ?? StartupTrace() {
    _directRouteSecret = directRouteSecret;
    this.mediaPolicyTransfer = mediaPolicyTransfer;
    this.nativeMediaAuthRefresh =
        nativeMediaAuthRefresh ??
        (Platform.isAndroid ? NativeMediaAuthRefresh() : null);
    this.nativeDownloads =
        nativeDownloads ??
        (Platform.isAndroid ? NativeDownloadRuntime() : null);
    if (bootstrap != null) {
      settings = bootstrap.settings;
      background = bootstrap.background;
      glassQualityCache = bootstrap.glassQualityCache;
      effectiveGlassQuality = switch (settings.glassQualityMode) {
        SiteLensGlassQualityMode.high => GlassQuality.premium,
        SiteLensGlassQualityMode.standard => GlassQuality.standard,
        SiteLensGlassQualityMode.automatic =>
          glassQualityCache?.quality ?? GlassQuality.standard,
      };
    }
    deviceDiagnostics = diagnostics ?? DeviceDiagnosticsService();
    deviceDiagnostics.addListener(_diagnosticsChanged);
    unawaited(deviceDiagnostics.refreshHcpp());
    settingsRepository = SettingsRepository(db);
    backgroundAssets = BackgroundAssetStore();
    secureDnsResolver = SecureDnsResolver();
    final nativeSystemTransport =
        systemHttpTransport ??
        (Platform.isAndroid ? NativeSystemHttpTransport() : null);
    // 直连出口的适配器走同一条系统网络通道：媒体、脚本、探测与目录不应该
    // 各自解释一套代理/DNS/TLS。
    _nativeSystemTransport = nativeSystemTransport;
    final mediaNetwork = Platform.isAndroid ? MediaNetwork() : null;
    if (bootstrap != null) _applySettings();
    transientCache = TransientCacheService(runtime: AppRuntimeApi());
    errorLogger = AppErrorLogger(db);
    glassQualityCacheRepository = SiteLensGlassQualityCacheRepository(db);
    this.sessionStore = sessionStore ?? BrowserSessionStore(db);
    scripts = ScriptService(
      db,
      ControlledHttp(nativeTransport: nativeSystemTransport),
    );
    hosts = NativeHosts(
      db,
      scripts,
      ControlledHttp(nativeTransport: nativeSystemTransport),
      api: api,
      beforeCreate: _ensureBrowserPrepared,
    );
    filterSnapshots = FilterSnapshotStore();
    filterSources = FilterSourceManager(
      store: filterSnapshots,
      db: db,
      http: ControlledHttp(nativeTransport: nativeSystemTransport),
    );
    final mediaResourceCoordinator = MediaResourceCoordinator(
      rootProvider: () async {
        final root = await mediaTasks.cacheRootDirectory();
        final shared = Directory('${root.path}/shared_resources');
        await shared.create(recursive: true);
        return shared;
      },
    );
    mediaTasks = ExportNotifyingMediaTaskStore(
      db: db,
      directoryProvider: mediaDirectoryProvider,
      resourceCoordinator: mediaResourceCoordinator,
    );
    mediaOperations = MediaOperationRunner(db);
    unawaited(mediaOperations.markInterrupted().catchError((_) {}));
    watchSaves = WatchSaveStore(db);
    nativePlayback = NativePlaybackStore(db);
    nativeExports = Platform.isAndroid ? NativeExportRuntime() : null;
    if (nativeExports != null &&
        settings.mediaStorageMode == MediaStorageMode.directPath) {
      unawaited(
        nativeExports!.configureDirectRoot(settings.mp4ExportDirectory),
      );
    }
    nativeMedia = NativeMediaRuntime();
    // T4：原生回传「凭证失效」之后，应用续期一次并重推；续期失败落到用户可见的
    // 「需要重新登录」。推送走单向通道 `site_lens/credentials`。
    credentialHandoff = SiteCredentialHandoff(
      adapterRegistry: _liveAdapterRegistry,
      pusher: NativeCredentialPush(),
      credentialSink: StoreCredentialSink(siteCredentialStore),
      media: nativeMedia,
      // 续期成功之后把这一集重开一次：用户不需要手动重试。
      reopen: () => unawaited(reopenAfterCredentialRefresh()),
    );
    _credentialOutcomes = credentialHandoff!.recoveries.listen(
      _onCredentialRecovery,
    );
    credentialHandoff!.attach();
    _diagnosticPlaybackEvents = nativeMedia.states.listen((session) {
      if (session.state == NativePlaybackState.stopped ||
          session.state == NativePlaybackState.restorable) {
        deviceDiagnostics.clearObservation('media.playback.session');
        // 会话结束：这一段的重试预算可以回收了。
        _remoteFailures.forget(session.id);
        _handledRemoteFailures.removeWhere(
          (key) => key.startsWith('${session.id}|'),
        );
        return;
      }
      // 远程失败归因（T8）。只认远程错误码：本地会话的失败码不在这条线上，
      // 两套归因不共用错误码，也不会互相覆盖。同一段会话的同一份结论只处置一
      // 次——快照会反复下发，重试预算不能因此被反复扣。
      if (session.state == NativePlaybackState.failed) {
        final key = '${session.id}|${session.errorCode}';
        if (_handledRemoteFailures.add(key)) {
          observeRemoteFailure(session);
        }
        return;
      }
      // 这段会话重新开始播了：它的失败结论与去重标记都可以收掉。
      _handledRemoteFailures.removeWhere(
        (key) => key.startsWith('${session.id}|'),
      );
      deviceDiagnostics.recordObservation(
        id: 'media.playback.session',
        observed: session.state.name,
        source: 'NativeMediaRuntime.states',
        identity: session.id,
        failed: session.errorCode != null,
      );
    });
    mediaDownloads = MediaDownloadService(
      tasks: mediaTasks,
      native: nativeDownloads,
      // Media transfers are carried by [policyTransfer] (native Kotlin). This
      // client only handles authorization and metadata, so it must not open a
      // second native path that decides routing again.
      http: ControlledHttp(nativeTransport: nativeSystemTransport),
      authorize: _authorizeMediaDownload,
      refreshAuthorization: (task, candidate) async {
        try {
          return await mediaCandidateForRetry(task, resetRetryBudget: false);
        } catch (error, stack) {
          AppErrorLogger.capture(
            error,
            module: 'media.authorization-refresh',
            context: task.id,
            stack: stack,
          );
          rethrow;
        }
      },
      policyTransfer:
          mediaPolicyTransfer ?? mediaNetwork?.transferFileWithPolicy,
      resourceCoordinator: mediaResourceCoordinator,
    );
    unawaited(
      mediaDownloads.reconcileOrphanedSharedResources().catchError((
        error,
        stack,
      ) {
        AppErrorLogger.capture(
          error,
          module: 'media.resource-gc',
          context: 'startup',
          stack: stack,
        );
      }),
    );
    _mediaNetworkUnsubscribe = mediaNetwork?.onNetworkChanged(() {
      if (!_disposed) unawaited(mediaDownloads.recoverAfterNetworkChange());
    });
    _mediaRuntimeReady = true;
    mediaDownloads.maxConcurrency = settings.mediaDownloadConcurrency;
    final downloads = nativeDownloads;
    if (downloads != null) {
      mediaDownloads.onProgressNotification = (taskId, title, bytes, total) {
        unawaited(
          downloads.progressNotification(
            taskId,
            title,
            bytes,
            totalBytes: total,
          ),
        );
      };
      mediaDownloads.onTaskNotificationDone = (taskId) {
        unawaited(downloads.clearProgressNotification(taskId));
      };
      unawaited(
        downloads.setConcurrency(settings.mediaDownloadConcurrency).catchError((
          error,
          stack,
        ) {
          AppErrorLogger.capture(error, module: 'media.settings', stack: stack);
        }),
      );
    }
    mediaExports = Mp4ExportService(tasks: mediaTasks, native: nativeExports);
    mediaLibrary = MediaLibrary(
      db: db,
      tasks: mediaTasks,
      native: nativeExports,
    );
    mediaStorage = MediaStorageService(
      tasks: mediaTasks,
      library: mediaLibrary,
      native: nativeExports,
      configuredMode: () async => settings.mediaStorageMode,
      configuredRoot: () async => mp4ExportDirectory,
    );
    mediaLibrary.mutationGuard = mediaStorage.ensureWritable;
    mediaLibrary.addListener(notifyMediaChanged);
    mediaExportQueue = MediaExportQueue(
      tasks: mediaTasks,
      db: db,
      concurrencyProvider: () => mediaExportConcurrency,
      execute: _performQueuedMediaExport,
      onError: (taskId, error, stack) {
        AppErrorLogger.capture(
          error,
          module: 'media.export',
          context: 'queue:$taskId',
          stack: stack,
        );
      },
    );
    if (nativeExports != null) {
      unawaited(
        nativeExports!
            .setExportConcurrency(settings.mediaExportConcurrency)
            .catchError((error, stack) {
              AppErrorLogger.capture(
                error,
                module: 'media.settings',
                stack: stack,
              );
            }),
      );
    }
    mediaDownloads.onCompleted = _autoConvertCompletedMedia;
    castSessions = CastSessionController(tasks: mediaTasks);
    mediaCast = DlnaCastController(
      castSessions,
      onTemporaryTaskFinished: cleanupTemporaryCastTask,
      onSessionFinished: _releaseCastCopy,
    );
    mediaPlayback = NativePlaybackController();
    mediaCast.addListener(_observeCastForDiagnostics);
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
      httpProbe:
          httpProbe ??
          // Dart's HttpClient leaves socket ownership, DNS and proxy to the
          // system route already used by Chromium. The native probe transport
          // duplicated those decisions and reintroduced Clash Meta timeouts.
          HttpProbe(
            onFailure: (error, stack, context) => AppErrorLogger.capture(
              error,
              module: 'discovery.probe',
              context: context,
              stack: stack,
            ),
          ),
      verifier: homepageVerifier ?? NativeHomepageVerifier(hosts),
      save: db.saveProbe,
    )..addListener(notifyListeners);
  }
  final AppDatabase db;
  final StartupTrace startupTrace;
  late final BackgroundAssetStore backgroundAssets;
  late final SecureDnsResolver secureDnsResolver;
  late final TransientCacheService transientCache;
  late final DeviceDiagnosticsService deviceDiagnostics;
  StreamSubscription<NativePlaybackSession>? _diagnosticPlaybackEvents;

  void _diagnosticsChanged() {
    // Diagnostics must not run the media-policy reconciliation performed by
    // this controller's general notifyListeners override.
    if (!_disposed) super.notifyListeners();
  }

  void _recordSecureDnsObservation() {
    final resolution = secureDnsResolver.resolution;
    deviceDiagnostics.recordObservation(
      id: 'network.secure_dns',
      observed: '${resolution.status.name}:${resolution.source.name}',
      source: 'SecureDnsResolver',
      identity: resolution.provider.wireId,
      failed: resolution.status == SecureDnsResolutionStatus.failed,
    );
    if (!_disposed) super.notifyListeners();
  }

  void _observeCastForDiagnostics() {
    final session = mediaCast.active;
    if (session == null) return;
    deviceDiagnostics.recordObservation(
      id: 'network.cast.session',
      observed: session.state.name,
      source: 'DlnaCastController',
      identity: session.id,
      failed: session.errorCode != null,
    );
  }

  List<CapabilityRecord> get deviceDiagnosticRecords =>
      deviceDiagnostics.records(
        glassMode: settings.glassQualityMode.name,
        adaptiveQuality: effectiveGlassQuality.name,
        allSurfacesHighQuality: settings.highQualityAllSurfaces,
        webViewMounted: browserSurfaceActive,
        backgroundHealthCheck: settings.backgroundHealthCheck,
        allowNativeBackgroundPlayback: settings.allowNativeBackgroundPlayback,
        exportDirectory: settings.mp4ExportDirectory,
      );
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
  bool _nativeForeground = true;
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
    // Android reports the notification shade and transient focus changes as
    // inactive/hidden before a real pause. Keep the media policy foreground
    // during those short transitions so MediaSession actions are not revoked
    // while the user is interacting with the notification.
    _nativeForeground =
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
    _foreground =
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached;
    if (_foreground) unawaited(deviceDiagnostics.refreshHcpp());
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshProfileHealth());
    }
    if (state != AppLifecycleState.resumed) {
      unawaited(_observeActivePlayback());
      unawaited(watchSaves.flush());
    }
    unawaited(_syncNativeMediaLifecycle());
    unawaited(syncMediaPolicy());
  }

  Future<void> _syncNativeMediaLifecycle() async {
    if (_disposed || !Platform.isAndroid) return;
    try {
      await nativeMedia.setApplicationLifecycle(
        foreground: _nativeForeground,
        allowNativeBackgroundPlayback: allowNativeBackgroundPlayback,
      );
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.native.lifecycle',
        context: 'foreground=$_nativeForeground',
        stack: stack,
      );
    }
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
        if (e is PlatformException && e.code == 'host_destroyed') {
          final currentHost = hosts.sessions[h.id];
          if (h.disposed || currentHost == null || !identical(currentHost, h)) {
            continue;
          }
          // Native host destruction can race with this policy call before the
          // hostInvalidated event reaches Dart. Retire the stale session and
          // keep its tab metadata available for a later reload.
          final wasActive = identical(activeBrowser?.loadedHost, h);
          for (final tab in browserTabs.where(
            (t) => identical(t.loadedHost, h),
          )) {
            tab.invalidate('网页进程已退出，选择标签可重新加载');
          }
          await hosts.destroy(h);
          if (wasActive) mediaSupported = false;
          notifyListeners();
          continue;
        }
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
  BackgroundSnapshot background = const BackgroundSnapshot();
  SiteLensGlassQualityCache? glassQualityCache;
  GlassQuality effectiveGlassQuality = GlassQuality.standard;
  late final ScriptService scripts;
  late final ProfilePacks packs;
  late final NativeHosts hosts;
  late final FilterSnapshotStore filterSnapshots;
  late final FilterSourceManager filterSources;
  late final ExportNotifyingMediaTaskStore mediaTasks;
  late final WatchSaveStore watchSaves;
  late final NativePlaybackStore nativePlayback;
  late final MediaDownloadService mediaDownloads;
  void Function()? _mediaNetworkUnsubscribe;
  var _mediaRuntimeReady = false;
  late final Mp4ExportService mediaExports;
  late final MediaExportQueue mediaExportQueue;
  late final MediaLibrary mediaLibrary;
  late final MediaStorageService mediaStorage;
  late final MediaOperationRunner mediaOperations;
  final _exportingMedia = <String, Future<MediaArtifact>>{};
  final _mediaExportProgress = <String, int>{};
  final _mediaExportProgressChanged = ChangeNotifier();
  late final CastSessionController castSessions;
  late final DlnaCastController mediaCast;
  late final NativePlaybackController mediaPlayback;
  late final NativeMediaRuntime nativeMedia;

  /// 应用侧持有的站点凭证（ADR-0007 的生产端）；推送与续期都只写这一份。
  final SiteCredentialStore siteCredentialStore = SiteCredentialStore();

  /// T4 的失效处置链：原生回传失效 → 续期一次 → 重推 → 原生重试一次。
  SiteCredentialHandoff? credentialHandoff;

  StreamSubscription<CredentialRecovery>? _credentialOutcomes;

  /// 最近一次续期后的站点档案。「需要重新登录」的提示就是给它的。
  int? _activeCredentialProfileId;
  String? _credentialPromptText;

  /// 用户看得到的那句话；为 null 表示没有待处理提示。
  String? get credentialPromptText => _credentialPromptText;

  /// 这条提示属于哪个档案；没有提示时为 null。
  int? get credentialNeedsLoginProfileId =>
      _credentialPromptText == null ? null : _activeCredentialProfileId;

  /// 这次播放属于哪个站点档案；失效处置按它定位适配器。
  void rememberCredentialProfile(int profileId) {
    _activeCredentialProfileId = profileId;
  }

  /// 直接播放一个站点候选（远程地址）。档案 id 随打开请求一起交给原生，由它
  /// 按站点凭证注入请求头；没有凭证时公开内容照播（ADR-0009）。
  Future<NativePlaybackSession> openRemoteCandidate(
    MediaCandidate candidate, {
    required int hostId,
    required int generation,
    required Uri sourceUrl,
    int? profileId,
  }) async {
    final target = profileId ?? _activeCredentialProfileId;
    if (target != null) rememberCredentialProfile(target);
    // 记住这一次打开用的四样东西：凭证续期后要原样再开一次本集。
    _lastRemoteOpen = (
      candidate: candidate,
      hostId: hostId,
      generation: generation,
      sourceUrl: sourceUrl,
      profileId: target,
    );
    return nativeMedia.open(
      candidate,
      hostId: hostId,
      generation: generation,
      sourceUrl: sourceUrl,
      profileId: target,
    );
  }

  /// 从剧集详情点选集进入远程播放（T11）。
  ///
  /// 详情页只交出它手上的那份**媒体候选**和一个选中线路的 id；应用侧在这里把
  /// 播放需要的四样东西补齐：原生宿主（站点档案对应的 host 与代次）、来源页、
  /// 以及「下一集从哪来」的目录来源。播放页本身不认识适配器，也不认识凭证。
  ///
  /// 不建任务、不写追剧记录：远程播放可以不建任务（ADR-0005），追剧位置是
  /// T12 的事。
  Future<RemotePlayerLaunch> openRemoteEpisode(
    MediaCandidate candidate, {
    required SiteAdapter adapter,
    required String seriesKey,
    String? lineId,
    int? profileId,
    int continueWatchingMs = 0,
    String? episodeTitle,
  }) async {
    final target = profileId ?? adapter.profileId;
    // 打开走的就是既有的那个入口：凭证注入、缓存、凭证租约、失败归因都在它
    // 里面，这里不重复任何一步。
    await openRemoteCandidate(
      candidate,
      hostId: candidate.hostId,
      generation: candidate.generation,
      sourceUrl: candidate.sourceUrl,
      profileId: target,
    );
    rememberCredentialProfile(target);
    final source = AdapterEpisodeSource(
      adapter: adapter,
      seriesKey: seriesKey,
      preferredLineId: lineId,
      preferredQuality: candidate.qualityLabel,
      preferredAudio: candidate.audioLabel,
    );
    return RemotePlayerLaunch(
      candidate: candidate,
      title: _seriesTitleOf(candidate),
      episodeNumber: episodeTitle ?? _episodeLabelOf(candidate),
      source: source,
      lineId: lineId,
      continueWatchingMs: continueWatchingMs,
      profileId: target,
    );
  }

  /// 播放页标题上的剧名：页面自己声明的剧名优先，其次是候选标题。
  static String _seriesTitleOf(MediaCandidate candidate) {
    final series = candidate.seriesTitle?.trim();
    if (series != null && series.isNotEmpty) return series;
    final title = candidate.title.trim();
    return title.isEmpty ? '当前选集' : title;
  }

  static String _episodeLabelOf(MediaCandidate candidate) {
    final number = candidate.episodeNumber;
    return number == null ? '当前选集' : '第 $number 集';
  }

  /// 最近一次远程播放的请求参数。自动重开用它把**同一集**再打开一次。
  ({
    MediaCandidate candidate,
    int hostId,
    int generation,
    Uri sourceUrl,
    int? profileId,
  })?
  _lastRemoteOpen;

  /// 用户最后看到的远程失败结论（T8）。它不是媒体任务状态：远程播放可以不建
  /// 任务，结局只能挂在这里。null 表示没有待处理的远程失败。
  RemoteFailureNotice? _remoteFailureNotice;

  /// 四类远程失败的重试预算。按「会话 + 种类」记，会话结束由链自己回收。
  final RemoteFailureRetryChain _remoteFailures = RemoteFailureRetryChain();

  /// 已经处置过的远程失败（会话 + 错误码）。同一份快照反复下发时不再重复处置。
  final _handledRemoteFailures = <String>{};

  /// 最近四类远程失败各自怎么判定、要不要重开、给用户看什么。
  RemoteFailureNotice? get remoteFailureNotice => _remoteFailureNotice;

  /// 远程失败的重试策略；次数与间隔可配，同一段会话每一类最多一次。
  RemoteRetryPolicy get remoteRetryPolicy => _remoteFailures.policy;

  set remoteRetryPolicy(RemoteRetryPolicy next) =>
      _remoteFailures.policy = next;

  /// 从原生会话快照里认一次远程失败并处置；不是远程失败就返回 null。
  ///
  /// 这是界面与桥接层唯一需要的入口：判定在 [RemotePlaybackFailure.classify]
  /// 里，重试预算在 [_remoteFailures] 里，两者都不读媒体任务。
  /// [retry] 让调用方换掉默认的重开动作（播放页用它重开**播放页正在放的那
  /// 一集**，而不是 `_lastRemoteOpen` 记住的那一份）。传了就由它决定是否重开。
  RemoteFailurePlan? observeRemoteFailure(
    NativePlaybackSession session, {
    void Function()? retry,
  }) {
    final failure = RemotePlaybackFailure.classify(session);
    if (failure == null) return null;
    return reportRemoteFailure(failure, retry: retry);
  }

  /// 主动处置一次远程失败。原生把失败写进会话快照之后，由界面或桥接层调用。
  ///
  /// 四类结局各走各的路：凭证失效续期后重开、清单失效重取清单再开一次、分片
  /// 失败建议下载、网络失败沿用既有文案。分片与网络不重开整集，凭证与清单也
  /// 各自只重开一次；耗尽之后只给建议，不静默重试。
  RemoteFailurePlan reportRemoteFailure(
    RemotePlaybackFailure failure, {
    void Function()? retry,
  }) {
    retry ??= switch (failure.kind) {
      RemoteFailureKind.credentialRejected => () {
        unawaited(reopenAfterCredentialRefresh());
      },
      RemoteFailureKind.manifestUnavailable => () {
        unawaited(reopenAfterManifestRefresh());
      },
      // 分片失败与网络失败不重开整集：它们连重试动作都不该有。
      RemoteFailureKind.segmentFailed || RemoteFailureKind.network => null,
    };
    final plan = _remoteFailures.plan(failure: failure, retry: retry);
    _remoteFailureNotice = RemoteFailureNotice(plan: plan);
    notifyListeners();
    if (plan.retries) {
      final action = plan.retry!;
      final delay = plan.delay;
      if (delay == Duration.zero) {
        action();
      } else {
        unawaited(
          Future<void>.delayed(delay).then((_) {
            if (_remoteFailureNotice?.plan.failure.sessionId !=
                failure.sessionId) {
              // 这段会话已经有了新的结论：过期的重试不再执行。
              return;
            }
            action();
          }),
        );
      }
    }
    return plan;
  }

  /// 分片失败之后「下载该集」（T8）。
  ///
  /// 建议本身是这一类的动作：远程流取不到的片段，下载任务手里那份清单通常还能
  /// 取到，取不到也只是任务自己的失败。这里只把「该下载哪一集」交出去——
  /// 建任务是下载自己的动作，不让远程失败去写任务状态。
  Future<MediaCandidate?> downloadEpisodeAfterSegmentFailure() async {
    final last = _lastRemoteOpen;
    if (last == null) return null;
    dismissRemoteFailure();
    return last.candidate;
  }

  /// 用户点掉远程失败的提示。
  void dismissRemoteFailure() {
    if (_remoteFailureNotice == null) return;
    _remoteFailureNotice = null;
    notifyListeners();
  }

  /// 清单失效之后的那一次重开：重取清单再开同一集。
  ///
  /// 直连出口没有来源页（GLOSSARY: 来源页），能重取的是适配器给出的候选；因此
  /// 这里与凭证续期共用同一个重开动作，区别只在预算与文案——两者各记各的。
  Future<void> reopenAfterManifestRefresh() async {
    final last = _lastRemoteOpen;
    if (last == null) return;
    try {
      await openRemoteCandidate(
        last.candidate,
        hostId: last.hostId,
        generation: last.generation,
        sourceUrl: last.sourceUrl,
        profileId: last.profileId,
      );
    } on Object catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.remote_failure',
        context: 'retry=manifest',
        stack: stack,
      );
    }
  }

  /// 凭证续期成功后重开本集（T6）。没有可重开的远程播放就什么都不做。
  ///
  /// 重开就是一次普通的 [openRemoteCandidate]：原生按当前凭证重新取头，用户看
  /// 到的是一次短暂停顿，不是错误页。失败不转成新提示——下一次失效事件会按它
  /// 自己的预算判定。
  Future<void> reopenAfterCredentialRefresh() async {
    final last = _lastRemoteOpen;
    if (last == null) return;
    try {
      await openRemoteCandidate(
        last.candidate,
        hostId: last.hostId,
        generation: last.generation,
        sourceUrl: last.sourceUrl,
        profileId: last.profileId,
      );
    } on Object catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.credential',
        context: 'reopen=1',
        stack: stack,
      );
    }
  }

  /// 用户点掉提示。
  void dismissCredentialPrompt() {
    if (_credentialPromptText == null) return;
    _credentialPromptText = null;
    _activeCredentialProfileId = null;
    notifyListeners();
  }

  void _onCredentialRecovery(CredentialRecovery outcome) {
    // 成功与失败是两种结局，绝不合并成同一句文案（ADR-0007 Consequences）。
    switch (outcome) {
      case CredentialRecovered():
        _credentialPromptText = null;
      case CredentialNeedsLogin():
        _credentialPromptText = '登录已失效，请重新登录后继续播放';
    }
    notifyListeners();
  }

  /// 把所有能续期的适配器组成一个注册表，供失效处置解析档案。
  SiteAdapterRegistry get _liveAdapterRegistry =>
      SiteAdapterRegistry(_theaterAdapters.values);

  /// Android authorization-refresh bridge. Injectable so the adoption path can
  /// be exercised without a device; production keeps the real bridge.
  late final NativeMediaAuthRefresh? nativeMediaAuthRefresh;

  /// Media addresses this controller adopted from a completed authorization
  /// refresh, per task. Only these may authorize a transfer after the source
  /// tab has closed.
  ///
  /// Bounded by construction: [adoptRefreshedMediaUrl] keeps a single address
  /// per task (the latest adoption is the only one a retry can use), and
  /// entries are dropped as soon as the task stops being retryable or is no
  /// longer in the task list, so a long session cannot accumulate addresses.
  final _adoptedMediaUrls = <String, String>{};
  late final NativeDownloadRuntime? nativeDownloads;

  /// Test seam for the native transfer; production gets it from the media
  /// network runtime below.
  NativeTlsTransferWithPolicy? mediaPolicyTransfer;
  late final NativeExportRuntime? nativeExports;
  late final ProbeCoordinator probes;
  List<Candidate> sites = [];
  List<PublishingSource> sources = [];
  List<SiteProfile> profiles = [];

  /// The adapter that serves one profile's 直连出口, or null when that profile
  /// has none. [installTheaterAdapter] is the test seam; production composes a
  /// real one from the addresses the profile publishes.
  final Map<int, SiteAdapter> _theaterAdapters = {};

  /// Which 线路 the user picked for an 选集, for the app's lifetime.
  ///
  /// Scoped to adapter + series + episode inside the store; it survives
  /// leaving the detail page, while playing, and switching candidates. It is
  /// deliberately not persisted: durable 追剧记录 is a different concern.
  final SeriesLineMemory seriesLineMemory = SeriesLineMemory();

  /// Composes (once per profile) the adapter 剧场 reads its catalog from.
  void installTheaterAdapter(int profileId, SiteAdapter adapter) {
    _theaterAdapters[profileId] = adapter;
  }

  SiteAdapter? theaterAdapterFor(int profileId) {
    final known = _theaterAdapters[profileId];
    if (known != null) return known;
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null) return null;
    final routes = profile.routes.isEmpty ? {SiteRoute.browse} : profile.routes;
    if (!routes.contains(SiteRoute.direct)) return null;
    final addresses = _theaterAddressesFor(profile);
    if (addresses.isEmpty) return null;
    // 首屏由真适配器供数：只有认不出站点时才没有剧场（而不是拿假目录显示
    // 空态）。建立适配器要读一次已存凭证，所以它是异步的；读完之后由
    // [load] 收尾重建，在那之前 [theaterAdapterFor] 返回 null，界面显示的是
    // 「还在准备」而不是「没有内容」。
    final ready = _directRouteAdapters[profileId];
    if (ready != null) return ready;
    unawaited(_composeDirectRouteAdapter(profile, addresses));
    return null;
  }

  /// 直连出口的适配器，按档案缓存。与 [_theaterAdapters] 分开，是因为后者是
  /// 测试与界面注入的入口（[installTheaterAdapter]），而这里的实例由应用自
  /// 己按已存凭证组装。
  final Map<int, SiteAdapter> _directRouteAdapters = {};

  /// The system-network transport the 直连出口 shares with scripts, hosts and
  /// filter sources. Null off Android, where dart:io's stack is the system's.
  NativeSystemHttpTransport? _nativeSystemTransport;

  /// A published key already in hand. Production leaves this null so the
  /// adapter fetches its own; a test fixture hands one in instead of letting a
  /// fake interface answer with content the app cannot read.
  Uint8List? _directRouteSecret;
  final Set<int> _directRouteComposing = {};

  Future<void> _composeDirectRouteAdapter(
    SiteProfile profile,
    List<Uri> addresses,
  ) async {
    final profileId = profile.id;
    if (_directRouteComposing.contains(profileId)) return;
    _directRouteComposing.add(profileId);
    try {
      final composed = await createDirectRouteAdapter(
        profileId: profileId,
        addresses: addresses,
        http: ControlledHttp(nativeTransport: _nativeSystemTransport),
        credentials: siteCredentialStore,
        remoteSecret: _directRouteSecret,
      );
      if (composed == null || _directRouteAdapters.containsKey(profileId)) {
        return;
      }
      _directRouteAdapters[profileId] = composed.adapter;
      notifyListeners();
    } catch (error) {
      // 认不出站点或凭证读不出来：这个档案就没有直连出口。界面按「这个站点
      // 还没有直连入口」处理，不把插件错误抛给用户。
      unawaited(errorLogger.record(error, module: 'theater.adapter'));
    } finally {
      _directRouteComposing.remove(profileId);
    }
  }

  List<Uri> _theaterAddressesFor(SiteProfile profile) {
    final owned = <Uri>{};
    final landing = profile.lastLanding;
    if (landing != null) owned.add(landing);
    for (final site in sites) {
      if (site.profileId == profile.id) owned.add(site.url);
    }
    return List.unmodifiable(owned);
  }

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
  bool allowNativeBackgroundPlayback = false;
  bool allowStreamingWhileDownloading = true;
  bool autoSaveWebPlayback = false;
  bool autoConvertToMp4 = false;
  bool deleteMediaTaskAfterMp4Export = false;
  MediaStorageMode mediaStorageMode = MediaStorageMode.appPrivate;
  String? mp4ExportDirectory;
  bool mediaLibraryAutoRefresh = true;
  int mediaDownloadConcurrency = AppPolicy.defaultMediaDownloadConcurrency;
  int mediaExportConcurrency = AppPolicy.defaultMediaExportConcurrency;
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

  Future<void>? _initialization;
  Future<void>? _browserPreparation;
  Future<void>? _deferredStartup;
  Future<void>? _nativePlaybackRestore;
  bool _profilesKnown = false;
  bool _browserPreparationFailed = false;
  bool mediaReady = false;
  String? mediaStartupError;

  Future<void> initialize() => _initialization ??= _initialize();

  /// Lifecycle/backup callers wait for all accepted startup work before close.
  Future<void> get startupSettled async {
    await _initialization;
    await _deferredStartup;
    await _waitForBrowserPreparation();
  }

  Future<void> _waitForBrowserPreparation() async {
    try {
      await _browserPreparation;
    } catch (_) {
      // Settings and repair actions remain available after a failed startup.
    }
  }

  Future<void> _ensureBrowserPrepared() async {
    if (_disposed || restoringData) throw const Cancelled();
    if (_browserPreparationFailed) {
      _browserPreparationFailed = false;
      final retry = _prepareBrowserRuntime(suppressCorruption: true);
      _browserPreparation = retry;
      unawaited(
        retry.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            _browserPreparationFailed = true;
          },
        ),
      );
    }
    await _browserPreparation;
    if (_disposed || restoringData) throw const Cancelled();
  }

  Future<void> _initialize() async {
    WidgetsBinding.instance.addObserver(this);
    mediaTasks.requireRestore();
    final navigation = Completer<void>();
    _browserPreparation = navigation.future;
    // Keep failures observable by navigation without an unhandled background
    // error when the user never opens a web page.
    unawaited(
      navigation.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    try {
      // Only local presentation metadata belongs on the first-screen path.
      await _loadMetadata(suppressCorruption: true, prepareRuntime: false);
      if (_disposed) throw const Cancelled();
      await startupTrace.measure(
        StartupPhase.savedTabsRestore,
        restoreSavedSessions,
      );
      startupTrace.markOnce(
        StartupPhase.savedTabsReady,
        itemCount: browserTabs.length,
      );
      if (_disposed) throw const Cancelled();
      startupTrace.markOnce(StartupPhase.controllerReady);
      // Queue independent maintenance after publishing ready home/tab metadata.
      final browser = Future<void>.microtask(() async {
        try {
          if (_disposed) throw const Cancelled();
          await _prepareBrowserRuntime(suppressCorruption: true);
          navigation.complete();
        } catch (error, stack) {
          _browserPreparationFailed = true;
          navigation.completeError(error, stack);
          if (!_disposed) {
            AppErrorLogger.capture(
              error,
              module: 'startup.browser',
              stack: stack,
            );
          }
        }
      });
      final media = Future<void>.microtask(() async {
        try {
          if (_disposed) return;
          await startupTrace.measure(
            StartupPhase.mediaTasksRestore,
            () => mediaTasks.ready,
          );
          if (_disposed) return;
          await watchSaves.restore();
          if (_disposed) return;
          startupTrace.markOnce(
            StartupPhase.mediaTasksReady,
            itemCount: mediaTasks.tasks.length,
          );
          await startupTrace.measure(
            StartupPhase.mediaLibraryRestore,
            mediaLibrary.restore,
          );
          if (_disposed) return;
          await mediaExportQueue.restore();
          if (_disposed) return;
          await mediaStorage.reconcileMigrationJournal();
          if (_disposed) return;
          await _restoreNativePlaybackIfAvailable();
          if (_disposed) return;
          startupTrace.markOnce(
            StartupPhase.mediaLibraryReady,
            itemCount: mediaLibrary.items.length,
          );
          try {
            await startupTrace.measure(
              StartupPhase.nativeDownloadReconcile,
              mediaDownloads.reconcileNative,
            );
          } catch (error) {
            AppErrorLogger.capture(error, module: 'media.reconcile');
          }
          mediaReady = true;
        } catch (error, stack) {
          mediaStartupError = friendlyError(error);
          AppErrorLogger.capture(error, module: 'startup.media', stack: stack);
        }
        if (!_disposed) notifyListeners();
      });
      final maintenance =
          Future<void>.microtask(() async {
            if (_disposed) return;
            await startupTrace.measure(
              StartupPhase.pendingLogRecovery,
              errorLogger.recoverPending,
            );
            if (_disposed) return;
            await startupTrace.measure(
              StartupPhase.nativeLogRecovery,
              errorLogger.recoverNativeReports,
            );
            if (_disposed) return;
            await startupTrace.measure(
              StartupPhase.backgroundNotice,
              drainBackgroundNotice,
            );
            if (_disposed) return;
            unawaited(_applyBackgroundHealthSchedule());
            try {
              var previous = (await startupTrace.measure(
                StartupPhase.connectivitySetup,
                Connectivity().checkConnectivity,
              )).map((e) => e.name).join(',');
              if (_disposed) return;
              _network = Connectivity().onConnectivityChanged.listen((state) {
                final current = state.map((e) => e.name).join(',');
                if (current != previous) {
                  previous = current;
                  unawaited(secureDnsResolver.clearCache().catchError((_) {}));
                  cancel('网络发生变化，请重新检测；旧结果不参与推荐');
                }
              });
            } catch (_) {
              // Advisory network state never gates the product screen.
            }
          }).catchError((Object error, StackTrace stack) {
            if (!_disposed) {
              AppErrorLogger.capture(
                error,
                module: 'startup.maintenance',
                stack: stack,
              );
            }
          });
      _deferredStartup = Future.wait<void>([browser, media, maintenance])
          .then<void>((_) {});
    } catch (error, stack) {
      navigation.completeError(error, stack);
      rethrow;
    }
  }

  /// Wait only where media is actually used; home and tab metadata never do.
  Future<void> get mediaRestored async {
    await mediaTasks.ready;
    await mediaLibrary.restore();
    await watchSaves.restore();
    await _restoreNativePlaybackIfAvailable();
  }

  Future<void> _restoreNativePlaybackIfAvailable() =>
      _nativePlaybackRestore ??= _restoreNativePlayback();

  Future<void> _restoreNativePlayback() async {
    if (!Platform.isAndroid || _disposed) return;
    try {
      final saved = await nativeMedia.state();
      if (saved.state != NativePlaybackState.restorable ||
          saved.taskId.isEmpty) {
        if (saved.state == NativePlaybackState.restorable) {
          await nativeMedia.discardRestorable();
        }
        return;
      }
      final task = mediaTasks.task(saved.taskId);
      if (task == null) {
        await nativeMedia.discardRestorable();
        return;
      }
      final file = await mediaPlaybackFile(task, preferExported: false);
      if (file == null || _disposed) {
        if (!_disposed) await nativeMedia.discardRestorable();
        return;
      }
      await nativeMedia.restoreLocal(task, file, play: false);
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.playback.restore',
        stack: stack,
      );
    }
  }

  String get glassQualityFingerprint =>
      SiteLensGlassFingerprint.current(appVersion: _packageVersion);

  final String _packageVersion = const String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: 'dev',
  );

  GlassAdaptiveScopeConfig get glassAdaptiveConfig {
    final mode = settings.glassQualityMode;
    final androidWebViewSurface =
        Platform.isAndroid &&
        browserSurfaceActive &&
        !deviceDiagnostics.effectiveHcpp;
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
    await _refreshBackgroundSnapshot();
    if (patch.containsKey('glassQualityMode')) {
      await _clearGlassQualityCache();
      effectiveGlassQuality =
          settings.glassQualityMode == SiteLensGlassQualityMode.high
          ? GlassQuality.premium
          : GlassQuality.standard;
    }
    if (!settings.restoreBrowserSessions) await sessionStore.clear();
    _applySettings();
    if (patch.containsKey('allowNativeBackgroundPlayback') ||
        patch.containsKey('allowBackgroundPlayback')) {
      await _syncNativeMediaLifecycle();
    }
    if (nativeExports != null &&
        (patch.containsKey('mediaStorageMode') ||
            patch.containsKey('mp4ExportDirectory'))) {
      await nativeExports!.configureDirectRoot(
        mediaStorageMode == MediaStorageMode.directPath
            ? mp4ExportDirectory
            : null,
      );
    }
    mediaStorage.invalidate();
    await hosts.applyPreferences(hostPreferences);
    await syncMediaPolicy();
    notifyListeners();
  }

  Future<void> updateFilterPolicy(FilterPolicy next, {int? profileId}) async {
    await _waitForBrowserPreparation();
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
    await _waitForBrowserPreparation();
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
          enabled: source.enabled,
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
    await _waitForBrowserPreparation();
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
    await _waitForBrowserPreparation();
    final bundle = await filterSources.delete(id);
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
    await _waitForBrowserPreparation();
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
    await _waitForBrowserPreparation();
    final source = filterSourceList.firstWhere(
      (item) => item.id == id,
      orElse: () => throw StateError('规则源不存在'),
    );
    return refreshFilterSource(source);
  }

  Future<void> setFilterSourceEnabled(int id, bool enabled) async {
    await _waitForBrowserPreparation();
    final bundle = await filterSources.setEnabled(id, enabled);
    hosts.setFilterEngine(
      filterSnapshots.activeEngine,
      policy: filterPolicy,
      snapshot: bundle ?? filterSnapshots.activeSnapshot,
      profilePolicies: profileFilterPolicies,
    );
    filterSourceList = await db.filterSources();
    notifyListeners();
  }

  void _applySettings() {
    themeModePreference = settings.themeMode;
    themePreset = settings.themePreset;
    secureDnsResolver.setProvider(settings.secureDnsProvider);
    secureDnsResolver.syncNativeProvider();
    restoreBrowserSessions = settings.restoreBrowserSessions;
    allowNativeBackgroundPlayback = settings.allowNativeBackgroundPlayback;
    allowStreamingWhileDownloading = settings.allowStreamingWhileDownloading;
    autoSaveWebPlayback = settings.autoSaveWebPlayback;
    autoConvertToMp4 = settings.autoConvertToMp4;
    deleteMediaTaskAfterMp4Export = settings.deleteMediaTaskAfterMp4Export;
    mediaStorageMode = settings.mediaStorageMode;
    mp4ExportDirectory = settings.mp4ExportDirectory;
    mediaLibraryAutoRefresh = settings.mediaLibraryAutoRefresh;
    mediaDownloadConcurrency = settings.mediaDownloadConcurrency;
    mediaExportConcurrency = settings.mediaExportConcurrency;
    if (_mediaRuntimeReady) {
      mediaDownloads.maxConcurrency = mediaDownloadConcurrency;
      if (nativeExports != null) {
        unawaited(
          nativeExports!
              .setExportConcurrency(mediaExportConcurrency)
              .catchError((error, stack) {
                AppErrorLogger.capture(
                  error,
                  module: 'media.settings',
                  stack: stack,
                );
              }),
        );
      }
    }
    playerVerticalGesture = settings.playerVerticalGesture;
    scriptsDisabled = settings.scriptsDisabled;
    pullToRefresh = settings.pullToRefresh;
    backgroundHealthCheck = settings.backgroundHealthCheck;
    browserControlsFraction = Offset(settings.controlsX, settings.controlsY);
  }

  Future<void> _refreshBackgroundSnapshot() async {
    final file = await backgroundAssets.fileFor(settings.backgroundAssetId);
    background = BackgroundSnapshot(
      mode: settings.backgroundMode,
      imagePath: file?.path,
      assetMissing: settings.backgroundAssetId != null && file == null,
    );
  }

  Future<void> setBackgroundMode(BackgroundMode value) async {
    if (value == BackgroundMode.customImage &&
        settings.backgroundAssetId == null) {
      throw StateError('请先上传背景图片');
    }
    await updateSettings({'backgroundMode': value.wireId});
  }

  Future<void> setBackgroundAsset(String assetId) async {
    final previous = settings.backgroundAssetId;
    try {
      await updateSettings({
        'backgroundMode': BackgroundMode.customImage.wireId,
        'backgroundAssetId': assetId,
      });
    } catch (_) {
      if (assetId != previous) await backgroundAssets.delete(assetId);
      rethrow;
    }
    if (previous != null && previous != assetId) {
      await backgroundAssets.delete(previous);
    }
    await backgroundAssets.cleanupUnused([assetId]);
  }

  Future<void> setSecureDnsProvider(SecureDnsProvider value) =>
      updateSettings({'secureDnsProvider': value.wireId});

  Future<SecureDnsResolution> verifySecureDns() async {
    try {
      await secureDnsResolver.resolve('example.com');
    } catch (_) {
      // The resolver exposes the failure through its observable status.
    }
    _recordSecureDnsObservation();
    return secureDnsResolver.resolution;
  }

  Future<void> clearBackgroundAsset() async {
    final old = settings.backgroundAssetId;
    await updateSettings({
      'backgroundMode': BackgroundMode.defaultGradient.wireId,
      'backgroundAssetId': null,
    });
    await backgroundAssets.delete(old);
    await backgroundAssets.cleanupUnused(const []);
  }

  Future<CacheInventory> transientCacheInventory() => transientCache.inspect();

  Future<CacheClearReport> clearTransientCache() async {
    final report = await transientCache.clear();
    await _clearGlassQualityCache();
    notifyListeners();
    return report;
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

  Future<void> setAllowNativeBackgroundPlayback(bool value) =>
      updateSettings({'allowNativeBackgroundPlayback': value});

  Future<void> setAllowStreamingWhileDownloading(bool value) =>
      updateSettings({'allowStreamingWhileDownloading': value});

  Future<void> setAutoSaveWebPlayback(bool value) async {
    await updateSettings({'autoSaveWebPlayback': value});
    if (value) unawaited(_observeActivePlayback());
  }

  Future<void> setAutoConvertToMp4(bool value) =>
      updateSettings({'autoConvertToMp4': value});

  Future<void> setDeleteMediaTaskAfterMp4Export(bool value) =>
      updateSettings({'deleteMediaTaskAfterMp4Export': value});

  Future<void> setMp4ExportDirectory(String? value) =>
      updateSettings({'mp4ExportDirectory': value});

  Future<void> setMediaStorageMode(MediaStorageMode value) =>
      updateSettings({'mediaStorageMode': value.wireId});

  Future<void> setMediaLibraryAutoRefresh(bool value) =>
      updateSettings({'mediaLibraryAutoRefresh': value});

  Future<void> setMediaDownloadConcurrency(int value) async {
    await updateSettings({'mediaDownloadConcurrency': value});
    final downloads = nativeDownloads;
    if (downloads != null) {
      await downloads.setConcurrency(mediaDownloadConcurrency);
    }
  }

  /// Bytes held by the remote playback cache, or `null` when this platform
  /// has no native cache. Reading it never touches a download.
  Future<PlaybackCacheUsage?> playbackCacheUsage() async {
    final downloads = nativeDownloads;
    if (downloads == null) return null;
    return _readPlaybackCache(downloads.playbackCacheUsage);
  }

  /// Clears the remote playback cache and returns what was removed.
  ///
  /// Only the cache directory is touched: completed downloads own another
  /// directory, keep their files, and keep their task rows. Returns `null`
  /// when this platform has no native cache to clear.
  Future<PlaybackCacheClearResult?> clearPlaybackCache() async {
    final downloads = nativeDownloads;
    if (downloads == null) return null;
    final result = await _readPlaybackCache(downloads.clearPlaybackCache);
    if (result == null) return null;
    // The tasks themselves did not change; only what a replay could reuse.
    notifyListeners();
    return result;
  }

  /// A native call that a desktop or test host may not implement. A missing
  /// channel means "this platform has no cache", not a playback failure.
  Future<T?> _readPlaybackCache<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> setMediaExportConcurrency(int value) async {
    await updateSettings({'mediaExportConcurrency': value});
    if (nativeExports != null) {
      await nativeExports!.setExportConcurrency(mediaExportConcurrency);
    }
    mediaExportQueue.wake();
  }

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
  Future<MediaCandidate> mediaCandidateForRetry(
    MediaTask task, {
    bool resetRetryBudget = true,
  }) async {
    if (resetRetryBudget) mediaDownloads.resetRetryBudget(task.id);
    final session = hosts.sessions[task.hostId];
    final stored = await db.mediaCandidate(task.candidateId);
    if (session != null && !session.disposed && stored != null) {
      for (final candidate in hosts.mediaCandidatesForHost(task.hostId)) {
        if (candidate.id != task.candidateId) continue;
        if (!mediaCandidatesEquivalent(stored, candidate)) {
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
      throw StateError('当前页面尚未重新授权媒体，请保持来源页并重试');
    }
    if (task.state == MediaTaskState.reauthorize) {
      throw StateError('下载地址已失效或被拒绝，请返回来源页刷新并重新选择媒体后下载');
    }
    if (stored == null) {
      throw StateError('媒体候选已不存在，请返回来源页重新选择媒体');
    }
    return stored;
  }

  /// Returns the current document-scoped playback observation without creating
  /// or reloading a browser host. Watch-save creation must still recheck the
  /// tab, generation and candidate identity immediately before committing.
  PlaybackEvidence? playbackEvidenceFor(ActiveBrowserSession tab) =>
      tab.loadedHost?.playbackEvidence;

  MediaCandidate _authorizeMediaDownload(
    MediaTask task,
    MediaCandidate candidate,
  ) {
    final requiresLiveAuthorization = _mediaTaskNeedsAuthorizationRefresh(task);
    if (!requiresLiveAuthorization) return candidate;
    final session = hosts.sessions[task.hostId];
    if (session == null || session.disposed) {
      // A background authorization refresh already re-authorized the stored
      // observation against the page itself, so the missing tab is no longer a
      // reason to block. Anything else keeps the old page-required failure.
      return _authorizedWithoutLiveSession(task, candidate);
    }
    if (session.generation != task.generation) {
      throw StateError('页面已更新，请返回来源页重新选择媒体');
    }
    final current = hosts.authorizeMediaCandidate(task.hostId, candidate.id);
    if (current.generation != task.generation ||
        mediaDocumentIdentity(current.sourceUrl) !=
            mediaDocumentIdentity(task.sourceUrl)) {
      throw StateError('媒体资源已变化，请返回来源页重新选择媒体');
    }
    return current;
  }

  /// Keeps [_adoptedMediaUrls] to tasks a retry can still use.
  ///
  /// The map holds one address per task, so it grows with the number of
  /// adopted tasks, not with the number of retries. An entry is dropped as soon
  /// as the task left the retryable states (a finished or playing task never
  /// asks again) or is gone from the store (deleted or replaced by a new id).
  /// Pruning before every write and before every read means a stale entry can
  /// never authorize a transfer, and the map cannot outlive the task list.
  void _pruneAdoptedMediaUrl(String taskId) {
    final live = mediaTasks.task(taskId);
    final retryable =
        live != null &&
        (live.state == MediaTaskState.reauthorize ||
            live.errorCode == MediaErrorCode.authorizationRequired);
    if (retryable) {
      _adoptedMediaUrls.removeWhere(
        (id, _) => id != taskId && mediaTasks.task(id) == null,
      );
      return;
    }
    _adoptedMediaUrls.remove(taskId);
  }

  /// Authorization for a task whose source tab has closed.
  ///
  /// Only an address this controller adopted from a completed refresh may use
  /// it: [adoptRefreshedMediaUrl] records the adopted address, and anything
  /// else keeps the old page-required failure.
  MediaCandidate _authorizedWithoutLiveSession(
    MediaTask task,
    MediaCandidate candidate,
  ) {
    if (candidate.id != task.candidateId) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    final adopted = _adoptedMediaUrls[task.id];
    if (adopted == null || adopted != candidate.mediaUrl.toString()) {
      _pruneAdoptedMediaUrl(task.id);
      throw StateError('下载地址已失效，请返回来源页重新选择媒体');
    }
    if (candidate.generation != task.generation ||
        mediaDocumentIdentity(candidate.sourceUrl) !=
            mediaDocumentIdentity(task.sourceUrl)) {
      throw StateError('媒体资源已变化，请返回来源页重新选择媒体');
    }
    return candidate;
  }

  /// Refreshes surfaces that derive their content from the durable media task
  /// store after a foreground export completes.
  void notifyMediaChanged() {
    if (!_disposed) notifyListeners();
  }

  int? mediaExportProgress(String taskId) => _mediaExportProgress[taskId];

  ChangeNotifier get mediaExportProgressChanged => _mediaExportProgressChanged;

  void _setMediaExportProgress(String taskId, int progress) {
    final next = progress.clamp(0, 100).toInt();
    if (_mediaExportProgress[taskId] == next) return;
    _mediaExportProgress[taskId] = next;
    if (!_disposed) _mediaExportProgressChanged.notifyListeners();
    final downloads = nativeDownloads;
    if (downloads != null) {
      unawaited(
        downloads
            .progressNotification(
              'export:$taskId',
              '导出 MP4',
              next,
              totalBytes: 100,
            )
            .catchError((Object _) {}),
      );
    }
  }

  void _clearMediaExportProgress(String taskId) {
    if (_mediaExportProgress.remove(taskId) == null) return;
    if (!_disposed) {
      _mediaExportProgressChanged.notifyListeners();
      notifyMediaChanged();
    }
    final downloads = nativeDownloads;
    if (downloads != null) {
      unawaited(
        downloads
            .clearProgressNotification('export:$taskId')
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _autoConvertCompletedMedia(MediaTask task) async {
    if (!autoConvertToMp4) return;
    final file = await mediaTasks.cachedFile(task.id);
    if (file == null || !file.path.toLowerCase().endsWith('.m3u8')) return;
    try {
      await mediaExportQueue.enqueueAutomatic(task.id);
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
    bool forceRegenerate = false,
  }) => mediaExportQueue.export(
    task.id,
    deliverToConfiguredDirectory: deliverToConfiguredDirectory,
    forceRegenerate: forceRegenerate,
  );

  Future<MediaArtifact> _performQueuedMediaExport(
    MediaExportRequest request,
  ) async {
    final task = request.task;
    final deliverToConfiguredDirectory = request.deliverToConfiguredDirectory;
    final forceRegenerate = request.forceRegenerate;
    _setMediaExportProgress(task.id, 0);
    var backgroundExportStarted = false;
    try {
      final exports = nativeExports;
      if (exports != null) {
        try {
          await exports.beginBackgroundExport(task.id);
          backgroundExportStarted = true;
        } catch (error, stack) {
          // The foreground service is a durability aid. A denied or
          // unavailable service must not make an otherwise valid local export
          // fail.
          AppErrorLogger.capture(
            error,
            module: 'media.export.background',
            context: task.id,
            stack: stack,
          );
        }
      }
      final artifactFuture = request.preparedArtifact != null
          ? Future<MediaArtifact>.value(request.preparedArtifact)
          : _exportingMedia.putIfAbsent(
              task.id,
              () => _prepareMediaArtifact(
                task,
                forceRegenerate: forceRegenerate,
                onProgress: (progress) =>
                    _setMediaExportProgress(task.id, progress),
              ),
            );
      late final MediaArtifact artifact;
      try {
        artifact = await artifactFuture;
      } on StateError catch (error) {
        final message = error.toString();
        if (message.contains('媒体任务正在执行文件操作') ||
            message.contains('媒体任务仍被播放、导出、投屏或管理占用')) {
          throw const MediaExportDeferred();
        }
        rethrow;
      }
      if (!deliverToConfiguredDirectory) return artifact;
      if (!mediaTasks.canDelete(task.id)) {
        throw MediaExportDeferred(preparedArtifact: artifact);
      }
      try {
        await mediaTasks.withExclusive(task.id, () async {
          await mediaLibrary.deliver(task.id, mp4ExportDirectory);
        });
      } on StateError catch (error) {
        final message = error.toString();
        if (message.contains('媒体任务仍被播放、导出、投屏或管理占用') ||
            message.contains('媒体正在播放、导出、投屏或管理中')) {
          throw MediaExportDeferred(preparedArtifact: artifact);
        }
        rethrow;
      }
      final delivered = mediaLibrary.item(task.id) ?? artifact;
      if (deleteMediaTaskAfterMp4Export) {
        // MediaArtifact owns the exported MP4 independently. Deleting through
        // the task service removes only the task cache and task row, preserving
        // the exported artifact and its catalog index.
        await deleteMediaTask(task.id);
      }
      return delivered;
    } finally {
      if (backgroundExportStarted) {
        final exports = nativeExports;
        if (exports != null) {
          unawaited(
            exports.endBackgroundExport(task.id).catchError((Object _) {}),
          );
        }
      }
      _clearMediaExportProgress(task.id);
    }
  }

  /// Returns true when this episode already has readable output in its task
  /// group, even when the previous download task was deleted.
  Future<bool> hasPlayableEpisodeInGroup({
    required String group,
    required MediaCandidate candidate,
  }) async {
    final fileName = mediaEpisodeFileNameForCandidate(candidate);
    if (fileName == null) return false;
    if (await mediaLibrary.readableArtifactForEpisode(
          directory: group,
          fileName: fileName,
        ) !=
        null) {
      return true;
    }
    if (mediaStorageMode != MediaStorageMode.directPath) return false;
    final rawDirectory = mp4ExportDirectory?.trim() ?? '';
    if (rawDirectory.isEmpty) return false;
    final configured = Uri.tryParse(rawDirectory);
    if (configured == null ||
        (configured.hasScheme && configured.scheme != 'file')) {
      return false;
    }
    final root = configured.scheme == 'file'
        ? Directory.fromUri(configured)
        : Directory(rawDirectory);
    final folder = mediaPhysicalDirectoryName(group);
    final target = File(p.join(root.path, folder, fileName));
    try {
      if (!await target.exists() || await target.length() <= 0) return false;
      final exports = nativeExports;
      if (exports == null) return true;
      final metadata = await exports.inspect(target.path);
      return (metadata['mime'] as String? ?? '').toLowerCase() == 'video/mp4' &&
          ((metadata['durationMs'] as num?)?.toInt() ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  Future<MediaArtifact> _prepareMediaArtifact(
    MediaTask task, {
    bool forceRegenerate = false,
    void Function(int progress)? onProgress,
  }) async {
    var retained = false;
    try {
      await Future<void>.value();
      mediaTasks.retain(task.id);
      retained = true;
      await mediaLibrary.restore();
      var artifact = forceRegenerate ? null : mediaLibrary.item(task.id);
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
        onProgress?.call(5);
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
          final result = await mediaExports.export(
            task.id,
            input,
            forceRegenerate: forceRegenerate,
            onProgress: onProgress,
          );
          if (result.state != ExportState.deliverable ||
              result.outputPath == null) {
            throw StateError(result.errorCode ?? '导出失败');
          }
          output = result.outputPath!;
        } else {
          onProgress?.call(10);
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
          final folder = task.storageDirectoryName;
          final directory = Directory(
            '${(await mediaTasks.cacheRootDirectory()).parent.path}/media_exports/$folder',
          );
          await directory.create(recursive: true);
          final name = '$baseName.mp4';
          artifactName = name;
          final destination = File('${directory.path}/$name');
          final sourceSize = await file.length();
          if (!forceRegenerate &&
              await destination.exists() &&
              await destination.length() == sourceSize &&
              await _sameLocalFileBytes(file, destination)) {
            output = destination.path;
          } else {
            final temporary = File('${destination.path}.part');
            final previous = File('${destination.path}.previous');
            try {
              await file.copy(temporary.path);
              onProgress?.call(90);
              if (await temporary.length() != sourceSize) {
                throw StateError('MP4 副本校验失败');
              }
              if (await previous.exists()) await previous.delete();
              if (await destination.exists()) {
                await destination.rename(previous.path);
              }
              await temporary.rename(destination.path);
              if (await previous.exists()) await previous.delete();
              output = destination.path;
            } catch (_) {
              if (!await destination.exists() && await previous.exists()) {
                await previous.rename(destination.path);
              }
              rethrow;
            } finally {
              if (await temporary.exists()) await temporary.delete();
            }
          }
        }
        onProgress?.call(95);
        artifact = await mediaLibrary.register(
          mediaTasks.task(task.id) ?? task,
          output,
          name: artifactName,
          mime: artifactMime,
        );
      }
      onProgress?.call(100);
      return artifact;
    } finally {
      if (retained) mediaTasks.release(task.id);
      _exportingMedia.remove(task.id);
      notifyMediaChanged();
    }
  }

  Future<bool> _sameLocalFileBytes(File left, File right) async {
    if (!await left.exists() || !await right.exists()) return false;
    if (await left.length() != await right.length()) return false;
    final leftDigest = await sha256.bind(left.openRead()).first;
    final rightDigest = await sha256.bind(right.openRead()).first;
    return leftDigest == rightDigest;
  }

  Future<void> deleteMediaArtifact(
    String taskId, {
    bool deleteTaskCache = false,
    bool? deleteTask,
  }) async {
    final removeTask = deleteTask ?? deleteTaskCache;
    if (deleteTaskCache) {
      await mediaDownloads.delete(
        taskId,
        deleteTask: removeTask,
        beforeDelete: mediaLibrary.item(taskId) == null
            ? null
            : (nativeMutationReservation) => mediaLibrary.delete(
                taskId,
                exclusiveAlreadyHeld: true,
                nativeMutationReservation: nativeMutationReservation,
              ),
      );
    } else {
      await mediaLibrary.delete(taskId);
    }
    notifyMediaChanged();
  }

  /// Downloads own their cache, while exported documents belong to the library.
  Future<void> deleteMediaTask(String taskId) async {
    await mediaLibrary.restore();
    await mediaDownloads.delete(taskId);
    notifyMediaChanged();
  }

  Future<void> cleanupTemporaryCastTask(String taskId) async {
    final task = mediaTasks.task(taskId);
    if (task == null) return;
    await deleteMediaArtifact(taskId, deleteTaskCache: true, deleteTask: true);
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

  Future<File?> mediaPartialPlaybackFile(MediaTask task) =>
      mediaTasks.partialPlaybackFile(task.id);

  Future<MediaAuthorizationRefreshResult> refreshMediaAuthorization(
    MediaTask task,
    MediaCandidate candidate,
  ) async {
    final bridge = nativeMediaAuthRefresh;
    if (bridge == null) {
      return const MediaAuthorizationRefreshResult(
        state: 'waiting_execution',
        reason: '当前平台不支持后台授权刷新',
      );
    }
    return bridge.refresh(task, candidate);
  }

  /// Retries a task whose page-required state blocks the transfer.
  ///
  /// The refresh runs before any candidate lookup: [mediaCandidateForRetry]
  /// needs the source tab to still exist, and a tab the user left long ago is
  /// exactly the case the refresh exists to recover. Adoption goes through
  /// [adoptRefreshedMediaUrl]; when it fails the task keeps its page-required
  /// state so the row can offer the source page again.
  ///
  /// Throwing variant kept for callers that only care whether the retry was
  /// accepted. UI code that has to tell the three refresh states apart calls
  /// [retryMediaTaskResult], which never throws for a refresh outcome.
  ///
  /// The confirmation toast stays in the screen, which owns progress reporting
  /// for batch and single retries alike.
  Future<MediaTask> retryMediaTask(MediaTask task) async {
    final outcome = await retryMediaTaskResult(task);
    final retried = outcome.task;
    if (retried != null) return retried;
    throw StateError(outcome.message);
  }

  /// [retryMediaTask] that returns the outcome instead of throwing.
  ///
  /// The three refresh states carry different next steps (see GLOSSARY.md), so
  /// a single thrown [StateError] lost the one thing the message must do: tell
  /// the user whether retrying again can help, whether the page has to be
  /// re-picked, or whether the platform is waiting for its own window. Only a
  /// genuine local failure (a missing observation) still throws.
  Future<MediaRetryOutcome> retryMediaTaskResult(MediaTask task) async {
    mediaDownloads.resetRetryBudget(task.id);
    try {
      final retried = await _retryMediaTaskOnce(task);
      return MediaRetryOutcome(
        taskId: retried.id,
        kind: MediaRetryOutcomeKind.resumed,
        message: mediaRetryResumedMessage,
        task: retried,
      );
    } on _MediaRefreshFailure catch (failure) {
      final result = failure.result;
      final kind =
          failure.kind ??
          (result == null
              ? MediaRetryOutcomeKind.unchanged
              : mediaRefreshFailureKind(result));
      if (result == null || kind != mediaRefreshFailureKind(result)) {
        return MediaRetryOutcome(
          taskId: task.id,
          kind: kind,
          message: _refreshFailureMessageFor(
            kind,
            failure.message ?? result?.reason,
          ),
        );
      }
      return _refreshFailureOutcome(task, result);
    }
  }

  /// Retries [tasks] as a batch, refreshing once per source page.
  ///
  /// Page-required tasks are grouped by the origin of their source page and
  /// each group costs exactly one page load: the page is loaded once and every
  /// task in the group asks for its own playlist address in that single load.
  /// A task that comes back `unchanged` or `reauthorize` is reported as such
  /// and is never resumed, and never receives another task's address.
  ///
  /// Outcomes come back in the order of [tasks]. Groups run one after another
  /// so a batch never starts two page loads for the same site at once.
  Future<List<MediaRetryOutcome>> retryMediaTasks(List<MediaTask> tasks) async {
    final outcomes = List<MediaRetryOutcome?>.filled(tasks.length, null);
    final groups = <String, List<(int, MediaTask)>>{};
    final singles = <(int, MediaTask)>[];
    for (final (index, task) in tasks.indexed) {
      final page = task.sourceUrl;
      final origin = _mediaTaskNeedsAuthorizationRefresh(task)
          ? webOriginKey(page)
          : null;
      if (origin == null) {
        singles.add((index, task));
      } else {
        groups.putIfAbsent(origin, () => []).add((index, task));
      }
    }
    for (final entry in groups.values) {
      for (final (index, outcome) in (await _refreshMediaTasksBatch([
        for (final (_, task) in entry) task,
      ])).indexed) {
        outcomes[entry[index].$1] = outcome;
      }
    }
    for (final (index, task) in singles) {
      outcomes[index] = await retryMediaTaskResult(task);
    }
    return [for (final outcome in outcomes) outcome!];
  }

  /// One refresh for every task in [group], which shares one source page.
  Future<List<MediaRetryOutcome>> _refreshMediaTasksBatch(
    List<MediaTask> group,
  ) async {
    final bridge = nativeMediaAuthRefresh;
    if (bridge == null) {
      const unsupported = MediaAuthorizationRefreshResult(
        state: 'waiting_execution',
        reason: '当前平台不支持后台授权刷新',
      );
      return [
        for (final task in group) _refreshFailureOutcome(task, unsupported),
      ];
    }
    final prepared = <(MediaTask, MediaCandidate)>[];
    for (final task in group) {
      mediaDownloads.resetRetryBudget(task.id);
      if (!_mediaTaskNeedsAuthorizationRefresh(task)) {
        prepared.add((task, await mediaCandidateForRetry(task)));
        continue;
      }
      final stored = await db.mediaCandidate(task.candidateId);
      if (stored == null) {
        throw StateError('媒体候选已不存在，请返回来源页重新选择媒体');
      }
      prepared.add((task, stored));
    }
    final pageRequired = [
      for (final (task, stored) in prepared)
        if (_mediaTaskNeedsAuthorizationRefresh(task)) (task, stored),
    ];
    if (pageRequired.isEmpty) {
      return [
        for (final (task, stored) in prepared)
          MediaRetryOutcome(
            taskId: task.id,
            kind: MediaRetryOutcomeKind.resumed,
            message: mediaRetryResumedMessage,
            task: await _resumePrepared(task, stored),
          ),
      ];
    }
    final requests = [
      for (final (task, stored) in pageRequired)
        MediaAuthorizationRefreshRequest.fromCandidate(task, stored),
    ];
    List<MediaAuthorizationRefreshResult> results;
    try {
      results = await bridge.refreshBatch(requests);
    } on Object {
      results = const [];
    }
    final outcomes = <MediaRetryOutcome>[];
    for (var index = 0; index < prepared.length; index++) {
      final (task, stored) = prepared[index];
      final requestIndex = pageRequired.indexWhere(
        (entry) => entry.$1.id == task.id,
      );
      if (requestIndex < 0) {
        outcomes.add(
          MediaRetryOutcome(
            taskId: task.id,
            kind: MediaRetryOutcomeKind.resumed,
            message: mediaRetryResumedMessage,
            task: await _resumePrepared(task, stored),
          ),
        );
        continue;
      }
      // An answer that never arrived is the same dead end as an unanswered
      // single refresh: nothing is adopted and the row keeps its state.
      final result = requestIndex < results.length
          ? results[requestIndex]
          : const MediaAuthorizationRefreshResult(
              state: 'waiting_execution',
              reason: '授权刷新无响应',
            );
      if (!result.refreshed) {
        outcomes.add(_refreshFailureOutcome(task, result));
        continue;
      }
      try {
        final rebound = await adoptRefreshedMediaUrl(task, result);
        final resumed = await _resumePrepared(task, rebound);
        outcomes.add(
          MediaRetryOutcome(
            taskId: task.id,
            kind: MediaRetryOutcomeKind.resumed,
            message: mediaRetryResumedMessage,
            task: resumed,
          ),
        );
      } on StateError catch (error) {
        // The refresh reported success, so the page did answer; an address
        // that cannot be adopted is the page's own hand-over failing, which the
        // glossary calls 需回来源页, not "授权未变化".
        outcomes.add(
          MediaRetryOutcome(
            taskId: task.id,
            kind: MediaRetryOutcomeKind.requiresPage,
            message: _refreshFailureMessageFor(
              MediaRetryOutcomeKind.requiresPage,
              error.message,
            ),
          ),
        );
      }
    }
    return outcomes;
  }

  /// The single-task retry body, before its refresh outcome is classified.
  Future<MediaTask> _retryMediaTaskOnce(MediaTask task) async {
    if (task.state == MediaTaskState.paused) {
      final stored = await db.mediaCandidate(task.candidateId);
      if (stored == null) {
        throw StateError('媒体候选已不存在，请返回来源页重新选择媒体');
      }
      return mediaDownloads.resumeNative(task.id, stored);
    }
    if (!_mediaTaskNeedsAuthorizationRefresh(task)) {
      final resolved = await mediaCandidateForRetry(task);
      return _resumePrepared(task, resolved);
    }
    final stored = await db.mediaCandidate(task.candidateId);
    if (stored == null) {
      throw StateError('媒体候选已不存在，请返回来源页重新选择媒体');
    }
    final result = await refreshMediaAuthorization(task, stored);
    if (!result.refreshed) throw _MediaRefreshFailure(result);
    final MediaCandidate rebound;
    try {
      rebound = await adoptRefreshedMediaUrl(task, result);
    } on StateError catch (error) {
      // The refresh did report success; only the adoption failed. Nothing is
      // adopted and no state is touched, and the outcome degrades to
      // 需回来源页 because retrying the same refresh cannot help.
      return Future.error(
        _MediaRefreshFailure(
          null,
          message: error.message,
          kind: MediaRetryOutcomeKind.requiresPage,
        ),
      );
    }
    return mediaDownloads.resumeNative(task.id, rebound);
  }

  /// Resumes a task whose address is already resolved and authorized.
  Future<MediaTask> _resumePrepared(MediaTask task, MediaCandidate resolved) {
    final current = mediaTasks.task(task.id) ?? task;
    // cache_missing says the finished file vanished, and the transfer keeps its
    // own bytes beside it: a resumable partial is offered to the server as a
    // Range, and a 200 rewrites it. Deleting the task's cache here would also
    // delete that partial through the native runtime and turn every retry into
    // a download from zero, so the transfer decides for itself.
    if (task.state == MediaTaskState.failed &&
        nativeDownloads != null &&
        !resolved.isHls) {
      return mediaDownloads.resumeNative(task.id, resolved);
    }
    return mediaDownloads.startNative(current, resolved);
  }

  /// Reports a refresh that produced no usable address without touching the
  /// task: no progress, no state churn, nothing to roll back.
  MediaRetryOutcome _refreshFailureOutcome(
    MediaTask task,
    MediaAuthorizationRefreshResult result,
  ) => MediaRetryOutcome(
    taskId: task.id,
    kind: mediaRefreshFailureKind(result),
    message: _refreshFailureMessage(result),
  );

  /// Message for a refresh that produced no usable address.
  String _refreshFailureMessage(MediaAuthorizationRefreshResult result) =>
      _refreshFailureMessageFor(mediaRefreshFailureKind(result), result.reason);

  static bool _mediaTaskNeedsAuthorizationRefresh(MediaTask task) =>
      task.state == MediaTaskState.reauthorize ||
      task.errorCode == MediaErrorCode.authorizationRequired;

  /// User-facing wording for an authorization refresh that produced no usable
  /// address, keyed by the outcome the user has to act on.
  String _refreshFailureMessageFor(MediaRetryOutcomeKind kind, String? reason) {
    final text = (reason ?? '').trim();
    switch (kind) {
      case MediaRetryOutcomeKind.waiting:
        return text.isNotEmpty ? text : '等待系统允许后台授权刷新';
      case MediaRetryOutcomeKind.requiresPage:
        return text.isNotEmpty ? text : '需回来源页重新授权媒体';
      case MediaRetryOutcomeKind.unchanged:
        return '授权未变化：${text.isNotEmpty ? text : '请返回来源页重新选择媒体'}';
      case MediaRetryOutcomeKind.resumed:
        return text.isNotEmpty ? text : mediaRetryResumedMessage;
    }
  }

  /// Copies [candidate] with only its address replaced.
  ///
  /// Every identity bearing field stays as observed, so the rebound candidate
  /// keeps the same id, host, generation, page and selection and the task's
  /// cache key survives. [MediaCandidate] has no copyWith by design; the
  /// identity fields are enumerated here instead.
  MediaCandidate _mediaCandidateWithUrl(
    MediaCandidate candidate,
    Uri mediaUrl,
  ) => MediaCandidate(
    id: candidate.id,
    hostId: candidate.hostId,
    generation: candidate.generation,
    sourceUrl: candidate.sourceUrl,
    mediaUrl: mediaUrl,
    title: candidate.title,
    mime: candidate.mime,
    source: candidate.source,
    seriesKey: candidate.seriesKey,
    episodeNumber: candidate.episodeNumber,
    representationRank: candidate.representationRank,
    qualityLabel: candidate.qualityLabel,
    audioLabel: candidate.audioLabel,
    thumbnailUrl: candidate.thumbnailUrl,
    durationMs: candidate.durationMs,
    createdAt: candidate.createdAt,
    manifestHeaders: candidate.manifestHeaders,
    resourceHeaders: candidate.resourceHeaders,
    seriesTitle: candidate.seriesTitle,
  );

  /// Rebinds [task] to the address the source page itself requested during an
  /// authorization refresh.
  ///
  /// Fails closed at every step: the result must be a successful refresh, the
  /// address must be an HTTP(S) locator without embedded credentials, it must
  /// describe the same logical resource as the candidate the task is bound to,
  /// and it must carry the task's own resource identity. The rebound candidate
  /// keeps the stored observation's id, host, generation and source page and
  /// differs only in its address, so the task's cache key and partial bytes
  /// survive.
  Future<MediaCandidate> adoptRefreshedMediaUrl(
    MediaTask task,
    MediaAuthorizationRefreshResult result,
  ) async {
    if (!result.refreshed) throw StateError(_refreshFailureMessage(result));
    final raw = result.mediaUrl?.trim() ?? '';
    if (raw.isEmpty) throw StateError('授权刷新未提供媒体地址，需回来源页重新授权');
    final mediaUrl = Uri.tryParse(raw);
    if (mediaUrl == null ||
        !const {'http', 'https'}.contains(mediaUrl.scheme) ||
        mediaUrl.host.isEmpty ||
        mediaUrl.userInfo.isNotEmpty) {
      throw StateError('授权刷新提供的媒体地址无效，需回来源页重新授权');
    }
    final stored = await db.mediaCandidate(task.candidateId);
    if (stored == null) throw StateError('媒体候选已不存在，请返回来源页重新选择媒体');
    final next = _mediaCandidateWithUrl(stored, mediaUrl);
    if (mediaCandidateLogicalIdentity(next) !=
        mediaCandidateLogicalIdentity(stored)) {
      throw StateError('授权刷新提供的是另一个媒体资源，需回来源页重新选择媒体');
    }
    if (task.resourceKey.isNotEmpty &&
        mediaResourceKeyForCandidate(next) != task.resourceKey) {
      throw StateError('授权刷新的媒体资源身份不一致，需回来源页重新选择媒体');
    }
    const validator = MediaCandidateValidator();
    try {
      validator.validate(
        next,
        hostId: stored.hostId,
        generation: stored.generation,
        sourceUrl: stored.sourceUrl,
      );
    } on Object {
      throw StateError('授权刷新提供的媒体地址未通过校验，需回来源页重新授权');
    }
    await db.saveMediaCandidate(next);
    // The refresh has already proved the address: the page that owns the task
    // asked for it and it passed every identity gate above. A live tab is only
    // a convenience — its host may have moved on to a later generation, or be
    // showing a different episode by now — so a refusal there is recorded and
    // the adopted address still stands. Turning a successful refresh into
    // 需回来源页 here is exactly the "刷新成功却还要求授权" symptom.
    final session = hosts.sessions[task.hostId];
    if (session != null && !session.disposed) {
      try {
        hosts.authorizeMediaCandidate(task.hostId, next.id);
      } on Object {
        // Nothing to adopt from the tab; the address below is the authority.
      }
    }
    _adoptedMediaUrls[task.id] = next.mediaUrl.toString();
    _pruneAdoptedMediaUrl(task.id);
    await mediaTasks.rebindCandidate(
      task.id,
      next,
      allowAuthorizationRefresh: true,
    );
    return next;
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
        final profile = !_profilesKnown || ids.contains(record.profileId)
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
    unawaited(_observeActivePlayback());
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

  Future<void> _observeActivePlayback() async {
    final tab = activeBrowser;
    await _observePlaybackForTab(tab);
  }

  Future<void> _observePlaybackForTab(
    ActiveBrowserSession? tab, {
    bool requireCurrent = true,
  }) async {
    if (_disposed || !autoSaveWebPlayback || tab == null) return;
    final host = tab.loadedHost;
    final evidence = host?.playbackEvidence;
    if (host == null ||
        host.disposed ||
        evidence == null ||
        !browserTabs.contains(tab) && requireCurrent) {
      return;
    }
    try {
      await watchSaves.observe(
        evidence,
        profileId: tab.site.profileId,
        isCurrent: requireCurrent
            ? () =>
                  !_disposed &&
                  identical(activeBrowser, tab) &&
                  browserTabs.contains(tab) &&
                  identical(tab.loadedHost, host) &&
                  identical(host.playbackEvidence, evidence)
            : null,
      );
    } catch (error, stack) {
      if (!_disposed) {
        AppErrorLogger.capture(error, module: 'media.watch_save', stack: stack);
      }
    }
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
    await _ensureBrowserPrepared();
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

  int _healthRefreshEpoch = 0;

  Future<void> refreshProfileHealth() async {
    final epoch = ++_healthRefreshEpoch;
    try {
      final health = await db.profileHealthAll();
      final byRoute = await db.routeHealthRows();
      if (_disposed || epoch != _healthRefreshEpoch) return;
      profileHealth = health;
      routeHealthRecords = byRoute;
      notifyListeners();
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'background.health-refresh',
        stack: stack,
      );
    }
  }

  Future<void> load({bool suppressCorruption = false}) =>
      _loadMetadata(suppressCorruption: suppressCorruption);

  Future<void> _loadMetadata({
    bool suppressCorruption = false,
    bool prepareRuntime = true,
  }) async {
    if (prepareRuntime) await _waitForBrowserPreparation();
    final trace = _persistentStateLoaded ? StartupTrace() : startupTrace;
    Future<T> read<T>(Future<T> Function() action, T fallback) async {
      if (!suppressCorruption) return action();
      try {
        return await action();
      } catch (_) {
        return fallback;
      }
    }

    if (suppressCorruption) error = null;
    await trace.measure(StartupPhase.storedMetadataRead, () async {
      sites = await read(db.candidates, sites);
      sources = await read(db.sources, sources);
      try {
        profiles = await db.profiles();
        _profilesKnown = true;
      } catch (_) {
        if (!suppressCorruption) rethrow;
      }
      profilePages = await read(db.profilePages, profilePages);
      profileHealth = await read(db.profileHealthAll, profileHealth);
      routeHealthRecords = await read(db.routeHealthRows, routeHealthRecords);
      profileScriptLinks = await read(db.profileScripts, profileScriptLinks);
    });
    await trace.measure(StartupPhase.preferencesRead, () async {
      settings = await read(settingsRepository.read, settings);
      await read(_refreshBackgroundSnapshot, null);
      glassQualityCache = await read(
        glassQualityCacheRepository.read,
        glassQualityCache,
      );
    });
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
    trace.measureSync(StartupPhase.preferencesApply, _applySettings);
    if (prepareRuntime) {
      await _prepareBrowserRuntime(suppressCorruption: suppressCorruption);
    }
    await _syncNativeMediaLifecycle();
    if (_disposed) return;
    _persistentStateLoaded = true;
    trace.markOnce(
      StartupPhase.persistentStateReady,
      itemCount: profiles.length,
    );
    notifyListeners();
  }

  Future<void> _prepareBrowserRuntime({bool suppressCorruption = false}) async {
    final trace = startupTrace;
    Future<T> read<T>(Future<T> Function() action, T fallback) async {
      try {
        return await action();
      } catch (_) {
        if (!suppressCorruption) rethrow;
        return fallback;
      }
    }

    installed = await db.scripts();
    filterPolicy = await db.filterPolicy();
    profileFilterPolicies = await db.explicitProfileFilterPolicies();
    history = await read(db.recentProbes, history);
    await trace.measure(
      StartupPhase.filterSourcesSeed,
      _seedBuiltInFilterSources,
    );
    filterSourceList = await db.filterSources();
    trace.markOnce(
      StartupPhase.filterSourcesReady,
      itemCount: filterSourceList.length,
    );
    if (await db.latestFilterSnapshot() != null) {
      await trace.measure(
        StartupPhase.filterBundleRebuild,
        filterSources.rebuildBundle,
      );
    }
    if (_disposed) return;
    trace.measureSync(
      StartupPhase.hostFiltersApply,
      () => hosts.setFilterEngine(
        filterSnapshots.activeEngine,
        policy: filterPolicy,
        snapshot: filterSnapshots.activeSnapshot,
        profilePolicies: profileFilterPolicies,
      ),
    );
    if (suppressCorruption) {
      try {
        await trace.measure(
          StartupPhase.hostPreferencesApply,
          () => hosts.applyPreferences(hostPreferences),
        );
      } catch (_) {}
    } else {
      await trace.measure(
        StartupPhase.hostPreferencesApply,
        () => hosts.applyPreferences(hostPreferences),
      );
    }
    await trace.measure(StartupPhase.mediaPolicySync, syncMediaPolicy);
    if (!_disposed) notifyListeners();
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

  /// Per-出口 health, as stored (ADR-0006). Read for the detail screen only:
  /// nothing sorts or recommends from it.
  List<({int profileId, SiteRoute route, ProfileHealth health})>
  routeHealthRecords = [];

  /// The 出口-level record for [profileId]. Its aggregate is the badge.
  RouteHealthRecord routeHealthFor(int profileId) {
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    return routeHealthFromStored(
      profileId: profileId,
      routes: profile?.routes ?? const {SiteRoute.browse},
      pages: profilePages.where((page) => page.profileId == profileId).toList(),
      verdicts: {
        for (final row in routeHealthRecords)
          if (row.profileId == profileId) row.route: row.health,
      },
    );
  }

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
      await _ensureBrowserPrepared();
      cancelToken.check();
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

  /// Compatibility API for existing background-check integration coverage.
  /// The settings page uses the passive device diagnostics API instead.
  Future<HealthRunReport> runHealthCheckOnce({
    HealthConditions? conditions,
  }) async {
    conditions ??= await const DeviceConditions().read();
    final checker = ProfileHealthChecker(
      db: db,
      probe: Platform.isAndroid ? NativeHealthProbe() : HttpReachabilityProbe(),
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
    _diagnosticsChanged();
    try {
      final snapshot = await deviceDiagnostics.refresh();
      final records = {for (final row in snapshot.capabilities) row.id: row};
      bool supported(String id) =>
          records[id]?.state == CapabilityState.supported &&
          records[id]?.effective == true;
      if (!records.containsKey('webview.isolatedScripts')) {
        throw StateError('网页能力查询未完成');
      }
      final result = HostCapabilities(
        platform: snapshot.webViewProvider ?? snapshot.platform,
        isolatedScripts: supported('webview.isolatedScripts'),
        documentStart: supported('webview.documentStart'),
        privateProbes: supported('webview.privateProbes'),
        reason: records['webview.isolatedScripts']!.reason,
      );
      capabilities = result;
      return result;
    } catch (_) {
      capabilities = null;
      hostCapabilityError = '检查未完成，请重试';
      throw StateError('检查未完成，请重试');
    } finally {
      checkingHostCapabilities = false;
      _diagnosticsChanged();
    }
  }

  String? lastHealthNotice;

  Future<void>? _scriptToggleRun;
  bool get changingScripts => _scriptToggleRun != null;

  Future<void> disableAllScripts(bool disabled) {
    final running = _scriptToggleRun;
    if (running != null) {
      // Requests from recovery menus use the same serialized path as the
      // settings switch; opposing changes cannot race native registration.
      return running.then<void>(
        (_) => disableAllScripts(disabled),
        onError: (Object _, StackTrace _) => disableAllScripts(disabled),
      );
    }
    late final Future<void> run;
    run = _setScriptsDisabled(disabled).whenComplete(() {
      if (identical(_scriptToggleRun, run)) _scriptToggleRun = null;
      if (!_disposed) super.notifyListeners();
    });
    _scriptToggleRun = run;
    if (!_disposed) super.notifyListeners();
    return run;
  }

  Future<void> _setScriptsDisabled(bool disabled) async {
    final previous = scriptsDisabled;
    scriptsDisabled = disabled;
    if (!_disposed) super.notifyListeners();
    try {
      settings = await settingsRepository.update({'scriptsDisabled': disabled});
      _applySettings();
      // The durable policy now blocks GM requests. Revoke registrations and
      // reload each browsing host without waiting on unrelated media work.
      await Future.wait([
        for (final session in hosts.sessions.values.toList())
          if (!session.disposed && session.purpose == HostPurpose.browsing)
            (() async {
              await hosts.configure(session);
              if (!session.disposed && !_disposed) {
                hosts.resetNavigationRetry(session);
                await hosts.api.reload(session.id);
              }
            })(),
      ]);
    } catch (_) {
      scriptsDisabled = previous;
      if (!_disposed) super.notifyListeners();
      rethrow;
    }
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
      hosts.resetNavigationRetry(session);
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
    await _observePlaybackForTab(tab, requireCurrent: false);
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
      await _observePlaybackForTab(tab, requireCurrent: false);
      if (tab.loadedHost != null) await hosts.destroy(tab.loadedHost!);
    }
    if (persist) await _persistSessions();
  }

  bool restoringData = false;
  Future<Uint8List> exportBackup() async {
    await _persistSessions();
    return BackupService(db, backgroundAssets: backgroundAssets).export();
  }

  Future<BackupSnapshot> inspectBackup(Uint8List bytes) =>
      BackupService(db, backgroundAssets: backgroundAssets).validate(bytes);
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
      await startupSettled;
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
      await BackupService(
        db,
        backgroundAssets: backgroundAssets,
      ).restore(snapshot);
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
    await backgroundAssets.cleanupUnused(const []);
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
    final nativePlaybackFlush = nativePlayback.flush();
    final mediaExportFlush = mediaExportQueue.close();
    final watchSaveFlush = watchSaves.flush();
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    deviceDiagnostics.removeListener(_diagnosticsChanged);
    deviceDiagnostics.dispose();
    unawaited(_diagnosticPlaybackEvents?.cancel());
    // 凭证握手订阅着原生会话流；不释放它，shutdown 之后仍有一个活的订阅，
    // 测试里的 pumpAndSettle 就永远等不到静止。
    unawaited(_credentialOutcomes?.cancel());
    _credentialOutcomes = null;
    final handoff = credentialHandoff;
    credentialHandoff = null;
    if (handoff != null) unawaited(handoff.dispose());
    mediaCast.removeListener(_observeCastForDiagnostics);
    hosts.changed.removeListener(_hostMetadataChanged);
    _network?.cancel();
    _mediaNetworkUnsubscribe?.call();
    _mediaNetworkUnsubscribe = null;
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
    final nativeDispose = _clearAndDisposeNativeMedia();
    _shutdownFuture =
        Future.wait<void>([
          flush,
          mediaFlush,
          nativePlaybackFlush,
          watchSaveFlush,
          (() async {
            try {
              await _initialization;
            } catch (_) {}
            try {
              await _deferredStartup;
            } catch (_) {}
            await _waitForBrowserPreparation();
            await mediaTasks.flushAll();
          })(),
          close,
          nativeDispose,
          stopCast,
          mediaExportFlush,
          if (_scriptToggleRun != null)
            _scriptToggleRun!.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
        ]).then<void>((_) {}).whenComplete(() {
          mediaExportQueue.dispose();
          mediaTasks.dispose();
          settingsRepository.dispose();
        });
    unawaited(
      _shutdownFuture!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    mediaLibrary.removeListener(notifyMediaChanged);
    mediaStorage.dispose();
    mediaOperations.dispose();
    mediaLibrary.dispose();
    watchSaves.dispose();
    _mediaExportProgressChanged.dispose();
    AppErrorLogger.detach(errorLogger);
    super.dispose();
  }

  Future<void> _clearAndDisposeNativeMedia() async {
    await nativeMedia.clearForAppShutdown();
    await _credentialOutcomes?.cancel();
    _credentialOutcomes = null;
    await credentialHandoff?.dispose();
    credentialHandoff = null;
    await nativeMedia.dispose();
  }
}

/// 用户看到的远程失败结论（T8）。它不落到任何 `MediaTaskState` 上：远程播放
/// 可以不建任务，结局只能由这份提示、而不是任务状态来表达。
class RemoteFailureNotice {
  const RemoteFailureNotice({required this.plan});

  final RemoteFailurePlan plan;

  RemoteFailureKind get kind => plan.failure.kind;
  RemoteFailureAction get action => plan.action;

  /// 用户看得到的那句话。四类各不相同。
  String get message => plan.message;

  /// 这一次是不是已经自动重试过了。
  bool get retried => plan.retries;

  /// 这一次没有自动重试（预算用完、或这一类根本不重开）：只剩建议。
  bool get exhausted => !plan.retries;
}

/// 一次「从详情页点选集进入远程播放」要交给播放页的全部参数（T11）。
///
/// 它只携带**播放**需要的东西：一集候选、剧名、集号、下一集从哪里来，以及
/// 调用方手里已有的观看位置。没有任务、没有下载、没有追剧记录的落库。
class RemotePlayerLaunch {
  const RemotePlayerLaunch({
    required this.candidate,
    required this.title,
    required this.episodeNumber,
    required this.source,
    this.lineId,
    this.continueWatchingMs = 0,
    this.profileId,
  });

  final MediaCandidate candidate;
  final String title;
  final String episodeNumber;
  final RemoteEpisodeSource source;
  final String? lineId;
  final int continueWatchingMs;

  /// 这一部剧所属的站点档案：播放页换集、失败重开时原样带回宿主，原生按它
  /// 取凭证（ADR-0009）。
  final int? profileId;
}

/// 把 `AppController` 的远程播放能力交给播放页（[RemotePlaybackHost]）。
///
/// 这是播放页与原生/凭证/失败归因之间唯一的缝：播放页不持有 `AppController`，
/// 也就不会顺手去碰下载任务或追剧记录。远程失败一律经过控制器既有的归因链，
/// 播放页只执行它给出的下一步。
class AppRemotePlaybackHost implements RemotePlaybackHost {
  AppRemotePlaybackHost(this.app);

  final AppController app;

  /// 档案 id 由调用方交进来，不从候选身上推。
  ///
  /// 候选的 `hostId` 是观察它的网页宿主，档案 id 是凭证与目录的归属者；两者
  /// 只是碰巧都是小整数。把宿主 id 当档案 id 用，原生就会去一个不存在的档案
  /// 名下找凭证，带凭证的站点在换集、失败重开时安静地退回匿名。
  @override
  Future<NativePlaybackSession> openRemote(
    MediaCandidate candidate, {
    int? profileId,
  }) => app.openRemoteCandidate(
    candidate,
    hostId: candidate.hostId,
    generation: candidate.generation,
    sourceUrl: candidate.sourceUrl,
    profileId: profileId,
  );

  @override
  Stream<NativePlaybackSession> get nativeStates => app.nativeMedia.states;

  @override
  Future<NativePlaybackSession> play(String sessionId) =>
      app.nativeMedia.play(sessionId: sessionId);

  @override
  Future<NativePlaybackSession> pause(String sessionId) =>
      app.nativeMedia.pause(sessionId: sessionId);

  @override
  Future<NativePlaybackSession> seek(Duration position, String sessionId) =>
      app.nativeMedia.seek(position, sessionId: sessionId);

  @override
  Future<NativePlaybackSession> setSpeed(double speed, String sessionId) =>
      app.nativeMedia.setSpeed(speed, sessionId: sessionId);

  @override
  Future<NativePlaybackSession> close(String sessionId) =>
      app.nativeMedia.close(sessionId: sessionId);

  @override
  RemoteFailurePlan? observeRemoteFailure(
    NativePlaybackSession session, {
    void Function()? retry,
  }) => app.observeRemoteFailure(session, retry: retry);

  @override
  void dismissRemoteFailure() {
    // 播放页有自己的失败提示；全局那一条同源，一并清掉，免得用户要关两次。
    app.dismissRemoteFailure();
  }
}
