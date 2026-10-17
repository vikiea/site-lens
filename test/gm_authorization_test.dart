import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

class SnapshotApi extends WebHostApi {
  final calls = <String>[];
  @override
  Future<PageSnapshot> inspect(int hostId, String selector) async =>
      PageSnapshot(
        url: 'https://example.com/',
        title: 'fixture',
        generation: 1,
        ready: true,
        challenge: false,
        interactionRequired: false,
        links: [],
        text: 'fixture',
        error: '',
      );

  @override
  Future<void> notify(int hostId, String title, String body) async {
    calls.add('notify:$title:$body');
  }

  @override
  Future<void> openExternal(int hostId, String url) async {
    calls.add('openExternal:$url');
  }
}

class CancelAwareHttp extends ControlledHttp {
  int started = 0;
  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async {
    cancel.check();
    started++;
    return FetchResponse(
      url: url,
      status: 200,
      bytes: utf8.encode('ok'),
      headers: {},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'public mode cannot be enabled without explicit per-script confirmation',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final scripts = ScriptService(db, CancelAwareHttp());
      final script = await scripts.save(
        '// ==UserScript==\n'
        '// @name public-confirmation\n'
        '// @match https://example.com/*\n'
        '// @grant GM_xmlhttpRequest\n'
        '// @connect example.com\n'
        '// ==/UserScript==',
      );
      await expectLater(
        scripts.enable(
          script,
          Cancellation(),
          networkMode: ScriptNetworkMode.public,
        ),
        throwsA(isA<StateError>()),
      );
      final stored = (await db.scripts()).single;
      expect(stored.enabled, isFalse);
      expect(stored.publicConfirmed, isFalse);
      await db.close();
    },
  );

  test('public approval is revoked by mode changes and source edits', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final root = await Directory.systemTemp.createTemp('site-lens-public-');
    addTearDown(() => root.delete(recursive: true));
    final scripts = ScriptService(
      db,
      CancelAwareHttp(),
      sourceDirectory: () async => root,
    );
    final source =
        '// ==UserScript==\n'
        '// @name public\n'
        '// @match https://example.com/*\n'
        '// @grant GM_xmlhttpRequest\n'
        '// ==/UserScript==';
    final script = await scripts.save(source);
    await scripts.enable(
      script,
      Cancellation(),
      networkMode: ScriptNetworkMode.public,
      publicConfirmed: true,
    );
    expect((await db.scripts()).single.publicConfirmed, isTrue);
    expect(await scripts.registrations(), hasLength(1));
    await scripts.setNetworkMode(script.id, ScriptNetworkMode.public);
    expect(await scripts.registrations(), isEmpty);
    final edited = await scripts.save('$source\n// edited', id: script.id);
    expect(edited.id, script.id);
    expect(await scripts.registrations(), isEmpty);
    await db.close();
  });

  test(
    'registered media candidates survive a fresh host/session read',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final scripts = ScriptService(db, CancelAwareHttp());
      final script = await scripts.save(
        '// ==UserScript==\n// @name media\n// @match https://example.com/*\n// @grant SiteLens.registerMedia\n// ==/UserScript==',
      );
      await scripts.enable(script, Cancellation());
      final api = SnapshotApi();
      final hosts = NativeHosts(db, scripts, CancelAwareHttp(), api: api);
      final session = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'fixture',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: 'test',
        ),
      )..generation = 1;
      session.registered[script.id] =
          (await db.scripts()).single.approvedDigest!;
      hosts.sessions[1] = session;
      final request = GmRequest(
        hostId: 1,
        generation: 1,
        scriptId: script.id,
        revision: (await db.scripts()).single.approvedDigest!,
        documentUrl: 'https://example.com/',
        payload: jsonEncode({
          'id': 'media',
          'op': 'registerMedia',
          'args': {
            'url': 'https://cdn.example/video.mp4',
            'title': 'fixture',
            'mime': 'video/mp4',
          },
        }),
      );
      final result = jsonDecode(await hosts.onGmRequest(request));
      expect(result['ok'], isTrue);
      final candidate = await db.mediaCandidate(
        result['value']['id'] as String,
      );
      expect(candidate?.mediaUrl.toString(), 'https://cdn.example/video.mp4');
      expect(candidate?.source, MediaCandidateSource.registered);
      await db.close();
    },
  );

  test(
    'registerMedia rejects stale generations and credential-bearing URLs',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final scripts = ScriptService(db, CancelAwareHttp());
      final script = await scripts.save(
        '// ==UserScript==\n// @name media\n// @match https://example.com/*\n// @grant SiteLens.registerMedia\n// ==/UserScript==',
      );
      await scripts.enable(script, Cancellation());
      final revision = (await db.scripts()).single.approvedDigest!;
      final hosts = NativeHosts(
        db,
        scripts,
        CancelAwareHttp(),
        api: SnapshotApi(),
      );
      final session =
          HostSession(
              1,
              HostPurpose.browsing,
              HostCapabilities(
                platform: 'fixture',
                isolatedScripts: true,
                documentStart: true,
                privateProbes: true,
                reason: 'test',
              ),
            )
            ..generation = 1
            ..registered[script.id] = revision;
      hosts.sessions[1] = session;
      GmRequest request({required int generation, required String url}) =>
          GmRequest(
            hostId: 1,
            generation: generation,
            scriptId: script.id,
            revision: revision,
            documentUrl: 'https://example.com/',
            payload: jsonEncode({
              'id': 'candidate',
              'op': 'registerMedia',
              'args': {'url': url, 'title': 'fixture', 'mime': 'video/mp4'},
            }),
          );

      final stale = jsonDecode(
        await hosts.onGmRequest(
          request(generation: 2, url: 'https://cdn.example/video.mp4'),
        ),
      );
      expect(stale['ok'], isFalse);
      for (final url in [
        'blob:https://example.com/opaque',
        'https://user:password@cdn.example/video.mp4',
      ]) {
        final rejected = jsonDecode(
          await hosts.onGmRequest(request(generation: 1, url: url)),
        );
        expect(rejected['ok'], isFalse);
      }
      expect(
        await db
            .customSelect('SELECT COUNT(*) AS count FROM media_candidates')
            .getSingle()
            .then((row) => row.read<int>('count')),
        0,
      );
      await db.close();
    },
  );

  test(
    'approved revision bound, and immediate abort wins before XHR registration',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final http = CancelAwareHttp();
      final scripts = ScriptService(db, http);
      final s = await scripts.save(
        '// ==UserScript==\n// @name network\n// @match https://example.com/*\n// @grant GM_xmlhttpRequest\n// @grant GM_notification\n// @grant GM_openInTab\n// @connect example.com\n// ==/UserScript==',
      );
      await scripts.enable(s, Cancellation());
      final approved = (await db.scripts()).single.approvedDigest!;
      final api = SnapshotApi();
      final hosts = NativeHosts(db, scripts, http, api: api);
      final session = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'fixture',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: 'test',
        ),
      )..generation = 1;
      session.registered[s.id] = approved;
      hosts.sessions[1] = session;
      GmRequest request(
        String op,
        Map<String, dynamic> args, {
        String? revision,
      }) => GmRequest(
        hostId: 1,
        generation: 1,
        scriptId: s.id,
        revision: revision ?? approved,
        documentUrl: 'https://example.com/',
        payload: jsonEncode({'id': 'test', 'op': op, 'args': args}),
      );
      final obsolete = jsonDecode(
        await hosts.onGmRequest(
          request('xhr', {
            'requestId': 'old',
            'url': 'https://example.com/',
          }, revision: 'old-revision'),
        ),
      );
      expect(obsolete['ok'], false);
      expect(http.started, 0);
      final aborted = jsonDecode(
        await hosts.onGmRequest(request('xhrAbort', {'requestId': 'early'})),
      );
      expect(aborted['ok'], true);
      final response = jsonDecode(
        await hosts.onGmRequest(
          request('xhr', {'requestId': 'early', 'url': 'https://example.com/'}),
        ),
      );
      expect(response['ok'], false);
      expect(http.started, 0);
      final notified = jsonDecode(
        await hosts.onGmRequest(
          request('notify', {'title': 'Title', 'body': 'Body'}),
        ),
      );
      final opened = jsonDecode(
        await hosts.onGmRequest(
          request('openExternal', {'url': 'https://example.com/next'}),
        ),
      );
      expect(notified['ok'], true);
      expect(opened['ok'], true);
      expect(api.calls, [
        'notify:Title:Body',
        'openExternal:https://example.com/next',
      ]);
      hosts.sessions.clear();
      session.cancellation.cancel();
      await db.close();
    },
  );
}
