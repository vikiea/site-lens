import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:site_lens/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'video_fixture.dart';

class _ModernApp extends AppController {
  _ModernApp(super.db);
  @override
  Future<void> initialize() async {
    await super.initialize();
  }
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() condition,
  String message,
) async {
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail(message);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'configured system proxy carries discovery and HLS task downloads',
    (tester) async {
      const fixtureEnabled = bool.fromEnvironment(
        'SITE_LENS_PROXY_FIXTURE',
        defaultValue: false,
      );
      if (!fixtureEnabled) {
        debugPrint('SYSTEM_PROXY_FIXTURE_SKIPPED');
        return;
      }
      final network = MediaNetwork();
      final url = Uri.parse('http://site-lens-proxy.invalid/contract.m3u8');
      final route = await network.probeRoute(url);
      final routes = route.proxy
          .split(';')
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toList();
      expect(routes, isNotEmpty);
      expect(
        routes.every((entry) => entry.startsWith('PROXY ')),
        isTrue,
        reason: 'The explicitly enabled proxy fixture must be active without a direct bypass',
      );
      final cancel = Cancellation();
      final redirect = url.resolve('/redirect');
      final probe =
          await HttpProbe(
            allowLocal: false,
            routeForAttempt: (uri, attempt) =>
                network.probeRoute(uri, attempt: attempt),
          ).run(
            Candidate(id: 1, url: redirect, label: 'Synthetic proxy'),
            1,
            cancel,
          );
      expect(probe.status, ProbeStatus.reachable, reason: probe.reason);
      expect(probe.entryUrl, redirect);
      expect(probe.finalUrl, url.resolve('/landing'));
      expect(cancel.cancelled, isFalse);
      final http = ControlledHttp(
        allowLocal: false,
        mediaRouteForAttempt: (uri, attempt) =>
            network.route(uri, attempt: attempt),
      );
      // Both the redirect and the downloaded bytes must traverse the configured
      // proxy. This reserved host cannot resolve via ordinary public DNS.
      const expectedPlaylist =
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:4\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n'
          '#EXTINF:4,\n'
          'segment.ts\n'
          '#EXT-X-ENDLIST\n';
      final response = await http.fetch(
        url,
        connect: const {'*'},
        document: url,
        cancel: cancel,
        mediaRequest: true,
      );
      expect(response.status, HttpStatus.ok);
      expect(response.url, url);
      expect(response.bytes, utf8.encode(expectedPlaylist));
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/proxy-contract-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final db = AppDatabase(NativeDatabase.memory());
      final tasks = MediaTaskStore(directoryProvider: () async => root, db: db);
      try {
        final candidate = MediaCandidate(
          id: 'proxy-contract',
          hostId: 1,
          generation: 1,
          sourceUrl: Uri.parse('http://site-lens-proxy.invalid/watch'),
          mediaUrl: url,
          title: 'Synthetic proxy HLS',
          mime: 'application/vnd.apple.mpegurl',
          source: MediaCandidateSource.dom,
        );
        await db.saveMediaCandidate(candidate);
        final task = tasks.create(candidate);
        final service = MediaDownloadService(tasks: tasks, http: http);
        await service.startNative(task, candidate);
        final completed = tasks.task(task.id)!;
        expect(
          completed.state,
          MediaTaskState.playable,
          reason: completed.errorReason,
        );
        final playlist = await tasks.cachedFile(task.id);
        expect(playlist, isNotNull);
        final input = await const HlsPlaylistParser().parseFile(playlist!.uri);
        expect(input.segments, hasLength(1));
        expect(input.keys, isEmpty);
        expect(input.initSegments, isEmpty);
        final segment = File.fromUri(input.segments.single);
        final bytes = await segment.readAsBytes();
        // h264_ts/seg00.ts in the checked-in, synthetic Media3 fixture.
        expect(bytes, hasLength(57340));
        expect(
          sha256.convert(bytes).toString(),
          '1f6c73b3c87100dc375dac28190681a205ad8bb961351cfd07fcfafa656b43db',
        );
        final cachedPlaylist = await playlist.readAsString();
        expect(
          cachedPlaylist,
          expectedPlaylist.replaceFirst(
            'segment.ts',
            input.segments.single.pathSegments.last,
          ),
        );
        final expectedBytes = bytes.length + utf8.encode(cachedPlaylist).length;
        expect(completed.bytesDownloaded, expectedBytes);
        expect(completed.totalBytes, expectedBytes);
        expect(await tasks.cachedBytes(task.id), expectedBytes);
        debugPrint(
          'PROXY_SYSTEM_DISCOVERY_DOWNLOAD_PASS '
          'redirect=landing exactPlaylist=true segmentSha256=true '
          'bytes=${completed.bytesDownloaded}',
        );
        await service.delete(task.id);
      } finally {
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  testWidgets(
    'passive native diagnostics read API, codecs and HCPP without hosts or media',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      try {
        await tester.pumpWidget(const SizedBox());
        final hostCount = app.hosts.sessions.length;
        expect(hostCount, 0);
        Future<void> expectReadOnly() async {
          expect(app.hosts.sessions.length, hostCount);
          expect(app.browserTabs, isEmpty);
          expect(app.browserSurfaceActive, isFalse);
          expect(find.byType(AndroidView), findsNothing);
          expect(app.nativeMedia.active, isNull);
          expect(app.mediaPlayback.active, isNull);
          expect(app.mediaTasks.tasks, isEmpty);
          expect(await db.mediaTasks(), isEmpty);
          expect(
            await db.customSelect('SELECT id FROM media_candidates').get(),
            isEmpty,
          );
        }

        await app.initialize();
        await expectReadOnly();
        // Use the actual Pigeon channel as well as the app-owned service. A
        // missing channel must fail rather than pass via the service fallback.
        final native = await DeviceDiagnosticsApi().readSnapshot();
        await expectReadOnly();
        final service = app.deviceDiagnostics;
        final snapshot = await service.refresh();
        await service.refreshHcpp();
        await expectReadOnly();
        final codecs = await service.readCodecInventory();
        await expectReadOnly();
        expect(snapshot.platform.toLowerCase(), 'android');
        expect(snapshot.apiLevel, native.apiLevel);
        expect(snapshot.apiLevel, greaterThan(0));
        expect(snapshot.capturedAtMs, greaterThan(0));
        expect(
          snapshot.capabilities.where((row) => row.id == 'diagnostics.native'),
          isEmpty,
        );
        expect(codecs.every((row) => row.name.isNotEmpty), isTrue);
        final rows = {
          for (final row in app.deviceDiagnosticRecords) row.id: row,
        };
        final mediaControl = rows['webview.mediaControl']!;
        final mediaFeatures = jsonDecode(mediaControl.detailsJson!) as Map;
        final hasUnknownMediaFeature = mediaFeatures.values.any(
          (feature) => feature == null,
        );
        final documentStart = mediaFeatures['documentStart'] == true;
        final webMessageListener = mediaFeatures['webMessageListener'] == true;
        final expectedMediaControl =
            !hasUnknownMediaFeature &&
            mediaFeatures['muteAudio'] == true &&
            documentStart &&
            webMessageListener;
        expect(mediaControl.configured, isTrue);
        if (hasUnknownMediaFeature) {
          expect(mediaControl.effective, isNull);
          expect(mediaControl.state, CapabilityState.error);
        } else {
          expect(mediaControl.effective, expectedMediaControl);
          expect(
            mediaControl.state,
            expectedMediaControl
                ? CapabilityState.supported
                : CapabilityState.unsupported,
          );
        }
        final engine = rows['platform.hcpp.engine']!;
        final manifest = rows['platform.hcpp.manifest']!;
        expect(manifest.effective, isNull);
        expect(
          manifest.state,
          manifest.configured == null
              ? CapabilityState.unknown
              : manifest.configured!
              ? CapabilityState.supported
              : CapabilityState.unsupported,
        );
        if (snapshot.apiLevel! < 34) {
          expect(engine.state, CapabilityState.notApplicable);
          expect(engine.effective, isNull);
        } else {
          expect(engine.effective, service.hcppSupported);
          expect(
            engine.state,
            service.hcppError != null
                ? CapabilityState.error
                : service.hcppSupported == null
                ? CapabilityState.unknown
                : service.hcppSupported!
                ? CapabilityState.supported
                : CapabilityState.unsupported,
          );
        }
        if (!service.effectiveHcpp) {
          expect(rows['platform.renderer']!.state, CapabilityState.unknown);
          expect(rows['platform.renderer']!.observed, isNull);
        }
        final playback = rows['media.playback.session']!;
        expect(playback.state, CapabilityState.unknown);
        expect(playback.observed, isNull);
        debugPrint(
          'MODERN_DIAGNOSTICS_READ_ONLY_PASS '
          'api=${snapshot.apiLevel} webView=${snapshot.webViewProvider ?? "unknown"} '
          'hcppEngine=${service.hcppSupported ?? "unknown"} '
          'hcppState=${engine.state.name} '
          'manifestConfigured=${manifest.configured ?? "unknown"} '
          'codecs=${codecs.length} '
          'mediaControl=${mediaControl.effective} '
          'mediaFeatures=${mediaControl.detailsJson} '
          'hardwareUnknown=${codecs.where((row) => row.hardwareAccelerated == null).length} '
          'hosts=${app.hosts.sessions.length}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'real WebView explicit episode data survives DOM mirrors and revokes SPA sources',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final requestedPaths = <String>[];
      server.listen((request) async {
        requestedPaths.add(request.uri.path);
        if (request.uri.path != '/video/42/') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(r'''<!doctype html>
<html><head><meta name="viewport" content="width=device-width">
<title>Mapped first series</title></head><body style="margin:12px">
<button id="next" style="width:220px;height:72px" onclick="advance(event)">Next synthetic page</button>
<p id="state"></p><p id="bounds"></p>
<div id="stale-mirror" data-play-src="/episode-1.mp4">Unlabelled mirror</div>
<div id="mirror" data-play-src="/episode-2.webm">Another unlabelled mirror</div>
<article data-play-id="400"><div data-play-src="/recommended.mp4">Recommendation</div></article>
<a href="/recommendation.html">Recommended title</a>
<a href="/episode-8.html">第8集</a>
<script type="application/json" id="videoInitialData">
{"id":42,"title":"Mapped first series","epPlaySrcs":{"1":"/episode-1.mp4","2":"/episode-2.webm"},"total":8,"recommendations":[{"url":"/recommendation.html"}],"episodes":[{"number":8,"url":"/episode-8.html"}]}
</script>
<script>
let taps = 0, lastTrusted = null;
function state(trusted) {
  if (trusted != null) lastTrusted = trusted;
  document.querySelector('#state').textContent = JSON.stringify({taps, trusted:lastTrusted, path:location.pathname});
  const r = document.querySelector('#next').getBoundingClientRect();
  document.querySelector('#bounds').textContent = JSON.stringify([r.left+r.width/2,r.top+r.height/2,innerWidth]);
}
function advance(event) {
  taps++;
  if (taps === 1) {
    history.pushState({}, '', '/video/42/ep-2/');
    state(event.isTrusted);
    return;
  }
  const ambiguous = taps === 3;
  history.pushState({}, '', ambiguous ? '/video/88/' : '/video/77/');
  document.title = ambiguous ? 'Ambiguous series' : 'Mapped next series';
  const data = JSON.parse(document.querySelector('#videoInitialData').textContent);
  data.id = ambiguous ? 88 : 77;
  data.title = document.title;
  data.epPlaySrcs = ambiguous
    ? {'5':'/shared.webm','6':'/shared.webm'}
    : {'3':'/episode-3.mp4','4':'/episode-4.webm'};
  document.querySelector('#videoInitialData').textContent = JSON.stringify(data);
  document.querySelector('#mirror').setAttribute('data-play-src', ambiguous ? '/shared.webm' : '/episode-3.mp4');
  // The unchanged old mirror deliberately stays in the DOM across SPA routes.
  state(event.isTrusted);
}
window.addEventListener('load', () => state(null));
window.addEventListener('resize', () => state(null));
</script></body></html>''');
        }
        await request.response.close();
      });
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      try {
        await app.initialize();
        final origin = Uri.parse('http://127.0.0.2:${server.port}');
        final tab = await app.openUrl(origin.resolve('/video/42/'));
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [browserRouteObserver],
            home: BrowserScreen(app: app, site: tab.site),
          ),
        );
        await _wait(
          tester,
          () => tab.host.loaded,
          'Episode fixture not loaded',
        );

        Future<String> inspectText(String selector) async =>
            (await app.hosts.api.inspect(tab.host.id, selector)).text;
        Future<List<MediaCandidate>> candidatesFor(
          String page,
          Map<String, int?> episodes,
        ) async {
          final deadline = DateTime.now().add(const Duration(seconds: 45));
          DateTime? stableSince;
          var latest = <MediaCandidate>[];
          while (DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            // Inspect every stored candidate so a stale generation cannot be
            // hidden by the current-generation accessor or display grouping.
            latest = tab.host.mediaCandidates.values.toList();
            final matches =
                latest.length == episodes.length &&
                latest.map((item) => item.mediaUrl.path).toSet().length ==
                    episodes.length &&
                latest.every(
                  (item) =>
                      item.generation == tab.host.generation &&
                      item.sourceUrl == origin.resolve(page) &&
                      item.source == MediaCandidateSource.dom &&
                      episodes.containsKey(item.mediaUrl.path) &&
                      mediaEpisodeLabel(item.title) ==
                          (episodes[item.mediaUrl.path] == null
                              ? null
                              : '第${episodes[item.mediaUrl.path]}集'),
                );
            if (matches) {
              stableSince ??= DateTime.now();
              if (DateTime.now().difference(stableSince) >=
                  const Duration(milliseconds: 750)) {
                expect(
                  app.hosts.mediaCandidates(tab.host),
                  hasLength(episodes.length),
                );
                return latest;
              }
            } else {
              stableSince = null;
            }
          }
          fail(
            'Episode snapshot for $page did not settle: '
            '${latest.map((item) => item.toJson()).toList()}',
          );
        }

        Future<void> tapNext(int expectedTaps) async {
          await _wait(
            tester,
            () => find.byType(AndroidView).evaluate().isNotEmpty,
            'Native WebView not mounted',
          );
          var bounds = await inspectText('#bounds');
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (bounds.isEmpty && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            bounds = await inspectText('#bounds');
          }
          final point = (jsonDecode(bounds) as List).cast<num>();
          final view = find.byType(AndroidView);
          expect(view, findsOneWidget);
          final scale = tester.getSize(view).width / point[2];
          await tester.tapAt(
            tester.getTopLeft(view) +
                Offset(point[0] * scale, point[1] * scale),
          );
          var state = <String, dynamic>{};
          final tapDeadline = DateTime.now().add(const Duration(seconds: 10));
          while (DateTime.now().isBefore(tapDeadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            state =
                jsonDecode(await inspectText('#state')) as Map<String, dynamic>;
            if (state['taps'] == expectedTaps) break;
          }
          expect(state['taps'], expectedTaps);
          expect(
            state['trusted'],
            isTrue,
            reason: 'SPA update requires a real tap',
          );
        }

        final first = await candidatesFor('/video/42/', {
          '/episode-1.mp4': 1,
          '/episode-2.webm': 2,
        });
        for (final candidate in first) {
          expect(
            app.hosts.authorizeMediaCandidate(tab.host.id, candidate.id).id,
            candidate.id,
          );
        }
        await tapNext(1);
        await candidatesFor('/video/42/ep-2/', {
          '/episode-1.mp4': 1,
          '/episode-2.webm': 2,
        });
        await tapNext(2);
        final second = await candidatesFor('/video/77/', {
          '/episode-3.mp4': 3,
          '/episode-4.webm': 4,
        });
        for (final candidate in first) {
          expect(
            () => app.hosts.authorizeMediaCandidate(tab.host.id, candidate.id),
            throwsStateError,
          );
        }
        await tapNext(3);
        await candidatesFor('/video/88/', {'/shared.webm': null});
        for (final candidate in second) {
          expect(
            () => app.hosts.authorizeMediaCandidate(tab.host.id, candidate.id),
            throwsStateError,
          );
        }
        expect(app.hosts.sessions, hasLength(1));
        expect(app.mediaTasks.tasks, isEmpty);
        expect(await db.mediaTasks(), isEmpty);
        expect(app.nativeMedia.active, isNull);
        expect(app.mediaPlayback.active, isNull);
        expect(
          requestedPaths.where(
            (path) => path != '/video/42/' && path != '/favicon.ico',
          ),
          isEmpty,
          reason: 'Discovery must not fetch media, recommendations or episode pages',
        );
        debugPrint(
          'MODERN_EXPLICIT_EPISODES_SPA_PASS first=1,2 next=3,4 ambiguous=unknown',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
        await server.close(force: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'modern settings, twelve themes, full backup and cold tab restore',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      try {
        await app.load();
        await app.db.createProfile('验收档案');
        await app.scripts.save(
          '// ==UserScript==\n// @name Backup fixture\n// @match https://example.com/*\n// @grant GM_getValue\n// ==/UserScript==\n',
        );
        await app.load();
        final script = app.installed.single;
        await db.setValue(script.id, 'acceptance-value', 42);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appControllerProvider.overrideWithValue(app)],
            child: const SiteLensApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        expect(find.text('浏览'), findsOneWidget);
        expect(find.text('外观'), findsOneWidget);
        expect(find.text('不透明度'), findsOneWidget);
        for (final preset in ThemePresetId.values) {
          await app.setThemePreset(preset);
          await app.setThemeModePreference(ThemeModePreference.light);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<MaterialApp>(find.byType(MaterialApp))
                .theme!
                .colorScheme
                .primary,
            buildSiteLensTheme(preset, Brightness.light).colorScheme.primary,
          );
        }
        await app.setThemeModePreference(ThemeModePreference.dark);
        await app.sessionStore.save([
          SavedBrowserTab(
            id: 'cold-a',
            initialUrl: Uri.parse('https://a.example/'),
            currentUrl: Uri.parse('https://a.example/new'),
            title: '冷标签 A',
          ),
          SavedBrowserTab(
            id: 'cold-b',
            initialUrl: Uri.parse('https://b.example/'),
            currentUrl: Uri.parse('https://b.example/'),
            title: '冷标签 B',
          ),
        ], 'cold-a');
        await app.restoreSavedSessions(force: true);
        expect(app.hosts.sessions, isEmpty);
        final exported = await app.exportBackup();
        final snapshot = await app.inspectBackup(exported);
        await db.setValue(script.id, 'acceptance-value', 100);
        await app.restoreBackup(snapshot);
        expect((await db.values(script.id))['acceptance-value'], 42);
        expect(app.installed.single.enabled, false);
        expect(app.installed.single.approvedDigest, isNull);
        expect(app.themePreset, ThemePresetId.values.last);
        expect(app.themeModePreference, ThemeModePreference.dark);
        expect(app.hosts.sessions, isEmpty);
        expect(app.browserTabs.map((t) => t.id), ['cold-a', 'cold-b']);
        expect(app.activeBrowser!.currentUrl.path, '/new');
        expect(app.browserTabs.every((t) => t.loadedHost == null), true);
        debugPrint('MODERN_BACKUP_THEMES_COLD_RESTORE_PASS');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
  );

  testWidgets(
    'real WebView media route pause, background playback and system controls',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/video.webm') {
          request.response.headers.contentType = ContentType('video', 'webm');
          request.response.add(base64Decode(webmVideoFixtureBase64));
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '''<!doctype html><meta name="viewport" content="width=device-width"><title>Site Lens debug media acceptance</title>
          <main><button id="play" style="width:200px;height:80px" onclick="play()">播放验收视频</button>
          <video id="video" muted playsinline loop src="/video.webm" width="200" height="120"></video><p id="state"></p><p id="bounds"></p></main>
          <script>let audio,failure='';const video=document.querySelector('#video');
          function status(){document.querySelector('#state').textContent=JSON.stringify({paused:video.paused,audio:audio?.state||'none',failure,ready:video.readyState,error:video.error?.code,codec:video.canPlayType('video/webm; codecs="vp8"')});}
          function play(){if(!audio){audio=new AudioContext();const o=audio.createOscillator(),g=audio.createGain();g.gain.value=0;o.connect(g);g.connect(audio.destination);o.start();audio.onstatechange=status;}audio.resume().catch(e=>{failure='audio:'+e.name;status();});video.play().catch(e=>{failure=e.name+':'+e.message;status();});status();}
          for(const e of ['play','pause','playing']) video.addEventListener(e,status);
          window.addEventListener('load',()=>{const r=document.querySelector('#play').getBoundingClientRect();document.querySelector('#bounds').textContent=JSON.stringify([r.left+r.width/2,r.top+r.height/2,innerWidth]);status();});</script>''',
          );
        }
        await request.response.close();
      });
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      final phase = File(
        '${(await getApplicationSupportDirectory()).path}/media_acceptance_phase',
      );
      final navigator = GlobalKey<NavigatorState>();
      try {
        await phase.writeAsString('idle');
        await app.initialize();
        await app.updateSettings({'autoHideBrowserControls': false});
        final tab = await app.openUrl(
          Uri.parse('http://127.0.0.2:${server.port}/media'),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [browserRouteObserver],
            home: BrowserScreen(app: app, site: tab.site),
          ),
        );
        await _wait(tester, () => tab.host.loaded, 'Media fixture not loaded');
        await app.syncMediaPolicy();
        expect(app.mediaSupported, true);
        Future<Map<String, dynamic>> state() async {
          final text = (await app.hosts.api.inspect(
            tab.host.id,
            '#state',
          )).text;
          return jsonDecode(text) as Map<String, dynamic>;
        }

        Future<void> awaitState(bool paused) async {
          final end = DateTime.now().add(const Duration(seconds: 45));
          while (DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 150));
            final value = await state();
            if (value['paused'] == paused &&
                value['audio'] == (paused ? 'suspended' : 'running')) {
              return;
            }
          }
          fail('Media state did not become paused=$paused: ${await state()}');
        }

        Future<void> play() async {
          final point = (jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#bounds')).text,
          ) as List).cast<num>();
          final view = find.byType(AndroidView);
          final scale = tester.getSize(view).width / point[2];
          await tester.tapAt(
            tester.getTopLeft(view) +
                Offset(point[0] * scale, point[1] * scale),
          );
          await awaitState(false);
        }

        await play();
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('二级页面'))),
          ),
        );
        await awaitState(true);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await play();
        await app.setAllowBackgroundPlayback(true);
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('后台播放验收'))),
          ),
        );
        await tester.pumpAndSettle();
        await awaitState(false);
        // The acceptance driver sends real MediaSession buttons / notification action.
        for (final command in ['pause', 'resume', 'stop']) {
          await phase.writeAsString(command, flush: true);
          await awaitState(command != 'resume');
          debugPrint('MEDIA_SYSTEM_${command.toUpperCase()}_PASS');
        }
        final other = await app.openUrl(
          Uri.parse('http://127.0.0.2:${server.port}/other'),
        );
        await app.activateTab(other);
        await awaitState(true);
        await app.closeAllTabs();
        debugPrint('MODERN_MEDIA_PASS');
      } finally {
        if (await phase.exists()) await phase.delete();
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
