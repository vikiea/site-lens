import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';

/// Contract coverage for the fake adapter. Every later ticket that drives real
/// screens with it relies on these behaviours, so they are pinned here.
void main() {
  late FakeSiteAdapter adapter;
  late CancellationSignal cancel;

  setUp(() {
    adapter = FakeSiteAdapter(
      profileId: 1,
      addresses: [Uri.parse('https://alpha.example/')],
    );
    cancel = CancellationSignal();
  });

  test('剧场目录可配置，剧集与选集按配置返回', () async {
    adapter.configureCatalog([
      const FakeSeries(
        seriesKey: 's-1',
        title: '第一部',
        episodes: [
          FakeEpisode(episodeNumber: 1, title: '第1集'),
          FakeEpisode(episodeNumber: 2, title: '第2集'),
        ],
      ),
    ]);

    final feed = await adapter.theater(cancel);
    expect(feed.series.map((s) => s.seriesKey), ['s-1']);
    expect(feed.series.single.episodeCount, 2);

    final episodes = await adapter.episodes('s-1', cancel);
    expect(episodes.episodes.map((e) => e.episodeNumber), [1, 2]);
  });

  test('线路产出媒体候选，候选不带站点专有细节且复用下游候选类型', () async {
    adapter.configureCatalog([
      const FakeSeries(
        seriesKey: 's-1',
        title: '第一部',
        episodes: [
          FakeEpisode(
            episodeNumber: 1,
            title: '第1集',
            lines: [
              FakeLine(
                lineId: 'main',
                label: '主线',
                representations: [
                  FakeRepresentation(
                    qualityLabel: '1080P',
                    audioLabel: '国语',
                    mediaUrl: 'https://cdn.alpha.example/1.m3u8',
                  ),
                  FakeRepresentation(
                    qualityLabel: '720P',
                    audioLabel: '国语',
                    mediaUrl: 'https://cdn.alpha.example/1-low.m3u8',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    final lines = await adapter.lines('s-1', 1, cancel);
    expect(lines, hasLength(1));
    expect(lines.single.lineId, 'main');

    final candidates = await adapter.candidates(lines.single, cancel);
    expect(candidates, hasLength(2));
    expect(candidates.map((c) => c.qualityLabel), ['1080P', '720P']);
    final top = candidates.first;
    expect(top, isA<MediaCandidate>());
    expect(top.seriesKey, 's-1');
    expect(top.episodeNumber, 1);
    expect(top.mime, 'application/vnd.apple.mpegurl');
    // The same representation yields a stable identity, so a durable task can
    // be matched back to it.
    expect(top.mediaUrl, Uri.parse('https://cdn.alpha.example/1.m3u8'));
  });

  test('登录页地址与登录成功判定来自配置，凭证可写入与刷新', () async {
    adapter.loginPage = Uri.parse('https://alpha.example/login');
    expect((await adapter.loginEntry(cancel)).url, adapter.loginPage);
    expect((await adapter.loginVerdict(cancel)).loggedIn, isFalse);

    adapter.acceptSignIn({'user': 'u', 'password': 'p'});
    final verdict = await adapter.signIn(
      const SiteCredentialUpdate(fields: {'user': 'u', 'password': 'p'}),
      cancel,
    );
    expect(verdict.loggedIn, isTrue);
    expect(verdict.credential.isUsable, isTrue);
    expect((await adapter.loginVerdict(cancel)).loggedIn, isTrue);

    adapter.refreshTo(
      const SiteCredential(
        accessToken: 'fresh',
        cookies: {'sid': 'new'},
        refreshToken: 'refresh-2',
      ),
    );
    final refreshed = await adapter.refreshCredential(cancel);
    expect(refreshed.accessToken, 'fresh');
  });

  test('基站与健康自检可配置，失败以明确的错误类型表达', () async {
    adapter.stations = [
      BaseStation(origin: Uri.parse('https://alpha.example/'), preferred: true),
      BaseStation(origin: Uri.parse('https://mirror-alpha.example/')),
    ];
    final stations = await adapter.liveStations(cancel);
    expect(stations.first.preferred, isTrue);
    expect(stations.map((s) => s.origin.host), [
      'alpha.example',
      'mirror-alpha.example',
    ]);

    adapter.healthState = ProfileHealthState.failing;
    final health = await adapter.health(cancel);
    expect(health.state, ProfileHealthState.failing);
    expect(health.isUsable, isFalse);

    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '站点暂时不可用');
    await expectLater(
      adapter.theater(cancel),
      throwsA(
        isA<SiteAdapterError>().having(
          (e) => e.kind,
          'kind',
          SiteAdapterErrorKind.unavailable,
        ),
      ),
    );
  });

  test('取消信号让进行中的调用以 cancelled 结束，而不是当成失败', () async {
    cancel.cancel();
    await expectLater(
      adapter.theater(cancel),
      throwsA(
        isA<SiteAdapterError>().having(
          (e) => e.kind,
          'kind',
          SiteAdapterErrorKind.cancelled,
        ),
      ),
    );
  });

  test('地址覆盖决定注册表把哪个站点交给哪个适配器', () {
    expect(
      adapter.matchesAddress(Uri.parse('https://alpha.example/x')),
      isTrue,
    );
    expect(
      adapter.matchesAddress(Uri.parse('https://other.example/x')),
      isFalse,
    );
  });
}
