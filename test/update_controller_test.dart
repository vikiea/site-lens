import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/update/update_controller.dart';
import 'package:site_lens/update/update_service.dart';

import 'fake_update_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late Directory handoff;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('site-lens-controller-work-');
    handoff = await Directory.systemTemp.createTemp(
      'site-lens-controller-handoff-',
    );
  });

  tearDown(() async {
    if (await work.exists()) await work.delete(recursive: true);
    if (await handoff.exists()) await handoff.delete(recursive: true);
  });

  ({
    UpdateController controller,
    FakeAssetServer server,
    FakeUpdatePlatform platform,
  })
  build({
    List<Duration> retryDelays = const [],
    int chunkSize = 4096,
    Duration chunkDelay = Duration.zero,
    int? failAfterChunks,
    int failTimes = 0,
    FakeUpdatePlatform? platform,
    int fixtureLength = 64 * 1024,
    String tag = 'v0.2.0',
    String version = '0.1.0',
  }) {
    final server = FakeAssetServer(
      bytes: fixtureBytes(fixtureLength),
      tag: tag,
      chunkSize: chunkSize,
      chunkDelay: chunkDelay,
      failAfterChunks: failAfterChunks ?? -1,
      failTimes: failTimes,
    );
    final fake = platform ?? FakeUpdatePlatform();
    final controller = UpdateController(
      service: fakeUpdateService(
        server: server,
        work: work,
        handoff: handoff,
        platform: fake,
        retryDelays: retryDelays,
        version: version,
      ),
    );
    addTearDown(controller.dispose);
    return (controller: controller, server: server, platform: fake);
  }

  test('checks, downloads and reports a ready APK', () async {
    final harness = build();
    final controller = harness.controller;

    await controller.check();
    expect(controller.release?.tagName, 'v0.2.0');
    expect(controller.currentVersion, '0.1.0');
    expect(controller.downloadState, UpdateDownloadState.idle);

    await controller.startDownload();
    expect(controller.downloadState, UpdateDownloadState.ready);
    expect(controller.percent, 100);
    expect(
      await File(handoffPath(handoff, 'site-lens-v0.2.0.apk')).exists(),
      isTrue,
    );
    expect(controller.noticeVisible, isTrue);
    expect(controller.error, isNull);
  });

  test('reports no update for equal and lower remote versions', () async {
    for (final version in ['0.1.0', '0.2.1']) {
      final harness = build(tag: 'v0.1.0', version: version);
      final controller = harness.controller;

      await controller.check();
      expect(controller.release, isNull);
      expect(controller.checkMessage, '暂无更新');
      expect(controller.error, isNull);
      await controller.startDownload();
      expect(controller.downloadState, UpdateDownloadState.idle);
      expect(harness.server.assetRequests, 0);
    }
  });

  test(
    'keeps the no-update wording when the result comes from cache',
    () async {
      final harness = build(tag: 'v0.1.0');
      final controller = harness.controller;

      await controller.check();
      expect(controller.checkMessage, '暂无更新');
      await controller.check();
      expect(controller.checkMessage, '暂无更新');
    },
  );

  test('keeps API errors separate from the no-update state', () async {
    final service = UpdateService(
      client: GitHubReleaseClient(client: _ForbiddenClient()),
      channel: UpdateChannel.beta,
      packageInfoLoader: () async => fakePackageInfo('0.1.0'),
      workDirectoryLoader: () async => work,
    );
    final controller = UpdateController(service: service);
    addTearDown(controller.dispose);

    await controller.check();

    expect(controller.release, isNull);
    expect(controller.checkMessage, isNull);
    expect(controller.error, 'GitHub API 请求受限，请配置 Token 后重试');
  });

  test('pause keeps the fragment and resume finishes it', () async {
    final harness = build(
      chunkSize: 1024,
      chunkDelay: const Duration(milliseconds: 5),
    );
    final controller = harness.controller;
    await controller.check();

    unawaited(controller.startDownload());
    await _waitFor(() => controller.received > 8192);
    controller.pause();
    await _waitFor(
      () => controller.downloadState == UpdateDownloadState.paused,
    );

    expect(controller.pauseReason, UpdatePauseReason.user);
    final retained = controller.received;
    expect(retained, greaterThan(0));
    expect(await File(partialPath(work, 'v0.2.0')).exists(), isTrue);

    await controller.resume();
    expect(controller.downloadState, UpdateDownloadState.ready);
    expect(harness.server.ranges.last, 'bytes=$retained-');
  });

  test('deleting the download clears the fragment and the state', () async {
    final harness = build(
      chunkSize: 1024,
      chunkDelay: const Duration(milliseconds: 5),
    );
    final controller = harness.controller;
    await controller.check();

    unawaited(controller.startDownload());
    await _waitFor(() => controller.received > 4096);
    await controller.deleteDownload();

    expect(controller.downloadState, UpdateDownloadState.idle);
    expect(controller.received, 0);
    expect(controller.noticeVisible, isFalse);
    expect(await File(partialPath(work, 'v0.2.0')).exists(), isFalse);
    expect(await File(partialMetaPath(work, 'v0.2.0')).exists(), isFalse);
  });

  test('a network pause stays resumable and reports the break', () async {
    final harness = build(
      chunkSize: 1024,
      failAfterChunks: 2,
      failTimes: 10,
      retryDelays: const [Duration.zero],
    );
    final controller = harness.controller;
    await controller.check();
    await controller.startDownload();

    expect(controller.downloadState, UpdateDownloadState.paused);
    expect(controller.pauseReason, UpdatePauseReason.network);
    expect(controller.error, isNotNull);
    expect(controller.received, greaterThan(0));
  });

  test('surfaces an older unfinished download and can clean it', () async {
    final harness = build(fixtureLength: 4096);
    final controller = harness.controller;
    final older = ReleaseInfo(
      tagName: 'v0.1.0',
      version: const AppVersion(0, 1, 0),
      body: '',
      htmlUrl: Uri.parse('https://github.com/vikiea/site-lens/releases/tag'),
      apkUrl: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/download/v0.1.0/site-lens-v0.1.0.apk',
      ),
      apkName: 'site-lens-v0.1.0.apk',
      apkSize: 4096,
      sha256: 'c' * 64,
    );
    await writePartial(
      work,
      release: older,
      prefix: fixtureBytes(4096).sublist(0, 1024),
    );

    await controller.check();
    expect(controller.release?.tagName, 'v0.2.0');
    expect(controller.stalePartials.single.tagName, 'v0.1.0');

    await controller.deleteStalePartials();
    expect(controller.stalePartials, isEmpty);
    expect(await File(partialPath(work, 'v0.1.0')).exists(), isFalse);
  });

  test('resumes an unfinished download when the page opens', () async {
    final harness = build(fixtureLength: 16 * 1024);
    final controller = harness.controller;
    final release = harness.server.release();
    await writePartial(
      work,
      release: release,
      prefix: fixtureBytes(16 * 1024).sublist(0, 4096),
      etag: harness.server.etag,
    );

    await controller.openUpdatePage();
    await _waitFor(() => controller.downloadState == UpdateDownloadState.ready);

    expect(harness.server.ranges.first, 'bytes=4096-');
    expect(controller.release?.tagName, 'v0.2.0');
  });

  test('a user pause survives a restart until the user continues', () async {
    final harness = build(fixtureLength: 16 * 1024);
    final controller = harness.controller;
    final release = harness.server.release();
    await writePartial(
      work,
      release: release,
      prefix: fixtureBytes(16 * 1024).sublist(0, 4096),
      etag: harness.server.etag,
      pausedByUser: true,
    );

    await controller.openUpdatePage();

    // The page learns the release from the check but never continues a
    // download the user paused themselves.
    expect(controller.release?.tagName, 'v0.2.0');
    expect(controller.downloadState, UpdateDownloadState.paused);
    expect(controller.pauseReason, UpdatePauseReason.user);
    expect(controller.received, 4096);
    expect(harness.server.assetRequests, 0);

    await controller.resume();
    expect(controller.downloadState, UpdateDownloadState.ready);
  });

  test('a network pause resumes when the page opens again', () async {
    final harness = build(
      chunkSize: 1024,
      failAfterChunks: 2,
      failTimes: 1,
      retryDelays: const [],
    );
    final controller = harness.controller;
    await controller.check();
    await controller.startDownload();
    expect(controller.downloadState, UpdateDownloadState.paused);
    expect(controller.pauseReason, UpdatePauseReason.network);

    // Re-entering the page continues the fragment without another check.
    await controller.openUpdatePage();
    await _waitFor(() => controller.downloadState == UpdateDownloadState.ready);
    expect(harness.server.ranges.first, isNull);
    // Two chunks of 1024 bytes were flushed before the break.
    expect(harness.server.ranges.last, 'bytes=2048-');
  });

  test('reports no stale fragment before the release is known', () async {
    final harness = build(fixtureLength: 4096);
    final controller = harness.controller;
    final release = harness.server.release();
    await writePartial(
      work,
      release: release,
      prefix: fixtureBytes(4096).sublist(0, 512),
      etag: harness.server.etag,
    );

    await controller.loadLocalState();

    expect(controller.release, isNull);
    expect(controller.stalePartials, isEmpty);
    expect(controller.downloadState, UpdateDownloadState.paused);
    // The unknown release blocks the stale-kind cleanup from deleting it.
    await controller.deleteStalePartials();
    expect(await File(partialPath(work, release.tagName)).exists(), isTrue);
  });

  test('keeps the notice until the user handles it', () async {
    final harness = build();
    final controller = harness.controller;
    await controller.check();
    await controller.startDownload();
    expect(controller.noticeVisible, isTrue);

    controller.dismissNotice();
    expect(controller.noticeVisible, isFalse);
    controller.drainPendingNotice();
    expect(controller.noticeVisible, isFalse);
  });

  test('holds the notice while the update page is open', () async {
    final harness = build();
    final controller = harness.controller;
    controller.setUpdateScreenVisible(true);
    await controller.check();
    await controller.startDownload();

    expect(controller.downloadState, UpdateDownloadState.ready);
    expect(controller.noticeVisible, isFalse);

    controller.setUpdateScreenVisible(false);
    expect(controller.noticeVisible, isTrue);
  });

  test('summarises download state for the settings entry', () {
    expect(
      updateEntrySubtitleFor(tagName: null, state: UpdateDownloadState.idle),
      '检查最新版本',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: 'v0.2.0',
        state: UpdateDownloadState.idle,
      ),
      '发现 v0.2.0',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: 'v0.2.0',
        state: UpdateDownloadState.downloading,
        percent: 45,
      ),
      '发现 v0.2.0 · 下载中 45%',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: null,
        state: UpdateDownloadState.downloading,
      ),
      '正在下载更新 · 下载中',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: 'v0.2.0',
        state: UpdateDownloadState.verifying,
      ),
      '正在校验下载文件…',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: 'v0.2.0',
        state: UpdateDownloadState.paused,
        received: 12 * 1024 * 1024,
      ),
      '已下载 12.0 MB，可继续',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: 'v0.2.0',
        state: UpdateDownloadState.ready,
      ),
      '已下载完成，待安装',
    );
    expect(
      updateEntrySubtitleFor(
        tagName: 'v0.2.0',
        state: UpdateDownloadState.failed,
      ),
      '下载失败，可重试',
    );
  });

  test('asks for the install permission before handing the APK over', () async {
    final platform = FakeUpdatePlatform(canInstall: false);
    final harness = build(platform: platform);
    final controller = harness.controller;
    await controller.check();
    await controller.startDownload();

    await controller.install();
    expect(platform.permissionRequests, 1);
    expect(platform.installed, isEmpty);
    expect(controller.installMessage, isNotNull);
    expect(controller.noticeVisible, isTrue);

    platform.canInstall = true;
    await controller.install();
    expect(platform.installed.single.path, controller.readyApk!.path);
    expect(controller.installMessage, isNull);
  });

  test('reports an install failure without losing the APK', () async {
    final platform = _FailingInstallPlatform();
    final harness = build(platform: platform);
    final controller = harness.controller;
    await controller.check();
    await controller.startDownload();

    await controller.install();
    expect(controller.error, 'APK SHA-256 校验失败');
    expect(controller.downloadState, UpdateDownloadState.ready);
    expect(await controller.readyApk!.exists(), isTrue);
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Mirrors the native channel: a rejected APK arrives as a PlatformException
/// whose message is what the user must see.
class _FailingInstallPlatform extends FakeUpdatePlatform {
  @override
  Future<void> verifyAndInstall(File apk, ReleaseInfo release) async {
    throw PlatformException(
      code: 'digest_mismatch',
      message: 'APK SHA-256 校验失败',
    );
  }
}

class _ForbiddenClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.value(const <int>[]),
        403,
        request: request,
      );
}
