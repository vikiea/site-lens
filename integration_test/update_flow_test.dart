import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/update/update_controller.dart';

import '../test/fake_update_platform.dart';

Future<void> _wait(
  WidgetTester tester,
  bool Function() condition,
  String message,
) async {
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail(message);
}

/// The update download runs against an in-memory release asset server, so the
/// flow is exercised on a device without reaching GitHub.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'update download survives leaving the page and installs from the notice',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      final root = await getApplicationSupportDirectory();
      final work = Directory('${root.path}/site-lens-update-acceptance');
      final handoff = Directory(
        '${(await getTemporaryDirectory()).path}/site-lens-update-acceptance',
      );
      final server = FakeAssetServer(
        bytes: fixtureBytes(64 * 1024),
        chunkSize: 2048,
        chunkDelay: const Duration(milliseconds: 20),
      );
      final platform = FakeUpdatePlatform();
      final update = UpdateController(
        service: fakeUpdateService(
          server: server,
          work: work,
          handoff: handoff,
          platform: platform,
        ),
      );
      addTearDown(() async {
        update.dispose();
        for (final directory in [work, handoff]) {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        }
        await db.close();
      });
      try {
        await app.load();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appControllerProvider.overrideWithValue(app),
              updateControllerProvider.overrideWithValue(update),
            ],
            child: const SiteLensApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('关于与更新'),
          200,
          scrollable: find.byType(Scrollable),
        );
        await tester.tap(find.text('关于与更新'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('软件更新'),
          200,
          scrollable: find.byType(Scrollable),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('软件更新'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('检查更新'));
        await _wait(
          tester,
          () => find.text('下载更新').evaluate().isNotEmpty,
          'the update page never offered the download',
        );
        await tester.tap(find.text('下载更新'));
        await _wait(
          tester,
          () => update.received > 8192,
          'the download never reported progress',
        );
        expect(find.text('暂停'), findsOneWidget);

        // Leave the page: the transfer keeps running in the controller.
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(update.updateScreenVisible, isFalse);

        await _wait(
          tester,
          () => update.downloadState == UpdateDownloadState.ready,
          'the download did not finish after leaving the page',
        );
        await tester.pumpAndSettle();
        expect(platform.installed, isEmpty);
        // The settings row also reports the completed state, so the notice is
        // matched by its own title.
        expect(find.text('Site Lens v0.2.0 已下载完成'), findsOneWidget);

        await tester.tap(find.text('查看更新'));
        await tester.pumpAndSettle();
        await _wait(
          tester,
          () => find.text('安装更新').evaluate().isNotEmpty,
          'the update page did not offer the install action',
        );
        await tester.tap(find.text('安装更新'));
        await _wait(
          tester,
          () => platform.installed.isNotEmpty,
          'the update page did not hand the APK to the installer',
        );
        expect(platform.installed.single.path, update.readyApk!.path);
      } finally {
        await app.shutdown();
      }
    },
  );
}
