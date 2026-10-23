import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:site_lens/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/device_diagnostics_screen.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/ui_primitives.dart';
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
    'configured system proxy carries HTTP HLS and verified HTTPS app downloads',
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

        Future<void> downloadNative(
          Uri mediaUrl, {
          required String identity,
          required int length,
          required String sha,
        }) async {
          final nativeCandidate = MediaCandidate(
            id: 'proxy-contract-$identity',
            hostId: 1,
            generation: 1,
            sourceUrl: mediaUrl,
            mediaUrl: mediaUrl,
            title: 'Synthetic proxy $identity media',
            mime: 'video/mp4',
            source: MediaCandidateSource.dom,
          );
          await db.saveMediaCandidate(nativeCandidate);
          final nativeTask = tasks.create(nativeCandidate);
          final nativeService = MediaDownloadService(
            tasks: tasks,
            native: NativeDownloadRuntime(),
          );
          try {
            await nativeService.startNative(nativeTask, nativeCandidate);
            final deadline = DateTime.now().add(const Duration(seconds: 45));
            while (DateTime.now().isBefore(deadline)) {
              final current = await nativeService.refreshTask(nativeTask.id);
              if (current.state == MediaTaskState.playable ||
                  current.state == MediaTaskState.failed ||
                  current.state == MediaTaskState.reauthorize) {
                break;
              }
              await tester.pump(const Duration(milliseconds: 250));
            }
            final completedNative = tasks.task(nativeTask.id)!;
            expect(
              completedNative.state,
              MediaTaskState.playable,
              reason: completedNative.errorReason,
            );
            expect(completedNative.localRef, isNotNull);
            final nativeBytes = await File(completedNative.localRef!)
                .readAsBytes();
            expect(nativeBytes, hasLength(length));
            expect(sha256.convert(nativeBytes).toString(), sha);
          } finally {
            await nativeService.delete(nativeTask.id);
          }
        }

        // HTTP and HTTPS use the same native Worker, independently of the
        // deterministic Dart HLS parser exercised above.
        await downloadNative(
          url.resolve('/direct.mp4'),
          identity: 'direct',
          length: 115175,
          sha: '4580dd745934f4174abc1081095adf1b9a0fa723669d2557047515006c81f8f5',
        );
        debugPrint('PROXY_NATIVE_DIRECT_DOWNLOAD_PASS bytes=115175');

        // This immutable, public repository fixture has a normal trusted TLS
        // certificate. The local proxy only tunnels encrypted bytes; no test
        // CA, TLS interception or certificate exception is installed.
        final httpsUrl = Uri.parse(
          'https://raw.githubusercontent.com/vikiea/site-lens/'
          '77e0e0233143a918bd458af724ec19fb919d7320/test/fixtures/video.mp4',
        );
        for (final httpsRoute in [
          await network.probeRoute(httpsUrl),
          await network.route(httpsUrl),
        ]) {
          final entries = httpsRoute.proxy.split(';').map((s) => s.trim());
          expect(entries, isNotEmpty);
          expect(entries.every((s) => s.startsWith('PROXY ')), isTrue);
        }
        Future<Map<String, dynamic>> checkpoint(
          String phase,
          String edge,
        ) async {
          final response = await http.fetch(
            url.resolve('/https-checkpoint/$phase/$edge'),
            connect: const {'*'},
            document: url,
            cancel: cancel,
            mediaRequest: true,
          );
          expect(response.status, HttpStatus.ok);
          return jsonDecode(utf8.decode(response.bytes))
              as Map<String, dynamic>;
        }

        Future<void> verifyHttps(
          String phase,
          Future<void> Function() action,
        ) async {
          final before = await checkpoint(phase, 'before');
          await action();
          final after = await checkpoint(phase, 'after');
          expect(
            after['sentBytes'] as int,
            greaterThan(before['sentBytes'] as int),
          );
          expect(
            after['receivedBytes'] as int,
            greaterThan(before['receivedBytes'] as int),
          );
          debugPrint('PROXY_HTTPS_PHASE_PASS phase=$phase wireBytes=true');
        }

        await verifyHttps('probe', () async {
          final httpsProbe =
              await HttpProbe(
                allowLocal: false,
                routeForAttempt: (uri, attempt) =>
                    network.probeRoute(uri, attempt: attempt),
              ).run(
                Candidate(id: 2, url: httpsUrl, label: 'Synthetic HTTPS'),
                1,
                cancel,
              );
          expect(
            httpsProbe.status,
            ProbeStatus.reachable,
            reason: httpsProbe.reason,
          );
          expect(httpsProbe.finalUrl, httpsUrl);
        });
        final expectedHttps = base64Decode(videoFixtureBase64);
        const httpsSha =
            '2dc91b5ca138e4da5f65c245552d9aa8a7f885d9314d1ae12e5b2c4e0c3f2eae';
        expect(expectedHttps, hasLength(1878));
        expect(sha256.convert(expectedHttps).toString(), httpsSha);
        await verifyHttps('dart', () async {
          final httpsResponse = await http.fetch(
            httpsUrl,
            connect: const {'*'},
            document: httpsUrl,
            cancel: cancel,
            mediaRequest: true,
          );
          expect(httpsResponse.status, HttpStatus.ok);
          expect(httpsResponse.bytes, expectedHttps);
        });
        await verifyHttps('nativeTls', () async {
          final nativeTls = File('${root.path}/https-native.part');
          await network.transferFile(
            httpsUrl,
            httpsUrl,
            nativeTls,
            expectedHttps.length,
            cancel,
          );
          expect(await nativeTls.readAsBytes(), expectedHttps);
        });
        await verifyHttps('worker', () async {
          await downloadNative(
            httpsUrl,
            identity: 'https',
            length: expectedHttps.length,
            sha: httpsSha,
          );
        });
        debugPrint(
          'PROXY_HTTPS_APP_PASS probe=true dartBytes=true nativeTls=true '
          'worker=true bytes=1878',
        );
        await verifyHttps('hls', () async {
          // Upstream Media3's complete, fixed, small fMP4 VOD fixture.
          // Apache-2.0 source; fetched only in this opt-in device test.
          final playlistUrl = Uri.parse(
            'https://raw.githubusercontent.com/androidx/media/'
            'b7bbc6e2bc3e45ff3ed99884c114c50f03bba5c9/'
            'libraries/test_data/src/test/assets/media/hls/multi-segment/playlist.m3u8',
          );
          final manifest = await http.fetch(
            playlistUrl,
            connect: const {'*'},
            document: playlistUrl,
            cancel: cancel,
            mediaRequest: true,
          );
          expect(manifest.status, HttpStatus.ok);
          expect(manifest.bytes, hasLength(200));
          expect(
            sha256.convert(manifest.bytes).toString(),
            '76d64fa3c7adb700c08d09340aeacc002526b4ede7fd60e1785e41843a2433fc',
          );
          final hlsCandidate = MediaCandidate(
            id: 'proxy-contract-https-hls',
            hostId: 1,
            generation: 1,
            sourceUrl: playlistUrl,
            mediaUrl: playlistUrl,
            title: 'Upstream Media3 HTTPS HLS fixture',
            mime: 'application/vnd.apple.mpegurl',
            source: MediaCandidateSource.dom,
          );
          await db.saveMediaCandidate(hlsCandidate);
          final hlsTask = tasks.create(hlsCandidate);
          final hlsService = MediaDownloadService(
            tasks: tasks,
            http: http,
            tlsTransfer: network.transferFile,
          );
          try {
            final completed = await hlsService.startNative(
              hlsTask,
              hlsCandidate,
            );
            expect(completed.state, MediaTaskState.playable);
            final cached = await tasks.cachedFile(hlsTask.id);
            expect(cached, isNotNull);
            final local = await const HlsPlaylistParser().parseFile(
              cached!.uri,
            );
            expect(local.segments, hasLength(2));
            expect(local.initSegments, hasLength(1));
            expect(local.keys, isEmpty);
            const HlsInputValidator().validate(
              playlist: local.playlist,
              segments: local.segments,
              initSegment: local.initSegment,
              initSegments: local.initSegments,
              keys: local.keys,
            );
            final resources = [
              (
                local.initSegments.single,
                3779,
                '00954d45f53935eb89220cb777dc5fba1a5c5b736c03b6588f9e25c6e4e80f24',
              ),
              (
                local.segments[0],
                220265,
                'ca8a7548ff3e94f4f7e78fe74544f5c1f9f01b3f947b1bf98879213a37cb23a9',
              ),
              (
                local.segments[1],
                203292,
                '6634c25dbe26952456bd3382d20e1c67b6151644f045f5fb9c2d879e2255a311',
              ),
            ];
            for (final (resource, length, sha) in resources) {
              final bytes = await File.fromUri(resource).readAsBytes();
              expect(bytes, hasLength(length));
              expect(sha256.convert(bytes).toString(), sha);
            }
            expect(
              await tasks.cachedBytes(hlsTask.id),
              completed.bytesDownloaded,
            );
            debugPrint(
              'PROXY_HTTPS_HLS_PASS segments=2 init=1 keys=0 resourcesSha256=true',
            );
          } finally {
            await hlsService.delete(hlsTask.id);
          }
        });
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
        final privateDns = rows['network.privateDns']!;
        if (snapshot.apiLevel! < 28) {
          expect(privateDns.state, CapabilityState.notApplicable);
          expect(privateDns.effective, isNull);
        } else {
          expect(privateDns.reason, contains('未查询域名'));
          expect(
            privateDns.state,
            anyOf(CapabilityState.supported, CapabilityState.unknown),
          );
          if (privateDns.effective != null) {
            expect(privateDns.observed, isNotNull);
          }
        }
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
    'high quality codec inventory reaches the end and reverses without nested scrolling',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      try {
        await app.load();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appControllerProvider.overrideWithValue(app)],
            child: const SiteLensApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        final settings = find.byType(SettingsPage);
        final settingsScroll = find.descendant(
          of: settings,
          matching: find.byType(Scrollable),
        );
        expect(settingsScroll, findsOneWidget);
        Finder setting(String title) =>
            find.descendant(of: settings, matching: find.text(title));
        await tester.scrollUntilVisible(
          setting('高质量'),
          150,
          scrollable: settingsScroll,
        );
        await tester.tap(setting('高质量'));
        await tester.pumpAndSettle();
        final coverage = setting('高质量覆盖全部面板');
        await tester.scrollUntilVisible(
          coverage,
          150,
          scrollable: settingsScroll,
        );
        if (!app.settings.highQualityAllSurfaces) {
          await tester.tap(coverage);
          await tester.pumpAndSettle();
        }
        expect(app.settings.glassQualityMode, SiteLensGlassQualityMode.high);
        expect(app.settings.highQualityAllSurfaces, isTrue);
        // A grouped panel may already have built rows below the viewport.
        // Scroll the page until the actual entry can receive the tap.
        final diagnosticsEntry = setting('设备能力');
        for (
          var attempt = 0;
          diagnosticsEntry.hitTestable().evaluate().isEmpty && attempt < 24;
          attempt++
        ) {
          await tester.drag(settingsScroll, const Offset(0, -220));
          await tester.pumpAndSettle();
        }
        expect(diagnosticsEntry.hitTestable(), findsOneWidget);
        await tester.tap(diagnosticsEntry);
        await tester.pumpAndSettle();
        final diagnostics = find.byType(DeviceDiagnosticsScreen);
        final diagnosticsScroll = find.descendant(
          of: diagnostics,
          matching: find.byType(Scrollable),
        );
        expect(diagnosticsScroll, findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('编解码器清单').hitTestable(),
          200,
          scrollable: diagnosticsScroll,
          maxScrolls: 30,
        );
        expect(find.text('编解码器清单').hitTestable(), findsOneWidget);
        await tester.tap(find.text('编解码器清单').hitTestable());
        await tester.pumpAndSettle();
        final screen = find.byType(CodecInventoryScreen);
        final viewport = find.descendant(
          of: screen,
          matching: find.byType(Scrollable),
        );
        expect(viewport, findsOneWidget);
        final list = find.byKey(const PageStorageKey('device-codec-list'));
        expect(list, findsOneWidget);
        final panel = find.descendant(
          of: screen,
          matching: find.byType(SiteLensListPanel),
        );
        final plan = SiteLensGlassPolicyScope.of(tester.element(panel))
            .resolve(tester.element(panel), role: SiteLensSurfaceRole.panel);
        expect(plan.quality, GlassQuality.premium);
        expect(
          plan.useCompatibilityFallback,
          isFalse,
          reason: 'This acceptance requires the real high-quality shader path',
        );
        final glass = find.descendant(
          of: panel,
          matching: find.byType(AdaptiveGlass),
        );
        expect(glass, findsOneWidget);
        expect(
          tester.widget<AdaptiveGlass>(glass).quality,
          GlassQuality.premium,
        );
        final position = tester.state<ScrollableState>(viewport).position;
        expect(position.viewportDimension, greaterThan(0));
        expect(
          tester.getSize(glass).height,
          lessThanOrEqualTo(tester.getSize(screen).height),
        );
        await tester.tap(find.text('读取清单'));
        await _wait(
          tester,
          () => find.byKey(const ValueKey('codec-0')).evaluate().isNotEmpty,
          'Native codec inventory did not appear',
        );
        final codecs = await app.deviceDiagnostics.readCodecInventory();
        expect(codecs.length, greaterThan(20));
        final last = find.byKey(ValueKey('codec-${codecs.length - 1}'));
        final lastTitle = find.descendant(
          of: last,
          // Compact rows shorten visual copy, but retain the complete native
          // identity in the tooltip and accessible label.
          matching: find.byTooltip(codecs.last.name),
        );
        expect(last, findsNothing);
        await tester.scrollUntilVisible(
          lastTitle,
          400,
          scrollable: viewport,
          maxScrolls: 200,
        );
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(find.byKey(const ValueKey('codec-0')), findsNothing);
        final collapsed = position.pixels;
        expect(collapsed, greaterThan(position.viewportDimension));
        await tester.tap(lastTitle);
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(collapsed, 1));
        await tester.scrollUntilVisible(
          find.textContaining('MIME：'),
          120,
          scrollable: viewport,
        );
        expect(find.textContaining('MIME：').hitTestable(), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(position.pixels, greaterThanOrEqualTo(collapsed));
        await tester.scrollUntilVisible(lastTitle, -120, scrollable: viewport);
        await tester.pumpAndSettle();
        final beforeCollapsePixels = position.pixels;
        final beforeCollapseTop = tester.getTopLeft(last).dy;
        await tester.tap(lastTitle);
        await tester.pumpAndSettle();
        expect(find.textContaining('MIME：'), findsNothing);
        // Collapsing the final detail may reduce maxScrollExtent below the
        // old position. Only that unavoidable end clamp may move the anchor.
        final expectedCollapsedPixels = beforeCollapsePixels.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        expect(position.pixels, closeTo(expectedCollapsedPixels, 1));
        expect(
          tester.getTopLeft(last).dy - beforeCollapseTop,
          closeTo(beforeCollapsePixels - position.pixels, 1),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('codec-list-end')),
          120,
          scrollable: viewport,
        );
        await tester.pumpAndSettle();
        final endLabel = find.textContaining('清单结束，共 ').hitTestable();
        expect(endLabel, findsOneWidget);
        final endText = tester.widget<Text>(endLabel).data!;
        final endCount = int.parse(
          RegExp(r'清单结束，共 (\d+) 项').firstMatch(endText)!.group(1)!,
        );
        expect(endCount, codecs.length);
        final bottom = position.pixels;
        await tester.drag(list, const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(position.pixels, lessThan(bottom));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('codec-0')),
          -400,
          scrollable: viewport,
          maxScrolls: 200,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('codec-0')).hitTestable(),
          findsOneWidget,
        );
        expect(position.pixels, lessThan(position.viewportDimension));
        expect(viewport, findsOneWidget);
        expect(app.hosts.sessions, isEmpty);
        expect(app.nativeMedia.active, isNull);
        expect(app.mediaTasks.tasks, isEmpty);
        expect(tester.takeException(), isNull);
        debugPrint(
          'HIGH_QUALITY_CODEC_SCROLL_PASS count=${codecs.length} '
          'quality=${plan.quality.name} fallback=${plan.useCompatibilityFallback} '
          'end=$bottom returned=${position.pixels} singleViewport=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'real WebView explicit episode data survives DOM mirrors and revokes SPA sources',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final requestedPaths = <String>[];
      server.listen((request) async {
        requestedPaths.add(request.uri.toString());
        if (request.uri.path == '/api/videos/77/play' &&
            request.uri.queryParameters['ep'] == '4') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'status': 1,
              'data': {
                'id': 77,
                'ep_num': 4,
                'video_url': '/episode-4.webm?series=77&version=0',
              },
            }),
          );
        } else if (request.uri.path != '/video/42/') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(r'''<!doctype html>
<html><head><meta name="viewport" content="width=device-width">
<title>Mapped first series</title></head><body style="margin:12px">
<button id="next" style="width:220px;height:72px" onclick="advance(event)">Next synthetic page</button>
<p id="state"></p><p id="bounds"></p>
<div id="stale-mirror" data-play-src="/episode-8.webm?series=42" data-episode="8">0 likes</div>
<div id="mirror" data-play-src="/episode-2.webm?series=42">Another unlabelled mirror</div>
<article data-play-id="400"><div data-play-src="/recommended.mp4">Recommendation</div></article>
<a href="/recommendation.html">Recommended title</a>
<a href="/episode-8.html">第8集</a>
<script type="application/json" id="videoInitialData">
{"id":42,"title":"Mapped first series","epPlaySrcs":{"1":"/episode-1.mp4?series=42","2":"/episode-2.webm?series=42","3":"/episode-3.mp4?series=42","4":"/episode-4.webm?series=42","5":"/episode-5.mp4?series=42","6":"/episode-6.webm?series=42","7":"/episode-7.mp4?series=42","8":"/episode-8.webm?series=42"},"total":8,"recommendations":[{"url":"/recommendation.html"}],"episodes":[{"number":8,"url":"/episode-8.html"}]}
</script>
<script>
let taps = 0, lastTrusted = null, responseReady = false;
function state(trusted) {
  if (trusted != null) lastTrusted = trusted;
  document.querySelector('#state').textContent = JSON.stringify({taps, trusted:lastTrusted, responseReady, path:location.pathname});
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
  if (taps === 3) {
    const xhr = new XMLHttpRequest();
    xhr.open('GET', '/api/videos/77/play?ep=4');
    xhr.onload = () => { responseReady = xhr.status === 200; state(event.isTrusted); };
    xhr.send();
    state(event.isTrusted);
    return;
  }
  const ambiguous = taps === 5;
  history.pushState({}, '', ambiguous ? '/video/88/' : (taps === 4 ? '/video/77/ep-4/' : '/video/77/'));
  document.title = ambiguous ? 'Ambiguous series' : 'Mapped next series';
  const data = JSON.parse(document.querySelector('#videoInitialData').textContent);
  data.id = ambiguous ? 88 : 77;
  data.title = document.title;
  data.epPlaySrcs = ambiguous
    ? {'1':'/shared.webm?series=88','2':'/shared.webm?series=88','3':'/shared.webm?series=88','4':'/shared.webm?series=88','5':'/shared.webm?series=88','6':'/shared.webm?series=88','7':'/shared.webm?series=88','8':'/shared.webm?series=88'}
    : {'1':'/episode-1.mp4?series=77','2':'/episode-2.webm?series=77','3':'/episode-3.mp4?series=77','4':'/episode-4.webm?series=77','5':'/episode-5.mp4?series=77','6':'/episode-6.webm?series=77','7':'/episode-7.mp4?series=77','8':'/episode-8.webm?series=77'};
  if (taps === 4) {
    for (const number of Object.keys(data.epPlaySrcs)) data.epPlaySrcs[number] += '&version=2';
  }
  document.querySelector('#videoInitialData').textContent = JSON.stringify(data);
  document.querySelector('#mirror').setAttribute('data-play-src', ambiguous ? '/shared.webm?series=88' : '/episode-1.mp4?series=77' + (taps === 4 ? '&version=2' : ''));
  // The old source stays in the DOM; changing a counter cannot rebind it.
  document.querySelector('#stale-mirror').textContent = `${taps} likes`;
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
                latest.map((item) => item.mediaUrl.toString()).toSet().length ==
                    episodes.length &&
                latest.every(
                  (item) =>
                      item.generation == tab.host.generation &&
                      item.sourceUrl == origin.resolve(page) &&
                      item.source == MediaCandidateSource.dom &&
                      episodes.containsKey(item.mediaUrl.toString()) &&
                      mediaEpisodeLabel(item.title) ==
                          (episodes[item.mediaUrl.toString()] == null
                              ? null
                              : '第${episodes[item.mediaUrl.toString()]}集'),
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

        Map<String, int> mappedEpisodes(int series) => {
          for (var episode = 1; episode <= 8; episode++)
            origin
                    .resolve(
                      '/episode-$episode.${episode.isOdd ? 'mp4' : 'webm'}?series=$series',
                    )
                    .toString():
                episode,
        };
        final first = await candidatesFor('/video/42/', mappedEpisodes(42));
        for (final candidate in first) {
          expect(
            app.hosts.authorizeMediaCandidate(tab.host.id, candidate.id).id,
            candidate.id,
          );
        }
        await tapNext(1);
        await candidatesFor('/video/42/ep-2/', mappedEpisodes(42));
        await tapNext(2);
        final second = await candidatesFor('/video/77/', mappedEpisodes(77));
        for (final candidate in first) {
          expect(
            () => app.hosts.authorizeMediaCandidate(tab.host.id, candidate.id),
            throwsStateError,
          );
        }
        await tapNext(3);
        final responseDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (DateTime.now().isBefore(responseDeadline)) {
          final state = jsonDecode(await inspectText('#state')) as Map;
          if (state['responseReady'] == true) break;
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          (jsonDecode(await inspectText('#state')) as Map)['responseReady'],
          true,
        );
        final withResponse = Map<String, int>.from(mappedEpisodes(77));
        withResponse.remove(
          origin.resolve('/episode-4.webm?series=77').toString(),
        );
        withResponse[origin
                .resolve('/episode-4.webm?series=77&version=0')
                .toString()] =
            4;
        await candidatesFor('/video/77/', withResponse);
        await tapNext(4);
        await candidatesFor('/video/77/ep-4/', {
          for (final entry in mappedEpisodes(77).entries)
            '${entry.key}&version=2': entry.value,
        });
        await tapNext(5);
        final ambiguousUrl = origin
            .resolve('/shared.webm?series=88')
            .toString();
        await candidatesFor('/video/88/', {ambiguousUrl: null});
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
            (path) =>
                path != '/video/42/' &&
                path != '/favicon.ico' &&
                path != '/api/videos/77/play?ep=4',
          ),
          isEmpty,
          reason: 'Discovery must not fetch media, recommendations or episode pages',
        );
        expect(
          requestedPaths.where((path) => path == '/api/videos/77/play?ep=4'),
          hasLength(1),
        );
        debugPrint(
          'MODERN_EXPLICIT_EPISODES_SPA_PASS first=1..8 next=1..8 exactResources=true textOnlyRetired=true newerMapWins=true ambiguous=unknown',
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
        final settings = find.byType(SettingsPage);
        expect(settings, findsOneWidget);
        final settingsScroll = find.descendant(
          of: settings,
          matching: find.byType(Scrollable),
        );
        Finder setting(String title) =>
            find.descendant(of: settings, matching: find.text(title));
        await tester.scrollUntilVisible(
          setting('浏览'),
          200,
          scrollable: settingsScroll,
        );
        expect(setting('浏览'), findsOneWidget);
        await tester.scrollUntilVisible(
          setting('外观'),
          -200,
          scrollable: settingsScroll,
        );
        expect(setting('外观'), findsOneWidget);
        expect(setting('不透明度'), findsOneWidget);
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
    'real WebView discovers same-page episode changes without refresh',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final fetched = <String>[];
      server.listen((request) async {
        if (request.uri.path == '/video.webm') {
          request.response.headers.contentType = ContentType('video', 'webm');
          request.response.add(base64Decode(webmVideoFixtureBase64));
        } else if (request.uri.path.endsWith('.m3u8')) {
          fetched.add(request.uri.path);
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write('''<!doctype html><meta name="viewport" content="width=device-width">
          <title>同页播放 第1集</title>
          <button id="next" style="width:200px;height:80px" onclick="next()">切换媒体</button>
          <video id="player" muted playsinline loop width="200" height="120" src="/video.webm"></video>
          <p id="state"></p><p id="bounds"></p><script>
          let selected=0; const video=document.querySelector('#player');
          function status(){document.querySelector('#state').textContent=JSON.stringify({selected,paused:video.paused,source:video.currentSrc,url:location.href});}
          async function next(){await video.play(); const url='/episode-'+(++selected)+'.m3u8';
            if(selected===1) await fetch(url).then(r=>r.text());
            else await new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest();xhr.open('GET',url);xhr.onload=resolve;xhr.onerror=reject;xhr.send();});status();}
          window.addEventListener('load',()=>{const r=document.querySelector('#next').getBoundingClientRect();document.querySelector('#bounds').textContent=JSON.stringify([r.left+r.width/2,r.top+r.height/2,innerWidth]);status();});
          </script>''');
        }
        await request.response.close();
      });
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      try {
        await app.initialize();
        await app.updateSettings({'autoHideBrowserControls': false});
        final page = Uri.parse('http://127.0.0.2:${server.port}/watch');
        final tab = await app.openUrl(page);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [browserRouteObserver],
            home: BrowserScreen(app: app, site: tab.site),
          ),
        );
        await _wait(
          tester,
          () => tab.host.loaded,
          'Same-page fixture not loaded',
        );
        await app.syncMediaPolicy();
        final generation = tab.host.generation;
        for (var episode = 1; episode <= 2; episode++) {
          final point = (jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#bounds')).text,
          ) as List).cast<num>();
          final view = find.byType(AndroidView);
          final scale = tester.getSize(view).width / point[2];
          await tester.tapAt(
            tester.getTopLeft(view) +
                Offset(point[0] * scale, point[1] * scale),
          );
          final expected = page.resolve('/episode-$episode.m3u8');
          await _wait(
            tester,
            () => app.hosts
                .mediaCandidates(tab.host)
                .any((item) => item.mediaUrl == expected),
            'Episode $episode was not discovered without refreshing',
          );
          final unbound = app.hosts
              .mediaCandidates(tab.host)
              .singleWhere((item) => item.mediaUrl == expected);
          expect(unbound.title, contains('集数未确认'));
          expect(mediaEpisodeLabel(unbound.title), isNull);
          var state = jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#state')).text,
          ) as Map<String, dynamic>;
          final stateDeadline = DateTime.now().add(const Duration(seconds: 5));
          while (state['selected'] != episode &&
              DateTime.now().isBefore(stateDeadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            state = jsonDecode(
              (await app.hosts.api.inspect(tab.host.id, '#state')).text,
            ) as Map<String, dynamic>;
          }
          expect(state['selected'], episode);
          expect(state['paused'], false);
          expect(state['source'], page.resolve('/video.webm').toString());
          expect(state['url'], page.toString());
          expect(tab.host.generation, generation);
        }
        expect(fetched, containsAll(['/episode-1.m3u8', '/episode-2.m3u8']));
        debugPrint(
          'SAME_PAGE_MEDIA_AUTO_DISCOVERY_PASS fetch=true xhr=true unchangedUrl=true unchangedPlayer=true unchangedGeneration=true unboundEpisodeUnknown=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'real WebView page restoration rejects late fetch and XHR episode responses',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final release = Completer<void>();
      final started = <String>{};
      final startedAt = <String, DateTime>{};
      server.listen((request) async {
        try {
          if (request.uri.path == '/api/videos/42/play') {
            final kind = request.uri.queryParameters['kind']!;
            started.add(kind);
            startedAt[kind] = DateTime.now();
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"status":1,"data":');
            await request.response.flush();
            await release.future;
            request.response.write(
              '${jsonEncode({'id': 42, 'ep_num': int.parse(request.uri.queryParameters['ep']!), 'video_url': '/poison-$kind.m3u8'})}}',
            );
          } else if (request.uri.path == '/fresh.m3u8') {
            request.response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            request.response.write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n',
            );
          } else {
            request.response.headers.contentType = ContentType.html;
            request.response.write(
              '''<!doctype html><meta name="viewport" content="width=device-width">
            <title>Restored episode fixture</title>
            <button id="restore" style="width:200px;height:80px" onclick="restore()">恢复页面</button>
            <p id="state"></p><p id="bounds"></p>
            <script type="application/json" id="videoInitialData">${jsonEncode({
                'id': 42,
                'title': 'Restored fixture',
                'epPlaySrcs': {'1': '/one.m3u8', '2': '/two.m3u8'},
              })}</script><script>
            const status={restored:false,fetch:false,xhr:false,fresh:false};
            function show(){document.querySelector('#state').textContent=JSON.stringify(status);}
            function restore(){window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));const node=document.querySelector('#videoInitialData'),data=JSON.parse(node.textContent);data.epPlaySrcs['3']='/fresh.m3u8';node.textContent=JSON.stringify(data);status.restored=true;show();fetch('/fresh.m3u8').then(r=>r.text()).then(()=>{status.fresh=true;show();});}
            fetch('/api/videos/42/play?ep=2&kind=fetch').then(r=>r.text()).then(()=>{status.fetch=true;show();});
            const xhr=new XMLHttpRequest();xhr.open('GET','/api/videos/42/play?ep=1&kind=xhr');xhr.onload=()=>{status.xhr=true;show();};xhr.send();
            window.addEventListener('load',()=>{const r=document.querySelector('#restore').getBoundingClientRect();document.querySelector('#bounds').textContent=JSON.stringify([r.left+r.width/2,r.top+r.height/2,innerWidth]);show();});
            </script>''',
            );
          }
          await request.response.close();
        } on HttpException {
          // Teardown may close a deliberately suspended fixture response.
        } on SocketException {
          // Teardown may close a deliberately suspended fixture response.
        }
      });
      final db = AppDatabase(NativeDatabase.memory());
      final app = _ModernApp(db);
      try {
        await app.initialize();
        await app.updateSettings({'autoHideBrowserControls': false});
        final page = Uri.parse('http://127.0.0.2:${server.port}/video/42/');
        final tab = await app.openUrl(page);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [browserRouteObserver],
            home: BrowserScreen(app: app, site: tab.site),
          ),
        );
        await _wait(
          tester,
          () => tab.host.loaded && started.length == 2,
          'Suspended episode requests did not start',
        );
        await _wait(
          tester,
          () => app.hosts
              .mediaCandidates(tab.host)
              .any((item) => item.mediaUrl == page.resolve('/two.m3u8')),
          'Original explicit map did not appear',
        );
        final generation = tab.host.generation;
        final bounds = (jsonDecode(
          (await app.hosts.api.inspect(tab.host.id, '#bounds')).text,
        ) as List).cast<num>();
        final view = find.byType(AndroidView);
        final scale = tester.getSize(view).width / bounds[2];
        await tester.tapAt(
          tester.getTopLeft(view) +
              Offset(bounds[0] * scale, bounds[1] * scale),
        );
        final end = DateTime.now().add(const Duration(seconds: 15));
        var restored = false;
        while (DateTime.now().isBefore(end)) {
          final state = jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#state')).text,
          ) as Map<String, dynamic>;
          if (state['restored'] == true) {
            restored = true;
            break;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(restored, isTrue);
        for (final sent in startedAt.values) {
          expect(
            DateTime.now().difference(sent),
            lessThan(const Duration(seconds: 4)),
            reason: 'Complete bodies before the five-second clone reader timeout; timeout must not explain rejection',
          );
        }
        release.complete();
        var finished = false;
        while (DateTime.now().isBefore(end)) {
          final state = jsonDecode(
            (await app.hosts.api.inspect(tab.host.id, '#state')).text,
          ) as Map<String, dynamic>;
          if (state.values.every((value) => value == true)) {
            finished = true;
            break;
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          finished,
          isTrue,
          reason: 'Page-owned fetch and XHR must finish after restoration',
        );
        for (final sent in startedAt.values) {
          expect(
            DateTime.now().difference(sent),
            lessThan(const Duration(seconds: 4)),
            reason: 'Body completion must stay inside the clone reader timeout',
          );
        }
        await _wait(
          tester,
          () => app.hosts
              .mediaCandidates(tab.host)
              .any((item) => item.mediaUrl == page.resolve('/fresh.m3u8')),
          'Fresh post-restoration resource not discovered',
        );
        await tester.pump(const Duration(seconds: 1));
        final media = app.hosts.mediaCandidates(tab.host);
        expect(
          media.any((item) => item.mediaUrl.path.startsWith('/poison-')),
          isFalse,
        );
        for (final (number, path) in [(1, '/one.m3u8'), (2, '/two.m3u8')]) {
          expect(
            media
                .singleWhere(
                  (item) => mediaEpisodeLabel(item.title) == '第$number集',
                )
                .mediaUrl,
            page.resolve(path),
          );
        }
        expect(tab.host.generation, generation);
        debugPrint(
          'MEDIA_PAGE_RESTORATION_LATE_RESPONSES_PASS fetch=true xhr=true staleRejected=true freshDiscovered=true syntheticPageEvents=true distinctEpisodes=true insideCloneBudget=true',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('real WebView media route pause, background playback and system controls', (
    tester,
  ) async {
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
          <article data-play-id="42"><video id="video" muted playsinline loop src="/video.webm?series=42&episode=1" width="200" height="120"></video></article>
          <article data-play-id="77"><video id="foreign" muted playsinline loop src="/video.webm?series=42&episode=4" width="80" height="48"></video></article>
          <p id="state"></p><p id="bounds"></p></main>
          <script type="application/json" id="videoInitialData">${jsonEncode({
            'id': 42,
            'title': 'Synthetic playback series',
            'epPlaySrcs': {for (var episode = 1; episode <= 8; episode++) '$episode': '/video.webm?series=42&episode=$episode'},
          })}</script>
          <script>let audio,failure='',playOrder=[];const video=document.querySelector('#video'),foreign=document.querySelector('#foreign');
          function status(){document.querySelector('#state').textContent=JSON.stringify({paused:video.paused,audio:audio?.state||'none',failure,ready:video.readyState,error:video.error?.code,source:video.currentSrc,foreignSource:foreign.currentSrc,foreignPaused:foreign.paused,foreignReady:foreign.readyState,playOrder,codec:video.canPlayType('video/webm; codecs="vp8"')});}
          async function play(){failure='';playOrder=[];if(!audio){audio=new AudioContext();const o=audio.createOscillator(),g=audio.createGain();g.gain.value=0;o.connect(g);g.connect(audio.destination);o.start();audio.onstatechange=status;}await audio.resume().catch(e=>{failure='audio:'+e.name;status();});await video.play().then(()=>playOrder.push('own'),e=>{failure=e.name+':'+e.message;status();});await foreign.play().then(()=>playOrder.push('foreign'),e=>{failure='foreign:'+e.name;status();});status();}
          for(const node of [video,foreign]) for(const e of ['play','pause','playing','loadedmetadata']) node.addEventListener(e,status);
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
        Uri.parse('http://127.0.0.2:${server.port}/video/42/'),
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
        final text = (await app.hosts.api.inspect(tab.host.id, '#state')).text;
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
          tester.getTopLeft(view) + Offset(point[0] * scale, point[1] * scale),
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
      final expectedForeign = tab.currentUrl.resolve(
        '/video.webm?series=42&episode=4',
      );
      final playbackDeadline = DateTime.now().add(const Duration(seconds: 15));
      var foreignPlaying = false;
      while (DateTime.now().isBefore(playbackDeadline)) {
        final value = await state();
        if (value['foreignPaused'] == false &&
            (value['foreignReady'] as num? ?? 0) >= 2 &&
            (value['playOrder'] as List).join(',') == 'own,foreign') {
          expect(value['failure'], isEmpty);
          expect(value['foreignSource'], expectedForeign.toString());
          foreignPlaying = true;
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        foreignPlaying,
        true,
        reason:
            'The foreign player must actually play after the current player: ${await state()}',
      );
      for (final (command, episode) in [('next', 2), ('previous', 1)]) {
        await phase.writeAsString(command, flush: true);
        final end = DateTime.now().add(const Duration(seconds: 45));
        var selected = false;
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 150));
          final value = await state();
          final expectedOwn = tab.currentUrl.resolve(
            '/video.webm?series=42&episode=$episode',
          );
          if (value['source'] == expectedOwn.toString() &&
              value['paused'] == false) {
            expect(value['foreignSource'], expectedForeign.toString());
            expect(value['foreignPaused'], false);
            expect(value['failure'], isEmpty);
            selected = true;
            break;
          }
        }
        expect(
          selected,
          true,
          reason:
              'System $command must change only the current series player: ${await state()}',
        );
        debugPrint(
          'MEDIA_SYSTEM_${command.toUpperCase()}_EPISODE_PASS episode=$episode foreignUnchanged=true',
        );
      }
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
  }, timeout: const Timeout(Duration(minutes: 5)));
}
