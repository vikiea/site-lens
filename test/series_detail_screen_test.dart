import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/theater/series_line_memory.dart';
import 'package:site_lens/ui/series_detail_screen.dart';
import 'package:site_lens/ui/theater_screen.dart';
import 'package:site_lens/ui/ui_primitives.dart';

/// 剧集详情：概况、选集、线路与候选。全部由假适配器驱动，不依赖网络。
///
/// 术语遵守 `GLOSSARY.md`：用户选的是**线路**，一条线路产出多个**媒体候选**
/// （清晰度 / 音轨）；播放器拿候选，详情页不播放（播放属于 T11）。
void main() {
  SiteProfile profile(int id, String name) => SiteProfile(
    id: id,
    name: name,
    createdAt: DateTime.utc(2026, 1, 1),
    routes: const {SiteRoute.direct, SiteRoute.browse},
  );

  const alphaStream = FakeLine(
    lineId: 'alpha',
    label: '甲线路',
    representations: [
      FakeRepresentation(
        mediaUrl: 'https://media.invalid/alpha-1080.m3u8',
        qualityLabel: '1080P',
        audioLabel: '国语',
      ),
      FakeRepresentation(
        mediaUrl: 'https://media.invalid/alpha-720.m3u8',
        qualityLabel: '720P',
        audioLabel: '国语',
      ),
    ],
  );

  const betaStream = FakeLine(
    lineId: 'beta',
    label: '乙线路',
    representations: [
      FakeRepresentation(
        mediaUrl: 'https://media.invalid/beta-1080.m3u8',
        qualityLabel: '1080P',
        audioLabel: '粤语音轨',
      ),
    ],
  );

  const series = FakeSeries(
    seriesKey: 's-1',
    title: '示例剧',
    episodes: [
      FakeEpisode(
        episodeNumber: 1,
        title: '第1集',
        lines: [alphaStream, betaStream],
      ),
      FakeEpisode(
        episodeNumber: 2,
        title: '第2集',
        lines: [alphaStream, betaStream],
      ),
    ],
  );

  FakeSiteAdapter adapterWith({
    String id = 'fake-1',
    int profileId = 1,
    List<FakeSeries> catalog = const [series],
  }) {
    final adapter = FakeSiteAdapter(
      id: id,
      profileId: profileId,
      addresses: [Uri.parse('https://$id.example/')],
    );
    adapter.configureCatalog(catalog);
    return adapter;
  }

  /// Opens the detail page the way 剧场 does: from the series the theater row
  /// handed over.
  Future<SeriesLineMemory> pumpDetail(
    WidgetTester tester, {
    required FakeSiteAdapter adapter,
    required SiteProfile owner,
    SeriesSummary? summary,
    SeriesLineMemory? memory,
  }) async {
    final store = memory ?? SeriesLineMemory();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SeriesDetailScreen(
            adapter: adapter,
            profile: owner,
            series:
                summary ??
                const SeriesSummary(
                  seriesKey: 's-1',
                  title: '示例剧',
                  summary: '少年在旧车站遇见一列只在雨夜出现的列车。',
                  episodeCount: 2,
                ),
            lineMemory: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  /// 线路名在线路行里出现两次（行标题与选择器触发器都会渲染它），断言要看
  /// 「线路区里写着哪条线路」，而不是页面上这个词出现了几次。
  Finder lineText(String label) => find.descendant(
    of: find.byIcon(Icons.alt_route),
    matching: find.text(label),
  );

  testWidgets('详情页显示剧名、简介、总集数与已更新的集数', (tester) async {
    final owner = profile(1, '甲站');
    await pumpDetail(tester, adapter: adapterWith(), owner: owner);

    expect(find.text('示例剧'), findsWidgets);
    expect(find.text('少年在旧车站遇见一列只在雨夜出现的列车。'), findsOneWidget);
    expect(find.textContaining('共 2 集'), findsWidgets);
    // 目录只给出两集，已更新到第几集由目录里最大的集号得出。
    expect(find.textContaining('已更新到第 2 集'), findsWidgets);
  });

  testWidgets('选集列表能选到某一集，线路区跟着换成那一集的线路', (tester) async {
    final owner = profile(1, '甲站');
    final adapter = adapterWith(
      catalog: const [
        FakeSeries(
          seriesKey: 's-1',
          title: '示例剧',
          episodes: [
            FakeEpisode(
              episodeNumber: 1,
              title: '第1集',
              lines: [
                FakeLine(
                  lineId: 'alpha',
                  label: '甲线路',
                  representations: [
                    FakeRepresentation(
                      mediaUrl: 'https://media.invalid/alpha-1080.m3u8',
                      qualityLabel: '1080P',
                    ),
                  ],
                ),
              ],
            ),
            FakeEpisode(
              episodeNumber: 2,
              title: '第2集',
              lines: [
                FakeLine(
                  lineId: 'gamma',
                  label: '丙线路',
                  representations: [
                    FakeRepresentation(
                      mediaUrl: 'https://media.invalid/gamma-480.m3u8',
                      qualityLabel: '480P',
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await pumpDetail(tester, adapter: adapter, owner: owner);
    expect(lineText('甲线路'), findsWidgets);

    await tester.tap(find.text('第2集'));
    await tester.pumpAndSettle();

    expect(lineText('丙线路'), findsWidgets);
    expect(lineText('甲线路'), findsNothing);
  });

  testWidgets('切换线路后立即生效，并出现在线路区', (tester) async {
    final owner = profile(1, '甲站');
    await pumpDetail(tester, adapter: adapterWith(), owner: owner);

    expect(lineText('甲线路'), findsWidgets);
    await tester.tap(find.byTooltip('切换线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙线路').last);
    await tester.pumpAndSettle();

    expect(lineText('乙线路'), findsWidgets);
    expect(lineText('甲线路'), findsNothing);
  });

  testWidgets('一条线路下的清晰度与音轨作为候选呈现', (tester) async {
    final owner = profile(1, '甲站');
    await pumpDetail(tester, adapter: adapterWith(), owner: owner);

    expect(find.text('1080P'), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    expect(find.textContaining('国语'), findsWidgets);
  });

  testWidgets('本集选过线路后，换清晰度仍保持那条线路', (tester) async {
    final owner = profile(1, '甲站');
    await pumpDetail(tester, adapter: adapterWith(), owner: owner);

    await tester.tap(find.byTooltip('切换线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙线路').last);
    await tester.pumpAndSettle();
    expect(lineText('乙线路'), findsWidgets);

    // 候选是线路产出的清晰度/音轨；换候选不影响「我选的是哪条线路」。
    await tester.tap(find.byTooltip('切换清晰度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('粤语音轨').last);
    await tester.pumpAndSettle();

    expect(lineText('乙线路'), findsWidgets);
    expect(lineText('甲线路'), findsNothing);
    expect(find.textContaining('粤语音轨'), findsWidgets);
  });

  testWidgets('本集选过线路后，重新进入这一集仍保持那条线路', (tester) async {
    final owner = profile(1, '甲站');
    final adapter = adapterWith();
    final memory = await pumpDetail(tester, adapter: adapter, owner: owner);

    await tester.tap(find.byTooltip('切换线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙线路').last);
    await tester.pumpAndSettle();
    expect(lineText('乙线路'), findsWidgets);

    // 退出再进来（新的详情页实例，同一份记忆）。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await pumpDetail(tester, adapter: adapter, owner: owner, memory: memory);

    expect(lineText('乙线路'), findsWidgets);
    expect(lineText('甲线路'), findsNothing);
  });

  testWidgets('换集不继承上一集的线路选择：新集回到目录给出的第一条', (tester) async {
    final owner = profile(1, '甲站');
    await pumpDetail(tester, adapter: adapterWith(), owner: owner);

    await tester.tap(find.byTooltip('切换线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙线路').last);
    await tester.pumpAndSettle();
    expect(lineText('乙线路'), findsWidgets);

    await tester.tap(find.text('第2集'));
    await tester.pumpAndSettle();
    expect(lineText('甲线路'), findsWidgets);
    expect(lineText('乙线路'), findsNothing);
  });

  testWidgets('线路本身不可用时说清是这条线路的问题，而不是笼统的播放失败', (tester) async {
    final owner = profile(1, '甲站');
    final adapter = adapterWith();
    await pumpDetail(tester, adapter: adapter, owner: owner);

    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '该线路维护中');
    await tester.tap(find.byTooltip('切换线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙线路').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('乙线路'), findsWidgets);
    expect(find.textContaining('线路'), findsWidgets);
    expect(find.textContaining('不可用'), findsWidgets);
    expect(find.textContaining('播放失败'), findsNothing);
    // 失败之后仍然停在这条线路上，用户可以直接重试或换一条。
    expect(find.textContaining('该线路维护中'), findsOneWidget);
  });

  testWidgets('播放入口明确标为尚未实现，本轮不做播放', (tester) async {
    final owner = profile(1, '甲站');
    await pumpDetail(tester, adapter: adapterWith(), owner: owner);

    final play = find.widgetWithText(FilledButton, '播放');
    expect(play, findsOneWidget);
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(find.textContaining('播放'), findsWidgets);
  });

  testWidgets('剧场点进剧集后打开详情页', (tester) async {
    final owner = profile(1, '甲站');
    final adapter = adapterWith();
    final station = TheaterStation(profile: owner, adapter: adapter);
    final memory = SeriesLineMemory();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TheaterScreen(
            stations: [station],
            onOpenSeries: (station, series) {
              Navigator.of(tester.element(find.text('示例剧'))).push(
                MaterialPageRoute<void>(
                  builder: (_) => SeriesDetailScreen(
                    adapter: station.adapter,
                    profile: station.profile,
                    series: series,
                    lineMemory: memory,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('示例剧'));
    await tester.pumpAndSettle();

    expect(find.byType(SeriesDetailScreen), findsOneWidget);
    expect(lineText('甲线路'), findsWidgets);
  });

  testWidgets('线路不可用时，线路区给出重试而不是空区域', (tester) async {
    final owner = profile(1, '甲站');
    final adapter = adapterWith();
    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '接口连不上');
    await pumpDetail(tester, adapter: adapter, owner: owner);
    // 线路列表没取到，重试入口必须带着集号说清楚在读哪一集。

    expect(find.textContaining('接口连不上'), findsOneWidget);
    expect(find.byType(SiteLensNotice), findsWidgets);
  });
}
