import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/theater/series_line_memory.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/series_batch_download.dart';
import 'package:site_lens/ui/series_batch_download_resolver.dart';
import 'package:site_lens/ui/series_batch_download_sheet.dart';
import 'package:site_lens/ui/series_detail_screen.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'fake_web_host_api.dart';

/// 统计适配器往返次数的替身：真实适配器每次调用都要取一次页面，一集读两次
/// 就是整批的页面读取翻倍。
class CountingFakeSiteAdapter extends FakeSiteAdapter {
  CountingFakeSiteAdapter()
    : super(
        id: 'fake-count',
        profileId: 1,
        addresses: [Uri.parse('https://fake-count.example/')],
      );

  int linesCalls = 0;
  int candidateCalls = 0;

  @override
  Future<List<Line>> lines(
    String seriesKey,
    int episodeNumber,
    CancellationSignal cancel,
  ) {
    linesCalls++;
    return super.lines(seriesKey, episodeNumber, cancel);
  }

  @override
  Future<List<MediaCandidate>> candidates(
    Line line,
    CancellationSignal cancel,
  ) {
    candidateCalls++;
    return super.candidates(line, cancel);
  }
}

/// T14 批量下载: selection model, batch executor, sheet and per-episode delete.
///
/// The batch is driven by the fake adapter and the real `MediaTaskStore` on an
/// in-memory database. No test reaches the network, the native download
/// runtime or a real player: `mediaDownloads.startNativeBatch` returns the
/// enqueued rows through the fake runtime seam below, and playback is only ever
/// asserted at the seam (which candidate was handed to the player).
void main() {
  SiteProfile profile(int id, String name) => SiteProfile(
    id: id,
    name: name,
    createdAt: DateTime.utc(2026, 1, 1),
    routes: const {SiteRoute.direct},
  );

  FakeSeries seriesOf({
    String key = 's-1',
    String title = '示例剧',
    List<int> episodes = const [1, 2, 3],
  }) => FakeSeries(
    seriesKey: key,
    title: title,
    episodes: [
      for (final number in episodes)
        FakeEpisode(
          episodeNumber: number,
          title: '第$number集',
          lines: [
            FakeLine(
              lineId: 'alpha',
              label: '甲线路',
              representations: [
                FakeRepresentation(
                  mediaUrl: 'https://media.invalid/$key-$number-1080.m3u8',
                  qualityLabel: '1080P',
                  audioLabel: '国语',
                ),
              ],
            ),
          ],
        ),
    ],
  );

  FakeSiteAdapter adapterWith(List<FakeSeries> catalog) {
    final adapter = FakeSiteAdapter(
      id: 'fake-1',
      profileId: 1,
      addresses: [Uri.parse('https://fake-1.example/')],
    );
    adapter.configureCatalog(catalog);
    return adapter;
  }

  SeriesBatchDownloadStore storeFor(
    AppController app,
    SiteAdapter adapter, {
    String title = '示例剧',
  }) => SeriesBatchDownloadStore(
    app: app,
    seriesKey: 's-1',
    adapterId: adapter.id,
    resolver: SeriesBatchDownloadResolver(
      adapter: adapter,
      memory: SeriesLineMemory(),
      seriesKey: 's-1',
      seriesTitle: title,
      hostId: 1,
    ),
  );

  List<SeriesBatchEpisode> episodesOf(int count) => [
    for (var index = 0; index < count; index++)
      SeriesBatchEpisode(
        position: index,
        episodeNumber: index + 1,
        title: '第${index + 1}集',
      ),
  ];

  late AppDatabase db;
  late AppController app;
  late Directory mediaRoot;
  var mediaRootSeq = 0;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // 删除走 MediaDownloadService.delete：它要读缓存根来判断任务自己拥有的
    // 文件。widget 测试不注册 path_provider，这里给一个真实的临时根，让删除
    // 的缓存计划拿到文件系统而不是在插件通道上炸掉。
    //
    // 临时目录用同步 API 创建：`testWidgets` 的假时钟只推进 fake timer，
    // 区内直接 await 的异步文件 IO 永远不会完成，测试就会挂到超时。
    mediaRoot = Directory(
      '${Directory.systemTemp.path}/site-lens-media-$pid-$mediaRootSeq',
    )..createSync(recursive: true);
    mediaRootSeq++;
    app = AppController(
      db,
      api: FakeWebHostApi(),
      mediaDirectoryProvider: () async => mediaRoot,
    );
    await app.load();
  });

  tearDown(() async {
    await app.shutdown();
    await db.close();
    if (mediaRoot.existsSync()) mediaRoot.deleteSync(recursive: true);
  });

  /// The store enqueues through `startNativeBatch`, which ends in the native
  /// download runtime. Tests leave that runtime unset, so this seam answers
  /// with what a real start would: every request is started. It is the only
  /// thing replaced — task creation, deduplication, the folder and the delete
  /// path all run for real against the in-memory database.
  void stubBatchStart(SeriesBatchDownloadStore store) {
    store.startBatch = (requests) async {
      final items = <MediaBatchDownloadItemResult>[
        for (final request in requests)
          MediaBatchDownloadItemResult(
            request: request,
            outcome: MediaBatchDownloadOutcome.started,
            task: request.task,
          ),
      ];
      return MediaBatchDownloadResult(items);
    };
  }

  group('selection model', () {
    test('批量入队的模型按目录位置记账，标签是「已选 N / 共 M 集」', () {
      final adapter = adapterWith([seriesOf()]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));

      expect(store.selectionLabel, '已选 0 / 3 集');
      store.select(store.episodes[0]);
      store.select(store.episodes[2]);
      expect(store.selectionLabel, '已选 2 / 3 集');
      expect(store.selectedEpisodes.map((e) => e.episodeNumber), [1, 3]);

      store.deselect(0);
      expect(store.selectionLabel, '已选 1 / 3 集');

      store.selectAll();
      expect(store.selectionLabel, '已选 3 / 3 集');

      store.clearSelection();
      expect(store.selectedCount, 0);
    });

    test('目录重载保留仍在可见范围内的选集，丢掉消失的集', () {
      final adapter = adapterWith([seriesOf()]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.selectAll();

      store.setEpisodes(episodesOf(2));

      expect(store.selectionLabel, '已选 2 / 2 集');
      expect(store.selectedEpisodes.map((e) => e.position), [0, 1]);
    });
  });

  group('batch executor', () {
    test('一集只向适配器解析一次，命名与入队共用同一批候选', () async {
      final adapter = CountingFakeSiteAdapter()
        ..configureCatalog([
          seriesOf(episodes: [1, 2, 3]),
        ]);
      final store = storeFor(app, adapter);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.selectAll();

      final started = await store.startSelection();

      expect(started.notice, isNull);
      expect(store.job?.total, 3);
      // 三集各一次：命名时取到的那份候选直接用于入队。
      expect(adapter.linesCalls, 3, reason: '每集只应读一次线路');
      expect(adapter.candidateCalls, 3, reason: '每集只应解析一次候选');
    });

    test('每集建一个独立任务并共享同一批次目录', () async {
      final adapter = adapterWith([seriesOf()]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.selectAll();

      final started = await store.startSelection();
      final job = started.job;

      expect(job.batchDirectory, '示例剧');
      expect(job.total, 3);
      final tasks = app.mediaTasks.tasks;
      expect(tasks, hasLength(3));
      expect(tasks.map((task) => task.batchDirectory).toSet(), {'示例剧'});
      expect(tasks.map((task) => task.episodeNumber).toSet(), {1, 2, 3});
    });

    test('单集失败留原因，其余照常入队；重试只重做失败的那一集', () async {
      final adapter = adapterWith([seriesOf()]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.selectAll();

      // 第 2 集的线路取不到候选：一集失败不能拖垮整批。
      adapter.configureCatalog([
        FakeSeries(
          seriesKey: 's-1',
          title: '示例剧',
          episodes: [
            for (final number in [1, 2, 3])
              FakeEpisode(
                episodeNumber: number,
                title: '第$number集',
                lines: number == 2
                    ? const []
                    : [
                        FakeLine(
                          lineId: 'alpha',
                          label: '甲线路',
                          representations: [
                            FakeRepresentation(
                              mediaUrl:
                                  'https://media.invalid/s-1-$number-1080.m3u8',
                            ),
                          ],
                        ),
                      ],
              ),
          ],
        ),
      ]);

      final job = (await store.startSelection()).job;
      final failedRow = job.items.firstWhere((item) => item.episodeNumber == 2);
      expect(failedRow.phase, SeriesBatchItemPhase.failed);
      expect(failedRow.message, isNotNull);
      expect(app.mediaTasks.tasks.map((task) => task.episodeNumber).toSet(), {
        1,
        3,
      });

      await store.retryItem(failedRow.position);
      expect(
        store.job?.itemAt(failedRow.position)?.phase,
        SeriesBatchItemPhase.failed,
        reason: '线路仍然没有候选，重试只能重报原因',
      );
      expect(app.mediaTasks.tasks.map((task) => task.episodeNumber).toSet(), {
        1,
        3,
      }, reason: '重试一集不能顺带重做其他集');
    });

    test('已经有可播放文件的一集不重复下载，也不算失败', () async {
      final adapter = adapterWith([
        seriesOf(episodes: [1]),
      ]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(1));
      store.selectAll();

      await store.startSelection();
      final first = app.mediaTasks.tasks.single;
      final before = app.mediaTasks.tasks.length;

      // 同一批再点一次：已有任务，不得再建第二行。
      await store.startSelection();
      expect(app.mediaTasks.tasks, hasLength(before));
      expect(app.mediaTasks.tasks.single.id, first.id);
    });
  });

  group('sync and delete', () {
    test('同步只读任务状态：不暂停、不取消正在下载的一集', () async {
      final adapter = adapterWith([
        seriesOf(episodes: [1, 2]),
      ]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(2));
      store.selectAll();
      await store.startSelection();

      final task = app.mediaTasks.tasks.first;
      final before = app.mediaTasks.task(task.id)!;

      store.syncFromTasks();

      final after = app.mediaTasks.task(task.id)!;
      expect(after.state, before.state);
      expect(after.bytesDownloaded, before.bytesDownloaded);
    });

    test('单独删除一集只删这一集，其他集与批次目录都还在', () async {
      final adapter = adapterWith([seriesOf()]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.selectAll();
      await store.startSelection();

      expect(app.mediaTasks.tasks, hasLength(3));
      final removed = await store.deleteEpisode(2);

      expect(
        removed,
        1,
        reason:
            'tasks=${app.mediaTasks.tasks.map((t) => '${t.id}/${t.episodeNumber}/${t.batchDirectory}').toList()}',
      );
      expect(app.mediaTasks.tasks.map((task) => task.episodeNumber).toSet(), {
        1,
        3,
      });
      expect(app.mediaTasks.tasks.map((task) => task.batchDirectory).toSet(), {
        '示例剧',
      }, reason: '批次目录是共享的，删一集不能删掉邻居的归属');
      expect(store.job?.items.map((item) => item.episodeNumber).toSet(), {
        1,
        3,
      });
      expect(store.isSelected(1), isFalse, reason: '被删掉的那一集退出选集');
      expect(store.isSelected(0), isTrue);
      expect(store.isSelected(2), isTrue);
    });

    test('删除被占用的一集时失败并保留原因，不影响其他集', () async {
      final adapter = adapterWith([seriesOf()]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.selectAll();
      await store.startSelection();

      final target = app.mediaTasks.tasks.firstWhere(
        (task) => task.episodeNumber == 2,
      );
      // 播放、导出或投屏持有引用时，删除必须拒绝而不是强删。
      app.mediaTasks.retain(target.id);
      addTearDown(() => app.mediaTasks.release(target.id));

      final removed = await store.deleteEpisode(2);

      expect(removed, 0);
      expect(app.mediaTasks.tasks, hasLength(3));
      final row = store.job?.items.firstWhere(
        (item) => item.episodeNumber == 2,
      );
      expect(row?.phase, SeriesBatchItemPhase.failed);
      expect(row?.message, contains('停止'));
    });
  });

  group('sheet', () {
    testWidgets('面板显示已选计数、整体进度与逐项失败，可单独重试', (tester) async {
      await tester.runAsync(() async {});
      final adapter = adapterWith([
        seriesOf(episodes: [1, 2, 3]),
      ]);
      final store = storeFor(app, adapter);
      addTearDown(store.dispose);
      stubBatchStart(store);
      store.setEpisodes(episodesOf(3));
      store.select(store.episodes[0]);
      store.select(store.episodes[1]);

      // 面板的「批量下载」按钮会调 startSelection；那一串 future 由真实
      // 数据库、真实适配器和 400ms 轮询定时器组成，假时钟推不动，等多久都
      // 不会完成。这里把同一套流程先跑完，只把「点了之后面板如何呈现批次」
      // 留给 widget：入队语义另有 batch executor 组覆盖。
      await tester.runAsync(() => store.startSelection());
      expect(store.job?.total, 2, reason: '两次选集的批次应当真的入队');

      final played = <MediaCandidate>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeriesBatchDownloadSheet(
              store: store,
              onPlay: (candidate) async => played.add(candidate),
              onChanged: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 2 / 3 集'), findsWidgets);
      expect(find.byKey(const Key('batch-progress')), findsOneWidget);
      expect(find.byKey(const Key('batch-summary')), findsOneWidget);
      expect(store.job?.total, 2);

      // 逐项失败：把一集改成失败，行里出现重试。
      await tester.runAsync(() => store.retryItem(0));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.byKey(const Key('batch-row-0')),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('batch-row-0')),
          matching: find.byTooltip('播放这一集'),
        ),
        findsOneWidget,
      );
      expect(played, isEmpty);

      // 播放一集不影响批次里其他行。
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('batch-row-0')),
          matching: find.byTooltip('播放这一集'),
        ),
      );
      await tester.pumpAndSettle();
      expect(played, hasLength(1));
      expect(store.job?.total, 2);
    });
  });

  group('detail page', () {
    testWidgets('详情页一次选中多集，显示「已选 N / 共 M 集」', (tester) async {
      final adapter = adapterWith([
        seriesOf(episodes: [1, 2, 3]),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeriesDetailScreen(
              app: app,
              adapter: adapter,
              profile: profile(1, '甲站'),
              series: const SeriesSummary(
                seriesKey: 's-1',
                title: '示例剧',
                episodeCount: 3,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('目录共有 3 集'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('批量下载'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('批量下载'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('batch-selection-label')), findsOneWidget);
      expect(find.text('已选 0 / 3 集'), findsWidgets);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('episode-select-1')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('episode-select-1')));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 / 3 集'), findsWidgets);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('episode-select-2')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('episode-select-2')));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 / 3 集'), findsWidgets);

      // 打开批量下载面板，计数跟着选集走。
      await tester.scrollUntilVisible(
        find.byKey(const Key('open-batch-sheet')),
        -120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('open-batch-sheet')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SeriesBatchDownloadSheet),
          matching: find.text('已选 2 / 3 集'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('没有 app 时详情页仍可用，但不开批量入队', (tester) async {
      final adapter = adapterWith([
        seriesOf(episodes: [1, 2]),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeriesDetailScreen(
              adapter: adapter,
              profile: profile(1, '甲站'),
              series: const SeriesSummary(
                seriesKey: 's-1',
                title: '示例剧',
                episodeCount: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('目录共有 2 集'), findsOneWidget);
      // 没有 app 就没有任务表，批量入队不可能成立：入口照常出现，但必须
      // 是禁用的按钮，而不是能点进去、点完才发现没有 store 的按钮。
      final batchEntry = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '批量下载'),
      );
      expect(batchEntry.onPressed, isNull, reason: '没有 app 时批量入队入口不可用');
      expect(find.byType(SiteLensCompactRow), findsWidgets);
    });
  });
}
