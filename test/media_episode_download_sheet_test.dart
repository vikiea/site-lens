import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

MediaCandidate _candidate({
  required String id,
  required int episode,
  required String url,
  int rank = 0,
}) => MediaCandidate(
  id: id,
  hostId: 1,
  generation: 1,
  sourceUrl: Uri.parse('https://example.com/video/42/'),
  mediaUrl: Uri.parse(url),
  title: '剧集标题 - 第$episode集',
  mime: 'video/mp4',
  source: MediaCandidateSource.dom,
  seriesKey: 'https://example.com/video/42',
  episodeNumber: episode,
  representationRank: rank,
);

void main() {
  testWidgets(
    'series change clears selection and restored candidates never auto-select after clear',
    (tester) async {
      final changed = ChangeNotifier();
      final host = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'test',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: '',
        ),
      )..generation = 1;
      var candidates = [
        _candidate(id: 'one', episode: 1, url: 'https://cdn.example/one.mp4'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeDownloadSheet(
              host: host,
              candidatesChanged: changed,
              readCandidates: () => candidates,
              onDownload: (_) async {},
              onPlay: (_) async {},
              onResniff: () {},
            ),
          ),
        ),
      );
      final other = MediaCandidate(
        id: 'other',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.com/video/99/'),
        mediaUrl: Uri.parse('https://cdn.example/other.mp4'),
        title: '另一剧集 - 第1集',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
        seriesKey: 'https://example.com/video/99',
        episodeNumber: 1,
      );
      candidates = [other];
      changed.notifyListeners();
      await tester.pump();
      expect(find.text('已选 0 / 1 集'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pump();
      candidates = [];
      changed.notifyListeners();
      await tester.pump();
      candidates = [other];
      changed.notifyListeners();
      await tester.pump();
      expect(find.text('已选 0 / 1 集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      changed.dispose();
    },
  );

  testWidgets(
    'live candidates replace selected signed URLs and revoke disappeared episodes',
    (tester) async {
      final changed = ChangeNotifier();
      final host = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'test',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: '',
        ),
      )..generation = 1;
      var candidates = [
        _candidate(
          id: 'old',
          episode: 1,
          url: 'https://cdn.example/e1.mp4?token=old',
        ),
      ];
      final selected = <MediaCandidate>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeDownloadSheet(
              host: host,
              candidatesChanged: changed,
              readCandidates: () => candidates,
              onDownload: (value) async => selected.addAll(value),
              onPlay: (_) async {},
              onResniff: () {},
            ),
          ),
        ),
      );
      candidates = [
        _candidate(
          id: 'new',
          episode: 1,
          url: 'https://other.example/e1.mp4?token=new',
        ),
        _candidate(
          id: 'episode2',
          episode: 2,
          url: 'https://cdn.example/e2.mp4',
        ),
      ];
      changed.notifyListeners();
      await tester.pump();
      expect(find.text('已选 1 / 2 集'), findsOneWidget);
      await tester.tap(find.text('下载 1 集'));
      expect(selected.single.id, 'new');
      candidates = [];
      changed.notifyListeners();
      await tester.pump();
      expect(find.text('当前页面没有可确认集数的媒体'), findsOneWidget);
      expect(find.text('下载 0 集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      changed.dispose();
    },
  );

  testWidgets('submit rereads current generation even without a notification', (
    tester,
  ) async {
    final changed = ChangeNotifier();
    final host = HostSession(
      1,
      HostPurpose.browsing,
      HostCapabilities(
        platform: 'test',
        isolatedScripts: true,
        documentStart: true,
        privateProbes: true,
        reason: '',
      ),
    )..generation = 1;
    var candidates = [
      _candidate(id: 'old', episode: 1, url: 'https://cdn.example/e1.mp4'),
    ];
    var submitted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpisodeDownloadSheet(
            host: host,
            candidatesChanged: changed,
            readCandidates: () => candidates,
            onDownload: (_) async => submitted = true,
            onPlay: (_) async {},
            onResniff: () {},
          ),
        ),
      ),
    );
    host.generation = 2;
    candidates = [];
    await tester.tap(find.text('下载 1 集'));
    await tester.pump();
    expect(submitted, isFalse);
    expect(find.text('下载 0 集'), findsOneWidget);
    host.disposed = true;
    changed.notifyListeners();
    await tester.pump();
    expect(find.text('当前页面没有可确认集数的媒体'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    changed.dispose();
  });

  testWidgets(
    'episode sheet supports custom selection and one default version',
    (tester) async {
      final selected = <MediaCandidate>[];
      final candidates = [
        _candidate(
          id: 'episode-1-low',
          episode: 1,
          url: 'https://cdn.example/episode-1-low.mp4',
        ),
        _candidate(
          id: 'episode-1-high',
          episode: 1,
          url: 'https://cdn.example/episode-1-high.mp4',
          rank: 2,
        ),
        _candidate(
          id: 'episode-2',
          episode: 2,
          url: 'https://cdn.example/episode-2.mp4',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeDownloadSheet(
              host: HostSession(
                1,
                HostPurpose.browsing,
                HostCapabilities(
                  platform: 'test',
                  isolatedScripts: true,
                  documentStart: true,
                  privateProbes: true,
                  reason: '',
                ),
              )..generation = 1,
              candidatesChanged: ChangeNotifier(),
              readCandidates: () => candidates,
              onDownload: (value) async => selected.addAll(value),
              onPlay: (_) async {},
              onResniff: () {},
            ),
          ),
        ),
      );

      expect(find.text('已选 2 / 2 集'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(find.text('下载 0 集'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.text('下载 1 集'), findsOneWidget);
      await tester.tap(find.text('下载 1 集'));
      await tester.pump();

      expect(selected, hasLength(1));
      expect(selected.single.episodeNumber, 1);
      expect(selected.single.id, 'episode-1-high');
    },
  );
}
