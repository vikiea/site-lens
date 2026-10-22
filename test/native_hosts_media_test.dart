import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
