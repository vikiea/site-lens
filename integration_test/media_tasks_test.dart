import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/native_export_runtime.dart';
import 'package:site_lens/media/native_media_runtime.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'video_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'temporary cast cleanup removes unfinished HLS without an MP4 artifact',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      final candidate = MediaCandidate(
        id: 'temporary-cast-cache-check',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.org/watch'),
        mediaUrl: Uri.parse('https://example.org/index.m3u8'),
        title: 'Temporary cast cleanup',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
      );
      try {
        await db.saveMediaCandidate(candidate);
        final task = app.mediaTasks.create(candidate);
        final parent = await app.mediaTasks.cacheDirectory(
          storageDirectory: task.storageDirectoryName,
        );
        final cache = await Directory('${parent.path}/${task.cacheKey}.hls')
            .create();
        final playlist = await File('${cache.path}/index.m3u8')
            .writeAsString('#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n');
        await File('${cache.path}/segment.ts').writeAsBytes([1, 2, 3]);
        app.mediaTasks.transition(task.id, MediaTaskState.downloading);
        app.mediaTasks.setLocalRef(task.id, playlist.path);
        app.mediaTasks.transition(task.id, MediaTaskState.playable);
        await app.mediaTasks.flush(task.id);
        expect(app.mediaLibrary.item(task.id), isNull);
        await app.cleanupTemporaryCastTask(task.id);
        expect(app.mediaTasks.task(task.id), isNull);
        expect(await cache.exists(), isFalse);
        expect(await db.mediaTasks(), isEmpty);
        debugPrint('NATIVE_TEMPORARY_CAST_CACHE_DELETE_PASS');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
  );

  testWidgets(
    'native HLS remux plays continuously and task deletion removes cache',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/media-device-check-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final db = AppDatabase(NativeDatabase.memory());
      final tasks = MediaTaskStore(directoryProvider: () async => root, db: db);
      final native = NativeExportRuntime();
      final player = NativeMediaRuntime();
      final library = MediaLibrary(db: db, tasks: tasks, native: native);
      try {
        final candidate = MediaCandidate(
          id: 'native-media-acceptance',
          hostId: 1,
          generation: 1,
          sourceUrl: Uri.parse('https://example.org/watch/1'),
          mediaUrl: Uri.parse('https://example.org/video/index.m3u8'),
          title: 'Native acceptance - 第1集',
          mime: 'application/vnd.apple.mpegurl',
          source: MediaCandidateSource.dom,
        );
        await db.saveMediaCandidate(candidate);
        final task = tasks.create(candidate);
        tasks.transition(task.id, MediaTaskState.downloading);
        final parent = await tasks.cacheDirectory(
          storageDirectory: task.storageDirectoryName,
        );
        final cache = await Directory('${parent.path}/${task.cacheKey}.hls')
            .create();
        final segment = await File('${cache.path}/segment.mp4')
            .writeAsBytes(base64Decode(videoFixtureBase64));
        final playlist = await File('${cache.path}/index.m3u8').writeAsString(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.mp4\n#EXTINF:2,\nsegment.mp4\n#EXT-X-ENDLIST\n',
        );
        tasks.setLocalRef(task.id, playlist.path);
        tasks.transition(task.id, MediaTaskState.playable);
        final expected = await playlist.length() + await segment.length();
        expect(await tasks.cachedBytes(task.id), expected);
        final input = await const HlsPlaylistParser().parseFile(playlist.uri);
        final export = await Mp4ExportService(
          tasks: tasks,
          native: native,
          directoryProvider: () async => root,
        ).export(task.id, input);
        expect(export.state, ExportState.deliverable, reason: export.errorCode);
        final artifact = await library.register(task, export.outputPath!);
        expect(artifact.size, greaterThan(0));
        expect(artifact.durationMs, greaterThan(2500));
        expect(tasks.task(task.id)!.localRef, playlist.path);
        debugPrint(
          'NATIVE_REMUX_PASS size=${artifact.size} duration=${artifact.durationMs} cache=$expected',
        );

        final session = await player.openLocal(task, File(artifact.location));
        final end = DateTime.now().add(const Duration(seconds: 12));
        var state = session;
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
          state = await player.state(sessionId: session.id);
          if (state.state == NativePlaybackState.failed) {
            fail(state.errorCode ?? 'native playback failed');
          }
          if (state.positionMs >= 500) break;
        }
        expect(state.positionMs, greaterThanOrEqualTo(500));
        await player.pause(sessionId: session.id);
        final paused = await player.state(sessionId: session.id);
        await tester.pump(const Duration(milliseconds: 300));
        final stillPaused = await player.state(sessionId: session.id);
        expect(stillPaused.state, NativePlaybackState.paused);
        expect(
          (stillPaused.positionMs - paused.positionMs).abs(),
          lessThan(150),
        );
        await player.seek(
          const Duration(milliseconds: 200),
          sessionId: session.id,
        );
        await player.play(sessionId: session.id);
        await tester.pump(const Duration(milliseconds: 600));
        final resumed = await player.state(sessionId: session.id);
        expect(resumed.positionMs, greaterThan(350));
        await player.close(sessionId: session.id);
        debugPrint('NATIVE_MP4_CONTINUOUS_PLAY_PASS');

        await MediaDownloadService(tasks: tasks).delete(task.id);
        expect(await cache.exists(), isFalse);
        expect(tasks.task(task.id), isNull);
        expect(await File(artifact.location).exists(), isTrue);
        debugPrint('NATIVE_TASK_CACHE_DELETE_PASS exportedFilePreserved=true');
      } finally {
        await player.close();
        await player.dispose();
        library.dispose();
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );

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
