import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'video_fixture.dart';

class _VisualApp extends AppController {
  _VisualApp(super.db);
  Future<void>? _ready;
  @override
  Future<void> initialize() => _ready ??= super.initialize();
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail(reason);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real HCPP compositor matrix with video and Flutter surfaces',
    (tester) async {
      const runId = String.fromEnvironment('SITE_LENS_VISUAL_RUN_ID');
      expect(
        RegExp(r'^[0-9a-f]{32}$').hasMatch(runId),
        isTrue,
        reason: 'Run with tool/run_android_visual_acceptance.py; compositor capture acknowledgement is required',
      );
      final support = await getApplicationSupportDirectory();
      final request = File('${support.path}/visual_acceptance_phase.json');
      final ack = File('${support.path}/visual_acceptance_ack');
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      server.listen((incoming) async {
        if (incoming.uri.path == '/video.webm') {
          incoming.response.headers.contentType = ContentType('video', 'webm');
          incoming.response.add(base64Decode(webmVideoFixtureBase64));
        } else {
          incoming.response.headers.contentType = ContentType.html;
          incoming.response.write(
            '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;background:#c9d4db;font:14px sans-serif;-webkit-text-size-adjust:none}main{box-sizing:border-box;width:100%;padding:16px;background:repeating-linear-gradient(45deg,#d5dfe7 0 20px,#eef2f5 20px 40px)}h1{font-size:20px}button{width:240px;max-width:100%;height:64px}video{display:block;width:100%;max-width:360px}p{min-height:72px;overflow-wrap:anywhere}#bounds{display:none}#state{font-size:12px}</style>
        <main><h1>HCPP native WebView fixture</h1><button id="play" onclick="startPlayback()">播放合成视频</button>
        <video id="video" muted playsinline loop src="/video.webm"></video><p id="bounds"></p><p id="state"></p>
        <p>Native page stripes 01</p><p>Native page stripes 02</p><p>Native page stripes 03</p><p>Native page end</p></main>
        <script>const video=document.querySelector('#video');let taps=0,failure='',pointer=null;
        function state(){const r=document.querySelector('#play').getBoundingClientRect(),v=visualViewport,z=video.getBoundingClientRect();
        const x=r.left+r.width/2,y=r.top+r.height/2;
        document.querySelector('#bounds').textContent=JSON.stringify([x-v.offsetLeft,y-v.offsetTop,v.width,innerWidth,document.documentElement.clientWidth,document.documentElement.scrollWidth,z.left-v.offsetLeft,z.top-v.offsetTop,z.right-v.offsetLeft,z.bottom-v.offsetTop]);
        document.querySelector('#state').textContent=JSON.stringify({taps,failure,pointer,paused:video.paused,ready:video.readyState,error:video.error?.code,time:video.currentTime,scroll:scrollY,hit:document.elementFromPoint(x,y)?.id});}
        document.addEventListener('pointerdown',e=>{pointer={x:e.clientX,y:e.clientY,target:e.target.id};state();});
        async function startPlayback(){taps++;failure='';try{await video.play();}catch(e){failure=e.name+':'+e.message;}state();}
        setInterval(state,250);window.addEventListener('load',state);</script>''',
          );
        }
        await incoming.response.close();
      });
      final db = AppDatabase(NativeDatabase.memory());
      final app = _VisualApp(db);
      var checkpointIndex = 0;
      try {
        await app.initialize();
        final diagnostics = await app.deviceDiagnostics.refresh();
        expect(
          app.deviceDiagnostics.effectiveHcpp,
          isTrue,
          reason: 'This matrix requires a real HCPP-capable engine',
        );
        expect(
          diagnostics.capabilities
              .singleWhere((row) => row.id == 'platform.hcpp.manifest')
              .configured,
          isTrue,
        );
        debugPrint(
          'HCPP_VISUAL_DEVICE api=${diagnostics.apiLevel} webView=${diagnostics.webViewProvider} engineHcpp=true manifestConfigured=true',
        );
        await app.updateSettings({
          'autoHideBrowserControls': false,
          'highQualityAllSurfaces': true,
          'glassQualityMode': SiteLensGlassQualityMode.high.name,
          'allowBackgroundPlayback': true,
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appControllerProvider.overrideWithValue(app)],
            child: const SiteLensApp(),
          ),
        );
        await tester.pumpAndSettle();
        final page = Uri.parse('http://127.0.0.2:${server.port}/visual');
        final tab = await app.openUrl(page);
        unawaited(
          siteLensNavigatorKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => BrowserScreen(app: app, site: tab.site),
            ),
          ),
        );
        await _wait(
          tester,
          () =>
              tab.host.loaded && find.byType(AndroidView).evaluate().isNotEmpty,
          'Real WebView did not load',
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        await app.syncMediaPolicy();
        final point = (jsonDecode(
          (await app.hosts.api.inspect(tab.host.id, '#bounds')).text,
        ) as List).cast<num>();
        expect(point[5], lessThanOrEqualTo(point[4]));
        final view = find.byType(AndroidView);
        final scale = tester.getSize(view).width / point[2];
        debugPrint(
          'HCPP_VISUAL_PLAY_TARGET origin=${tester.getTopLeft(view)} size=${tester.getSize(view)} dom=$point scale=$scale',
        );
        await tester.tapAt(
          tester.getTopLeft(view) + Offset(point[0] * scale, point[1] * scale),
        );
        final playingDeadline = DateTime.now().add(const Duration(seconds: 15));
        var playing = false;
        while (DateTime.now().isBefore(playingDeadline)) {
          final state = jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#state')).text,
          ) as Map<String, dynamic>;
          if (state['paused'] == false &&
              (state['ready'] as int) >= 2 &&
              (state['time'] as num) > 0) {
            playing = true;
            break;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          playing,
          isTrue,
          reason:
              'Playback state: ${(await app.hosts.api.inspect(tab.host.id, "#state")).text}',
        );
        final started = jsonDecode(
          (await app.hosts.api.inspect(tab.host.id, '#state')).text,
        ) as Map<String, dynamic>;
        expect(started['taps'], 1);
        expect((started['pointer'] as Map)['target'], 'play');
        expect(started['failure'], '');
        debugPrint('HCPP_VISUAL_PLAY_STARTED state=${jsonEncode(started)}');
        await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('browser-navigation')),
          findsOneWidget,
        );

        Future<void> checkpoint(String name) async {
          await tester.pumpAndSettle();
          Future<Map<String, dynamic>> state() async => jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#state')).text,
          ) as Map<String, dynamic>;
          final before = await state();
          expect(before['paused'], isFalse);
          expect(before['ready'] as int, greaterThanOrEqualTo(2));
          var advanced = false;
          final videoDeadline = DateTime.now().add(const Duration(seconds: 4));
          while (DateTime.now().isBefore(videoDeadline)) {
            await tester.pump(const Duration(milliseconds: 250));
            final after = await state();
            if (after['paused'] == false &&
                ((after['time'] as num) - (before['time'] as num)).abs() >
                    0.05) {
              advanced = true;
              break;
            }
          }
          expect(
            advanced,
            isTrue,
            reason: 'Native video must continue playing at $name',
          );
          expect(app.browserSurfaceActive, isTrue);
          expect(app.deviceDiagnostics.effectiveHcpp, isTrue);
          expect(tester.takeException(), isNull);
          final id = '${runId}_${checkpointIndex++}';
          final pending = File('${request.path}.part');
          await pending.writeAsString(
            jsonEncode({'runId': runId, 'id': id, 'name': name}),
            flush: true,
          );
          await pending.rename(request.path);
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (DateTime.now().isBefore(deadline)) {
            if (await ack.exists() && await ack.readAsString() == id) {
              debugPrint('HCPP_VISUAL_CHECKPOINT_PASS name=$name');
              return;
            }
            await tester.pump(const Duration(milliseconds: 100));
          }
          fail('Android compositor screenshot not acknowledged: $name');
        }

        for (final theme in [
          ThemeModePreference.light,
          ThemeModePreference.dark,
        ]) {
          await app.setThemeModePreference(theme);
          for (final opacity in [0, 55, 100]) {
            await app.updateSettings({'glassOpacity': opacity});
            await tester.pumpAndSettle();
            void expectAppearance(BuildContext context) {
              expect(
                Theme.of(context).brightness,
                theme == ThemeModePreference.light
                    ? Brightness.light
                    : Brightness.dark,
              );
              expect(
                Theme.of(context)
                    .extension<SiteLensGlassTheme>()!
                    .backgroundAlpha,
                opacity / 100,
              );
            }

            final browser = tester.element(find.byType(BrowserScreen));
            expectAppearance(browser);
            expect(
              Theme.of(browser).brightness,
              theme == ThemeModePreference.light
                  ? Brightness.light
                  : Brightness.dark,
            );
            expect(
              Theme.of(browser)
                  .extension<SiteLensGlassTheme>()!
                  .backgroundAlpha,
              opacity / 100,
            );
            final strategy = SiteLensGlassPolicyScope.of(browser);
            expect(
              strategy
                  .resolve(browser, role: SiteLensSurfaceRole.platformView)
                  .useCompatibilityFallback,
              isTrue,
            );
            final plan = strategy.resolve(
              browser,
              role: SiteLensSurfaceRole.panel,
            );
            expect(plan.quality, GlassQuality.premium);
            expect(plan.useCompatibilityFallback, isFalse);
            await checkpoint('${theme.name}-$opacity-browser');
            unawaited(
              showModalBottomSheet<void>(
                context: browser,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => SafeArea(
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.7,
                    child: SiteLensGlassSurface(
                      key: const ValueKey('visual-overlay-panel'),
                      role: SiteLensSurfaceRole.platformView,
                      padding: const EdgeInsets.all(
                        SiteLensMetrics.panelPadding,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Flutter 玻璃面板叠层'),
                          const Text('WebView 与视频保持挂载'),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭验证面板'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            // The fixture refreshes geometry every 250 ms. Read the actual
            // video edges and viewport after this sheet's layout settles.
            await tester.pump(const Duration(milliseconds: 300));
            final geometry = (jsonDecode(
              (await app.hosts.api.inspect(tab.host.id, '#bounds')).text,
            ) as List).cast<num>();
            final currentView = tester.getRect(find.byType(AndroidView));
            expect(geometry[2], greaterThan(0));
            final currentScale = currentView.width / geometry[2];
            final videoRect = Rect.fromLTRB(
              currentView.left + geometry[6] * currentScale,
              currentView.top + geometry[7] * currentScale,
              currentView.left + geometry[8] * currentScale,
              currentView.top + geometry[9] * currentScale,
            );
            expect(videoRect.isEmpty, isFalse);
            final overlay = tester.element(
              find.byKey(const ValueKey('visual-overlay-panel')),
            );
            final overlayRect = tester.getRect(
              find.byKey(const ValueKey('visual-overlay-panel')),
            );
            expect(overlayRect.overlaps(videoRect), isTrue);
            expect(overlayRect.top, greaterThan(videoRect.top));
            debugPrint(
              'HCPP_VISUAL_VIDEO_OVERLAP theme=${theme.name} opacity=$opacity video=$videoRect overlay=$overlayRect',
            );
            expectAppearance(overlay);
            final overlayPlan = SiteLensGlassPolicyScope.of(overlay)
                .resolve(overlay, role: SiteLensSurfaceRole.platformView);
            expect(overlayPlan.useCompatibilityFallback, isTrue);
            expect(overlayPlan.quality, GlassQuality.standard);
            expect(overlayPlan.glassColor.a, closeTo(opacity / 100, 0.00001));
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('visual-overlay-panel')),
                matching: find.byType(AdaptiveGlass),
              ),
              findsNothing,
            );
            expect(find.byType(AndroidView), findsOneWidget);
            await checkpoint('${theme.name}-$opacity-overlay');
            await tester.tap(find.text('关闭验证面板'));
            await tester.pumpAndSettle();
            unawaited(
              siteLensNavigatorKey.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => const SiteLensPageScaffold(
                    title: 'Flutter 渲染验证',
                    body: Padding(
                      padding: EdgeInsets.all(SiteLensMetrics.pagePadding),
                      child: SiteLensPanel(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Flutter 自有页面'),
                            Text('底层 WebView 保持挂载'),
                            Text('高质量 · 0 / 55 / 100'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final ownPanel = tester.element(find.byType(SiteLensPanel).last);
            expectAppearance(ownPanel);
            expect(
              SiteLensGlassPolicyScope.of(ownPanel)
                  .resolve(ownPanel, role: SiteLensSurfaceRole.panel)
                  .useCompatibilityFallback,
              isFalse,
            );
            expect(
              tester
                  .widget<AdaptiveGlass>(
                    find.descendant(
                      of: find.byType(SiteLensPanel).last,
                      matching: find.byType(AdaptiveGlass),
                    ),
                  )
                  .quality,
              GlassQuality.premium,
            );
            expect(
              tester
                  .widget<AdaptiveGlass>(
                    find.descendant(
                      of: find.byType(SiteLensPanel).last,
                      matching: find.byType(AdaptiveGlass),
                    ),
                  )
                  .settings
                  .glassColor
                  .a,
              closeTo(opacity / 100, 0.00001),
            );
            await checkpoint('${theme.name}-$opacity-flutter');
            siteLensNavigatorKey.currentState!.pop();
            await tester.pumpAndSettle();
            if (find.byTooltip('新建标签页').evaluate().isEmpty) {
              await tester.tap(find.byTooltip('更多浏览器操作'));
              await tester.pumpAndSettle();
            }
            await tester.tap(find.byTooltip('新建标签页'));
            await tester.pumpAndSettle();
            final dialog = find.byType(SiteLensAlertDialog);
            expect(
              tester.widget<SiteLensAlertDialog>(dialog).surfaceRole,
              SiteLensSurfaceRole.platformView,
            );
            final dialogPlan =
                SiteLensGlassPolicyScope.of(tester.element(dialog)).resolve(
                  tester.element(dialog),
                  role: SiteLensSurfaceRole.platformView,
                );
            expect(dialogPlan.useCompatibilityFallback, isTrue);
            expect(dialogPlan.glassColor.a, closeTo(opacity / 100, 0.00001));
            expect(
              find.descendant(of: dialog, matching: find.byType(AdaptiveGlass)),
              findsNothing,
            );
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expect(app.browserTabs, hasLength(1));
            expect(tester.takeException(), isNull);
            debugPrint(
              'HCPP_VISUAL_NATIVE_DIALOG_PASS theme=${theme.name} opacity=$opacity role=platformView fallback=true',
            );
          }
        }
        expect(checkpointIndex, 18);
        debugPrint(
          'HCPP_VISUAL_MATRIX_PASS hcpp=true flutterQuality=premium nativeOverlay=platformView themes=2 opacity=0,55,100 surfaces=3 captures=18',
        );
      } finally {
        for (final file in [request, File('${request.path}.part'), ack]) {
          if (await file.exists()) await file.delete();
        }
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
        await server.close(force: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
