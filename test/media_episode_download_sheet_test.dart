import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/screens.dart';

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
              candidates: candidates,
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
