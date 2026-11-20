import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/media/native_media_auth_refresh.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';

/// Records the native start the retry ends with, so a test can prove the
/// transfer resumes against the refreshed address and never restarts blind.
class FakeNativeDownloads extends NativeDownloadRuntime {
  FakeNativeDownloads() : super(channel: const MethodChannel('fake_downloads'));

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
  Future<void> pause(String taskId) async => calls.add('pause:$taskId');

  @override
  Future<void> cancel(String taskId) async => calls.add('cancel:$taskId');
}

/// Stands in for the Android authorization-refresh bridge. Records every
/// request so a test can assert the refresh really ran.
class FakeAuthRefreshBridge extends NativeMediaAuthRefresh {
  FakeAuthRefreshBridge(this.answer);

  final MediaAuthorizationRefreshResult Function(
    MediaTask task,
    MediaCandidate candidate,
  )
  answer;
  final requests = <({String taskId, String mediaUrl})>[];

  @override
  Future<MediaAuthorizationRefreshResult> refresh(
    MediaTask task,
    MediaCandidate candidate,
  ) async {
    requests.add((taskId: task.id, mediaUrl: candidate.mediaUrl.toString()));
    return answer(task, candidate);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = const MethodChannel('site_lens/media_auth');

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => const <String, Object?>{'state': 'unchanged'},
        );
  });

  var sequence = 0;
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('site-lens-retry-$sequence-');
    sequence++;
  });

  tearDown(() async {
    if (cache.existsSync()) await cache.delete(recursive: true);
  });

  /// One stored candidate plus a page-required task. `retainFiles` keeps the
  /// cache directory outside the per-test temp root.
  MediaCandidate baseCandidate() => MediaCandidate(
    id: 'cand-1',
    hostId: 7,
    generation: 3,
    sourceUrl: Uri.parse('https://site.example/watch/1'),
    mediaUrl: Uri.parse('https://cdn.example/index.m3u8?token=old'),
    title: '系列 - 第1集',
    mime: 'application/vnd.apple.mpegurl',
    source: MediaCandidateSource.dom,
    seriesKey: 'series:1',
    episodeNumber: 1,
    qualityLabel: '720p',
  );

  /// Answers the manifest and one short segment so a resumed HLS transfer can
  /// finish offline; nothing leaves the machine.
  NativeTlsTransferWithPolicy offlineTransfer(List<String> requested) =>
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

  test(
    'a page-required retry still refreshes when the source tab is gone',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final native = FakeNativeDownloads();
      final bridge = FakeAuthRefreshBridge(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'refreshed',
          mediaUrl: 'https://cdn.example/index.m3u8?token=fresh',
        ),
      );
      final transfers = <String>[];
      final app = AppController(
        db,
        nativeDownloads: native,
        nativeMediaAuthRefresh: bridge,
        mediaDirectoryProvider: () async => cache,
        mediaPolicyTransfer: offlineTransfer(transfers),
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      final stored = baseCandidate();
      await db.saveMediaCandidate(stored);
      final created = await app.mediaTasks.create(stored);
      app.mediaTasks.transition(created.id, MediaTaskState.downloading);
      final failed = app.mediaTasks.transition(
        created.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );
      expect(app.hosts.sessions[stored.hostId], isNull);

      await app.retryMediaTask(failed);

      expect(bridge.requests, hasLength(1));
      expect(transfers.first, contains('token=fresh'));
      expect(bridge.requests.single.mediaUrl, contains('token=old'));
      expect(
        {
          MediaTaskState.downloading,
          MediaTaskState.playable,
        }.contains(app.mediaTasks.task(failed.id)!.state),
        isTrue,
        reason: 'the resumed transfer ran to completion offline',
      );
      expect(app.mediaTasks.task(failed.id)!.candidateId, stored.id);
      final persisted = await db.mediaCandidate(stored.id);
      expect(
        persisted!.mediaUrl,
        Uri.parse('https://cdn.example/index.m3u8?token=fresh'),
      );
    },
  );

  test(
    'an unchanged refresh keeps the task page-required and starts nothing',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final native = FakeNativeDownloads();
      final bridge = FakeAuthRefreshBridge(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'unchanged',
          reason: '页面未重新请求主清单，请返回来源页',
        ),
      );
      final app = AppController(
        db,
        nativeDownloads: native,
        nativeMediaAuthRefresh: bridge,
        mediaDirectoryProvider: () async => cache,
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      final stored = baseCandidate();
      await db.saveMediaCandidate(stored);
      final created = await app.mediaTasks.create(stored);
      app.mediaTasks.transition(created.id, MediaTaskState.downloading);
      final failed = app.mediaTasks.transition(
        created.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );

      await expectLater(
        app.retryMediaTask(failed),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            contains('页面未重新请求主清单'),
          ),
        ),
      );
      expect(bridge.requests, hasLength(1));
      expect(native.calls, isEmpty);
      expect(app.mediaTasks.task(failed.id)!.state, MediaTaskState.reauthorize);
      expect((await db.mediaCandidate(stored.id))!.mediaUrl, stored.mediaUrl);
    },
  );

  group('adoption fails closed', () {
    Future<({AppController app, MediaTask task, MediaCandidate stored})>
    pageRequired(
      MediaAuthorizationRefreshResult Function(MediaCandidate stored) capture,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      final stored = baseCandidate();
      final app = AppController(
        db,
        nativeDownloads: FakeNativeDownloads(),
        nativeMediaAuthRefresh: FakeAuthRefreshBridge(
          (task, candidate) => capture(candidate),
        ),
        mediaDirectoryProvider: () async => cache,
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      await db.saveMediaCandidate(stored);
      final created = await app.mediaTasks.create(stored);
      app.mediaTasks.transition(created.id, MediaTaskState.downloading);
      final failed = app.mediaTasks.transition(
        created.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );
      return (app: app, task: failed, stored: stored);
    }

    test('a refreshed result without an address is not adopted', () async {
      final h = await pageRequired(
        (stored) => const MediaAuthorizationRefreshResult(
          state: 'refreshed',
          reason: '页面没有主清单请求',
        ),
      );
      await expectLater(
        h.app.retryMediaTask(h.task),
        throwsA(isA<StateError>()),
      );
      expect(
        h.app.mediaTasks.task(h.task.id)!.state,
        MediaTaskState.reauthorize,
      );
      expect(h.app.mediaTasks.task(h.task.id)!.candidateId, h.stored.id);
    });

    test('a different logical resource is refused', () async {
      final h = await pageRequired(
        (stored) => const MediaAuthorizationRefreshResult(
          state: 'refreshed',
          mediaUrl: 'https://cdn.example/another-episode.m3u8?token=new',
        ),
      );
      await expectLater(
        h.app.retryMediaTask(h.task),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            contains('另一个媒体资源'),
          ),
        ),
      );
      expect(h.app.mediaTasks.task(h.task.id)!.candidateId, h.stored.id);
      expect(
        h.app.mediaTasks.task(h.task.id)!.state,
        MediaTaskState.reauthorize,
      );
    });

    test('a non-http address is refused', () async {
      final h = await pageRequired(
        (stored) => const MediaAuthorizationRefreshResult(
          state: 'refreshed',
          mediaUrl: 'file:///sdcard/index.m3u8',
        ),
      );
      await expectLater(
        h.app.retryMediaTask(h.task),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            contains('地址无效'),
          ),
        ),
      );
      expect(h.app.mediaTasks.task(h.task.id)!.candidateId, h.stored.id);
    });

    test('an address with embedded credentials is refused', () async {
      final h = await pageRequired(
        (stored) => const MediaAuthorizationRefreshResult(
          state: 'refreshed',
          mediaUrl: 'https://user:secret@cdn.example/index.m3u8?token=fresh',
        ),
      );
      await expectLater(
        h.app.retryMediaTask(h.task),
        throwsA(isA<StateError>()),
      );
      expect(h.app.mediaTasks.task(h.task.id)!.candidateId, h.stored.id);
    });
  });

  group('typed retry outcome', () {
    late Directory cache;
    late AppDatabase db;

    Future<
      ({
        AppController app,
        MediaTask task,
        MediaCandidate stored,
        FakeNativeDownloads native,
      })
    >
    pageRequired(
      MediaAuthorizationRefreshResult Function(
        MediaTask task,
        MediaCandidate candidate,
      )
      answer,
    ) async {
      cache = await Directory.systemTemp.createTemp('site-lens-retry-outcome-');
      db = AppDatabase(NativeDatabase.memory());
      final native = FakeNativeDownloads();
      final bridge = FakeAuthRefreshBridge(answer);
      final transfers = <String>[];
      final app = AppController(
        db,
        nativeDownloads: native,
        nativeMediaAuthRefresh: bridge,
        mediaDirectoryProvider: () async => cache,
        mediaPolicyTransfer: offlineTransfer(transfers),
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
        if (cache.existsSync()) await cache.delete(recursive: true);
      });
      await app.load();
      final stored = baseCandidate();
      await db.saveMediaCandidate(stored);
      final created = await app.mediaTasks.create(stored);
      app.mediaTasks.transition(created.id, MediaTaskState.downloading);
      final failed = app.mediaTasks.transition(
        created.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );
      return (app: app, task: failed, stored: stored, native: native);
    }

    test(
      'a cacheMissing retry resumes instead of deleting the bytes',
      () async {
        // cache_missing means the finished file is gone or the record was
        // lost. The bytes already fetched are still on disk, so retrying hands
        // them back to the native runtime as a Range instead of deleting and
        // restarting from zero.
        final root = await Directory.systemTemp.createTemp('site-lens-cache-');
        addTearDown(() => root.delete(recursive: true));
        final db = AppDatabase(NativeDatabase.memory());
        final native = FakeNativeDownloads();
        final app = AppController(
          db,
          nativeDownloads: native,
          nativeMediaAuthRefresh: FakeAuthRefreshBridge(
            (task, candidate) => const MediaAuthorizationRefreshResult(
              state: 'refreshed',
              mediaUrl: 'https://cdn.example/video.mp4?token=fresh',
            ),
          ),
          mediaDirectoryProvider: () async => root,
          mediaPolicyTransfer: offlineTransfer([]),
        );
        addTearDown(() async {
          await app.shutdown();
          await db.close();
        });
        await app.load();
        final stored = MediaCandidate(
          id: 'cand-direct',
          hostId: 7,
          generation: 3,
          sourceUrl: Uri.parse('https://site.example/watch/1'),
          mediaUrl: Uri.parse('https://cdn.example/video.mp4?token=old'),
          title: '系列 - 第1集',
          mime: 'video/mp4',
          source: MediaCandidateSource.dom,
        );
        await db.saveMediaCandidate(stored);
        final created = await app.mediaTasks.create(stored);
        app.mediaTasks.transition(created.id, MediaTaskState.downloading);
        final failed = app.mediaTasks.transition(
          created.id,
          MediaTaskState.reauthorize,
          errorCode: MediaErrorCode.authorizationRequired,
        );
        final missing = app.mediaTasks.transition(
          failed.id,
          MediaTaskState.failed,
          errorCode: MediaErrorCode.cacheMissing,
        );

        final outcome = await app.retryMediaTaskResult(missing);

        expect(outcome.kind, MediaRetryOutcomeKind.resumed);
        expect(
          native.calls.where((call) => call.startsWith('start:${missing.id}')),
          isNotEmpty,
        );
        expect(native.calls.where((call) => call.contains('delete')), isEmpty);
      },
    );

    test('refreshed answers with the existing resume wording', () async {
      final h = await pageRequired(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'refreshed',
          mediaUrl: 'https://cdn.example/index.m3u8?token=fresh',
        ),
      );

      final outcome = await h.app.retryMediaTaskResult(h.task);

      expect(outcome.kind, MediaRetryOutcomeKind.resumed);
      expect(outcome.message, '已开始续传');
      expect(outcome.offersSourcePage, isFalse);
      expect(outcome.resumed, isTrue);
      expect(outcome.taskId, h.task.id);
      expect(outcome.task, isNotNull);
    });

    test('unchanged says the authorization did not change', () async {
      final h = await pageRequired(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'unchanged',
          reason: '页面未重新请求主清单',
        ),
      );

      final outcome = await h.app.retryMediaTaskResult(h.task);

      expect(outcome.kind, MediaRetryOutcomeKind.unchanged);
      expect(outcome.message, '授权未变化：页面未重新请求主清单');
      expect(outcome.offersSourcePage, isTrue);
      expect(outcome.task, isNull);
      expect(outcome.task, isNull);
    });

    test('reauthorize asks the user back to the source page', () async {
      final h = await pageRequired(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'reauthorize',
          reason: '需回来源页重新授权媒体',
        ),
      );

      final outcome = await h.app.retryMediaTaskResult(h.task);

      expect(outcome.kind, MediaRetryOutcomeKind.requiresPage);
      expect(outcome.message, '需回来源页重新授权媒体');
      expect(outcome.offersSourcePage, isTrue);
      expect(
        h.app.mediaTasks.task(h.task.id)!.state,
        MediaTaskState.reauthorize,
      );
      expect(
        (await db.mediaCandidate(h.stored.id))!.mediaUrl,
        h.stored.mediaUrl,
      );
    });

    test('waiting_execution is a plain message with no action', () async {
      final h = await pageRequired(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'waiting_execution',
          reason: '系统暂不允许后台授权刷新',
        ),
      );

      final outcome = await h.app.retryMediaTaskResult(h.task);

      expect(outcome.kind, MediaRetryOutcomeKind.waiting);
      expect(outcome.offersSourcePage, isFalse);
      expect(outcome.message, '系统暂不允许后台授权刷新');
    });

    test('a refresh without an address degrades to 需回来源页', () async {
      final h = await pageRequired(
        (task, candidate) =>
            const MediaAuthorizationRefreshResult(state: 'refreshed'),
      );

      final outcome = await h.app.retryMediaTaskResult(h.task);

      // The refresh reported success, so the page did answer; an address that
      // cannot be adopted is the page's hand-over failing, not 授权未变化.
      expect(outcome.kind, MediaRetryOutcomeKind.requiresPage);
      expect(outcome.message, contains('来源页'));
      expect(outcome.message, isNot(startsWith('授权未变化：')));
      expect(outcome.offersSourcePage, isTrue);
      expect(outcome.task, isNull);
      expect(
        (await db.mediaCandidate(h.stored.id))!.mediaUrl,
        h.stored.mediaUrl,
        reason: 'nothing is adopted when the address does not pass the gates',
      );
      expect(
        h.app.mediaTasks.task(h.task.id)!.state,
        MediaTaskState.reauthorize,
      );
    });

    test('the throwing entry point keeps its message', () async {
      final h = await pageRequired(
        (task, candidate) => const MediaAuthorizationRefreshResult(
          state: 'unchanged',
          reason: '页面未重新请求主清单',
        ),
      );

      await expectLater(
        h.app.retryMediaTask(h.task),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '授权未变化：页面未重新请求主清单',
          ),
        ),
      );
    });
  });
}
