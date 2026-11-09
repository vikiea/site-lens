import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';
import 'package:site_lens/background/native_health_probe.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_media_runtime.dart';
import 'package:site_lens/network/transport.dart';

const _enabled = bool.fromEnvironment('SITE_LENS_REAL_MEDIA_DOWNLOAD');
const _fixture = String.fromEnvironment('SITE_LENS_MEDIA_TEST_URL');
const _job = 'site-lens-network-reliability-acceptance';

@pragma('vm:entry-point')
void networkReliabilityDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task != _job) return true;
    final result = await NativeHealthProbe().check(
      Uri.parse(input!['url'] as String),
    );
    final root = await getApplicationSupportDirectory();
    await File('${root.path}/${input['result']}').writeAsString(
      jsonEncode({
        'reachable': result.reachable,
        'routeKind': result.routeKind,
        'failureCategory': result.failureCategory,
        'headless': true,
      }),
      flush: true,
    );
    return true;
  });
}

/// Opt-in current-network evidence. Uses only the supplied neutral public HLS
/// sample, in a temporary app-private directory; never opens the user's DB.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'headless health plugin observes current VPN route without Activity registration',
    (tester) async {
      final root = await getApplicationSupportDirectory();
      final name = 'health-probe-${DateTime.now().microsecondsSinceEpoch}.json';
      final resultFile = File('${root.path}/$name');
      await Workmanager().initialize(networkReliabilityDispatcher);
      try {
        await Workmanager().registerOneOffTask(
          _job,
          _job,
          inputData: {'url': _fixture, 'result': name},
        );
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!await resultFile.exists() &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(
          await resultFile.exists(),
          isTrue,
          reason: 'headless worker must execute and return evidence',
        );
        final result = jsonDecode(await resultFile.readAsString()) as Map;
        expect(result['headless'], isTrue);
        expect(
          result['reachable'],
          isTrue,
          reason: '${result['failureCategory']}',
        );
        expect(
          result['routeKind'],
          isIn([
            'vpn_tun_fake_ip',
            'http_proxy',
            'router_fake_ip',
            'public_direct',
          ]),
        );
        debugPrint(
          'HEADLESS_HEALTH_PASS route=${result['routeKind']} reachable=true',
        );
      } finally {
        await Workmanager().cancelByUniqueName(_job);
        if (await resultFile.exists()) await resultFile.delete();
      }
    },
    skip: !_enabled || _fixture.isEmpty,
  );

  testWidgets(
    'current VPN downloads encrypted HLS manifest key segment and plays native cache',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Network acceptance'))),
      );
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/network-acceptance-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final network = MediaNetwork();
      final player = NativeMediaRuntime();
      final url = Uri.parse(_fixture);
      try {
        final route = await network.route(url);
        debugPrint(
          'CURRENT_HLS_ROUTE kind=${route.routeKind} dns=${route.targetDnsMode} proxy=${route.proxyConfigured}',
        );
        Future<File> transfer(
          Uri uri,
          String name,
          String kind,
          int max,
        ) async {
          final file = File('${root.path}/$name.part');
          final result = await network.transferFileWithPolicy(
            uri,
            url,
            file,
            max,
            Cancellation(),
            maxAttempts: 5,
            startAttempt: 0,
            resourceKind: kind,
          );
          expect(result.attemptsUsed, inInclusiveRange(1, 5));
          expect(await file.length(), greaterThan(0));
          return file.rename('${root.path}/$name');
        }

        final manifest = await transfer(
          url,
          'remote.m3u8',
          'manifest',
          1024 * 1024,
        );
        final text = await manifest.readAsString();
        final lines = const LineSplitter().convert(text);
        final keyLine = lines.firstWhere(
          (line) => line.startsWith('#EXT-X-KEY:METHOD=AES-128,'),
        );
        final keyPath = RegExp(r'URI="([^"]+)"').firstMatch(keyLine)!.group(1)!;
        final segmentIndex = lines.indexWhere(
          (line) => line.startsWith('#EXTINF:'),
        );
        final key = await transfer(
          url.resolve(keyPath),
          'key.bin',
          'key',
          1024,
        );
        expect(await key.length(), 16);
        final segment = await transfer(
          url.resolve(lines[segmentIndex + 1]),
          'segment.ts',
          'segment',
          16 * 1024 * 1024,
        );
        final local = File('${root.path}/index.m3u8');
        await local.writeAsString(
          [
            '#EXTM3U',
            '#EXT-X-VERSION:3',
            '#EXT-X-TARGETDURATION:10',
            '#EXT-X-MEDIA-SEQUENCE:0',
            keyLine.replaceFirst(RegExp(r'URI="[^"]+"'), 'URI="key.bin"'),
            lines[segmentIndex],
            'segment.ts',
            '#EXT-X-ENDLIST',
            '',
          ].join('\n'),
        );
        final candidate = MediaCandidate(
          id: 'neutral-network',
          hostId: 1,
          generation: 1,
          sourceUrl: url,
          mediaUrl: url,
          title: 'Neutral network acceptance',
          mime: 'application/vnd.apple.mpegurl',
          source: MediaCandidateSource.dom,
        );
        final tasks = MediaTaskStore(directoryProvider: () async => root);
        final task = await tasks.create(candidate);
        final session = await player.openLocal(task, local);
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while ((player.active?.positionMs ?? 0) < 500 &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          player.active?.state,
          isIn([NativePlaybackState.playing, NativePlaybackState.completed]),
          reason: player.active?.errorCode,
        );
        expect(player.active!.positionMs, greaterThanOrEqualTo(500));
        debugPrint(
          'NATIVE_ENCRYPTED_HLS_PASS manifest=true keyBytes=16 segmentBytes=${await segment.length()} positionMs=${player.active!.positionMs}',
        );
        await player.stop(sessionId: session.id);
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox());
        await root.delete(recursive: true);
      }
    },
    skip: !_enabled || _fixture.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
