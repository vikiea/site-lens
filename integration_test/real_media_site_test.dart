import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const rawUrl = String.fromEnvironment('SITE_LENS_MEDIA_TEST_URL');
  const download = bool.fromEnvironment('SITE_LENS_REAL_MEDIA_DOWNLOAD');

  testWidgets(
    'real media page sniffs HLS candidates and optionally downloads one',
    (tester) async {
      expect(
        rawUrl.trim(),
        isNotEmpty,
        reason: 'set SITE_LENS_MEDIA_TEST_URL when running this real-site test',
      );
      final url = Uri.parse(rawUrl.trim());
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      try {
        await app.initialize();
        final tab = await app.openUrl(url);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [browserRouteObserver],
            home: BrowserScreen(app: app, site: tab.site),
          ),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(deadline) &&
            !tab.host.loaded &&
            tab.host.errorKind == null) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tab.host.errorKind, isNull, reason: tab.host.error);
        expect(tab.host.loaded, isTrue);

        List<MediaCandidate> candidates() =>
            app.hosts.mediaCandidates(tab.host);
        while (DateTime.now().isBefore(deadline) && candidates().isEmpty) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        final media = candidates();
        expect(media, isNotEmpty);
        debugPrint(
          'REAL_MEDIA_CANDIDATES '
          '${media.map(_safeMediaIdentity).join(' || ')}',
        );
        expect(media.every((value) => value.isHls), isTrue);
        expect(media.every((value) => !value.isLikelyTransportSegment), isTrue);
        debugPrint(
          'REAL_MEDIA_SNIFF_PASS count=${media.length} '
          'items=${media.map(_safeMediaIdentity).join(',')}',
        );

        final candidate = media.firstWhere(
          (value) => value.isHls,
          orElse: () => media.first,
        );
        final route = await MediaNetwork().route(candidate.mediaUrl);
        debugPrint(
          'REAL_MEDIA_ROUTE proxy=${route.proxy} '
          'allowFakeIp=${route.allowProxyFakeIp}',
        );
        if (!download) return;
        await db.saveMediaCandidate(candidate);
        final task = app.mediaTasks.create(candidate);
        try {
          final completed = await app.mediaDownloads.start(task, candidate);
          expect(
            completed.state,
            anyOf(MediaTaskState.completed, MediaTaskState.playable),
          );
          debugPrint(
            'REAL_MEDIA_DOWNLOAD_PASS state=${completed.state.name} '
            'bytes=${completed.bytesDownloaded} local=${completed.localRef != null}',
          );
        } finally {
          if (app.mediaTasks.task(task.id) != null &&
              app.mediaTasks.canDelete(task.id)) {
            await app.mediaDownloads.delete(task.id);
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

String _safeMediaIdentity(MediaCandidate candidate) {
  final uri = candidate.mediaUrl;
  final keys = uri.queryParameters.keys.toList()..sort();
  return '${candidate.id} ${uri.host}${uri.path} '
      'queryKeys=${keys.join(',')} '
      'group=${mediaCandidateDisplayGroupKey(candidate)} · '
      '${candidate.effectiveMime}';
}
