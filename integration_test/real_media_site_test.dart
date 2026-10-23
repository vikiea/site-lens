import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'real_media_evidence.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const rawUrl = String.fromEnvironment('SITE_LENS_MEDIA_TEST_URL');
  const encodedUrls = String.fromEnvironment(
    'SITE_LENS_MEDIA_TEST_URLS_BASE64',
  );
  const download = bool.fromEnvironment('SITE_LENS_REAL_MEDIA_DOWNLOAD');
  const expectedEpisodeNumbers = String.fromEnvironment(
    'SITE_LENS_MEDIA_EXPECT_EPISODES',
  );

  final pages =
      (encodedUrls.isEmpty
              ? [rawUrl]
              : utf8.decode(base64.decode(encodedUrls)).split('\n'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
  if (pages.isEmpty) pages.add('');
  for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final pageUrl = pages[pageIndex];
    testWidgets(
      'real media page ${pageIndex + 1} retains explicit episode resource bindings',
      (tester) async {
        expect(
          pageUrl,
          isNotEmpty,
          reason:
              'set SITE_LENS_MEDIA_TEST_URL when running this real-site test',
        );
        final url = Uri.parse(pageUrl);
        final db = AppDatabase(NativeDatabase.memory());
        final app = AppController(db);
        try {
          await app.initialize();
          final snapshot = await DeviceDiagnosticsApi().readSnapshot();
          final mediaControl = snapshot.capabilities.firstWhere(
            (row) => row.id == 'webview.mediaControl',
          );
          debugPrint(
            'REAL_MEDIA_CAPABILITIES provider=${snapshot.webViewProvider} '
            'state=${mediaControl.state.name} effective=${mediaControl.effective} '
            'features=${mediaControl.detailsJson}',
          );
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
          debugPrint(
            'REAL_MEDIA_HOST_STATE loaded=${tab.host.loaded} '
            'errorKind=${tab.host.errorKind} error=${tab.host.error} '
            'url=${tab.currentUrl}',
          );
          expect(tab.host.errorKind, isNull, reason: tab.host.error);
          expect(tab.host.loaded, isTrue);
          final page = await app.hosts.api.inspect(tab.host.id, 'body');
          final data = await app.hosts.api.inspect(
            tab.host.id,
            '#videoInitialData',
          );
          debugPrint(
            'REAL_MEDIA_PAGE_DIAGNOSTICS '
            'ready=${page.ready} challenge=${page.challenge} '
            'interaction=${page.interactionRequired} bodyChars=${page.text.length} '
            'initialDataChars=${data.text.length} '
            'explicitSources=${data.text.contains('"epPlaySrcs"')} '
            'storedCandidates=${tab.host.mediaCandidates.length} '
            'inspectionError=${page.error.isNotEmpty || data.error.isNotEmpty}',
          );
          expect(
            mediaControl.effective,
            isTrue,
            reason: '${mediaControl.reason}; ${mediaControl.detailsJson}',
          );

          List<MediaCandidate> candidates() =>
              app.hosts.mediaCandidates(tab.host);
          final sniffDeadline = DateTime.now().add(const Duration(seconds: 30));
          while (DateTime.now().isBefore(sniffDeadline) &&
              candidates().isEmpty) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final media = candidates();
          expect(media, isNotEmpty);
          final exposedEpisodes = explicitEpisodeUrls(
            data.text,
            tab.currentUrl,
          );
          final selectedPage = tab.currentUrl;
          final selectedEpisode = selectedEpisodeFromFinalPage(
            url,
            selectedPage,
          );
          expect(
            exposedEpisodes.keys,
            contains(selectedEpisode),
            reason: 'The selected page must expose its own episode resource; otherwise acceptance is incomplete',
          );
          expect(media, hasLength(exposedEpisodes.length));
          final expectedBindings = {
            for (final entry in exposedEpisodes.entries)
              '第${entry.key}集': mediaCandidateAuthorizationKey(entry.value),
          };
          final actualBindings = {
            for (final item in media)
              mediaEpisodeLabel(item.title): mediaCandidateAuthorizationKey(
                item.mediaUrl,
              ),
          };
          expect(
            actualBindings,
            expectedBindings,
            reason: 'Every offered episode must retain its exact page-exposed resource; matching counts is insufficient',
          );
          if (expectedEpisodeNumbers.isNotEmpty) {
            final expected = expectedEpisodeNumbers
                .split(',')
                .map(int.parse)
                .toSet();
            expect(media, hasLength(expected.length));
            expect(
              media.map((item) => mediaEpisodeLabel(item.title)).toSet(),
              expected.map((number) => '第$number集').toSet(),
              reason:
                  'Only the declared current-series episodes may be offered',
            );
          }
          debugPrint(
            'REAL_MEDIA_EPISODE_BINDINGS_PASS verified=${actualBindings.length} '
            'unexposedEpisodesNotInferred=true',
          );
          debugPrint(
            'REAL_MEDIA_CANDIDATES '
            '${media.map(_safeMediaIdentity).join(' || ')}',
          );
          expect(media.every((value) => value.isHls), isTrue);
          expect(
            media.every((value) => !value.isLikelyTransportSegment),
            isTrue,
          );
          debugPrint(
            'REAL_MEDIA_SNIFF_PASS count=${media.length} '
            'items=${media.map(_safeMediaIdentity).join(',')}',
          );

          final candidate = media.firstWhere(
            (value) => mediaEpisodeLabel(value.title) == '第$selectedEpisode集',
          );
          expect(
            tab.currentUrl,
            selectedPage,
            reason: 'Page changed while binding the selected episode',
          );
          expect(
            mediaCandidateAuthorizationKey(candidate.mediaUrl),
            mediaCandidateAuthorizationKey(exposedEpisodes[selectedEpisode]!),
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
            expect(task.candidateId, candidate.id);
            expect(task.generation, candidate.generation);
            debugPrint(
              'REAL_MEDIA_SELECTED_EPISODE_PASS episode=$selectedEpisode finalPageBound=true',
            );
            final completed = await app.mediaDownloads.start(task, candidate);
            expect(
              completed.state,
              anyOf(MediaTaskState.completed, MediaTaskState.playable),
            );
            expect(completed.bytesDownloaded, greaterThan(0));
            final cached = await app.mediaTasks.cachedFile(completed.id);
            expect(cached, isNotNull);
            final input = await const HlsPlaylistParser().parseFile(
              cached!.uri,
            );
            final files = const HlsInputValidator().validate(
              playlist: input.playlist,
              segments: input.segments,
              initSegment: input.initSegment,
              initSegments: input.initSegments,
              keys: input.keys,
            );
            for (final resource in files) {
              expect(await File.fromUri(resource).length(), greaterThan(0));
            }
            debugPrint(
              'REAL_MEDIA_DOWNLOAD_PASS state=${completed.state.name} '
              'bytes=${completed.bytesDownloaded} segments=${input.segments.length} '
              'keys=${input.keys.length} allResourcesLocalAndNonempty=true',
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
}

String _safeMediaIdentity(MediaCandidate candidate) {
  final uri = candidate.mediaUrl;
  final keys = uri.queryParameters.keys.toList()..sort();
  final resource = sha256
      .convert(utf8.encode(mediaCandidateDisplayGroupKey(candidate)))
      .toString();
  return 'resource=$resource '
      'queryKeys=${keys.join(',')} '
      'episode=${mediaEpisodeLabel(candidate.title) ?? "unknown"} · '
      '${candidate.effectiveMime}';
}
