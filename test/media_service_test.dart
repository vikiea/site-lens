import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
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
}
