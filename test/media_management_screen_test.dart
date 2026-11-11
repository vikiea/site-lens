import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_organization.dart';
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

  test('direct storage detects an existing playable episode file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'site-lens-direct-existing-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/示例系列/第1集.mp4');
    await target.parent.create(recursive: true);
    await target.writeAsBytes([1, 2, 3]);
    await app.updateSettings({
      'mediaStorageMode': 'direct_path',
      'mp4ExportDirectory': directory.path,
    });
    final media = MediaCandidate(
      id: 'existing-direct',
      hostId: 0,
      generation: 0,
      sourceUrl: Uri.parse('https://example.test/video/1/'),
      mediaUrl: Uri.parse('https://cdn.example/existing-direct.m3u8'),
      title: '示例系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
      episodeNumber: 1,
    );

    expect(
      await app.hasPlayableEpisodeInGroup(group: '示例系列', candidate: media),
      isTrue,
    );
    expect(
      await app.hasPlayableEpisodeInGroup(group: '另一个系列', candidate: media),
      isFalse,
    );

    await app.updateSettings({'mp4ExportDirectory': null});
    expect(
      await app.hasPlayableEpisodeInGroup(group: '示例系列', candidate: media),
      isFalse,
    );
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

  testWidgets('media organization survives media page replacement', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: MediaLibraryScreen(app: app),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: MediaManagementScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('media management exposes native background playback setting', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: MediaManagementScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('后台播放'), findsOneWidget);
    expect(find.text('当前标签后台播放'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'media task route pops back to the media page instead of exiting the app',
    (tester) async {
      var rootBacks = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: MediaLibraryScreen(app: app, onRootBack: () => rootBacks++),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('媒体任务'));
      await tester.pumpAndSettle();
      expect(find.text('媒体任务'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(rootBacks, 0);
      expect(find.byTooltip('媒体任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('queued tasks expose the shared batch pause action', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await app.mediaTasks.ready;
      for (var episode = 1; episode <= 2; episode++) {
        final candidate = MediaCandidate(
          id: 'queued-$episode',
          hostId: 0,
          generation: 0,
          sourceUrl: Uri.parse('https://example.test/video/1/'),
          mediaUrl: Uri.parse('https://cdn.example/queued-$episode.mp4'),
          title: '排队测试 - 第$episode集',
          mime: 'video/mp4',
          source: MediaCandidateSource.dom,
          episodeNumber: episode,
        );
        await db.saveMediaCandidate(candidate);
        await app.mediaTasks.create(candidate);
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: MediaTasksScreen(app: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();

    expect(find.text('批量暂停下载'), findsOneWidget);
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

  testWidgets(
    'media task back gesture folds the current folder before root back',
    (tester) async {
      final organization = MediaOrganizationService(
        db: db,
        collection: 'tasks',
      );
      await organization.restore();
      await organization.createFolder('返回测试文件夹');
      var rootBacks = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: MediaTasksScreen(app: app, onRootBack: () => rootBacks++),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('返回测试文件夹'));
      await tester.pumpAndSettle();
      expect(find.textContaining('返回上一级'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.textContaining('返回上一级'), findsNothing);
      expect(find.text('返回测试文件夹'), findsOneWidget);
      expect(rootBacks, 0);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(rootBacks, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
        const explanation = '迁移会保留媒体身份并校验文件内容；权限失效或同名冲突时不会删除源文件。';
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
        final directoryRow = row('媒体库目录');
        final restoreRow = row('迁移应用媒体库');
        final directoryHeight = tester.getSize(directoryRow).height;
        final restoreHeight = tester.getSize(restoreRow).height;
        expect(find.byType(SiteLensPanel), findsNWidgets(2));
        expect(find.byType(ListView), findsOneWidget);
        expect(find.text(readable), findsNothing);

        await tester.tap(find.text('媒体库目录'));
        await tester.pumpAndSettle();
        expect(find.text(readable), findsOneWidget);
        expect(find.text('更换媒体目录'), findsOneWidget);
        expect(tester.getSize(directoryRow).height, directoryHeight);
        final fullPath = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(fullPath.data, readable);
        expect(fullPath.maxLines, isNull);

        await tester.ensureVisible(restoreRow);
        await tester.tap(find.text('迁移应用媒体库'));
        await tester.pumpAndSettle();
        expect(find.text(readable), findsNothing);
        expect(find.text(explanation), findsOneWidget);
        expect(tester.getSize(restoreRow).height, restoreHeight);
        expect(tester.getSize(directoryRow).height, directoryHeight);
        expect(find.text('清除媒体目录配置'), findsOneWidget);
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

  testWidgets(
    'media management exposes quiet refresh and concurrency settings',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.light),
          home: MediaManagementScreen(app: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自动同步媒体目录'), findsOneWidget);
      expect(find.text('下载并发数量'), findsOneWidget);
      expect(find.text('同时下载的媒体任务数量，范围 1 到 6'), findsOneWidget);
      expect(find.text('导出 MP4 后删除任务和缓存'), findsOneWidget);
      expect(app.deleteMediaTaskAfterMp4Export, isFalse);
      await tester.tap(find.text('导出 MP4 后删除任务和缓存'));
      await tester.pumpAndSettle();
      expect(app.deleteMediaTaskAfterMp4Export, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
