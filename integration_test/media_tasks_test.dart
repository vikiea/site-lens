import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';
import 'package:site_lens/ui/media_thumbnail.dart';

import 'media3_fixture.dart';
import 'video_fixture.dart';

void main() {
  // REGRESSION CONTRACT: MEDIA-HLS-001
  // REGRESSION CONTRACT: MEDIA-PLAY-001
  // REGRESSION CONTRACT: MEDIA-EXPORT-001
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('background media authorization refresh stays same-origin', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><title>media page</title>'
          '<script>document.cookie="site_lens_auth=ok; path=/";</script>',
        );
        await request.response.close();
      });
      final page = Uri.parse('http://127.0.0.1:${server.port}/watch');
      final media = Uri.parse('http://127.0.0.1:${server.port}/media.m3u8');
      final raw = await const MethodChannel('site_lens/media_auth')
          .invokeMapMethod<String, Object?>('refresh', {
            'taskId': 'auth-refresh-fixture',
            'pageUrl': page.toString(),
            'mediaUrl': media.toString(),
          });
      expect(raw?['state'], 'refreshed');
      expect((raw?['cookieDigest'] as String?)?.length, 64);
      debugPrint(
        'MEDIA_AUTH_REFRESH_PASS sameOrigin=true cookieBytes=notReturned digest=true',
      );
    } finally {
      await server.close(force: true);
    }
  });

  testWidgets('DLNA relay resolves a bindable local address through Android', (
    tester,
  ) async {
    final receiver = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    receiver.listen((socket) => socket.destroy());
    final root = await Directory.systemTemp.createTemp('dlna-local-route-');
    MediaRelayServer? relay;
    final http = HttpClient();
    try {
      final file = await File('${root.path}/fixture.mp4')
          .writeAsBytes([1, 2, 3]);
      relay = await MediaRelayServer.start(
        authorization: const RelayAuthorizer().issue(
          sessionId: 'local',
          taskId: 'fixture',
          deviceId: 'receiver',
        ),
        file: file,
        receiver: Uri.parse('http://127.0.0.1:${receiver.port}/control'),
      );
      expect(relay.url.host, '127.0.0.1');
      final request = await http.getUrl(relay.url);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.expand((bytes) => bytes).toList(), [1, 2, 3]);
      debugPrint('DLNA_LOCAL_ROUTE_PASS bindable=true bodyVerified=true');
    } finally {
      http.close(force: true);
      await relay?.close();
      await receiver.close();
      await root.delete(recursive: true);
    }
  });

  testWidgets(
    'native playback leases reject destructive file operations without Dart references',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/native-file-leases-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final tasks = MediaTaskStore(directoryProvider: () async => root);
      final player = NativeMediaRuntime();
      final native = NativeExportRuntime();
      final candidate = MediaCandidate(
        id: 'native-file-leases',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.org/watch'),
        mediaUrl: Uri.parse('https://example.org/episode.mp4'),
        title: 'Native file leases',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      );
      final task = tasks.create(candidate);
      final blocked = throwsA(
        isA<PlatformException>().having(
          (error) => error.message,
          'reader remains held',
          contains('正在播放'),
        ),
      );
      try {
        final bytes = base64Decode(videoFixtureBase64);
        final file = await File('${root.path}/第 1 集.mp4').writeAsBytes(bytes);
        final other = await File('${root.path}/other.mp4').writeAsBytes(bytes);
        final session = await player.openLocal(task, file);
        await player.pause(sessionId: session.id);
        // No Dart retain: the native reader must protect the bytes itself,
        // including paused or completed sessions and after route changes.
        expect(tasks.canDelete(task.id), isTrue);
        await expectLater(native.delete(file.path), blocked);
        await expectLater(
          native.deleteOwnedSources(task.id, [other.path, file.path]),
          blocked,
        );
        expect(await other.readAsBytes(), bytes);
        await expectLater(native.rename(file.path, 'renamed.mp4'), blocked);
        await expectLater(
          native.move(
            source: file.path,
            directory: root.uri,
            fileName: 'local-moved.mp4',
          ),
          blocked,
        );
        await expectLater(
          native.copyVerified(source: other.path, destination: file.path),
          blocked,
        );
        await expectLater(
          native.move(
            source: file.path,
            directory: Uri.parse('content://missing-provider/tree/not-granted'),
            fileName: 'moved.mp4',
          ),
          blocked,
        );
        await expectLater(
          native.deliver(source: other.path, destination: file.uri),
          blocked,
        );
        expect(await file.readAsBytes(), bytes);
        await player.close(sessionId: session.id);
        final renamed = await native.rename(file.path, 'renamed.mp4');
        expect(await File(renamed).readAsBytes(), bytes);
        final copied = await native.copyVerified(
          source: renamed,
          destination: '${root.path}/verified-copy.mp4',
        );
        expect(await File(copied).readAsBytes(), bytes);
        await expectLater(
          native.copyVerified(source: renamed, destination: copied),
          throwsA(isA<PlatformException>()),
        );
        final modified = await File(copied).lastModified();
        expect(
          await native.copyVerified(
            source: renamed,
            destination: copied,
            reuseExistingVerified: true,
          ),
          copied,
        );
        expect(await File(copied).lastModified(), modified);
        final mismatched = List<int>.of(bytes);
        mismatched[mismatched.length - 1] ^= 1;
        await other.writeAsBytes(mismatched);
        await expectLater(
          native.copyVerified(
            source: other.path,
            destination: copied,
            reuseExistingVerified: true,
          ),
          throwsA(isA<PlatformException>()),
        );
        expect(await File(copied).readAsBytes(), bytes);
        debugPrint(
          'NATIVE_VERIFIED_COPY_RECOVERY_PASS identicalReused=true mismatchRejected=true defaultRejects=true',
        );
        final moved = await native.move(
          source: renamed,
          directory: root.uri,
          fileName: 'local-moved.mp4',
        );
        expect(await File(renamed).exists(), isFalse);
        expect(await File(moved).readAsBytes(), bytes);
        await native.deleteOwnedSources(task.id, [moved, copied]);
        expect(await File(moved).exists(), isFalse);
        expect(await File(copied).exists(), isFalse);

        await unpackMedia3Fixtures(root);
        final playlist = File('${root.path}/h264_ts/index.m3u8');
        final segment = (await playlist.parent.list().toList())
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('.ts'));
        final hls = await player.openLocal(task, playlist);
        await expectLater(native.delete(segment.path), blocked);
        await expectLater(
          native.rename(playlist.path, 'renamed.m3u8'),
          blocked,
        );
        await player.close(sessionId: hls.id);
        await native.delete(segment.path);
        expect(await segment.exists(), isFalse);
        debugPrint(
          'NATIVE_PLAYBACK_FILE_LEASE_PASS pausedReader=true '
          'noDartReferences=true moveRejectedBeforeDelivery=true '
          'overwriteRejected=true hlsChildrenProtected=true stopReleases=true',
        );
      } finally {
        await player.close();
        await player.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );

  testWidgets('media list thumbnails preserve native frame aspect ratio', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = await Directory(
      '${support.path}/thumbnail-ui-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    HttpServer? server;
    String? thumbnailPath;
    try {
      final video = await File('${root.path}/thumbnail.mp4')
          .writeAsBytes(base64Decode(videoFixtureBase64));
      final metadata = await app.nativeExports!.inspect(video.path);
      expect(metadata['width'], 160);
      expect(metadata['height'], 96);
      thumbnailPath = metadata['thumbnailPath'] as String?;
      expect(thumbnailPath, isNotNull);
      final thumbnailBytes = await File(thumbnailPath!).readAsBytes();
      var networkRequests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        networkRequests++;
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(thumbnailBytes);
        await request.response.close();
      });
      final candidate = MediaCandidate(
        id: 'thumbnail-ui',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.org/watch'),
        mediaUrl: Uri.parse('https://example.org/thumbnail.mp4'),
        thumbnailUrl: Uri.parse('http://127.0.0.1:${server.port}/frame.jpg'),
        title: 'Thumbnail aspect ratio',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      );
      await db.saveMediaCandidate(candidate);
      final task = app.mediaTasks.create(candidate);
      await app.mediaLibrary.register(task, video.path);

      for (final library in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.dark),
            home: ListenableBuilder(
              listenable: app,
              builder: (_, _) => library
                  ? MediaLibraryScreen(app: app)
                  : MediaTasksScreen(app: app),
            ),
          ),
        );
        final thumbnail = find.byType(MediaThumbnail);
        final scrollable = find.descendant(
          of: find.byKey(
            PageStorageKey<String>(
              library ? 'media-library-scroll' : 'media-tasks-scroll',
            ),
          ),
          matching: find.byType(Scrollable),
        );
        expect(scrollable, findsOneWidget);
        await tester.scrollUntilVisible(thumbnail, 200, scrollable: scrollable);
        final rawImage = find.descendant(
          of: thumbnail,
          matching: find.byType(RawImage),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (rawImage.evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(rawImage, findsOneWidget);
        final provider = tester
            .widget<Image>(
              find.descendant(of: thumbnail, matching: find.byType(Image)),
            )
            .image;
        if (library) {
          expect(provider, isA<FileImage>());
          expect((provider as FileImage).file.path, thumbnailPath);
          expect(networkRequests, 0);
        } else {
          expect(provider, isA<NetworkImage>());
          expect(
            (provider as NetworkImage).url,
            candidate.thumbnailUrl.toString(),
          );
          expect(networkRequests, greaterThan(0));
        }
        final decoded = tester.widget<RawImage>(rawImage).image!;
        // The MP4 fixture is 160x96, not 16:9. This also catches distortion
        // introduced before Flutter receives the generated JPEG.
        expect(decoded.width / decoded.height, closeTo(160 / 96, 0.001));
        final displayed = tester.getRect(rawImage);
        final slot = tester.getRect(thumbnail);
        expect(
          displayed.size.aspectRatio,
          closeTo(decoded.width / decoded.height, 0.001),
        );
        expect(displayed.width, lessThanOrEqualTo(slot.width));
        expect(displayed.height, lessThanOrEqualTo(slot.height));
        expect((displayed.center - slot.center).distance, lessThan(0.01));
        expect(tester.takeException(), isNull);
        debugPrint(
          'MEDIA_THUMBNAIL_ROW_PASS source=${library ? "file" : "network"} '
          'decoded=${decoded.width}x${decoded.height} displayed=${displayed.size}',
        );
      }
      expect(networkRequests, greaterThan(0));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await server?.close(force: true);
      await app.shutdown();
      await db.close();
      if (await root.exists()) await root.delete(recursive: true);
      if (thumbnailPath != null) {
        final thumbnail = File(thumbnailPath);
        if (await thumbnail.exists()) await thumbnail.delete();
      }
    }
  });

  testWidgets('native MediaSession survives a Dart playback bridge rebind', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = await Directory(
      '${support.path}/media-session-rebind-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final tasks = MediaTaskStore(directoryProvider: () async => root);
    final first = NativeMediaRuntime();
    final candidate = MediaCandidate(
      id: 'media-session-rebind',
      hostId: 1,
      generation: 1,
      sourceUrl: Uri.parse('https://example.org/watch/rebind'),
      mediaUrl: Uri.parse('https://example.org/rebind.mp4'),
      title: 'MediaSession rebind',
      mime: 'video/mp4',
      source: MediaCandidateSource.dom,
    );
    final task = tasks.create(candidate);
    try {
      final file = await File('${root.path}/rebind.mp4')
          .writeAsBytes(base64Decode(videoFixtureBase64));
      final opened = await first.openLocal(task, file);
      await first.pause(sessionId: opened.id);
      final pausedPosition = (await first.state(sessionId: opened.id))
          .positionMs;
      await first.dispose();

      final rebound = NativeMediaRuntime();
      final restored = await rebound.state();
      expect(restored.id, opened.id);
      expect(restored.state, NativePlaybackState.paused);
      expect(restored.positionMs, greaterThanOrEqualTo(pausedPosition));
      await rebound.close(sessionId: restored.id);
      await rebound.dispose();
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(0));
      debugPrint(
        'MEDIA_SESSION_REBIND_PASS sameSession=true paused=true leaseReleased=true',
      );
    } finally {
      await first.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  testWidgets('HLS starts native playback before the download completes', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = await Directory(
      '${support.path}/partial-hls-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final fixtures = await Directory('${root.path}/fixtures').create();
    await unpackMedia3Fixtures(fixtures);
    final firstSegment = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final file = File('${fixtures.path}${request.uri.path}');
      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (request.uri.path.endsWith('/seg00.ts')) {
        firstSegment.complete();
      }
      if (request.uri.path.endsWith('/seg01.ts')) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      request.response.headers.contentType = request.uri.path.endsWith('.m3u8')
          ? ContentType('application', 'vnd.apple.mpegurl')
          : ContentType('video', 'mp2t');
      request.response.add(await file.readAsBytes());
      await request.response.close();
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}/h264_ts/index.m3u8');
    final candidate = MediaCandidate(
      id: 'partial-hls-playback',
      hostId: 1,
      generation: 1,
      sourceUrl: url,
      mediaUrl: url,
      title: 'Partial HLS playback',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    final tasks = MediaTaskStore(directoryProvider: () async => root);
    final task = tasks.create(candidate);
    final service = MediaDownloadService(
      tasks: tasks,
      http: ControlledHttp(allowLocal: true),
    );
    final download = service.start(task, candidate);
    final player = NativeMediaRuntime();
    try {
      await firstSegment.future.timeout(const Duration(seconds: 5));
      File? partial;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (partial == null && DateTime.now().isBefore(deadline)) {
        partial = await tasks.partialPlaybackFile(task.id);
        if (partial == null) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(partial, isNotNull);
      final session = await player.openLocal(task, partial!);
      final targetReady = await tasks.waitForHlsPosition(
        task.id,
        2500,
        timeout: const Duration(seconds: 6),
      );
      expect(targetReady, isTrue);
      await player.seek(
        const Duration(milliseconds: 2500),
        sessionId: session.id,
      );
      var progressed = false;
      final playbackDeadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(playbackDeadline)) {
        final state = await player.state(sessionId: session.id);
        progressed =
            progressed ||
            state.state == NativePlaybackState.playing ||
            state.positionMs > 0;
        if (progressed) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(progressed, isTrue);
      await download;
      expect(tasks.task(task.id)?.state, MediaTaskState.playable);
      await player.close(sessionId: session.id);
      debugPrint(
        'MEDIA_PARTIAL_PLAYBACK_PASS firstSegmentBeforeComplete=true '
        'nativeStarted=true uncachedSeekWaited=true',
      );
    } finally {
      await player.dispose();
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  testWidgets('HLS seek priority requests the target segment before backlog', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = await Directory(
      '${support.path}/hls-seek-priority-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final fixtures = await Directory('${root.path}/fixtures').create();
    await unpackMedia3Fixtures(fixtures);
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      if (path.endsWith('/index.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:2\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\nseg00.ts\n'
          '#EXTINF:2,\nseg01.ts\n#EXTINF:2,\nseg02.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
        return;
      }
      final fileName = path.endsWith('/seg02.ts')
          ? 'seg01.ts'
          : path.split('/').last;
      final file = File('${fixtures.path}/h264_ts/$fileName');
      request.response.headers.contentType = ContentType('video', 'mp2t');
      request.response.add(await file.readAsBytes());
      await request.response.close();
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}/h264_ts/index.m3u8');
    final candidate = MediaCandidate(
      id: 'hls-seek-priority',
      hostId: 1,
      generation: 1,
      sourceUrl: url,
      mediaUrl: url,
      title: 'HLS seek priority',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    final tasks = MediaTaskStore(directoryProvider: () async => root);
    final task = tasks.create(candidate);
    final service = MediaDownloadService(
      tasks: tasks,
      http: ControlledHttp(allowLocal: true),
    );
    service.prioritizeHlsSeek(task.id, 4500);
    try {
      await service.start(task, candidate);
      final target = requests.indexWhere((path) => path.endsWith('/seg02.ts'));
      final backlog = requests.indexWhere((path) => path.endsWith('/seg01.ts'));
      expect(target, greaterThanOrEqualTo(0));
      expect(backlog, greaterThanOrEqualTo(0));
      expect(target, lessThan(backlog));
      debugPrint(
        'MEDIA_HLS_SEEK_PRIORITY_PASS targetBeforeBacklog=true requests=${requests.join(',')}',
      );
    } finally {
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

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
    'download deletion preserves indexed MP4 and independent seek playback',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/media-ownership-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final db = AppDatabase(NativeDatabase.memory());
      final tasks = MediaTaskStore(directoryProvider: () async => root, db: db);
      final player = NativeMediaRuntime();
      final native = NativeExportRuntime();
      final library = MediaLibrary(db: db, tasks: tasks, native: native);
      try {
        final bytes = base64Decode(videoFixtureBase64);
        for (final legacy in [false, true]) {
          final candidate = MediaCandidate(
            id: 'ownership-$legacy',
            hostId: 1,
            generation: 1,
            sourceUrl: Uri.parse('https://example.org/watch/$legacy'),
            mediaUrl: Uri.parse('https://example.org/$legacy.mp4'),
            title: 'Ownership $legacy',
            mime: 'video/mp4',
            source: MediaCandidateSource.dom,
          );
          await db.saveMediaCandidate(candidate);
          final task = tasks.create(candidate);
          tasks.transition(task.id, MediaTaskState.downloading);
          final directory = await tasks.cacheDirectory(
            storageDirectory: task.storageDirectoryName,
          );
          final cache = await File('${directory.path}/${task.cacheKey}.media')
              .writeAsBytes(bytes);
          final export = File('${root.path}/media_exports/$legacy.mp4');
          await export.parent.create(recursive: true);
          await export.writeAsBytes(bytes);
          tasks.setLocalRef(task.id, legacy ? export.path : cache.path);
          tasks.transition(task.id, MediaTaskState.playable);
          final artifact = await library.register(task, export.path);
          final service = MediaDownloadService(tasks: tasks);
          tasks.retain(task.id);
          await expectLater(service.delete(task.id), throwsStateError);
          tasks.release(task.id);
          await service.delete(task.id);
          expect(await cache.exists(), isFalse);
          expect(tasks.task(task.id), isNull);
          expect(await export.readAsBytes(), bytes);
          final reopened = MediaLibrary(db: db, tasks: tasks, native: native);
          try {
            await reopened.restore();
            expect(reopened.item(task.id), isNotNull);
            final local = await reopened.localFile(task.id);
            expect(local, isNotNull);
            final session = await player.openLocal(
              reopened.presentationTask(artifact),
              local!,
            );
            await player.pause(sessionId: session.id);
            await player.seek(
              const Duration(milliseconds: 800),
              sessionId: session.id,
            );
            final seekDeadline = DateTime.now().add(
              const Duration(seconds: 10),
            );
            while (DateTime.now().isBefore(seekDeadline)) {
              await tester.pump(const Duration(milliseconds: 100));
              if ((await player.state(sessionId: session.id)).positionMs >=
                  750) {
                break;
              }
            }
            expect(
              (await player.state(sessionId: session.id)).positionMs,
              inInclusiveRange(750, 850),
              reason: 'Paused seek must move to the requested position',
            );
            await player.play(sessionId: session.id);
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 100));
              final state = await player.state(sessionId: session.id);
              expect(
                state.state,
                isNot(NativePlaybackState.failed),
                reason: state.errorCode,
              );
              if (state.positionMs >= 900) break;
            }
            expect(
              (await player.state(sessionId: session.id)).positionMs,
              greaterThanOrEqualTo(900),
            );
            await player.close(sessionId: session.id);
          } finally {
            if (player.active != null) {
              await player.close(sessionId: player.active!.id);
            }
            reopened.dispose();
          }
          debugPrint('DOWNLOAD_DELETE_EXPORT_RETAINED_PASS legacy=$legacy');
        }
      } finally {
        await player.dispose();
        library.dispose();
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
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
        final fixtures = Directory('${root.path}/media-fixtures')
          ..createSync(recursive: true);
        await unpackMedia3Fixtures(fixtures);
        final fixture = Directory('${fixtures.path}/h264_ts');
        await for (final file in fixture.list()) {
          if (file is File) {
            await file.copy('${cache.path}/${file.uri.pathSegments.last}');
          }
        }
        final playlist = File('${cache.path}/index.m3u8');
        tasks.setLocalRef(task.id, playlist.path);
        tasks.transition(task.id, MediaTaskState.playable);
        var expected = 0;
        await for (final file in cache.list(recursive: true)) {
          if (file is File) expected += await file.length();
        }
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
        final resumeDeadline = DateTime.now().add(const Duration(seconds: 12));
        var resumed = await player.state(sessionId: session.id);
        while (DateTime.now().isBefore(resumeDeadline) &&
            resumed.positionMs <= 350) {
          expect(
            resumed.state,
            isNot(NativePlaybackState.failed),
            reason: resumed.errorCode,
          );
          await tester.pump(const Duration(milliseconds: 100));
          resumed = await player.state(sessionId: session.id);
        }
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

  testWidgets(
    'media library rescan restores an MP4 after its index is missing',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-media-rescan-',
      );
      final db = AppDatabase(NativeDatabase.memory());
      final tasks = MediaTaskStore(directoryProvider: () async => root, db: db);
      final library = MediaLibrary(db: db, tasks: tasks);
      try {
        final directory = await Directory('${root.path}/media_exports/batch')
            .create(recursive: true);
        final file = await File('${directory.path}/恢复索引.mp4')
            .writeAsBytes([1, 2, 3, 4]);
        final result = await library.rescan();
        expect(result.added, 1);
        expect(library.items.single.location, file.path);
        expect(library.items.single.taskId, startsWith('library_'));
        expect((await library.rescan()).added, 0);
        debugPrint('MEDIA_LIBRARY_RESCAN_PASS');
      } finally {
        library.dispose();
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
        await tester.pumpWidget(const SizedBox());
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
      await expectLater(tasks.delete(task.id), throwsStateError);
      tasks.release(task.id);
      await tasks.delete(task.id);
      expect(tasks.tasks, isEmpty);
      debugPrint('MEDIA_TASK_LIFECYCLE_PASS');
    } finally {
      await root.delete(recursive: true);
      await db.close();
    }
  });

  testWidgets(
    'watch save persists playback progress and pause state without a media task',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      try {
        await app.load();
        final profileId = await db.createProfile('alpha1-watch-save');
        final playing = PlaybackEvidence(
          hostId: 7,
          generation: 4,
          frame: 'frame-watch',
          document: 'document-watch',
          epoch: 2,
          pageUrl: Uri.parse('https://example.test/watch/3'),
          sourceUrl: Uri.parse('https://cdn.example/series/ep3.m3u8?token=1'),
          sourceKey: 'https://cdn.example/series/ep3.m3u8',
          seriesKey: 'series-watch',
          episodeNumber: 3,
          title: 'Alpha1 示例剧 - 第3集',
          state: PlaybackEvidenceState.playing,
          confirmed: true,
          reason: null,
          observedAt: DateTime(2026, 10, 25, 1, 2, 3),
          mediaElementId: 'media-1',
          snapshot: 4,
          eventSequence: 10,
          positionMs: 30000,
          durationMs: 120000,
          sourceRevision: '4:https://cdn.example/series/ep3.m3u8',
        );
        final created = await app.watchSaves.observe(
          playing,
          profileId: profileId,
        );
        expect(created, isNotNull);
        expect(await db.mediaTasks(), isEmpty);

        final paused = PlaybackEvidence(
          hostId: playing.hostId,
          generation: playing.generation,
          frame: playing.frame,
          document: playing.document,
          epoch: playing.epoch,
          pageUrl: playing.pageUrl,
          sourceUrl: playing.sourceUrl,
          sourceKey: playing.sourceKey,
          seriesKey: playing.seriesKey,
          episodeNumber: playing.episodeNumber,
          title: playing.title,
          state: PlaybackEvidenceState.paused,
          confirmed: true,
          reason: null,
          observedAt: DateTime(2026, 10, 25, 1, 2, 4),
          mediaElementId: playing.mediaElementId,
          snapshot: playing.snapshot,
          eventSequence: 11,
          positionMs: 45000,
          durationMs: playing.durationMs,
          sourceRevision: playing.sourceRevision,
        );
        await app.watchSaves.observe(paused, profileId: profileId);
        final saved = (await db.watchSaves()).single;
        expect(saved.state, WatchSaveState.paused);
        expect(saved.positionMs, 45000);
        expect(saved.durationMs, 120000);
        expect(saved.profileId, profileId);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.light),
            home: MediaManagementScreen(app: app),
          ),
        );
        await tester.pumpAndSettle();
        final savedRow = find.byKey(
          ValueKey('watch-save-${WatchSave.ownerIdFor(playing)}'),
        );
        expect(savedRow, findsOneWidget);
        expect(
          find.descendant(
            of: savedRow,
            matching: find.text('Alpha1 示例剧 - 第3集'),
          ),
          findsOneWidget,
        );
        debugPrint(
          'WATCH_SAVE_ALPHA1_PASS state=paused position=45000 duration=120000 '
          'mediaTasks=0',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
  );
}
