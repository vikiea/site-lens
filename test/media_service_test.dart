import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/network/transport.dart';

class FakeNativeDownloads extends NativeDownloadRuntime {
  FakeNativeDownloads() : super(channel: const MethodChannel('fake_downloads'));

  final statuses = <String, Map<String, Object?>>{};
  final calls = <String>[];

  @override
  Future<Map<String, Object?>> start(
    MediaTask task,
    MediaCandidate candidate, {
    String? title,
  }) async {
    calls.add('start:${task.id}');
    return statuses[task.id] ?? {'state': 'downloading'};
  }

  @override
  Future<Map<String, Object?>> status(String taskId) async =>
      statuses[taskId] ?? {'state': 'missing'};

  @override
  Future<void> pause(String taskId) async => calls.add('pause:$taskId');

  @override
  Future<Map<String, Object?>> resume(String taskId) async {
    calls.add('resume:$taskId');
    return statuses[taskId] ?? {'state': 'downloading'};
  }
}

MediaCandidate candidate({
  String url = 'https://cdn.example/video.mp4',
  String mime = 'video/mp4',
  String title = 'video',
}) => MediaCandidate(
  id: 'candidate-1',
  hostId: 7,
  generation: 3,
  sourceUrl: Uri.parse('https://example.com/watch'),
  mediaUrl: Uri.parse(url),
  title: title,
  mime: mime,
  source: MediaCandidateSource.dom,
);

void main() {
  test('media task freezes the title and episode at creation', () {
    final store = MediaTaskStore();
    final task = store.create(candidate(title: '母衣半暖默许春朝 - 第3集'));
    expect(task.displayTitle, '母衣半暖默许春朝 - 第3集');
    expect(task.episodeLabel, '第3集');
    expect(task.displayName, '母衣半暖默许春朝 - 第3集');
  });

  test('media task prefers the episode marker in the media URL', () {
    final task = MediaTaskStore().create(
      candidate(
        title: '母衣半暖默许春朝 - 第1集',
        url: 'https://cdn.example/episode-3/video.mp4',
      ),
    );
    expect(task.episodeLabel, '第3集');
  });

  test('media retry clears the previous human-readable failure reason', () {
    final store = MediaTaskStore();
    final task = store.create(candidate());
    store.transition(task.id, MediaTaskState.downloading);
    final failed = store.transition(
      task.id,
      MediaTaskState.failed,
      errorCode: MediaErrorCode.network,
      errorReason: '网络连接中断，请重试',
    );
    expect(failed.errorReason, '网络连接中断，请重试');
    final retrying = store.transition(task.id, MediaTaskState.downloading);
    expect(retrying.errorCode, isNull);
    expect(retrying.errorReason, isNull);
  });

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
    expect(controller.setSpeed(8).speed, 8);
    expect(() => controller.setSpeed(8.1), throwsRangeError);
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
        {'url': 'https://cdn.example/live/index.m3u8?token=one'},
        {'url': 'https://cdn.example/live/index.m3u8?token=two'},
        {'url': 'blob:https://example.com/id'},
        {'url': 'file:///private/video.mp4'},
      ],
    );
    expect(values, hasLength(2));
    expect(
      values.map((value) => value.effectiveMime),
      containsAll(['video/mp4', 'application/vnd.apple.mpegurl']),
    );
  });

  test('signed HLS observations share one session group', () {
    expect(
      mediaCandidateGroupKey(
        Uri.parse('https://cdn.example/live/index.m3u8?token=one'),
      ),
      mediaCandidateGroupKey(
        Uri.parse('https://cdn.example/live/index.m3u8?token=two'),
      ),
    );
  });

  test('HLS transport segments are never selectable media', () {
    final segment = candidate(
      url: 'https://cdn.example/live/segment0.ts?auth=short-lived',
      mime: 'video/mp2t',
    );
    expect(segment.isLikelyTransportSegment, isTrue);
    expect(
      () => const MediaCandidateValidator().validate(segment),
      throwsFormatException,
    );
  });

  test('titled HLS observations collapse to one display candidate', () {
    final first = candidate(
      url: 'https://cdn.example/live/index.m3u8?token=one',
      mime: 'application/vnd.apple.mpegurl',
    );
    final second = MediaCandidate(
      id: 'candidate-2',
      hostId: first.hostId,
      generation: first.generation,
      sourceUrl: first.sourceUrl,
      mediaUrl: Uri.parse('https://cdn.example/live/index.m3u8?token=two'),
      title: first.title,
      mime: first.mime,
      source: first.source,
    );
    expect(
      mediaCandidateDisplayGroupKey(first),
      mediaCandidateDisplayGroupKey(second),
    );
  });

  test('HLS downloads a local playlist, segments and encryption key', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-hls-download-',
    );
    addTearDown(() => root.delete(recursive: true));
    final playlistUrl = Uri.parse('https://cdn.example/video/index.m3u8');
    final http = _MapHttp({
      playlistUrl.toString(): FetchResponse(
        url: playlistUrl,
        status: 200,
        bytes: utf8.encode(
          '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:1,\nseg.ts\n'
          '#EXT-X-ENDLIST\n',
        ),
        headers: const {},
      ),
      'https://cdn.example/video/key.bin': FetchResponse(
        url: Uri.parse('https://cdn.example/video/key.bin'),
        status: 200,
        bytes: [1, 2, 3, 4],
        headers: {},
      ),
      'https://cdn.example/video/seg.ts': FetchResponse(
        url: Uri.parse('https://cdn.example/video/seg.ts'),
        status: 200,
        bytes: [5, 6, 7],
        headers: {},
      ),
    });
    final store = MediaTaskStore(directoryProvider: () async => root);
    final hls = candidate(
      url: playlistUrl.toString(),
      mime: 'application/vnd.apple.mpegurl',
    );
    final task = store.create(hls);
    final result = await MediaDownloadService(
      tasks: store,
      http: http,
    ).start(task, hls);
    expect(result.state, MediaTaskState.playable);
    expect(result.bytesDownloaded, greaterThan(0));
    final cached = await store.cachedFile(task.id);
    expect(cached, isNotNull);
    expect(await cached!.readAsString(), contains('resource_'));
    expect(cached.parent.listSync(), hasLength(3));
    expect(http.calls, hasLength(3));
  });

  test('native task reconciliation restores progress, local URI and playable state', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-native-task-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final cache = await store.cacheDirectory();
    final file = File('${cache.path}/cached.media')
      ..writeAsBytesSync([1, 2, 3]);
    final task = store.create(candidate());
    store.transition(task.id, MediaTaskState.downloading);
    final native = FakeNativeDownloads();
    native.statuses[task.id] = {
      'state': 'completed',
      'bytesDownloaded': 3,
      'totalBytes': 3,
      'localUri': file.uri.toString(),
    };
    await MediaDownloadService(tasks: store, native: native).reconcileNative();
    expect(store.task(task.id)?.state, MediaTaskState.playable);
    expect(store.task(task.id)?.bytesDownloaded, 3);
    expect(store.task(task.id)?.localRef, file.path);
    expect(await store.cachedFile(task.id), isNotNull);
  });

  test(
    'native pause/resume keeps the task state and records backend calls',
    () async {
      final store = MediaTaskStore();
      final task = store.create(candidate());
      final native = FakeNativeDownloads();
      final service = MediaDownloadService(tasks: store, native: native);
      native.statuses[task.id] = {'state': 'downloading'};
      await service.startNative(task, candidate());
      expect(store.task(task.id)?.state, MediaTaskState.downloading);
      await service.pauseNative(task.id);
      expect(store.task(task.id)?.state, MediaTaskState.paused);
      await service.resumeNative(task.id, candidate());
      expect(store.task(task.id)?.state, MediaTaskState.downloading);
      expect(native.calls, [
        'start:${task.id}',
        'pause:${task.id}',
        'resume:${task.id}',
      ]);
    },
  );

  test('HTTP failures do not become playable cache entries', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-http-failure-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate());
    final http = _StatusHttp(404);
    final service = MediaDownloadService(tasks: store, http: http);
    await expectLater(
      service.start(task, candidate()),
      throwsA(isA<StateError>()),
    );
    expect(store.task(task.id)?.state, MediaTaskState.failed);
    expect(
      store.transition(task.id, MediaTaskState.downloading).state,
      MediaTaskState.downloading,
    );
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
    'MP4 export reports progress and leaves a validated deliverable',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-export-');
      addTearDown(() => root.delete(recursive: true));
      final playlist = File('${root.path}/index.m3u8')
        ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
      final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1, 2, 3]);
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      final progress = <int>[];
      final service = Mp4ExportService(
        tasks: store,
        directoryProvider: () async => root,
        muxer:
            ({
              required HlsCacheInput input,
              required String outputPath,
              required void Function(int) onProgress,
              required Cancellation cancellation,
            }) async {
              expect(input.segments.single.path, segment.path);
              onProgress(50);
              await File(outputPath).writeAsBytes([9, 8, 7]);
            },
      );
      final successful = await service.export(
        task.id,
        HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
        onProgress: progress.add,
      );
      expect(successful.state, ExportState.deliverable);
      expect(await File(successful.outputPath!).exists(), isTrue);
      expect(progress, containsAllInOrder([0, 50, 100]));
    },
  );

  test(
    'cancelled MP4 export removes the temporary output but keeps the task',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-export-cancel-',
      );
      addTearDown(() => root.delete(recursive: true));
      final playlist = File('${root.path}/index.m3u8')
        ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
      final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1]);
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate());
      store.transition(task.id, MediaTaskState.downloading);
      store.transition(task.id, MediaTaskState.completed);
      store.transition(task.id, MediaTaskState.playable);
      final cancel = Cancellation();
      final service = Mp4ExportService(
        tasks: store,
        directoryProvider: () async => root,
        muxer:
            ({
              required HlsCacheInput input,
              required String outputPath,
              required void Function(int) onProgress,
              required Cancellation cancellation,
            }) async {
              await File(outputPath).writeAsBytes([1, 2, 3]);
              cancellation.cancel();
              cancellation.check();
            },
      );
      final result = await service.export(
        task.id,
        HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
        cancellation: cancel,
      );
      expect(result.state, ExportState.cancelled);
      expect(store.task(task.id), isNotNull);
      expect(Directory('${root.path}/media_exports').listSync(), isEmpty);
    },
  );

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

  test('DLNA protocol info parser exposes narrow sink capabilities', () {
    final info = DlnaProtocolInfo.parse(
      '<GetProtocolInfoResponse><Sink>http-get:*:video/mp4:*,http-get:*:application/vnd.apple.mpegurl:*</Sink></GetProtocolInfoResponse>',
    );
    expect(info.supportsMime('video/mp4'), isTrue);
    expect(info.supportsMime('application/vnd.apple.mpegurl'), isTrue);
    expect(info.supportsMime('audio/flac'), isFalse);
    expect(
      DlnaProtocolInfo.parse('http-get:*:*:*').supportsMime('audio/flac'),
      isTrue,
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

class _StatusHttp extends ControlledHttp {
  _StatusHttp(this.statusCode);
  final int statusCode;

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async => FetchResponse(
    url: url,
    status: statusCode,
    bytes: const [],
    headers: const {},
  );
}

class _MapHttp extends ControlledHttp {
  _MapHttp(this.responses);
  final Map<String, FetchResponse> responses;
  final calls = <String>[];

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async {
    calls.add(url.toString());
    final response = responses[url.toString()];
    if (response == null) throw StateError('missing $url');
    return response;
  }
}
