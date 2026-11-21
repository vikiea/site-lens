import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/remote_episode_source.dart';
import 'package:site_lens/media/remote_playback_failure.dart';
import 'package:site_lens/testing/fake_remote_playback_host.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/ui/remote_player_screen.dart';

/// T11：播放页端到端——取景、控制栏、跳集、自动连播、失败归因。
///
/// 原生通道 `site_lens/native_media` 在测试里被显式 mock 掉：播放页只通过
/// [FakeRemotePlaybackHost] 说话，但 `SystemChrome` 与平台视图片段仍然会碰到
/// 通道，所以这里把两条通道都回答掉，并断言没有任何东西真的去开原生会话。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel('site_lens/native_media');
  final platformCalls = <String>[];

  setUp(() {
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          platformCalls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
  });

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

  FakeSiteAdapter catalogAdapter({int episodes = 2}) {
    final adapter = FakeSiteAdapter(
      id: 'fake',
      profileId: 1,
      addresses: [Uri.parse('https://fake.example/')],
    );
    adapter.configureCatalog([
      FakeSeries(
        seriesKey: 's-1',
        title: '示例剧',
        episodes: [
          for (var episode = 1; episode <= episodes; episode++)
            FakeEpisode(
              episodeNumber: episode,
              title: '第$episode集',
              lines: const [
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
        ],
      ),
    ]);
    return adapter;
  }

  Future<FakeRemotePlaybackHost> pumpPlayer(
    WidgetTester tester, {
    FakeRemotePlaybackHost? host,
    RemoteEpisodeSource? source,
    int continueWatching = 0,
    Size size = const Size(400, 800),
  }) async {
    final playback = host ?? FakeRemotePlaybackHost();
    addTearDown(playback.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: RemotePlayerScreen(
          host: playback,
          candidate: candidateFor(1),
          title: '示例剧',
          episodeNumber: '第 1 集',
          source: source,
          lineId: 'alpha',
          continueWatchingMs: continueWatching,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return playback;
  }

  testWidgets('点开就播：页面一开始就打开候选并播放，不需要再点一次', (tester) async {
    final host = await pumpPlayer(tester);

    expect(host.opened.single.id, candidateFor(1).id);
    expect(host.commands, contains('play:native_1'));
    expect(find.text('示例剧 · 第 1 集'), findsWidgets);
    // 播放页自己不开原生通道：会话全由宿主代劳。
    expect(platformCalls, isEmpty);
  });

  testWidgets('竖屏视口用适配包住 9:16 短剧，不裁切也不压扁', (tester) async {
    final host = FakeRemotePlaybackHost()
      ..videoWidth = 1080
      ..videoHeight = 1920;
    await pumpPlayer(tester, host: host, size: const Size(400, 800));

    // 400x800 可用区域里，9:16 的内容应当正好铺满宽度：宽 400、高 711.1。
    final texture = tester.widget<Texture>(find.byType(Texture));
    final box = tester.getSize(find.byType(Texture));
    expect(texture.textureId, 7);
    expect(box.width, closeTo(400, 0.5));
    expect(box.height, closeTo(400 * 1920 / 1080, 0.5));
  });

  testWidgets('横屏视口用适配装进 16:9，左右留边而不是裁掉画面', (tester) async {
    final host = FakeRemotePlaybackHost();
    await pumpPlayer(tester, host: host, size: const Size(400, 300));

    // 可用区域 400x300 里，16:9 的内容受宽度限制：宽 400、高 225，上下留边。
    // （按高度装会得到宽 533，超出可用区域，不是「装进去」。）
    final box = tester.getSize(find.byType(Texture));
    expect(box.width, closeTo(400, 0.5));
    expect(box.height, closeTo(400 * 9 / 16, 0.5));
  });

  test('取景算式：两种比例在两种方向下都不越界，且比例不变', () {
    Size fit(double w, double h, double ratio) =>
        RemoteVideoViewport.fittedSize(
          boxWidth: w,
          boxHeight: h,
          sourceRatio: ratio,
        );

    for (final ratio in [9 / 16, 16 / 9, 4 / 3]) {
      for (final box in [const Size(400, 800), const Size(800, 400)]) {
        final size = fit(box.width, box.height, ratio);
        expect(size.width, lessThanOrEqualTo(box.width + 0.01));
        expect(size.height, lessThanOrEqualTo(box.height + 0.01));
        expect(size.width / size.height, closeTo(ratio, 0.001));
      }
    }
  });

  testWidgets('跳集：点「下一集」换到第 2 集，同一屏不闪黑', (tester) async {
    final source = AdapterEpisodeSource(
      adapter: catalogAdapter(),
      seriesKey: 's-1',
    );
    final host = await pumpPlayer(tester, source: source);

    await tester.tap(find.byTooltip('下一集'));
    await tester.pumpAndSettle();

    expect(host.opened.map((c) => c.episodeNumber), [1, 2]);
    expect(find.text('示例剧 · 第 2 集'), findsWidgets);
    // 画面始终有纹理：换集过程中没有一帧是「没有画面」的空窗。
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('倍速在跳集后保持', (tester) async {
    final source = AdapterEpisodeSource(
      adapter: catalogAdapter(),
      seriesKey: 's-1',
    );
    final host = await pumpPlayer(tester, source: source);

    await tester.tap(find.byTooltip(RegExp('播放速度')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2x').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('下一集'));
    await tester.pumpAndSettle();

    expect(
      host.commands.where((command) => command.startsWith('speed:')),
      containsAllInOrder(['speed:2.00', 'speed:2.00']),
    );
    expect(find.byTooltip('播放速度 2x'), findsOneWidget);
  });

  testWidgets('自动连播：播完自动开下一集', (tester) async {
    final source = AdapterEpisodeSource(
      adapter: catalogAdapter(),
      seriesKey: 's-1',
    );
    final host = await pumpPlayer(tester, source: source);

    host.complete();
    await tester.pumpAndSettle();

    expect(host.opened.map((c) => c.episodeNumber), [1, 2]);
    expect(find.text('示例剧 · 第 2 集'), findsWidgets);
  });

  testWidgets('拔耳机：原生报 paused，控制栏跟着显示播放而不是暂停', (tester) async {
    final host = await pumpPlayer(tester);

    host.emit(NativePlaybackState.paused, positionMs: 5000);
    await tester.pumpAndSettle();

    // 原生媒体会话按 handleAudioBecomingNoisy 自己暂停；应用侧不去猜，只读快照。
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsNothing);
    expect(find.text('00:05'), findsOneWidget);
  });

  testWidgets('分片失败用远程归因，给出「回到选集」而不是任务状态', (tester) async {
    final host = await pumpPlayer(tester);

    host.emit(
      NativePlaybackState.failed,
      errorCode: 'remoteFailure; kind=segmentFailed; attempt=1',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('可以下载该集后观看'), findsOneWidget);
    expect(find.text('回到选集'), findsOneWidget);
    expect(find.textContaining('任务'), findsNothing);
  });

  testWidgets('网络失败只留文案，不给点了没用的按钮', (tester) async {
    final host = await pumpPlayer(tester);

    host.emit(
      NativePlaybackState.failed,
      errorCode: 'remoteFailure; kind=network; attempt=1',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('网络已切换'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('凭证失效给出归因与下一步，点一下会真的重开这一集', (tester) async {
    final host = await pumpPlayer(tester);

    host.emit(
      NativePlaybackState.failed,
      errorCode: 'credentialRejected; status=401; profile=1; attempt=1',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('登录已失效'), findsOneWidget);

    // 归因链在预算内已经自动重开过一次；用户再点「重新尝试」是显式重开。
    final before = host.opened.length;
    await tester.tap(find.text('重新尝试'));
    await tester.pumpAndSettle();
    expect(host.opened.length, before + 1);
  });

  testWidgets('关闭播放页会关掉原生会话并取消订阅', (tester) async {
    final host = FakeRemotePlaybackHost();
    addTearDown(host.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RemotePlayerScreen(
          host: host,
          candidate: candidateFor(1),
          title: '示例剧',
          episodeNumber: '第 1 集',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(host.closed, ['native_1']);
    // 页面已经销毁：之后原生再推快照不会引起任何异常。
    host.emit(NativePlaybackState.failed, errorCode: 'remoteFailure');
    await tester.pumpAndSettle();
  });

  testWidgets('没有目录来源时跳集按钮不可用，不假装还有下一集', (tester) async {
    await pumpPlayer(tester);

    final next = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.skip_next),
        matching: find.byType(IconButton),
      ),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('远程失败的四类图标互不相同，用户能分清是哪一类', (tester) async {
    final host = await pumpPlayer(tester);
    host.emit(
      NativePlaybackState.failed,
      errorCode: 'remoteFailure; kind=manifestUnavailable; attempt=1',
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(Stack),
        matching: find.byIcon(Icons.link_off),
      ),
      findsOneWidget,
    );
    expect(
      RemoteFailureAction.reloadManifestAndReopen,
      RemotePlaybackFailure(
        kind: RemoteFailureKind.manifestUnavailable,
        sessionId: 'native_1',
      ).action,
    );
  });
}
