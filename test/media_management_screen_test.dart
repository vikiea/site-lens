import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
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

  testWidgets('media library selection keeps every top-bar action visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: MediaLibraryScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('选择媒体'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('全选'), findsOneWidget);
    expect(find.byTooltip('批量操作'), findsOneWidget);
    expect(find.byTooltip('清除选择'), findsOneWidget);
    expect(find.byTooltip('退出选择'), findsOneWidget);
    expect(
      tester.getSize(find.byType(SiteLensTopBarActionGroup)).width,
      greaterThan(150),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('media task selection keeps every top-bar action visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: MediaTasksScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('选择任务'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('全选'), findsOneWidget);
    expect(find.byTooltip('批量操作'), findsOneWidget);
    expect(find.byTooltip('清除选择'), findsOneWidget);
    expect(find.byTooltip('退出选择'), findsOneWidget);
    expect(
      tester.getSize(find.byType(SiteLensTopBarActionGroup)).width,
      greaterThan(150),
    );
    expect(tester.takeException(), isNull);
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
                lightweightShaderSupported: true,
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
        expect(find.byType(SiteLensPanel), findsNWidgets(2));
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

  testWidgets('media management exposes durable watch saves', (tester) async {
    final now = DateTime(2026, 10, 24, 20, 30);
    await db.saveWatchSave(
      WatchSave(
        ownerId: 'watch:test',
        sourceKey: 'series\u0000episode\u00001\u0000source',
        sourceUrl: Uri.parse('https://media.example.test/episode-1.m3u8'),
        seriesKey: 'series',
        episodeNumber: 1,
        title: '示例剧集',
        pageUrl: Uri.parse('https://example.test/watch/1'),
        hostId: 1,
        generation: 2,
        state: WatchSaveState.paused,
        createdAt: now,
        updatedAt: now,
        positionMs: 30_000,
        durationMs: 120_000,
      ),
    );
    await app.watchSaves.reload();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.light),
        home: MediaManagementScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();
    final watchRow = find.ancestor(
      of: find.text('示例剧集'),
      matching: find.byType(SiteLensCompactRow),
    );
    final detailsButton = find.descendant(
      of: watchRow,
      matching: find.byType(SiteLensCompactIconButton),
    );
    expect(detailsButton, findsOneWidget);
    await tester.tap(detailsButton);
    await tester.pumpAndSettle();
    expect(
      find.text('第 1 集 · 00:30 / 02:00 · 已暂停 · 10-24 20:30'),
      findsOneWidget,
    );

    expect(find.text('观看保存'), findsOneWidget);
    expect(find.text('示例剧集'), findsOneWidget);
    expect(find.textContaining('第 1 集'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty watch saves explain and toggle from media management', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.light),
        home: MediaManagementScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无记录，自动保存已关闭'), findsOneWidget);
    expect(find.text('已关闭，点击开启；不会创建下载任务'), findsOneWidget);

    await tester.tap(find.text('自动保存网页观看记录'));
    await tester.runAsync(() async {
      for (
        var attempt = 0;
        attempt < 100 && !app.autoSaveWebPlayback;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(app.autoSaveWebPlayback, isTrue);
    expect(find.text('已开启，等待有效播放记录'), findsOneWidget);
    expect(find.text('已开启，稳定识别后保存播放进度'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
