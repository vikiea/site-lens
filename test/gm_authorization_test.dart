import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
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
