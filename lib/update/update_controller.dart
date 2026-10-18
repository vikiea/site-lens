import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/app_settings.dart';
import 'github_token_store.dart';
import 'update_service.dart';

/// App-level owner of the software update flow.
///
/// It outlives the update page so a running download keeps going after the
/// user leaves, keeps the fragment on disk so a process restart can resume it,
/// and owns the in-app completion notice state.
final updateControllerProvider = Provider<UpdateController>((ref) {
  final tokenStore = GitHubTokenStore();
  final controller = UpdateController(
    service: UpdateService(tokenLoader: tokenStore.read),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

enum UpdateDownloadState { idle, downloading, verifying, paused, ready, failed }

enum UpdatePauseReason { user, network }

class UpdateController extends ChangeNotifier with WidgetsBindingObserver {
  UpdateController({UpdateService? service})
    : service = service ?? UpdateService() {
    WidgetsBinding.instance.addObserver(this);
  }

  final UpdateService service;

  ReleaseInfo? _release;
  String? _currentVersion;
  bool _checking = false;
  bool _checkingStarted = false;
  String? _checkMessage;
  String? _error;
  String? _installMessage;
  DateTime? _checkedAt;
  UpdateDownloadState _downloadState = UpdateDownloadState.idle;
  UpdatePauseReason? _pauseReason;
  int _received = 0;
  int? _total;
  File? _readyApk;
  List<UpdatePartial> _partials = const [];
  bool _noticeVisible = false;
  bool _noticeHandled = false;
  bool _foreground = true;
  bool _updateScreenVisible = false;
  bool _disposed = false;
  UpdateDownload? _download;

  ReleaseInfo? get release => _release;
  String? get currentVersion => _currentVersion;
  bool get checking => _checking;
  String? get checkMessage => _checkMessage;
  String? get error => _error;
  String? get installMessage => _installMessage;
  DateTime? get checkedAt => _checkedAt;
  UpdateDownloadState get downloadState => _downloadState;
  UpdateChannel get channel => service.channel;
  UpdatePauseReason? get pauseReason => _pauseReason;
  int get received => _received;
  int? get total => _total;
  File? get readyApk => _readyApk;
  bool get downloading => _downloadState == UpdateDownloadState.downloading;
  bool get verifying => _downloadState == UpdateDownloadState.verifying;

  /// Switches the release source without carrying a stable result or cache
  /// into the beta channel. An active transfer must finish or be paused first.
  Future<void> setChannel(UpdateChannel next) async {
    if (service.channel == next) return;
    if (busy) throw StateError('下载进行中，暂时不能切换更新渠道');
    service.channel = next;
    _release = null;
    _checkMessage = null;
    _error = null;
    _readyApk = null;
    _downloadState = UpdateDownloadState.idle;
    _pauseReason = null;
    _received = 0;
    _total = null;
    await _refreshLocalState();
    _notify();
  }

  /// A transfer is in flight; the check action stays disabled meanwhile.
  bool get busy => downloading || verifying;

  double? get fraction {
    final total = _total;
    if (total == null || total <= 0) return null;
    return (_received / total).clamp(0.0, 1.0);
  }

  int? get percent {
    final value = fraction;
    return value == null ? null : (value * 100).floor();
  }

  /// The fragment that belongs to the release currently on screen.
  UpdatePartial? get currentPartial {
    final release = _release;
    if (release == null) return null;
    for (final partial in _partials) {
      if (partial.matches(release)) return partial;
    }
    return null;
  }

  /// Fragments for any other release: the user can still install the older
  /// version, so they are reported instead of being deleted silently. Before
  /// the release is known every fragment is a candidate for the current
  /// download, so nothing is reported as stale yet.
  List<UpdatePartial> get stalePartials {
    final tag = _release?.tagName;
    if (tag == null) return const [];
    return _partials.where((partial) => partial.tagName != tag).toList();
  }

  bool get updateScreenVisible => _updateScreenVisible;

  bool get noticeVisible =>
      _noticeVisible &&
      _foreground &&
      (!_updateScreenVisible || _installMessage != null);

  /// The fragment the resume action targets: the current release's fragment
  /// when one is known, otherwise the newest fragment on disk.
  UpdatePartial? get activePartial =>
      currentPartial ??
      (_release == null && _partials.isNotEmpty ? _partials.first : null);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) drainPendingNotice();
    _notify();
  }

  /// Called when the update page opens: refreshes the version and local
  /// fragments, and resumes an unfinished download the user never paused.
  ///
  /// A fragment on disk is the only reason the page acts by itself. When the
  /// release is already known from this session the transfer restarts
  /// directly; after a process restart the release identity is missing, so the
  /// page checks once (cached for a minute) and then resumes.
  Future<void> openUpdatePage() async {
    await loadLocalState();
    final partial = activePartial;
    if (partial == null || partial.received <= 0) return;
    // Only the user's own pause keeps a fragment from continuing; the release
    // identity is still resolved so the page can render the resume controls.
    final resumable = !partial.pausedByUser;
    if (_release == null) {
      await check(autoResume: resumable);
      return;
    }
    if (resumable && currentPartial != null) await startDownload();
  }

  Future<void> loadLocalState() async {
    if (!_checkingStarted) {
      _checkingStarted = true;
      try {
        _currentVersion = (await service.packageInfo).version;
      } catch (_) {
        /* version is cosmetic; the page falls back to a placeholder */
      }
    }
    await _refreshLocalState();
    _notify();
  }

  Future<void> check({bool autoResume = false}) async {
    if (_checking || _downloadState == UpdateDownloadState.downloading) return;
    _checking = true;
    _error = null;
    _checkMessage = null;
    // A failed or non-updating check must not leave an older result offering
    // a download. Only a release proven newer than the installed version is
    // allowed back into the downloadable state.
    _release = null;
    _notify();
    try {
      final result = await service.checkForUpdate();
      _currentVersion = (await service.packageInfo).version;
      _checkedAt = result.checkedAt;
      _release = result.release;
      // Cache freshness is an implementation detail. Keep the visible
      // message about the result itself so a cached latest check reads the
      // same as a network check.
      _checkMessage = result.release == null ? '暂无更新' : null;
      await _refreshLocalState();
    } catch (error) {
      _error = readableUpdateError(error);
    } finally {
      _checking = false;
      _notify();
    }
    final partial = currentPartial;
    if (autoResume &&
        _release != null &&
        partial != null &&
        !partial.pausedByUser &&
        _downloadState == UpdateDownloadState.paused) {
      await startDownload();
    }
  }

  Future<void> startDownload({bool restart = false}) async {
    final release = _release;
    if (release == null || _downloadState == UpdateDownloadState.downloading) {
      return;
    }
    final partial = restart ? null : currentPartial;
    _error = null;
    _installMessage = null;
    _pauseReason = null;
    _noticeVisible = false;
    _noticeHandled = false;
    _downloadState = UpdateDownloadState.downloading;
    _received = partial?.received ?? 0;
    _total = partial != null && partial.total > 0
        ? partial.total
        : (release.apkSize > 0 ? release.apkSize : null);
    _notify();

    final UpdateDownload download;
    try {
      download = await service.startDownload(
        release,
        restart: restart,
        onProgress: (received, total) {
          _received = received;
          if (total != null && total > 0) _total = total;
          _notify();
        },
        onVerifying: () {
          _downloadState = UpdateDownloadState.verifying;
          _notify();
        },
      );
    } catch (error) {
      _downloadState = UpdateDownloadState.failed;
      _error = readableUpdateError(error);
      _notify();
      return;
    }
    _download = download;
    try {
      final result = await download.done;
      if (result.isCompleted) {
        final file = result.file!;
        _readyApk = file;
        _downloadState = UpdateDownloadState.ready;
        _received = await _lengthOf(file, _received);
        _total = _received;
        _pauseReason = null;
        _noticeHandled = false;
        _noticeVisible = true;
      } else {
        final paused = result.partial!;
        _pauseReason = paused.pausedByUser
            ? UpdatePauseReason.user
            : UpdatePauseReason.network;
        _downloadState = UpdateDownloadState.paused;
        _received = paused.received;
        _total = paused.total > 0 ? paused.total : _total;
        if (_pauseReason == UpdatePauseReason.network) {
          _error = '下载中断，已保留断点，可继续下载';
        }
      }
    } on FormatException catch (error) {
      _downloadState = UpdateDownloadState.failed;
      _error = error.message;
    } catch (error) {
      _downloadState = UpdateDownloadState.failed;
      _error = readableUpdateError(error);
    } finally {
      _download = null;
      await _refreshLocalState();
      _notify();
    }
  }

  /// Stops the transfer and keeps the fragment so it can be resumed.
  void pause() {
    _download?.cancel();
  }

  /// Continues a retained download. A fragment alone does not carry the
  /// release identity, so this checks first when the page has not done so.
  Future<void> resume() async {
    if (_release == null) {
      await check(autoResume: true);
      return;
    }
    await startDownload();
  }

  /// Pause and delete the retained fragment and any verified APK.
  Future<void> deleteDownload() async {
    final download = _download;
    if (download != null) {
      download.cancel();
      try {
        await download.done;
      } catch (_) {
        /* the fragment is removed below regardless */
      }
      _download = null;
    }
    final release = _release;
    if (release != null) {
      try {
        await service.deleteDownload(release);
      } catch (_) {
        /* cleanup is best effort */
      }
    }
    _downloadState = UpdateDownloadState.idle;
    _pauseReason = null;
    _error = null;
    _installMessage = null;
    _readyApk = null;
    _received = 0;
    _total = release != null && release.apkSize > 0 ? release.apkSize : null;
    _noticeVisible = false;
    _noticeHandled = true;
    await _refreshLocalState();
    _notify();
  }

  Future<void> deleteStalePartials() async {
    final tag = _release?.tagName;
    // Before the release is known nothing is classified as stale, and an empty
    // keep-tag would delete the fragment the user is downloading.
    if (tag == null) return;
    try {
      await service.deleteStalePartials(tag);
    } catch (_) {
      /* cleanup is best effort */
    }
    await _refreshLocalState();
    _notify();
  }

  /// Runs the installer handshake: permission gate first, then the verified
  /// APK handoff. Non-Android platforms are handled by the update page.
  Future<void> install() async {
    final apk = _readyApk;
    final release = _release;
    if (apk == null || release == null) return;
    if (!service.platform.supportsApkInstall) return;
    _error = null;
    _installMessage = null;
    _notify();
    try {
      if (!await service.platform.canInstallPackages()) {
        await service.platform.openInstallPermissionSettings();
        _installMessage = '请允许 Site Lens 安装未知来源应用，然后再次点击安装更新';
        _noticeVisible = true;
        _noticeHandled = false;
        _notify();
        return;
      }
      await service.platform.verifyAndInstall(apk, release);
    } on PlatformException catch (error) {
      _error = error.message ?? 'APK 校验或安装失败';
      _notify();
    } catch (error) {
      _error = error is UnsupportedError ? '当前平台不支持 APK 安装' : '安装未能完成，请重试';
      _notify();
    }
  }

  /// The update page is visible: the completion notice stays out of the way
  /// because the page installs directly.
  void setUpdateScreenVisible(bool value) {
    if (_updateScreenVisible == value) return;
    _updateScreenVisible = value;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // The update page flips this from initState, during the build phase. The
      // notice layer lives outside the navigator, so notifying now would mark
      // it dirty mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _notify());
      return;
    }
    _notify();
  }

  /// Marks the notice as handled: it does not come back for this download.
  void dismissNotice() {
    _noticeVisible = false;
    _noticeHandled = true;
    _installMessage = null;
    _notify();
  }

  /// Surfaces a completion that happened while the app was in the background.
  void drainPendingNotice() {
    if (_downloadState != UpdateDownloadState.ready) return;
    if (_noticeHandled && _installMessage == null) return;
    _noticeVisible = true;
  }

  Future<void> _refreshLocalState() async {
    try {
      _partials = await service.listPartials();
    } catch (_) {
      _partials = const [];
    }
    final release = _release;
    if (release != null) {
      try {
        final ready = await service.existingDownload(release);
        if (ready != null) {
          _readyApk = ready;
          _downloadState = UpdateDownloadState.ready;
          _received = await _lengthOf(ready, _received);
          _total = _received;
          return;
        }
      } catch (_) {
        /* a corrupt handoff file is ignored; the download starts over */
      }
    }
    _readyApk = null;
    if (_downloadState == UpdateDownloadState.downloading ||
        _downloadState == UpdateDownloadState.verifying) {
      return;
    }
    final partial = activePartial;
    if (partial != null) {
      _downloadState = UpdateDownloadState.paused;
      _pauseReason = partial.pausedByUser
          ? UpdatePauseReason.user
          : UpdatePauseReason.network;
      _received = partial.received;
      _total = partial.total > 0 ? partial.total : null;
      return;
    }
    if (_downloadState != UpdateDownloadState.failed) {
      _downloadState = UpdateDownloadState.idle;
    }
    _received = 0;
    _total = release != null && release.apkSize > 0 ? release.apkSize : null;
  }

  Future<int> _lengthOf(File file, int fallback) async {
    try {
      return await file.length();
    } on FileSystemException {
      return fallback;
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    // An app teardown is not a user pause: the fragment stays resumable.
    _download?.cancel(byUser: false);
    unawaited(service.close());
    super.dispose();
  }
}

String readableUpdateError(Object error) => switch (error) {
  GitHubApiException(statusCode: 401) => 'GitHub Token 无效或已过期，请在更新设置中重新配置',
  GitHubApiException(statusCode: 403) => 'GitHub API 请求受限，请配置 Token 后重试',
  GitHubApiException(:final message) => message,
  HttpException(:final message) => message,
  FormatException(:final message) => message,
  _ => '更新失败，请检查网络后重试',
};

/// Subtitle for the settings entry that opens the update page.
String updateEntrySubtitle(UpdateController controller) =>
    updateEntrySubtitleFor(
      tagName: controller.release?.tagName,
      state: controller.downloadState,
      percent: controller.percent,
      received: controller.received,
    );

/// Pure form of [updateEntrySubtitle]: the settings row is the only place the
/// download state is summarised outside the update page.
String updateEntrySubtitleFor({
  required String? tagName,
  required UpdateDownloadState state,
  int? percent,
  int received = 0,
}) {
  final tag = tagName == null ? '' : '发现 $tagName';
  switch (state) {
    case UpdateDownloadState.downloading:
      final suffix = percent == null ? '' : ' $percent%';
      return '${tag.isEmpty ? '正在下载更新' : tag} · 下载中$suffix';
    case UpdateDownloadState.verifying:
      return '正在校验下载文件…';
    case UpdateDownloadState.paused:
      return '已下载 ${updateFormatBytes(received)}，可继续';
    case UpdateDownloadState.ready:
      return '已下载完成，待安装';
    case UpdateDownloadState.failed:
      return '下载失败，可重试';
    case UpdateDownloadState.idle:
      return tag.isEmpty ? '检查最新版本' : tag;
  }
}

String updateFormatBytes(int value) {
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}
