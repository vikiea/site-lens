import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

class _HeldCandidateDatabase extends AppDatabase {
  _HeldCandidateDatabase() : super(NativeDatabase.memory());
  final entered = Completer<void>();
  final releaseWrite = Completer<void>();
  final finished = Completer<void>();

  @override
  Future<void> saveMediaCandidate(MediaCandidate candidate) async {
    entered.complete();
    await releaseWrite.future;
    try {
      await super.saveMediaCandidate(candidate);
    } finally {
      finished.complete();
    }
  }
}

class _HeldInspectionWebHostApi extends FakeWebHostApi {
  final entered = Completer<void>();
  final snapshot = Completer<PageSnapshot>();

  @override
  Future<PageSnapshot> inspect(int hostId, String selector) {
    entered.complete();
    return snapshot.future;
  }
}

class _FailingCandidateDatabase extends AppDatabase {
  _FailingCandidateDatabase() : super(NativeDatabase.memory());

  @override
  Future<void> saveMediaCandidate(MediaCandidate candidate) =>
      Future<void>.error(StateError('candidate persistence unavailable'));
}

HostSession _session(NativeHosts hosts) {
  final session = HostSession(
    1,
    HostPurpose.browsing,
    HostCapabilities(
      platform: 'test',
      isolatedScripts: true,
      documentStart: true,
      privateProbes: true,
      reason: '',
    ),
  )..url = 'https://parent.example/watch';
  hosts.sessions[session.id] = session;
  return session;
}

HostEvent _event(
  HostSession session,
  int episode, {
  String? mediaUrl,
  String? seriesKey,
  int? episodeNumber,
}) => HostEvent(
  hostId: session.id,
  generation: session.generation,
  kind: 'mediaCandidate',
  url: session.url,
  detail: jsonEncode({
    'url': mediaUrl ?? 'https://cdn.example/episode.m3u8?episode=$episode',
    'title': 'Episode $episode',
    'mime': 'application/vnd.apple.mpegurl',
    'pageUrl': 'https://player.example/embed/$episode',
    'frame': 'child-1',
    'document': 'document-1',
    'main': false,
    ...?(seriesKey == null ? null : {'seriesKey': seriesKey}),
    ...?(episodeNumber == null ? null : {'episodeNumber': episodeNumber}),
  }),
);

MediaCandidate _candidate(HostSession session, {required int episode}) =>
    MediaCandidate(
      id: 'candidate-$episode',
      hostId: session.id,
      generation: session.generation,
      sourceUrl: Uri.parse(session.url),
      mediaUrl: Uri.parse('https://cdn.example/episode-$episode.m3u8'),
      title: 'Episode $episode',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('host destruction waits for an in-flight candidate write', () async {
    final db = _HeldCandidateDatabase();
    final http = ControlledHttp();
    final api = FakeWebHostApi();
    final hosts = NativeHosts(db, ScriptService(db, http), http, api: api);
    final session = _session(hosts);
    final event = hosts.onEvent(_event(session, 3));
    var destroyed = false;
    final destroy = hosts.destroy(session).then((_) => destroyed = true);
    try {
      await db.entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(destroyed, isFalse);
      db.releaseWrite.complete();
      await event;
      await destroy;
      expect(api.destroyed, contains(session.id));
      expect(session.mediaCandidates, isEmpty);
    } finally {
      if (!db.releaseWrite.isCompleted) db.releaseWrite.complete();
      await event;
      await destroy;
      await db.close();
    }
  });

  test(
    'failed candidate persistence never publishes an authorizable candidate',
    () async {
      final db = _FailingCandidateDatabase();
      final http = ControlledHttp();
      final hosts = NativeHosts(
        db,
        ScriptService(db, http),
        http,
        api: FakeWebHostApi(),
      );
      final session = _session(hosts);
      try {
        await hosts.onEvent(_event(session, 4));
        expect(session.mediaCandidates, isEmpty);
      } finally {
        await db.close();
      }
    },
  );

  test('main-frame network errors use a bounded retry budget', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeWebHostApi();
    final hosts = NativeHosts(
      db,
      ScriptService(db, ControlledHttp()),
      ControlledHttp(),
      api: api,
    );
    final session = _session(hosts);
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'started',
            url: session.url,
            detail: '',
          ),
        );
        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'networkError',
            url: session.url,
            detail: '连接超时 $attempt',
          ),
        );
        await Future<void>.delayed(switch (attempt) {
          0 => const Duration(milliseconds: 600),
          1 => const Duration(milliseconds: 1100),
          _ => const Duration(milliseconds: 2100),
        });
        expect(api.reloaded, List.filled(attempt + 1, session.id));
        session.generation++;
      }

      await hosts.onEvent(
        HostEvent(
          hostId: session.id,
          generation: session.generation,
          kind: 'started',
          url: session.url,
          detail: '',
        ),
      );
      await hosts.onEvent(
        HostEvent(
          hostId: session.id,
          generation: session.generation,
          kind: 'networkError',
          url: session.url,
          detail: '第四次超时',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(api.reloaded, List.filled(3, session.id));
    } finally {
      await db.close();
    }
  });

  test(
    'duplicate browser error-page events share one navigation retry',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeWebHostApi();
      final hosts = NativeHosts(
        db,
        ScriptService(db, ControlledHttp()),
        ControlledHttp(),
        api: api,
      );
      final session = _session(hosts);
      try {
        for (final detail in [
          'Bad state: WebView networkError: net::ERR_CONNECTION_CLOSED',
          'Bad state: WebView networkError: WebView committed an error page',
        ]) {
          await hosts.onEvent(
            HostEvent(
              hostId: session.id,
              generation: session.generation,
              kind: 'networkError',
              url: session.url,
              detail: detail,
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(api.reloaded, [session.id]);
        expect(session.errorKind, 'networkError');
        expect(session.error, '网络连接中断，请重试');
      } finally {
        await db.close();
      }
    },
  );

  test(
    'certificate and HTTP failures never trigger automatic reloads',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeWebHostApi();
      final hosts = NativeHosts(
        db,
        ScriptService(db, ControlledHttp()),
        ControlledHttp(),
        api: api,
      );
      final session = _session(hosts);
      try {
        for (final kind in ['certificateError', 'httpError']) {
          session.generation++;
          await hosts.onEvent(
            HostEvent(
              hostId: session.id,
              generation: session.generation,
              kind: 'started',
              url: session.url,
              detail: '',
            ),
          );
          await hosts.onEvent(
            HostEvent(
              hostId: session.id,
              generation: session.generation,
              kind: kind,
              url: session.url,
              detail: '$kind detail',
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(api.reloaded, isEmpty);
        expect(session.errorKind, 'httpError');
      } finally {
        await db.close();
      }
    },
  );

  test('visible player title can supply a single-task group', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeWebHostApi(playbackTitle: '母上攻略');
    final hosts = NativeHosts(
      db,
      ScriptService(db, ControlledHttp()),
      ControlledHttp(),
      api: api,
    );
    final session = _session(hosts)..url = 'https://example.test/video/1/';
    try {
      expect(await hosts.visiblePlaybackTitle(session.id), '母上攻略');
      session.generation++;
      expect(await hosts.visiblePlaybackTitle(session.id), isNull);
    } finally {
      await db.close();
    }
  });

  test('a descriptive page title is the visible-title fallback', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeWebHostApi(
      playbackDocumentTitle: '妈妈的答案 - 短剧视频在线观看 | 黄果短剧',
    );
    final hosts = NativeHosts(
      db,
      ScriptService(db, ControlledHttp()),
      ControlledHttp(),
      api: api,
    );
    final session = _session(hosts)..url = 'https://example.test/video/1/';
    try {
      expect(await hosts.visiblePlaybackTitle(session.id), '妈妈的答案');
    } finally {
      await db.close();
    }
  });

  test('generic DOM titles fall back to the descriptive page title', () async {
    for (final domTitle in ['批量媒体', '第1集']) {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeWebHostApi(
        playbackTitle: domTitle,
        playbackDocumentTitle: '妈妈的答案 - 短剧视频在线观看 | 黄果短剧',
      );
      final hosts = NativeHosts(
        db,
        ScriptService(db, ControlledHttp()),
        ControlledHttp(),
        api: api,
      );
      final session = _session(hosts)..url = 'https://example.test/video/1/';
      try {
        expect(
          await hosts.visiblePlaybackTitle(session.id),
          '妈妈的答案',
          reason: '$domTitle is not a truthful series title',
        );
      } finally {
        await db.close();
      }
    }
  });

  test(
    'same-URL candidate replacement rejects an older visible title',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = _HeldInspectionWebHostApi();
      final hosts = NativeHosts(
        db,
        ScriptService(db, ControlledHttp()),
        ControlledHttp(),
        api: api,
      );
      final session = _session(hosts)..url = 'https://example.test/video/1/';
      final candidate = _candidate(session, episode: 1);
      session.mediaCandidates[candidate.id] = candidate;
      session.mediaCandidateFrames[candidate.id] = (
        frame: 'frame-1',
        document: 'document-1',
        main: true,
        epoch: 1,
      );
      try {
        final pending = hosts.visiblePlaybackTitle(
          session.id,
          candidateId: candidate.id,
        );
        await api.entered.future;
        session.mediaCandidateFrames[candidate.id] = (
          frame: 'frame-1',
          document: 'document-2',
          main: true,
          epoch: 2,
        );
        api.snapshot.complete(
          PageSnapshot(
            url: 'https://example.test/video/1/',
            title: '',
            generation: session.generation,
            ready: true,
            challenge: false,
            interactionRequired: false,
            links: const [],
            text: '旧页面标题',
            error: '',
          ),
        );
        expect(await pending, isNull);
      } finally {
        await db.close();
      }
    },
  );

  test('same-document navigation rejects an older visible title', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = _HeldInspectionWebHostApi();
    final hosts = NativeHosts(
      db,
      ScriptService(db, ControlledHttp()),
      ControlledHttp(),
      api: api,
    );
    final session = _session(hosts)..url = 'https://parent.example/video/1/';
    try {
      final pending = hosts.visiblePlaybackTitle(session.id);
      await api.entered.future;
      session.url = 'https://parent.example/video/2/';
      api.snapshot.complete(
        PageSnapshot(
          url: 'https://parent.example/video/1/',
          title: '',
          generation: session.generation,
          ready: true,
          challenge: false,
          interactionRequired: false,
          links: const [],
          text: '旧页面标题',
          error: '',
        ),
      );
      expect(await pending, isNull);
    } finally {
      await db.close();
    }
  });

  test('same media URL keeps explicit episode identities separate', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final hosts = NativeHosts(
      db,
      ScriptService(db, ControlledHttp()),
      ControlledHttp(),
      api: FakeWebHostApi(),
    );
    final session = _session(hosts);
    try {
      await hosts.onEvent(
        _event(
          session,
          1,
          mediaUrl: 'https://cdn.example/same.m3u8',
          seriesKey: 'series:42',
          episodeNumber: 1,
        ),
      );
      await hosts.onEvent(
        _event(
          session,
          2,
          mediaUrl: 'https://cdn.example/same.m3u8',
          seriesKey: 'series:42',
          episodeNumber: 2,
        ),
      );

      expect(session.mediaCandidates, hasLength(2));
      expect(
        session.mediaCandidates.values.map((item) => item.episodeNumber),
        containsAll(<int>[1, 2]),
      );
      expect(
        session.mediaCandidates.values.map((item) => item.id).toSet(),
        hasLength(2),
      );
    } finally {
      await db.close();
    }
  });

  test(
    'candidate event completion includes persistence before database close',
    () async {
      final db = _HeldCandidateDatabase();
      final http = ControlledHttp();
      final hosts = NativeHosts(
        db,
        ScriptService(db, http),
        http,
        api: FakeWebHostApi(),
      );
      final session = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'test',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: '',
        ),
      )..url = 'https://parent.example/watch';
      hosts.sessions[session.id] = session;
      var completed = false;
      final event = hosts
          .onEvent(
            HostEvent(
              hostId: session.id,
              generation: session.generation,
              kind: 'mediaCandidate',
              url: session.url,
              detail: jsonEncode({
                'url': 'https://cdn.example/episode.m3u8?episode=2',
                'title': 'Episode 2',
                'mime': 'application/vnd.apple.mpegurl',
                'pageUrl': 'https://player.example/embed/2',
                'frame': 'child-1',
                'document': 'document-1',
                'main': false,
              }),
            ),
          )
          .then((_) => completed = true);
      try {
        await db.entered.future;
        await Future<void>.delayed(Duration.zero);
        expect(
          completed,
          false,
          reason: 'An awaited event must not leave a detached SQLite transaction behind',
        );
        db.releaseWrite.complete();
        await event;
        final candidate = session.mediaCandidates.values.single;
        expect(
          (await db.mediaCandidate(candidate.id))?.mediaUrl,
          candidate.mediaUrl,
        );
      } finally {
        if (!db.releaseWrite.isCompleted) db.releaseWrite.complete();
        await event;
        await db.finished.future;
        await db.close();
      }
    },
  );

  test(
    'cross-origin iframe candidates keep authorization and frame lifetime',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final http = ControlledHttp();
      final hosts = NativeHosts(
        db,
        ScriptService(db, http),
        http,
        api: FakeWebHostApi(),
      );
      final session = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'test',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: '',
        ),
      )..url = 'https://parent.example/watch';
      hosts.sessions[session.id] = session;

      Map<String, dynamic> candidate(String frame, String pageUrl) => {
        'kind': 'candidate',
        'url': 'https://cdn.example/episode.m3u8?line=1',
        'title': 'Series - $frame',
        'mime': 'application/vnd.apple.mpegurl',
        'pageUrl': pageUrl,
        'frame': frame,
        'document': 'document-1',
        'main': false,
      };

      try {
        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidate',
            url: session.url,
            detail: jsonEncode(
              candidate('child-1', 'https://player.example/embed/episode-1'),
            ),
          ),
        );
        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidate',
            url: session.url,
            detail: jsonEncode(
              candidate('child-2', 'https://player.example/embed/episode-2'),
            ),
          ),
        );

        expect(hosts.mediaCandidates(session), hasLength(2));
        final first = session.mediaCandidates.values.firstWhere(
          (value) => value.sourceUrl.host == 'player.example',
        );
        expect(
          hosts.authorizeMediaCandidate(session.id, first.id).sourceUrl.host,
          'player.example',
        );

        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidatesClear',
            url: session.url,
            detail: jsonEncode({
              'frame': 'child-1',
              'document': 'document-1',
              'main': false,
              'previousPageUrl': 'https://player.example/embed/episode-1',
            }),
          ),
        );

        expect(session.mediaCandidates, hasLength(1));
        expect(
          session.mediaCandidates.values.single.sourceUrl.path,
          '/embed/episode-2',
        );
      } finally {
        await db.close();
      }
    },
  );

  test(
    'playback evidence requires a same-frame candidate and is revoked by route',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final http = ControlledHttp();
      final hosts = NativeHosts(
        db,
        ScriptService(db, http),
        http,
        api: FakeWebHostApi(),
      );
      final session = _session(hosts);
      const source = 'https://cdn.example/episode.m3u8?episode=3';
      final sourceKey = source;
      HostEvent evidence({String? key, int epoch = 4}) => HostEvent(
        hostId: session.id,
        generation: session.generation,
        kind: 'mediaPlaybackEvidence',
        url: session.url,
        detail: jsonEncode({
          'frame': 'child-1',
          'document': 'document-1',
          'epoch': epoch,
          'pageUrl': 'https://player.example/embed/3',
          'sourceUrl': source,
          'sourceKey': key ?? sourceKey,
          'seriesKey': 'https://player.example/video/42',
          'episodeNumber': 3,
          'title': '示例剧 - 第3集',
          'state': 'playing',
        }),
      );
      try {
        await hosts.onEvent(
          evidence(key: 'https://cdn.example/other.m3u8?episode=3'),
        );
        expect(session.playbackEvidence, isNull);

        await hosts.onEvent(evidence());
        expect(session.playbackEvidence?.confirmed, isFalse);
        expect(session.playbackEvidence?.reason, 'candidate_not_published');

        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidate',
            url: session.url,
            detail: jsonEncode({
              'url': source,
              'title': '示例剧 - 第3集',
              'mime': 'application/vnd.apple.mpegurl',
              'pageUrl': 'https://player.example/embed/3',
              'frame': 'child-1',
              'document': 'document-1',
              'main': false,
              'epoch': 4,
            }),
          ),
        );
        expect(session.playbackEvidence?.confirmed, isTrue);
        expect(session.playbackEvidence?.autoSaveEligible, isTrue);

        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidate',
            url: session.url,
            detail: jsonEncode({
              'url': source,
              'title': '示例剧 - 第3集',
              'mime': 'application/vnd.apple.mpegurl',
              'pageUrl': 'https://player.example/embed/3',
              'frame': 'child-1',
              'document': 'document-1',
              'main': false,
              'epoch': 5,
            }),
          ),
        );
        expect(session.playbackEvidence?.confirmed, isFalse);
        expect(session.playbackEvidence?.reason, 'candidate_not_published');

        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidatesClear',
            url: session.url,
            detail: jsonEncode({
              'frame': 'child-1',
              'document': 'document-1',
              'main': false,
              'reason': 'snapshot',
            }),
          ),
        );
        expect(session.playbackEvidence, isNotNull);
        expect(session.playbackEvidence?.confirmed, isFalse);

        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: session.generation,
            kind: 'mediaCandidatesClear',
            url: session.url,
            detail: jsonEncode({
              'frame': 'child-1',
              'document': 'document-1',
              'main': false,
              'reason': 'route',
            }),
          ),
        );
        expect(session.playbackEvidence, isNull);
      } finally {
        await db.close();
      }
    },
  );
}
