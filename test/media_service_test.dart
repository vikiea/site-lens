import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_service.dart';

MediaCandidate candidate({String url = 'https://cdn.example/video.mp4'}) =>
    MediaCandidate(
      id: 'candidate-1',
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: Uri.parse(url),
      title: 'video',
      mime: 'video/mp4',
      source: MediaCandidateSource.dom,
    );

void main() {
  test('native playback controller enforces one session and safe controls', () {
    final controller = NativePlaybackController();
    final opening = controller.open(
      candidate(),
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
    );
    expect(opening.state, NativePlaybackState.preparing);
    expect(
      controller.transition(NativePlaybackState.playing).state,
      NativePlaybackState.playing,
    );
    expect(controller.seek(1200).positionMs, 1200);
    expect(controller.setSpeed(1.5).speed, 1.5);
    expect(
      () => controller.transition(NativePlaybackState.completed),
      returnsNormally,
    );
    expect(() => controller.seek(10), throwsStateError);
    final replacement = controller.open(
      candidate(url: 'https://cdn.example/other.mp4'),
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
    );
    expect(replacement.id, isNot(opening.id));
    expect(replacement.state, NativePlaybackState.preparing);
  });

  test('DOM collector rejects blob URLs and de-duplicates safe media URLs', () {
    final values = const MediaCandidateCollector().fromDom(
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
      elements: [
        {'url': 'https://cdn.example/video.mp4', 'mime': 'video/mp4'},
        {'url': 'https://cdn.example/video.mp4#fragment'},
        {'url': 'blob:https://example.com/id'},
        {'url': 'file:///private/video.mp4'},
      ],
    );
    expect(values, hasLength(1));
    expect(values.single.mediaUrl.toString(), 'https://cdn.example/video.mp4');
  });

  test(
    'media task store protects active references and restores state',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-media-');
      addTearDown(() => root.delete(recursive: true));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      expect(
        store.transition(task.id, MediaTaskState.downloading).state,
        MediaTaskState.downloading,
      );
      final completed = store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      store.retain(task.id);
      await expectLater(store.delete(task.id), throwsStateError);
      store.release(task.id);
      await store.delete(task.id);
      expect(store.task(completed.id), isNull);
    },
  );

  test('HLS parser and validator accept only local complete inputs', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-');
    addTearDown(() => root.delete(recursive: true));
    final playlist = File('${root.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
    final segment = File('${root.path}/seg.ts')..writeAsBytesSync([0, 1, 2]);
    final input = const HlsPlaylistParser().parse(
      playlist.uri,
      await playlist.readAsString(),
    );
    expect(input.segments.single.path, segment.path);
    expect(
      const HlsInputValidator().validate(
        playlist: input.playlist,
        segments: input.segments,
      ),
      hasLength(2),
    );
    expect(
      () => const HlsInputValidator().validate(
        playlist: Uri.parse('https://cdn.example/index.m3u8'),
        segments: const [],
      ),
      throwsFormatException,
    );
  });

  test(
    'HLS parser selects a local master variant without following network URLs',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-hls-master-',
      );
      addTearDown(() => root.delete(recursive: true));
      final low = Directory('${root.path}/low')..createSync();
      final high = Directory('${root.path}/high')..createSync();
      File('${low.path}/index.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXTINF:1,\nlow.ts\n');
      File('${high.path}/index.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXTINF:1,\nhigh.ts\n');
      File('${low.path}/low.ts').writeAsBytesSync([1]);
      File('${high.path}/high.ts').writeAsBytesSync([2]);
      final master = File('${root.path}/master.m3u8')
        ..writeAsStringSync(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nhigh/index.m3u8\n',
        );
      final input = await const HlsPlaylistParser().parseFile(master.uri);
      expect(input.segments.single.path, '${high.path}/high.ts');
      final remote = File('${root.path}/remote.m3u8')
        ..writeAsStringSync(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3\nhttps://cdn.example/high.m3u8\n',
        );
      await expectLater(
        const HlsPlaylistParser().parseFile(remote.uri),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('relay authorization binds token to session, task and device', () {
    final auth = const RelayAuthorizer().issue(
      sessionId: 'session',
      taskId: 'task',
      deviceId: 'device',
    );
    const RelayAuthorizer().validate(
      auth,
      token: auth.token,
      sessionId: 'session',
      taskId: 'task',
      deviceId: 'device',
    );
    expect(
      () => const RelayAuthorizer().validate(
        auth,
        token: auth.token,
        sessionId: 'other',
        taskId: 'task',
        deviceId: 'device',
      ),
      throwsStateError,
    );
  });

  test('relay request parser accepts HEAD and bounded ranges only', () {
    expect(
      const RelayRequestValidator().validate(
        const RelayRequest(method: 'HEAD'),
      ),
      (start: null, end: null),
    );
    expect(
      const RelayRequestValidator().validate(
        const RelayRequest(method: 'GET', range: 'bytes=10-20'),
      ),
      (start: 10, end: 20),
    );
    expect(
      () => const RelayRequestValidator().validate(
        const RelayRequest(method: 'POST'),
      ),
      throwsStateError,
    );
  });

  test('HLS relay rewrites only local manifest resources', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-relay-');
    addTearDown(() => root.delete(recursive: true));
    final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1, 2, 3]);
    final playlist = File('${root.path}/index.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
    final auth = const RelayAuthorizer().issue(
      sessionId: 's',
      taskId: 't',
      deviceId: 'd',
    );
    final relay = await HlsRelayServer.start(
      authorization: auth,
      playlist: playlist,
      allowedRoot: root,
      advertisedHost: '127.0.0.1',
    );
    addTearDown(relay.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(relay.url)).close();
    final body = await response.transform(const Utf8Decoder()).join();
    expect(response.statusCode, HttpStatus.ok);
    expect(body, contains('/hls/t/seg.ts?token=${auth.token}'));
    expect(segment.existsSync(), isTrue);
  });

  test(
    'local relay advertises a routable host and serves byte ranges',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-relay-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/video.mp4')
        ..writeAsBytesSync(List<int>.generate(32, (index) => index));
      final auth = const RelayAuthorizer().issue(
        sessionId: 'session',
        taskId: 'task',
        deviceId: 'device',
      );
      final relay = await MediaRelayServer.start(
        authorization: auth,
        file: file,
        allowedRoot: root,
        advertisedHost: '127.0.0.1',
      );
      addTearDown(relay.close);
      expect(relay.url.host, '127.0.0.1');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(relay.url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=4-7');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        await response.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        ),
        [4, 5, 6, 7],
      );
    },
  );
}
