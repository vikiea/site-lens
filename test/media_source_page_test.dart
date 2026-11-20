import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/web_page_origin.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/media/native_media_auth_refresh.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/media_source_page.dart';

import 'fake_web_host_api.dart';

class _FakeNativeDownloads extends NativeDownloadRuntime {
  _FakeNativeDownloads()
    : super(channel: const MethodChannel('fake_source_page_downloads'));

  final calls = <String>[];

  @override
  Future<Map<String, Object?>> start(
    MediaTask task,
    MediaCandidate candidate, {
    String? title,
    String? storageDirectory,
  }) async {
    calls.add('start:${task.id}:${candidate.mediaUrl}');
    return {'state': 'downloading', 'bytesDownloaded': task.bytesDownloaded};
  }

  @override
  Future<Map<String, Object?>> status(String taskId) async => {
    'state': 'downloading',
  };

  @override
  Future<void> progressNotification(
    String taskId,
    String title,
    int bytes, {
    int? totalBytes,
  }) async {}

  @override
  Future<void> clearProgressNotification(String taskId) async {}

  @override
  Future<void> setConcurrency(int value) async {}

  @override
  Future<void> pause(String taskId) async {}

  @override
  Future<void> cancel(String taskId) async {}
}

/// Answers per task and records the exact batch it was asked for, so a test
/// can prove one refresh covers the whole source page.
class _FakeAuthRefreshBridge extends NativeMediaAuthRefresh {
  _FakeAuthRefreshBridge(this.answer);

  MediaAuthorizationRefreshResult Function(MediaTask task) answer;
  final singles = <String>[];
  final batches = <List<MediaAuthorizationRefreshRequest>>[];

  @override
  Future<MediaAuthorizationRefreshResult> refresh(
    MediaTask task,
    MediaCandidate candidate,
  ) async {
    singles.add(task.id);
    return answer(task);
  }

  @override
  Future<List<MediaAuthorizationRefreshResult>> refreshBatch(
    List<MediaAuthorizationRefreshRequest> batch,
  ) async {
    batches.add(List.of(batch));
    return [for (final request in batch) answer(_task[request.taskId]!)];
  }

  final _task = <String, MediaTask>{};

  void remember(Iterable<MediaTask> tasks) {
    for (final task in tasks) {
      _task[task.id] = task;
    }
  }
}

MediaCandidate _candidate({
  required String id,
  required String sourceUrl,
  required String mediaUrl,
}) => MediaCandidate(
  id: id,
  hostId: 7,
  generation: 3,
  sourceUrl: Uri.parse(sourceUrl),
  mediaUrl: Uri.parse(mediaUrl),
  title: '系列 - 第1集',
  mime: 'application/vnd.apple.mpegurl',
  source: MediaCandidateSource.dom,
  seriesKey: 'series:1',
  episodeNumber: 1,
  qualityLabel: '720p',
);

/// Answers the manifest and one short segment so a resumed HLS transfer can
/// finish offline; nothing leaves the machine.
NativeTlsTransferWithPolicy _offlineTransfer(List<String> requested) =>
    (
      url,
      document,
      destination,
      maxBytes,
      cancellation, {
      onProgress,
      headers,
      requestContextId,
      required maxAttempts,
      required startAttempt,
      resourceKind = 'file',
    }) async {
      requested.add('$resourceKind:$url');
      if (resourceKind == 'manifest') {
        await destination.writeAsString(
          '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\n'
          'segment1.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        await destination.writeAsBytes(List<int>.filled(4, 7));
      }
      return MediaTransferResult(attemptsUsed: 1, finalUrl: url);
    };

Future<bool>? lastOpened;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('source page origin gate', () {
    test('default ports do not split an origin', () {
      expect(
        webOriginKey(Uri.parse('https://Play.Example:443/watch/1?x=1#top')),
        webOriginKey(Uri.parse('https://play.example/watch/2')),
      );
      expect(
        webOriginKey(Uri.parse('http://play.example:80/')),
        webOriginKey(Uri.parse('http://play.example/a/b')),
      );
    });

    test('scheme, host and non-default port are all part of the origin', () {
      final page = webOriginKey(Uri.parse('https://play.example/watch/1'));
      expect(
        webOriginKey(Uri.parse('http://play.example/watch/1')),
        isNot(page),
      );
      expect(
        webOriginKey(Uri.parse('https://other.example/watch/1')),
        isNot(page),
      );
      expect(
        webOriginKey(Uri.parse('https://play.example:8443/watch/1')),
        isNot(page),
      );
    });

    test('nothing but HTTP(S) with a host can be a source page', () {
      expect(webSourcePageUrl(''), isNull);
      expect(webSourcePageUrl('   '), isNull);
      expect(webSourcePageUrl('file:///sdcard/watch/1'), isNull);
      expect(webSourcePageUrl('https://user:secret@play.example/1'), isNull);
      expect(webSourcePageUrl('play.example/1'), isNull);
      expect(
        webSourcePageUrl('https://play.example/watch/1#t=12'),
        Uri.parse('https://play.example/watch/1'),
      );
    });
  });

  group('retry outcome', () {
    late Directory cache;
    late AppDatabase db;
    late _FakeNativeDownloads native;
    late _FakeAuthRefreshBridge bridge;
    late AppController app;
    late List<String> transfers;

    final channel = const MethodChannel('site_lens/media_auth');

    setUpAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => const <String, Object?>{'state': 'unchanged'},
          );
    });

    Future<MediaTask> pageRequiredTask(MediaCandidate candidate) async {
      await db.saveMediaCandidate(candidate);
      final created = await app.mediaTasks.create(candidate);
      app.mediaTasks.transition(created.id, MediaTaskState.downloading);
      return app.mediaTasks.transition(
        created.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );
    }

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('site-lens-source-page-');
      db = AppDatabase(NativeDatabase.memory());
      native = _FakeNativeDownloads();
      bridge = _FakeAuthRefreshBridge(
        (task) => const MediaAuthorizationRefreshResult(state: 'unchanged'),
      );
      transfers = <String>[];
      app = AppController(
        db,
        api: FakeWebHostApi(),
        nativeDownloads: native,
        nativeMediaAuthRefresh: bridge,
        mediaDirectoryProvider: () async => cache,
        mediaPolicyTransfer: _offlineTransfer(transfers),
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
        if (cache.existsSync()) await cache.delete(recursive: true);
      });
      await app.load();
    });

    test('a page-required task reports 需回播放页 and starts nothing', () async {
      final stored = _candidate(
        id: 'cand-page',
        sourceUrl: 'https://site.example/watch/1',
        mediaUrl: 'https://cdn.example/index.m3u8?token=old',
      );
      final task = await pageRequiredTask(stored);
      bridge.answer = (value) => const MediaAuthorizationRefreshResult(
        state: 'reauthorize',
        reason: '授权状态未更新，请返回来源页重新授权',
      );

      final outcome = await app.retryMediaTaskResult(task);

      expect(outcome.kind, MediaRetryOutcomeKind.requiresPage);
      expect(outcome.offersSourcePage, isTrue);
      expect(outcome.message, '授权状态未更新，请返回来源页重新授权');
      expect(bridge.singles, hasLength(1));
      expect(native.calls, isEmpty);
      expect(app.mediaTasks.task(task.id)!.state, MediaTaskState.reauthorize);
      expect((await db.mediaCandidate(stored.id))!.mediaUrl, stored.mediaUrl);
    });

    test(
      'an unchanged outcome says the authorization did not change',
      () async {
        final stored = _candidate(
          id: 'cand-unchanged',
          sourceUrl: 'https://site.example/watch/1',
          mediaUrl: 'https://cdn.example/index.m3u8?token=old',
        );
        final task = await pageRequiredTask(stored);
        bridge.answer = (value) => const MediaAuthorizationRefreshResult(
          state: 'unchanged',
          reason: '页面未重新请求主清单',
        );

        final outcome = await app.retryMediaTaskResult(task);

        expect(outcome.kind, MediaRetryOutcomeKind.unchanged);
        expect(outcome.offersSourcePage, isTrue);
        expect(outcome.message, '授权未变化：页面未重新请求主清单');
        expect(native.calls, isEmpty);
        expect(app.mediaTasks.task(task.id)!.state, MediaTaskState.reauthorize);
      },
    );

    test('a waiting outcome offers no source page', () async {
      final stored = _candidate(
        id: 'cand-waiting',
        sourceUrl: 'https://site.example/watch/1',
        mediaUrl: 'https://cdn.example/index.m3u8?token=old',
      );
      final task = await pageRequiredTask(stored);
      bridge.answer = (value) => const MediaAuthorizationRefreshResult(
        state: 'waiting_execution',
        reason: '系统暂不允许后台授权刷新',
      );

      final outcome = await app.retryMediaTaskResult(task);

      expect(outcome.kind, MediaRetryOutcomeKind.waiting);
      expect(outcome.offersSourcePage, isFalse);
      expect(outcome.message, '系统暂不允许后台授权刷新');
      expect(app.mediaTasks.task(task.id)!.state, MediaTaskState.reauthorize);
    });

    test(
      'a refresh whose address cannot be adopted degrades to 需回播放页',
      () async {
        final stored = _candidate(
          id: 'cand-empty',
          sourceUrl: 'https://site.example/watch/1',
          mediaUrl: 'https://cdn.example/index.m3u8?token=old',
        );
        final task = await pageRequiredTask(stored);
        bridge.answer = (value) =>
            const MediaAuthorizationRefreshResult(state: 'refreshed');

        final outcome = await app.retryMediaTaskResult(task);

        expect(outcome.kind, MediaRetryOutcomeKind.requiresPage);
        expect(outcome.offersSourcePage, isTrue);
        expect(outcome.message, isNot(startsWith('授权未变化：')));
        expect(native.calls, isEmpty);
        expect((await db.mediaCandidate(stored.id))!.mediaUrl, stored.mediaUrl);
        expect(app.mediaTasks.task(task.id)!.state, MediaTaskState.reauthorize);
      },
    );

    test('a refreshed outcome keeps the existing retry toast', () async {
      final stored = _candidate(
        id: 'cand-refreshed',
        sourceUrl: 'https://site.example/watch/1',
        mediaUrl: 'https://cdn.example/index.m3u8?token=old',
      );
      final task = await pageRequiredTask(stored);
      bridge.answer = (value) => const MediaAuthorizationRefreshResult(
        state: 'refreshed',
        mediaUrl: 'https://cdn.example/index.m3u8?token=fresh',
      );

      final outcome = await app.retryMediaTaskResult(task);

      expect(outcome.kind, MediaRetryOutcomeKind.resumed);
      expect(outcome.message, '已开始续传');
      expect(outcome.offersSourcePage, isFalse);
      expect(outcome.resumed, isTrue);
      expect(
        {
          MediaTaskState.downloading,
          MediaTaskState.playable,
        }.contains(app.mediaTasks.task(task.id)!.state),
        isTrue,
        reason: 'the resumed transfer keeps running; the local gate is done',
      );
      expect(
        (await db.mediaCandidate(stored.id))!.mediaUrl,
        Uri.parse('https://cdn.example/index.m3u8?token=fresh'),
      );
    });

    test(
      'one source page means one refresh for the whole page-required group',
      () async {
        final first = _candidate(
          id: 'cand-ep1',
          sourceUrl: 'https://site.example/watch/1',
          mediaUrl: 'https://cdn.example/ep1.m3u8?token=old',
        );
        final second = _candidate(
          id: 'cand-ep2',
          sourceUrl: 'https://site.example/watch/1',
          mediaUrl: 'https://cdn.example/ep2.m3u8?token=old',
        );
        final other = _candidate(
          id: 'cand-other',
          sourceUrl: 'https://other.example/watch/9',
          mediaUrl: 'https://cdn.example/ep9.m3u8?token=old',
        );
        final tasks = [
          await pageRequiredTask(first),
          await pageRequiredTask(second),
          await pageRequiredTask(other),
        ];
        bridge.remember(tasks);
        bridge.answer = (task) => MediaAuthorizationRefreshResult(
          state: 'refreshed',
          mediaUrl: switch (task.candidateId) {
            'cand-ep1' => 'https://cdn.example/ep1.m3u8?token=fresh',
            'cand-ep2' => 'https://cdn.example/ep2.m3u8?token=fresh',
            _ => 'https://cdn.example/ep9.m3u8?token=fresh',
          },
        );

        final outcomes = await app.retryMediaTasks(tasks);

        expect(bridge.batches, hasLength(2), reason: 'one group per origin');
        expect(
          bridge.batches.map((batch) => batch.map((r) => r.taskId).toSet()),
          [
            {tasks[0].id, tasks[1].id},
            {tasks[2].id},
          ],
        );
        expect(bridge.singles, isEmpty);
        expect(
          outcomes.map((outcome) => outcome.kind),
          everyElement(MediaRetryOutcomeKind.resumed),
        );
        expect(
          outcomes.map((outcome) => outcome.taskId),
          tasks.map((task) => task.id),
        );
        expect(
          (await db.mediaCandidate('cand-ep2'))!.mediaUrl,
          Uri.parse('https://cdn.example/ep2.m3u8?token=fresh'),
        );
        expect(
          transfers.where((line) => line.startsWith('manifest:')),
          hasLength(3),
          reason: 'each task resumed against its own refreshed address',
        );
        expect(
          transfers.where((line) => line.startsWith('manifest:')),
          everyElement(contains('token=fresh')),
        );
      },
    );

    test('a member without its own capture is reported, not resumed', () async {
      final first = _candidate(
        id: 'cand-a',
        sourceUrl: 'https://site.example/watch/1',
        mediaUrl: 'https://cdn.example/a.m3u8?token=old',
      );
      final second = _candidate(
        id: 'cand-b',
        sourceUrl: 'https://site.example/watch/1',
        mediaUrl: 'https://cdn.example/b.m3u8?token=old',
      );
      final tasks = [
        await pageRequiredTask(first),
        await pageRequiredTask(second),
      ];
      bridge.remember(tasks);
      bridge.answer = (task) => task.candidateId == 'cand-a'
          ? const MediaAuthorizationRefreshResult(
              state: 'refreshed',
              mediaUrl: 'https://cdn.example/a.m3u8?token=fresh',
            )
          : const MediaAuthorizationRefreshResult(
              state: 'reauthorize',
              reason: '页面没有为这一集请求主清单，需回播放页重新选择',
            );

      final outcomes = await app.retryMediaTasks(tasks);

      expect(bridge.batches, hasLength(1));
      expect(outcomes.map((outcome) => outcome.kind), [
        MediaRetryOutcomeKind.resumed,
        MediaRetryOutcomeKind.requiresPage,
      ]);
      expect(outcomes.last.offersSourcePage, isTrue);
      expect(
        app.mediaTasks.task(tasks[1].id)!.state,
        MediaTaskState.reauthorize,
      );
      expect(
        (await db.mediaCandidate('cand-b'))!.mediaUrl,
        Uri.parse('https://cdn.example/b.m3u8?token=old'),
        reason: 'a task never receives another task address',
      );
    });

    test('a single retry never opens a second refresh path', () async {
      final first = _candidate(
        id: 'cand-single',
        sourceUrl: 'https://site.example/watch/1',
        mediaUrl: 'https://cdn.example/one.m3u8?token=old',
      );
      final task = await pageRequiredTask(first);
      bridge.remember([task]);
      bridge.answer = (value) => const MediaAuthorizationRefreshResult(
        state: 'refreshed',
        mediaUrl: 'https://cdn.example/one.m3u8?token=fresh',
      );

      await app.retryMediaTaskResult(task);

      expect(bridge.singles, hasLength(1));
      expect(bridge.batches, isEmpty);
    });
  });

  group('来源页 entry', () {
    late Directory cache;
    late AppDatabase db;
    late AppController app;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('site-lens-source-open-');
      db = AppDatabase(NativeDatabase.memory());
      app = AppController(
        db,
        api: FakeWebHostApi(),
        nativeDownloads: _FakeNativeDownloads(),
        nativeMediaAuthRefresh: _FakeAuthRefreshBridge(
          (task) => const MediaAuthorizationRefreshResult(state: 'unchanged'),
        ),
        mediaDirectoryProvider: () async => cache,
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
        if (cache.existsSync()) await cache.delete(recursive: true);
      });
      await app.load();
    });

    /// A widget host, because the entry reports refusals on screen.
    Future<void> pumpHost(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => lastOpened = openMediaTaskSourcePage(
                  context,
                  app,
                  taskId: 'entry-task',
                  sourceUrl: Uri.parse('https://other.example/watch/9'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    Future<MediaTask> storeTask(WidgetTester tester) async =>
        (await tester.runAsync(() async {
          final candidate = _candidate(
            id: 'cand-entry',
            sourceUrl: 'https://site.example/watch/1',
            mediaUrl: 'https://cdn.example/index.m3u8?token=old',
          );
          await db.saveMediaCandidate(candidate);
          return app.mediaTasks.create(candidate);
        }))!;

    testWidgets('a cross-origin source page is refused and opens nothing', (
      tester,
    ) async {
      await storeTask(tester);
      await pumpHost(tester);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final opened = await tester.runAsync(() async => await lastOpened);
      expect(
        opened,
        isFalse,
        reason: 'the refusal must not be reported as a page on screen',
      );
      expect(app.browserTabs, isEmpty, reason: 'no tab was opened');
      expect(app.activeBrowser, isNull);
      expect(find.text('来源页与任务所在站点不一致，已停止打开'), findsOneWidget);
    });
  });
}
