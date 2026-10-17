import 'package:site_lens/settings/settings_repository.dart';

import 'dart:io';
import 'dart:convert';

import 'video_fixture.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/discovery/probe_coordinator.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

const fixture = '''<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Contract fixture</title></head><body>
<main><h1>Unprivileged fixture</h1><p id="result">Waiting for approved user script</p><p id="page-bridge"></p><p id="cookie-state"></p><p id="local-state"></p><a href="/next">Next document</a></main>
<iframe src="/frame"></iframe><script>
document.querySelector('#page-bridge').textContent = String(typeof window.lensBridge !== 'undefined' || !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lensBridge));
document.querySelector('#cookie-state').textContent = document.cookie;
document.querySelector('#local-state').textContent = localStorage.getItem('browser-secret') || '';
</script></body></html>''';
String userScript(
  String name,
  String body, {
  String grants = '// @grant GM_setValue\n// @grant GM_getValue',
  String phase = 'document-end',
}) =>
    '// ==UserScript==\n// @name $name\n// @match http://127.0.0.1/*\n// @run-at $phase\n$grants\n// ==/UserScript==\n$body';
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native host contract: isolation, DOM, GM, profiles, navigation and fail-closed',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var privateNetworkHits = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        switch (request.uri.path) {
          case '/video.mp4':
            request.response.headers.contentType = ContentType('video', 'mp4');
            request.response.add(base64Decode(videoFixtureBase64));
          case '/video':
            request.response.write(
              '<!doctype html><meta name="viewport" content="width=device-width"><main><video id="video" controls playsinline src="/video.mp4" width="240" height="144"></video><button id="fullscreen" onclick="document.getElementById(&quot;video&quot;).requestFullscreen()">Enter video fullscreen</button><p id="bounds"></p></main><script>window.addEventListener("load", () => { const r = document.querySelector("#fullscreen").getBoundingClientRect(); document.querySelector("#bounds").textContent = JSON.stringify([r.left+r.width/2, r.top+r.height/2, innerWidth]); });</script>',
            );
          case '/publish':
            request.response.write(
              '<html><body><section id="latest-addresses"><h2>最新地址</h2><p>正在读取最新可用的入口地址列表</p><a href="http://127.0.0.1:${server.port}/publish">本站</a></section><a href="https://unrelated.example/">其他导航</a><script>setTimeout(() => { document.querySelector("#latest-addresses").innerHTML = `<h2>最新地址</h2><a href="https://\${document.documentElement.dataset.startPhase ? "scripts-must-not-run" : "business"}.example/">站点入口</a><a href="https://backup-publish.example/">备用发布页</a>`; }, 200);</script></body></html>',
            );
            break;
          case '/private-network':
            privateNetworkHits++;
            request.response.write('secret');
          case '/empty':
            request.response.write(
              '<html><body>HTTP 200 is not readiness</body></html>',
            );
          case '/captcha':
            request.response.write(
              '<html><body><main>验证码 人机验证 captcha, not a usable homepage</main></body></html>',
            );
          case '/frame':
            request.response.write(
              '<html><body><script>parent.document.body.dataset.iframeBridge = String(typeof lensBridge !== "undefined" || !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lensBridge));</script></body></html>',
            );
          case '/set-cookie':
            request.response.cookies.add(
              Cookie('browser-session', 'private-browser-secret')
                ..httpOnly = false
                ..path = '/',
            );
            request.response.write(
              fixture.replaceFirst(
                '</script>',
                "localStorage.setItem('browser-secret','kept-only-in-browser');</script>",
              ),
            );
          default:
            request.response.write(fixture);
        }
        await request.response.close();
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/');
      final db = AppDatabase(NativeDatabase.memory());
      final service = ScriptService(db, ControlledHttp());
      final hosts = NativeHosts(db, service, ControlledHttp());
      final created = <HostSession>[];
      Future<T> step<T>(String label, Future<T> action) async {
        debugPrint('STEP begin $label');
        try {
          final result = await action.timeout(const Duration(seconds: 10));
          debugPrint('STEP done $label');
          return result;
        } catch (e) {
          debugPrint('STEP failed $label: $e');
          rethrow;
        }
      }

      Future<HostSession> create(HostPurpose purpose) async {
        final h = await step('create ${purpose.name}', hosts.create(purpose));
        created.add(h);
        return h;
      }

      Future<PageSnapshot> until(
        HostSession host,
        String selector,
        bool Function(PageSnapshot) accepts,
      ) async {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 10)) {
          await step(
            'pump $selector',
            tester.pump(const Duration(milliseconds: 100)),
          );
          try {
            final s = await hosts.api
                .inspect(host.id, selector)
                .timeout(const Duration(seconds: 2));
            if (accepts(s)) return s;
          } catch (_) {}
        }
        fail('Timed out waiting for $selector on ${host.url}; ${host.error}');
      }

      try {
        debugPrint('CHECKPOINT create browser');
        final browser = await create(HostPurpose.browsing);
        await hosts.api.setHostActivity(browser.id, true, true, true, false);
        debugPrint(
          'HOST_CAPABILITIES ${browser.capabilities.platform}: ${browser.capabilities.reason}',
        );
        debugPrint('CHECKPOINT mount native view');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Platform.isAndroid
                  ? AndroidView(
                      viewType: 'site_lens/web_host',
                      creationParams: {'hostId': browser.id},
                      creationParamsCodec: const StandardMessageCodec(),
                    )
                  : UiKitView(
                      viewType: 'site_lens/web_host',
                      creationParams: {'hostId': browser.id},
                      creationParamsCodec: const StandardMessageCodec(),
                    ),
            ),
          ),
        );
        debugPrint('CHECKPOINT save scripts');
        final attack = await service.save(
          userScript(
            'A identity',
            '''
(async function() {
  const prior = GM_getValue('modern', 0);
  GM_setValue('count', 7);
  const sync = GM_getValue('count', 0);
  await GM.setValue('modern', 11);
  const modern = await GM.getValue('modern');
  GM_addStyle('main { border: 1px solid green; }');
  const menu = GM_registerMenuCommand('Contract menu', () => { document.querySelector('#result').textContent = 'menu-invoked'; });
  GM_unregisterMenuCommand(GM_registerMenuCommand('Removed', () => {}));
  lensBridge.postMessage(JSON.stringify({ id: 'spoof', token: __lensBridgeToken, scriptId: 'other-script', revision: 'forged-revision', op: 'setValue', args: { key: 'native-identity', value: 'belongs-to-A' } }));
  let denied = false;
  try { await GM.xmlHttpRequest({url: '${url.resolve('/private-network')}', timeout: 1000}); } catch (_) { denied = true; }
  document.querySelector('#result').textContent = JSON.stringify({sync, modern, denied, prior, start: document.documentElement.dataset.startPhase, other: document.documentElement.dataset.otherStored});
})().catch(console.error);
''',
            grants: '// @grant GM_setValue\n// @grant GM_getValue\n// @grant GM_addStyle\n// @grant GM_registerMenuCommand\n// @grant GM_unregisterMenuCommand\n// @grant GM.setValue\n// @grant GM.getValue\n// @grant GM.xmlHttpRequest\n// @connect *',
          ),
        );
        final other = await service.save(
          userScript(
            'B isolated storage',
            "document.documentElement.dataset.otherStored = String(GM_getValue('count', 'empty'));",
          ),
        );
        final start = await service.save(
          userScript(
            'C document start',
            "document.documentElement.dataset.startPhase = document.readyState;",
            phase: 'document-start',
            grants: '// @grant GM_addStyle',
          ),
        );
        await step('approve A', service.enable(attack, Cancellation()));
        await step('approve B', service.enable(other, Cancellation()));
        await step('approve C', service.enable(start, Cancellation()));
        debugPrint('CHECKPOINT configure scripts');
        await step('configure', hosts.configure(browser));
        debugPrint('CHECKPOINT navigate fixture');
        await step('navigate fixture', hosts.navigate(browser, url));
        await until(browser, 'main', (s) => s.ready);
        debugPrint('CHECKPOINT fixture ready');
        final pageBridge = await step(
          'inspect page bridge',
          hosts.api.inspect(browser.id, '#page-bridge'),
        );
        expect(pageBridge.text, 'false');
        if (browser.capabilities.isolatedScripts) {
          final state = await until(
            browser,
            '#result',
            (s) =>
                s.text.startsWith('{') &&
                browser.menus.length == 1 &&
                browser.menus.values.single.label == 'Contract menu',
          );
          expect(jsonDecode(state.text), {
            'sync': 7,
            'modern': 11,
            'denied': true,
            'prior': 0,
            'start': 'loading',
            'other': 'empty',
          });
          expect(privateNetworkHits, 0);
          expect(
            (await db.values(attack.id))['native-identity'],
            'belongs-to-A',
          );
          expect(await db.values(other.id), isEmpty);
          expect(browser.menus.values.map((m) => m.label), ['Contract menu']);
          final menu = browser.menus.values.single;
          await step('invoke menu', hosts.invokeMenu(browser, menu));
          await until(browser, '#result', (s) => s.text == 'menu-invoked');
        } else {
          expect(
            (await db.values(attack.id)),
            isEmpty,
            reason: 'Unsupported provider must never gain privileges',
          );
          expect(
            (await hosts.api.inspect(browser.id, '#result')).text,
            'Waiting for approved user script',
          );
          debugPrint(
            'ENHANCED_CONTRACT_NOT_ACCEPTED: provider lacks required native isolation/lifecycle features. Fail-closed path tested.',
          );
        }
        final before = browser.generation;
        await step(
          'navigate next',
          hosts.navigate(browser, url.resolve('/next')),
        );
        await until(browser, 'main', (s) => s.ready && s.url.endsWith('/next'));
        expect(browser.generation, greaterThan(before));
        if (browser.capabilities.isolatedScripts) {
          await until(
            browser,
            '#result',
            (s) =>
                s.text.startsWith('{') &&
                (jsonDecode(s.text) as Map)['prior'] == 11,
          );
        }
        if (browser.capabilities.privateProbes) {
          await db.addSource(
            url.resolve('/publish'),
            'fixture publisher',
            '@latest-addresses',
          );
          await step(
            'render publisher',
            PublishingDiscovery(db, hosts).refresh(Cancellation()),
          );
          expect(
            (await db.candidates()).map((c) => c.url.host),
            ['business.example'],
            reason: 'Rendered latest region only, backup excluded, no user scripts in discovery',
          );
          expect((await db.sources()).single.error, isNull);
        }
        if (Platform.isAndroid) {
          debugPrint('CHECKPOINT video fullscreen');
          await step(
            'navigate video',
            hosts.navigate(browser, url.resolve('/video')),
          );
          final bounds = await until(
            browser,
            '#bounds',
            (s) => s.text.startsWith('['),
          );
          final point = (jsonDecode(bounds.text) as List).cast<num>();
          final nativeView = find.byType(AndroidView);
          final origin = tester.getTopLeft(nativeView);
          final scale = tester.getSize(nativeView).width / point[2];
          final interactionsBeforeTap = browser.interactions;
          await tester.tapAt(
            origin + Offset(point[0] * scale, point[1] * scale),
          );
          final deadline = Stopwatch()..start();
          while (!browser.fullscreen &&
              deadline.elapsed < const Duration(seconds: 5)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            browser.fullscreen,
            true,
            reason: 'Real native WebView touch must enter video custom view',
          );
          expect(browser.interactions, greaterThan(interactionsBeforeTap));
          final currentUrl = browser.url;
          expect(await hosts.api.goBack(browser.id), true);
          await tester.pump(const Duration(milliseconds: 200));
          expect(browser.fullscreen, false);
          expect(
            browser.url,
            currentUrl,
            reason: 'Back exits fullscreen before navigating history',
          );
          await step('navigate fixture', hosts.navigate(browser, url));
          await until(browser, 'main', (s) => s.ready && s.url.endsWith('/'));
        }
        // Global recovery really removes registration and reloads a clean document.
        await SettingsRepository(db).update({'scriptsDisabled': true});
        await step('configure', hosts.configure(browser));
        await step('reload', hosts.api.reload(browser.id));
        await until(
          browser,
          '#result',
          (s) => s.text == 'Waiting for approved user script',
        );
        expect(browser.menus, isEmpty);
        if (browser.capabilities.privateProbes) {
          await step(
            'navigate cookie',
            hosts.navigate(browser, url.resolve('/set-cookie')),
          );
          await until(
            browser,
            'main',
            (s) => s.ready && s.url.endsWith('/set-cookie'),
          );
          await step('navigate fixture', hosts.navigate(browser, url));
          await until(
            browser,
            '#cookie-state',
            (s) => s.text.contains('private-browser-secret'),
          );
          final probe = await create(HostPurpose.verification);
          await hosts.navigate(probe, url);
          await until(probe, 'main', (s) => s.ready);
          expect((await hosts.api.inspect(probe.id, '#cookie-state')).text, '');
          expect((await hosts.api.inspect(probe.id, '#local-state')).text, '');
          expect(
            (await hosts.api.inspect(browser.id, '#local-state')).text,
            'kept-only-in-browser',
          );
          final challenge = await NativeHomepageVerifier(hosts).verify(
            Candidate(id: 99, url: url.resolve('/captcha'), label: 'captcha'),
            9,
            Cancellation(),
          );
          expect(challenge.status, ProbeStatus.challenge);
          final cancellation = Cancellation();
          final old = NativeHomepageVerifier(hosts).verify(
            Candidate(id: 100, url: url.resolve('/empty'), label: 'empty'),
            9,
            cancellation,
          );
          await tester.pump(const Duration(milliseconds: 200));
          cancellation.cancel();
          expect((await old).status, ProbeStatus.cancelled);
        } else {
          await expectLater(
            hosts.create(HostPurpose.verification),
            throwsA(isA<PlatformException>()),
          );
          debugPrint(
            'PRIVATE_PROBE_CONTRACT_NOT_ACCEPTED: unavailable profile; no fallback into browsing store.',
          );
        }
        await hosts.navigate(browser, url);
        await until(browser, 'main', (s) => s.ready && s.url.endsWith('/'));
        await hosts.navigate(browser, url.resolve('/next'));
        await until(browser, 'main', (s) => s.ready && s.url.endsWith('/next'));
        expect(await hosts.api.goBack(browser.id), true);
        await until(browser, 'main', (s) => s.ready && s.url.endsWith('/'));
        expect(await hosts.api.goForward(browser.id), true);
        await until(browser, 'main', (s) => s.ready && s.url.endsWith('/next'));
        await hosts.destroy(browser);
        await expectLater(
          hosts.api.inspect(browser.id, 'main'),
          throwsA(isA<PlatformException>()),
        );
      } finally {
        for (final host in created) {
          await hosts.destroy(host);
        }
        await tester.pumpWidget(const SizedBox());
        await db.close();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
