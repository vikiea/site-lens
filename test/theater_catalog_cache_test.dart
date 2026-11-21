import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/theater/theater_catalog_store.dart';

/// 剧场目录的缓存边界。适配器是唯一的数据来源，缓存只是它的旁路：它只回答
/// 一件事——接口不可用时，用户还能不能看见上一次看得见的内容。
void main() {
  late FakeSiteAdapter adapter;
  late TheaterCatalogStore store;

  FakeSeries series(String key, String title) => FakeSeries(
    seriesKey: key,
    title: title,
    episodes: const [FakeEpisode(episodeNumber: 1, title: '第1集')],
  );

  setUp(() {
    adapter = FakeSiteAdapter(
      profileId: 1,
      addresses: [Uri.parse('https://alpha.example/')],
    );
    store = TheaterCatalogStore();
    adapter.configureCatalog([series('s-1', '第一部')]);
  });

  test('首次从适配器取目录：不是缓存内容，并记住这份目录', () async {
    final snapshot = await store.load(adapter, CancellationSignal());

    expect(snapshot.series.map((s) => s.seriesKey), ['s-1']);
    expect(snapshot.fromCache, isFalse);
    expect(snapshot.failure, isNull);

    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '站点连不上');
    final again = await store.load(adapter, CancellationSignal());
    expect(again.series.map((s) => s.seriesKey), ['s-1']);
    expect(again.fromCache, isTrue);
  });

  test('接口失败时返回上一次的目录，并标明来自缓存', () async {
    await store.load(adapter, CancellationSignal());
    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '站点连不上');

    final snapshot = await store.load(adapter, CancellationSignal());

    expect(snapshot.series.map((s) => s.seriesKey), ['s-1']);
    expect(snapshot.fromCache, isTrue);
    expect(snapshot.failure?.kind, SiteAdapterErrorKind.unavailable);
  });

  test('接口答案为空时也退回缓存，避免首屏突然变空', () async {
    await store.load(adapter, CancellationSignal());
    adapter.configureCatalog(const []);

    final snapshot = await store.load(adapter, CancellationSignal());

    expect(snapshot.series.map((s) => s.seriesKey), ['s-1']);
    expect(snapshot.fromCache, isTrue);
    expect(snapshot.failure, isNull);
  });

  test('没有缓存且接口失败时给出空目录与失败原因，不抛异常', () async {
    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '站点连不上');

    final snapshot = await store.load(adapter, CancellationSignal());

    expect(snapshot.series, isEmpty);
    expect(snapshot.fromCache, isFalse);
    expect(snapshot.failure?.kind, SiteAdapterErrorKind.unavailable);
  });

  test('缓存按适配器分开：另一个站点不会拿到这里的目录', () async {
    await store.load(adapter, CancellationSignal());
    final other = FakeSiteAdapter(
      id: 'fake-two',
      profileId: 2,
      addresses: [Uri.parse('https://beta.example/')],
    );
    other.failNextWith(SiteAdapterErrorKind.unavailable, '站点连不上');

    final snapshot = await store.load(other, CancellationSignal());

    expect(snapshot.series, isEmpty);
    expect(snapshot.fromCache, isFalse);
  });
}
