import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/remote_episode_source.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';

/// T11：下一集从哪来。播放页不认识站点，所以「下一集」必须能从一个只讲线路
/// 与候选的接口里拿到，并且沿用用户在详情页选过的那条线路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FakeSiteAdapter adapterWith({required List<FakeEpisode> episodes}) {
    final adapter = FakeSiteAdapter(
      id: 'fake',
      profileId: 1,
      addresses: [Uri.parse('https://fake.example/')],
    );
    adapter.configureCatalog([
      FakeSeries(seriesKey: 's-1', title: '示例剧', episodes: episodes),
    ]);
    return adapter;
  }

  const alpha = FakeLine(
    lineId: 'alpha',
    label: '甲线路',
    representations: [
      FakeRepresentation(
        mediaUrl: 'https://media.example/a-1080.m3u8',
        qualityLabel: '1080P',
        audioLabel: '国语',
      ),
      FakeRepresentation(
        mediaUrl: 'https://media.example/a-720.m3u8',
        qualityLabel: '720P',
        audioLabel: '国语',
      ),
    ],
  );

  const beta = FakeLine(
    lineId: 'beta',
    label: '乙线路',
    representations: [
      FakeRepresentation(
        mediaUrl: 'https://media.example/b-1080.m3u8',
        qualityLabel: '1080P',
        audioLabel: '粤语',
      ),
    ],
  );

  test('沿用这一集选过的线路，而不是永远退回第一条', () async {
    final adapter = adapterWith(
      episodes: const [
        FakeEpisode(episodeNumber: 1, title: '第1集', lines: [alpha, beta]),
        FakeEpisode(episodeNumber: 2, title: '第2集', lines: [alpha, beta]),
      ],
    );
    final source = AdapterEpisodeSource(
      adapter: adapter,
      seriesKey: 's-1',
      preferredLineId: 'beta',
      preferredQuality: '1080P',
      preferredAudio: '粤语',
    );

    final candidate = await source.resolve(2, CancellationSignal());
    expect(candidate.episodeNumber, 2);
    expect(candidate.mediaUrl.host, 'media.example');
    expect(candidate.audioLabel, '粤语');
  });

  test('那条线路在这一集上没有了，就退回目录的第一条线路', () async {
    final adapter = adapterWith(
      episodes: const [
        FakeEpisode(episodeNumber: 1, title: '第1集', lines: [alpha, beta]),
        FakeEpisode(episodeNumber: 2, title: '第2集', lines: [alpha]),
      ],
    );
    final source = AdapterEpisodeSource(
      adapter: adapter,
      seriesKey: 's-1',
      preferredLineId: 'beta',
    );

    final candidate = await source.resolve(2, CancellationSignal());
    expect(candidate.audioLabel, '国语');
  });

  test('同一条线路里保持清晰度档位', () async {
    final adapter = adapterWith(
      episodes: const [
        FakeEpisode(episodeNumber: 1, title: '第1集', lines: [alpha]),
        FakeEpisode(episodeNumber: 2, title: '第2集', lines: [alpha]),
      ],
    );
    final source = AdapterEpisodeSource(
      adapter: adapter,
      seriesKey: 's-1',
      preferredLineId: 'alpha',
      preferredQuality: '720P',
    );

    final candidate = await source.resolve(2, CancellationSignal());
    expect(candidate.qualityLabel, '720P');
  });

  test('目录里没有这一集时说实话，而不是返回某一集凑数', () async {
    final adapter = adapterWith(
      episodes: const [
        FakeEpisode(episodeNumber: 1, title: '第1集', lines: [alpha]),
      ],
    );
    final source = AdapterEpisodeSource(adapter: adapter, seriesKey: 's-1');

    await expectLater(
      source.resolve(9, CancellationSignal()),
      throwsA(
        isA<SiteAdapterError>().having(
          (error) => error.kind,
          'kind',
          SiteAdapterErrorKind.notFound,
        ),
      ),
    );
  });
}
