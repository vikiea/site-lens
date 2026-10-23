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

HostEvent _event(HostSession session, int episode) => HostEvent(
  hostId: session.id,
  generation: session.generation,
  kind: 'mediaCandidate',
  url: session.url,
  detail: jsonEncode({
    'url': 'https://cdn.example/episode.m3u8?episode=$episode',
    'title': 'Episode $episode',
    'mime': 'application/vnd.apple.mpegurl',
    'pageUrl': 'https://player.example/embed/$episode',
    'frame': 'child-1',
    'document': 'document-1',
    'main': false,
  }),
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
}
