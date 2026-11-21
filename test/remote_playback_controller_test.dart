import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/remote_episode_source.dart';
import 'package:site_lens/media/remote_playback_controller.dart';
import 'package:site_lens/media/remote_playback_failure.dart';
import 'package:site_lens/testing/fake_remote_playback_host.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';

/// T11：播放器自己那一层——换集、连播、倍速保持、失败归因、订阅清理。
///
/// 全部跑在假宿主上：没有原生通道、没有网络，也不需要设备。原生侧的声音
/// 焦点与锁屏控件由媒体会话负责，这里只验证播放页交出去的命令对不对。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaCandidate candidateFor(int episode) => MediaCandidate(
    id: 'fake:s-1:$episode:alpha:0',
    hostId: 1,
    generation: 1,
    sourceUrl: Uri.parse('https://fake.example/'),
    mediaUrl: Uri.parse('https://media.example/$episode.m3u8'),
    title: '示例剧 第$episode集',
    mime: 'application/vnd.apple.mpegurl',
    source: MediaCandidateSource.registered,
    seriesKey: 's-1',
    seriesTitle: '示例剧',
    episodeNumber: episode,
    qualityLabel: '1080P',
    audioLabel: '国语',
  );

  FakeSiteAdapter catalogAdapter() {
    final adapter = FakeSiteAdapter(
      id: 'fake',
      profileId: 1,
      addresses: [Uri.parse('https://fake.example/')],
    );
    adapter.configureCatalog(const [
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
                    mediaUrl: 'https://media.example/1.m3u8',
                    qualityLabel: '1080P',
                    audioLabel: '国语',
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
                lineId: 'alpha',
                label: '甲线路',
                representations: [
                  FakeRepresentation(
                    mediaUrl: 'https://media.example/2.m3u8',
                    qualityLabel: '1080P',
                    audioLabel: '国语',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
    return adapter;
  }

  RemotePlaybackController controllerFor(
    FakeRemotePlaybackHost host, {
    RemoteEpisodeSource? source,
    int continueWatching = 0,
    int? profileId,
  }) => RemotePlaybackController(
    host: host,
    title: '示例剧',
    episodeNumber: '第 1 集',
    initial: candidateFor(1),
    source: source,
    lineId: 'alpha',
    qualityLabel: '1080P',
    audioLabel: '国语',
    continueWatching: continueWatching,
    profileId: profileId,
  );

  test('点开就播：start 打开候选并让它开始播放', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(host);
    addTearDown(() => controller.stopAndDispose());

    await controller.start();

    expect(host.opened.single.id, candidateFor(1).id);
    expect(controller.session!.state, NativePlaybackState.playing);
    expect(host.commands, contains('play:native_1'));
  });

  // ADR-0009：原生按档案 id 取站点凭证。候选自带的 hostId 是观察它的网页
  // 宿主，不是档案；带着凭证的站点如果在换集时把宿主 id 当档案传下去，就会
  // 安静地退回匿名播放，用户看到的是「突然只能放 480P 或者直接 403」。
  //
  // 换集拿到的新候选与原候选属于同一个网页宿主（都是 hostId=1），所以这条
  // 用例直接盯住控制器交给宿主的那两个值：档案 id 必须一路是同一个，宿主 id
  // 只在打开候选时用，不能顶替档案。
  test('换集与重开都带着同一个档案 id，不拿候选的宿主 id 顶替', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
      profileId: 7,
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    await controller.switchBy(1);
    await controller.retryCurrent();

    expect(host.opened, hasLength(3));
    expect(host.openedProfileIds, [7, 7, 7], reason: '每一次打开都该带同一个档案 id');
    // 候选上的宿主 id 与档案 id 不是一回事：换集时宿主 id 保持 1，档案 id
    // 保持 7。两边任意一方被另一方顶替，这里就对不上。
    expect(host.opened.map((c) => c.hostId), [1, 1, 1]);
  });

  test('跳集：新会话开好之后才关旧的，一次换集只构建一次 MediaItem', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    await controller.switchBy(1);

    // 两次打开：第一集一次，第二集一次。中间没有「关掉再重开」的第二次构建。
    expect(host.opened.map((c) => c.episodeNumber), [1, 2]);
    expect(controller.currentEpisode, '第 2 集');
    expect(host.closed, ['native_1']);
    expect(host.active!.id, 'native_2');
  });

  test('倍速在跳集后保持：新会话开出来就带回去', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    await controller.setSpeed(2);
    await controller.switchBy(1);

    expect(controller.speed, 2);
    expect(host.commands, containsAllInOrder(['speed:2.00', 'speed:2.00']));
  });

  test('自动连播：播完就开下一集，且走同一条换集路径', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    await controller.setSpeed(1.5);
    host.complete();
    await pumpEventQueue();

    expect(controller.currentEpisode, '第 2 集');
    expect(host.opened.map((c) => c.episodeNumber), [1, 2]);
    expect(host.commands.where((c) => c.startsWith('speed:')), [
      'speed:1.50',
      'speed:1.50',
    ]);
  });

  test('最后一集播完不假装还有下一集', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final adapter = catalogAdapter();
    final controller = RemotePlaybackController(
      host: host,
      title: '示例剧',
      episodeNumber: '第 2 集',
      initial: candidateFor(2),
      source: AdapterEpisodeSource(adapter: adapter, seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    host.complete();
    await pumpEventQueue();

    expect(controller.reachedLastEpisode, isTrue);
    expect(host.opened, hasLength(1));
  });

  test('换集失败时停在原来那一集，并说清是哪一集取不到', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final adapter = catalogAdapter();
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: adapter, seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    adapter.failNextWith(SiteAdapterErrorKind.unavailable, '线路维护中');
    await controller.switchBy(1);

    expect(controller.currentEpisode, '第 1 集');
    expect(controller.openError, contains('线路维护中'));
    expect(host.closed, isEmpty);
    expect(controller.session!.id, 'native_1');
  });

  test('继续观看的位置在打开后定位一次，跳集时不沿用', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
      continueWatching: 42000,
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    await controller.switchBy(1);

    expect(host.commands.where((c) => c.startsWith('seek:')), ['seek:42000']);
  });

  test('清单失效自动重开一次；同一会话再来一次就只给建议，不再重开', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(host);
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    host.emit(
      NativePlaybackState.failed,
      errorCode: 'remoteFailure; kind=manifestUnavailable; attempt=1',
    );
    await pumpEventQueue();

    // 预算内：显式重开同一集（同一份候选），不是静默重试。
    expect(host.opened, hasLength(2));
    expect(host.opened.last.id, candidateFor(1).id);
    expect(controller.failure!.retries, isTrue);

    // 重开之后的会话又失败一次：预算用完，只剩建议，不再开第三次。
    host.emit(
      NativePlaybackState.failed,
      errorCode: 'remoteFailure; kind=manifestUnavailable; attempt=2',
    );
    await pumpEventQueue();
    expect(host.opened, hasLength(2));
    expect(controller.failure!.retries, isFalse);
    expect(controller.failure!.message, contains('地址已经失效'));
  });

  test('凭证失效的重放用的是播放页正在放的那一集，而不是别处记的那一份', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    await controller.switchBy(1);
    final before = host.opened.length;
    host.emit(
      NativePlaybackState.failed,
      errorCode: 'credentialRejected; status=401; profile=1; attempt=1',
    );
    await pumpEventQueue();

    expect(
      controller.failure!.action,
      RemoteFailureAction.refreshCredentialAndReopen,
    );
    expect(host.opened, hasLength(before + 1));
    expect(host.opened.last.episodeNumber, 2);
  });

  test('分片失败不重开整集，只给「下载该集」这条建议', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(host);
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    host.emit(
      NativePlaybackState.failed,
      errorCode: 'remoteFailure; kind=segmentFailed; attempt=1',
    );
    await pumpEventQueue();

    expect(controller.failure!.action, RemoteFailureAction.suggestDownload);
    expect(controller.failure!.retries, isFalse);
    expect(host.opened, hasLength(1));
  });

  test('关闭播放页会取消订阅并关掉原生会话', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(host);

    await controller.start();
    await controller.stopAndDispose();

    expect(host.closed, ['native_1']);
    // 收尾之后再推快照不会抛：订阅已经取消，控制器也不再响应。
    host.emit(NativePlaybackState.failed, errorCode: 'remoteFailure');
    await pumpEventQueue();
    expect(controller.failure, isNull);
  });

  test('跳集只打开一次：同一份候选不会被打开两次', () async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    final controller = controllerFor(
      host,
      source: AdapterEpisodeSource(adapter: catalogAdapter(), seriesKey: 's-1'),
    );
    addTearDown(() => controller.stopAndDispose());

    await controller.start();
    // 并发两次「下一集」：第二次在第一次还没走完时被挡住。
    final first = controller.switchBy(1);
    final second = controller.switchBy(1);
    await Future.wait([first, second]);

    expect(host.opened.map((c) => c.episodeNumber), [1, 2]);
  });
}
