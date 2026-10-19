import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('media task lifecycle and local HLS export gate', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final root = await Directory.systemTemp.createTemp(
      'site-lens-media-acceptance-',
    );
    try {
      final candidate = MediaCandidate(
        id: 'acceptance-candidate',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.com/watch'),
        mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
        title: 'Acceptance media',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      );
      final tasks = MediaTaskStore(directoryProvider: () async => root, db: db);
      await db.saveMediaCandidate(candidate);
      final task = tasks.create(candidate);
      expect(
        tasks.transition(task.id, MediaTaskState.downloading).state,
        MediaTaskState.downloading,
      );
      tasks.updateProgress(task.id, 10, totalBytes: 20);
      expect(
        tasks.transition(task.id, MediaTaskState.paused).state,
        MediaTaskState.paused,
      );
      tasks.transition(task.id, MediaTaskState.downloading);
      tasks.transition(task.id, MediaTaskState.completed);
      expect(
        tasks.transition(task.id, MediaTaskState.playable).state,
        MediaTaskState.playable,
      );

      final playlist = File('${root.path}/index.m3u8')
        ..writeAsStringSync('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
      final segment = File('${root.path}/seg.ts')..writeAsBytesSync([1, 2, 3]);
      final export = Mp4ExportService(
        tasks: tasks,
        directoryProvider: () async => root,
        muxer:
            ({
              required HlsCacheInput input,
              required String outputPath,
              required void Function(int) onProgress,
              required Cancellation cancellation,
            }) async {
              expect(input.segments.single.path, segment.path);
              await File(outputPath).writeAsBytes([4, 5, 6]);
            },
      );
      final exported = await export.export(
        task.id,
        HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
      );
      expect(exported.state, ExportState.deliverable);
      expect(await File(exported.outputPath!).exists(), isTrue);
      expect(
        DlnaProtocolInfo.parse(
          '<Sink>http-get:*:video/mp4:*,http-get:*:application/vnd.apple.mpegurl:*</Sink>',
        ).supportsMime('video/mp4'),
        isTrue,
      );
      tasks.retain(task.id);
      expect(() => tasks.delete(task.id), throwsStateError);
      tasks.release(task.id);
      await tasks.delete(task.id);
      expect(tasks.tasks, isEmpty);
      debugPrint('MEDIA_TASK_LIFECYCLE_PASS');
    } finally {
      await root.delete(recursive: true);
      await db.close();
    }
  });
}
