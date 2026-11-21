import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/theater/theater_catalog_store.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/theater_screen.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'fake_web_host_api.dart';

/// 剧场首屏：顶部站点切换器、主体 feed、下方「我的追剧」横排。全部由假适配器
/// 驱动，不依赖网络。
void main() {
  SiteProfile profile(int id, String name) => SiteProfile(
    id: id,
    name: name,
    createdAt: DateTime.utc(2026, 1, 1),
    routes: const {SiteRoute.direct, SiteRoute.browse},
  );

  FakeSiteAdapter adapterFor(SiteProfile profile, String title) {
    final adapter = FakeSiteAdapter(
      id: 'fake-${profile.id}',
      profileId: profile.id,
      addresses: [Uri.parse('https://${profile.id}.example/')],
    );
    adapter.configureCatalog([
      FakeSeries(
        seriesKey: 's-${profile.id}-$title',
        title: title,
        episodes: const [FakeEpisode(episodeNumber: 1, title: '第1集')],
      ),
    ]);
    return adapter;
  }

  Future<void> pumpTheater(
    WidgetTester tester, {
    required List<TheaterStation> stations,
    TheaterCatalogStore? store,
    void Function(TheaterStation, SeriesSummary)? onOpenSeries,
    VoidCallback? onAddSite,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TheaterScreen(
            stations: stations,
            catalogStore: store,
            onOpenSeries: onOpenSeries,
            onAddSite: onAddSite,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('首屏是剧场：顶部站点切换器、目录 feed 与追剧横排', (tester) async {
    final alpha = profile(1, '甲站');
    final beta = profile(2, '乙站');
    final alphaAdapter = adapterFor(alpha, '甲的剧');
    final betaAdapter = adapterFor(beta, '乙的剧');

    await pumpTheater(
      tester,
      stations: [
        TheaterStation(profile: alpha, adapter: alphaAdapter),
        TheaterStation(profile: beta, adapter: betaAdapter),
      ],
    );

    expect(find.text('甲站'), findsWidgets);
    expect(find.text('甲的剧'), findsOneWidget);
    expect(find.text('乙的剧'), findsNothing);
    expect(find.text('我的追剧'), findsOneWidget);
    expect(find.text('开始观看'), findsOneWidget);
  });

  testWidgets('切换站点后 feed 随之改变', (tester) async {
    final alpha = profile(1, '甲站');
    final beta = profile(2, '乙站');
    final stations = [
      TheaterStation(profile: alpha, adapter: adapterFor(alpha, '甲的剧')),
      TheaterStation(profile: beta, adapter: adapterFor(beta, '乙的剧')),
    ];

    await pumpTheater(tester, stations: stations);
    expect(find.text('甲的剧'), findsOneWidget);

    // The trigger renders the selected station's name; "切换站点" is only its
    // tooltip and semantics label.
    await tester.tap(find.byTooltip('切换站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙站').last);
    await tester.pumpAndSettle();

    expect(find.text('乙的剧'), findsOneWidget);
    expect(find.text('甲的剧'), findsNothing);

    // 切回来仍能看到甲站的目录：每个站点各自缓存自己那一份。
    await tester.tap(find.byTooltip('切换站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('甲站').last);
    await tester.pumpAndSettle();
    expect(find.text('甲的剧'), findsOneWidget);
  });

  testWidgets('切到还没有内容的站点时不显示上一个站点的剧集', (tester) async {
    final alpha = profile(1, '甲站');
    final beta = profile(2, '乙站');
    final emptyBeta = FakeSiteAdapter(
      id: 'fake-2',
      profileId: 2,
      addresses: [Uri.parse('https://2.example/')],
    );

    await pumpTheater(
      tester,
      stations: [
        TheaterStation(profile: alpha, adapter: adapterFor(alpha, '甲的剧')),
        TheaterStation(profile: beta, adapter: emptyBeta),
      ],
    );
    expect(find.text('甲的剧'), findsOneWidget);

    // The trigger renders the selected station's name; "切换站点" is only its
    // tooltip and semantics label.
    await tester.tap(find.byTooltip('切换站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙站').last);
    await tester.pumpAndSettle();

    expect(find.text('甲的剧'), findsNothing);
    expect(find.text('这里还没有内容'), findsOneWidget);
  });

  testWidgets('接口不可用时仍能看到已缓存的目录，并说明这是缓存内容', (tester) async {
    final alpha = profile(1, '甲站');
    final adapter = adapterFor(alpha, '甲的剧');
    final store = TheaterCatalogStore();

    await pumpTheater(
      tester,
      stations: [TheaterStation(profile: alpha, adapter: adapter)],
      store: store,
    );
    expect(find.text('甲的剧'), findsOneWidget);
    expect(find.textContaining('已缓存'), findsNothing);

    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '站点连不上');
    await tester.fling(find.text('开始观看'), const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(find.text('甲的剧'), findsOneWidget);
    expect(find.textContaining('已缓存的目录'), findsOneWidget);
  });

  testWidgets('没有直连站点时不空白也不无限加载', (tester) async {
    var added = false;
    await pumpTheater(
      tester,
      stations: const [],
      onAddSite: () => added = true,
    );

    expect(find.text('还没有可直连的站点'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '添加站点'));
    expect(added, isTrue);
  });

  testWidgets('我的追剧横排可以有自己的数据源，并可点进剧集', (tester) async {
    final alpha = profile(1, '甲站');
    final adapter = adapterFor(alpha, '甲的剧');
    const watching = SeriesSummary(
      seriesKey: 's-1-追的那部',
      title: '追的那部',
      episodeCount: 8,
    );
    String? tapped;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TheaterScreen(
            stations: [TheaterStation(profile: alpha, adapter: adapter)],
            following: const [watching],
            onOpenSeries: (_, series) => tapped = series.seriesKey,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('甲的剧'), findsOneWidget);
    expect(find.text('追的那部'), findsOneWidget);
    expect(find.text('共 8 集'), findsOneWidget);

    await tester.tap(find.text('追的那部'));
    await tester.pump();
    expect(tapped, 's-1-追的那部');
  });

  testWidgets('剧集行可点，并把所在站点与剧集交给调用方', (tester) async {
    final alpha = profile(1, '甲站');
    final adapter = adapterFor(alpha, '甲的剧');
    TheaterStation? tappedStation;
    String? tappedKey;

    await pumpTheater(
      tester,
      stations: [TheaterStation(profile: alpha, adapter: adapter)],
      onOpenSeries: (station, series) {
        tappedStation = station;
        tappedKey = series.seriesKey;
      },
    );

    await tester.tap(find.text('甲的剧'));
    await tester.pump();

    expect(tappedStation?.profile.id, 1);
    expect(tappedKey, 's-1-甲的剧');
  });

  testWidgets('底部导航是剧场/站外浏览/媒体库/设置，旧能力从设置二级入口到达', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    await tester.runAsync(() async {
      await app.initialize();
      await app.startupSettled;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWithValue(app)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('剧场'), findsOneWidget);
    expect(find.text('站外浏览'), findsOneWidget);
    expect(find.text('媒体库'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('站点'), findsNothing);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    // 站外浏览 分类不在首屏视口内，惰性列表要先滚到它才会构建。
    await tester.scrollUntilVisible(
      find.text('脚本管理'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('脚本管理'), findsOneWidget);
    expect(find.text('广告与反跟踪'), findsOneWidget);

    // 设置页滚动之后，「站外浏览」既是导航标签也是分类标题；只有滚回顶部
    // 再点导航项才不会歧义。
    await tester.tap(find.text('剧场'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('站外浏览'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('新建标签页'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await app.shutdown();
      await db.close();
    });
  });

  testWidgets('剧场首屏不出现脚本与广告过滤等旧能力入口', (tester) async {
    final alpha = profile(1, '甲站');
    await pumpTheater(
      tester,
      stations: [
        TheaterStation(profile: alpha, adapter: adapterFor(alpha, '甲的剧')),
      ],
    );

    expect(find.text('脚本管理'), findsNothing);
    expect(find.text('广告与反跟踪'), findsNothing);
    expect(find.byType(SiteLensNotice), findsNothing);
  });
}
