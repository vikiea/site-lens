import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/update_notice.dart';
import 'package:site_lens/update/update_controller.dart';

import 'fake_update_platform.dart';
import 'update_widget_support.dart';

void main() {
  late Directory work;
  late Directory handoff;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('site-lens-notice-work-');
    handoff = await Directory.systemTemp.createTemp(
      'site-lens-notice-handoff-',
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
  build() {
    final server = FakeAssetServer(bytes: fixtureBytes(4096));
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

  Widget noticeApp(UpdateController controller) => ProviderScope(
    overrides: [updateControllerProvider.overrideWithValue(controller)],
    child: MaterialApp(
      navigatorKey: siteLensNavigatorKey,
      builder: (context, child) =>
          SiteLensUpdateNoticeLayer(child: child ?? const SizedBox()),
      home: const Scaffold(body: Center(child: Text('首页'))),
    ),
  );

  /// Runs the notice's entrance animation to completion so its controls are
  /// reachable by a tap.
  Future<void> appear(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  Future<void> reachReady(
    WidgetTester tester,
    UpdateController controller,
  ) async {
    await runReal(tester, () => controller.check());
    await runReal(tester, () => controller.startDownload());
    expect(controller.downloadState, UpdateDownloadState.ready);
  }

  testWidgets('shows the completed download and dismisses itself', (
    tester,
  ) async {
    final harness = build();
    final controller = harness.controller;
    await tester.pumpWidget(noticeApp(controller));
    expect(find.textContaining('已下载完成'), findsNothing);

    await runReal(tester, () => controller.check());
    await runReal(tester, () => controller.startDownload());
    await renderScreen(
      tester,
      noticeApp(controller),
      () => find.textContaining('已下载完成').evaluate().isNotEmpty,
    );

    expect(find.textContaining('Site Lens v0.2.0 已下载完成'), findsOneWidget);
    expect(find.text('查看更新'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    expect(find.textContaining('已下载完成'), findsNothing);
    expect(controller.noticeVisible, isFalse);
    // Dismissed for good: it does not come back for this download.
    controller.drainPendingNotice();
    await tester.pump();
    expect(find.textContaining('已下载完成'), findsNothing);
  });

  testWidgets('can be swiped away', (tester) async {
    final harness = build();
    final controller = harness.controller;
    await tester.pumpWidget(noticeApp(controller));
    await reachReady(tester, controller);
    await renderScreen(
      tester,
      noticeApp(controller),
      () => find.textContaining('已下载完成').evaluate().isNotEmpty,
    );

    await appear(tester);
    await tester.drag(
      find.byKey(const ValueKey('site-lens-update-notice')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('已下载完成'), findsNothing);
    expect(controller.noticeVisible, isFalse);
  });

  testWidgets('opens the update page from the notice', (tester) async {
    final harness = build();
    final controller = harness.controller;
    await tester.pumpWidget(noticeApp(controller));
    await reachReady(tester, controller);
    await appear(tester);

    await tester.tap(find.text('查看更新'));
    await tester.pumpAndSettle();

    expect(find.text('软件更新'), findsOneWidget);
    expect(controller.updateScreenVisible, isTrue);
    expect(controller.noticeVisible, isFalse);
  });

  testWidgets('installs straight from the notice', (tester) async {
    final harness = build();
    final controller = harness.controller;
    await tester.pumpWidget(noticeApp(controller));
    await reachReady(tester, controller);
    await appear(tester);

    await tester.tap(find.text('安装'));
    await tester.pump();

    expect(harness.platform.installed, hasLength(1));
    expect(harness.platform.installed.single.path, controller.readyApk!.path);
  });

  testWidgets('stays hidden while the update page is open', (tester) async {
    final harness = build();
    final controller = harness.controller;
    controller.setUpdateScreenVisible(true);
    await tester.pumpWidget(noticeApp(controller));
    await reachReady(tester, controller);
    await tester.pump();

    expect(find.textContaining('已下载完成'), findsNothing);
    expect(controller.noticeVisible, isFalse);

    controller.setUpdateScreenVisible(false);
    await tester.pump();
    expect(find.textContaining('已下载完成'), findsOneWidget);
  });

  testWidgets('keeps a background completion until the app returns', (
    tester,
  ) async {
    final harness = build();
    final controller = harness.controller;
    await tester.pumpWidget(noticeApp(controller));
    await runReal(tester, () => controller.check());

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    await runReal(tester, () => controller.startDownload());
    await tester.pump();
    expect(controller.downloadState, UpdateDownloadState.ready);
    expect(controller.noticeVisible, isFalse);
    expect(find.textContaining('已下载完成'), findsNothing);

    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.noticeVisible, isTrue);
    expect(find.textContaining('已下载完成'), findsOneWidget);
  });

  testWidgets('explains a blocked install without hiding the notice', (
    tester,
  ) async {
    final platform = FakeUpdatePlatform(canInstall: false);
    final server = FakeAssetServer(bytes: fixtureBytes(4096));
    final controller = UpdateController(
      service: fakeUpdateService(
        server: server,
        work: work,
        handoff: handoff,
        platform: platform,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(noticeApp(controller));
    await reachReady(tester, controller);
    await appear(tester);

    await tester.tap(find.text('安装'));
    await tester.pump();

    expect(platform.permissionRequests, 1);
    expect(platform.installed, isEmpty);
    expect(find.textContaining('请允许 Site Lens 安装未知来源应用'), findsOneWidget);
    expect(controller.noticeVisible, isTrue);

    // Guidance stays on screen instead of timing out.
    await tester.pump(const Duration(seconds: 7));
    expect(find.textContaining('请允许 Site Lens 安装未知来源应用'), findsOneWidget);
  });
}
