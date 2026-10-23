import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'fake_web_host_api.dart';

void main() {
  late AppDatabase db;
  late AppController app;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = AppController(db, api: FakeWebHostApi());
    await app.load();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'media details keep compact headers and readable full paths in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1200);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        const directory = '/storage/emulated/0/Movies/系统带我攻略弟弟（漫剧版）/完整媒体导出保存目录';
        const readable = '内部存储/Movies/系统带我攻略弟弟（漫剧版）/完整媒体导出保存目录';
        const explanation = '清除目录配置后，后续 MP4 只保存在应用媒体库。已导出的文件不会被删除。';
        app.mp4ExportDirectory = directory;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(ThemePresetId.mistPine, brightness),
            builder: (context, child) => SiteLensGlassPolicyScope(
              strategy: const SiteLensGlassQualityStrategy(
                shaderSupported: true,
              ),
              child: SiteLensBackdrop(child: child!),
            ),
            home: ListenableBuilder(
              listenable: app,
              builder: (_, _) => MediaManagementScreen(app: app),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Finder row(String title) => find.ancestor(
          of: find.text(title),
          matching: find.byType(SiteLensCompactRow),
        );
        final directoryRow = row('MP4 保存目录');
        final restoreRow = row('恢复应用媒体库');
        final directoryHeight = tester.getSize(directoryRow).height;
        final restoreHeight = tester.getSize(restoreRow).height;
        expect(find.byType(SiteLensPanel), findsOneWidget);
        expect(find.byType(Scrollable), findsOneWidget);
        expect(find.text(readable), findsNothing);

        await tester.tap(find.text('MP4 保存目录'));
        await tester.pumpAndSettle();
        expect(find.text(readable), findsOneWidget);
        expect(find.text('更换保存目录'), findsOneWidget);
        expect(tester.getSize(directoryRow).height, directoryHeight);
        final fullPath = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(fullPath.data, readable);
        expect(fullPath.maxLines, isNull);

        await tester.ensureVisible(restoreRow);
        await tester.tap(find.text('恢复应用媒体库'));
        await tester.pumpAndSettle();
        expect(find.text(readable), findsNothing);
        expect(find.text(explanation), findsOneWidget);
        expect(tester.getSize(restoreRow).height, restoreHeight);
        expect(tester.getSize(directoryRow).height, directoryHeight);
        expect(find.text('清除目录配置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
