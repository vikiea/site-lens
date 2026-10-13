import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';

import 'video_fixture.dart';

class _ModernApp extends AppController {
  _ModernApp(super.db);
  @override
  Future<void> initialize() async {
    await load();
    await restoreSavedSessions();
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
  testWidgets('modern settings, six themes, full backup and cold tab restore', (
    tester,
  ) async {
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWithValue(app)],
          child: const SiteLensApp(),
        ),
      );
      await tester.pumpAndSettle();
      // The app uses a custom labelled bottom row so the icon and label share
      // one selected capsule; assert its public semantics instead of relying
      // on Material NavigationDestination internals.
      expect(find.bySemanticsLabel('设置'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('设置'));
      await tester.pumpAndSettle();
      expect(find.text('脚本管理'), findsOneWidget);
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
      expect(app.themePreset, ThemePresetId.graphiteBlue);
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
  });

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
        await app.load();
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
