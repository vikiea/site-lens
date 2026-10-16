import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/software_update_screen.dart';
import 'package:site_lens/update/update_controller.dart';
import 'package:site_lens/update/update_service.dart';

import 'fake_update_platform.dart';
import 'update_widget_support.dart';

/// The update engine reads and writes real files, which the widget test's fake
/// clock does not drive. Transfers therefore run inside
/// [WidgetTester.runAsync], while every widget assertion is made on a tree the
/// test renders explicitly afterwards.
void main() {
  late Directory work;
  late Directory handoff;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('site-lens-screen-work-');
    handoff = await Directory.systemTemp.createTemp(
      'site-lens-screen-handoff-',
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
  build({int chunkSize = 1024, Duration chunkDelay = Duration.zero}) {
    final server = FakeAssetServer(
      bytes: fixtureBytes(),
      chunkSize: chunkSize,
      chunkDelay: chunkDelay,
    );
    final platform = FakeUpdatePlatform();
    final controller = UpdateController(
      service: fakeUpdateService(
        server: server,
        work: work,
        handoff: handoff,
        platform: platform,
      ),
    );
    addTearDown(controller.dispose);
    return (controller: controller, server: server, platform: platform);
  }

  Widget screenApp(UpdateController controller) => ProviderScope(
    overrides: [updateControllerProvider.overrideWithValue(controller)],
    child: const MaterialApp(home: SoftwareUpdateScreen()),
  );

  testWidgets('renders the download lifecycle and installs from the page', (
    tester,
  ) async {
    final harness = build(
      chunkSize: 512,
      chunkDelay: const Duration(milliseconds: 2),
    );
    final controller = harness.controller;
    final app = screenApp(controller);
    await tester.pumpWidget(app);
    await tester.pump();
    expect(find.text('下载更新'), findsNothing);

    await runReal(tester, () => controller.check());
    await renderScreen(
      tester,
      app,
      () => find.text('下载更新').evaluate().isNotEmpty,
    );
    expect(find.text('v0.2.0'), findsOneWidget);

    await runReal(tester, () async {
      unawaited(controller.startDownload());
      await realWait(() => controller.received > 4096);
    });
    await renderScreen(
      tester,
      app,
      () => find.textContaining('正在下载').evaluate().isNotEmpty,
    );
    expect(find.textContaining('· 离开页面后会继续'), findsOneWidget);
    await tapVisible(tester, find.text('暂停'));

    await waitFor(
      tester,
      () => controller.downloadState == UpdateDownloadState.paused,
    );
    await renderScreen(
      tester,
      app,
      () => find.textContaining('已暂停').evaluate().isNotEmpty,
    );
    expect(find.textContaining('已暂停'), findsOneWidget);
    expect(find.text('继续下载'), findsOneWidget);
    expect(controller.pauseReason, UpdatePauseReason.user);
    expect(
      await tester.runAsync(() => File(partialPath(work, 'v0.2.0')).exists()),
      isTrue,
    );

    // Finishing while the page is visible continues into the installer.
    await runReal(tester, () async {
      unawaited(controller.resume());
      await realWait(() => harness.platform.installed.isNotEmpty);
    });
    await renderScreen(
      tester,
      app,
      () => find.text('安装更新').evaluate().isNotEmpty,
    );
    expect(find.text('安装更新'), findsOneWidget);
    expect(find.textContaining('已下载完成'), findsOneWidget);
    expect(controller.noticeVisible, isFalse);
  });

  testWidgets('leaving the page keeps the download running', (tester) async {
    final harness = build(
      chunkSize: 512,
      chunkDelay: const Duration(milliseconds: 2),
    );
    final controller = harness.controller;
    await tester.pumpWidget(screenApp(controller));
    await tester.pump();

    await runReal(tester, () async {
      await controller.check();
      unawaited(controller.startDownload());
      await realWait(() => controller.received > 4096);
    });
    expect(controller.updateScreenVisible, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(controller.updateScreenVisible, isFalse);

    await waitFor(
      tester,
      () => controller.downloadState == UpdateDownloadState.ready,
    );
    expect(harness.platform.installed, isEmpty);
    expect(controller.noticeVisible, isTrue);
  });

  testWidgets('offers to clean an unfinished older download', (tester) async {
    final harness = build();
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
    await tester.runAsync(
      () => writePartial(
        work,
        release: older,
        prefix: fixtureBytes(4096).sublist(0, 1024),
      ),
    );
    final app = screenApp(controller);
    await tester.pumpWidget(app);
    await tester.pump();

    await runReal(tester, () => controller.check());
    await renderScreen(
      tester,
      app,
      () => find.text('存在旧版本未完成下载').evaluate().isNotEmpty,
    );
    expect(find.textContaining('v0.1.0'), findsWidgets);
    expect(find.text('清理'), findsOneWidget);
  });

  testWidgets('shows a checksum failure and keeps no fragment', (tester) async {
    final server = FakeAssetServer(
      bytes: fixtureBytes(4096),
      advertisedSha256: 'b' * 64,
    );
    final platform = FakeUpdatePlatform();
    final controller = UpdateController(
      service: fakeUpdateService(
        server: server,
        work: work,
        handoff: handoff,
        platform: platform,
      ),
    );
    addTearDown(controller.dispose);
    final app = screenApp(controller);
    await tester.pumpWidget(app);
    await tester.pump();

    await runReal(tester, () => controller.check());
    await runReal(tester, () => controller.startDownload());
    await renderScreen(
      tester,
      app,
      () => find.textContaining('APK 校验失败').evaluate().isNotEmpty,
    );

    expect(find.textContaining('APK 校验失败'), findsOneWidget);
    expect(find.text('重新下载'), findsOneWidget);
    expect(platform.installed, isEmpty);
    expect(
      await tester.runAsync(() => File(partialPath(work, 'v0.2.0')).exists()),
      isFalse,
    );
  });
}
