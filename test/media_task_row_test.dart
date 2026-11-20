import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_download_runtime.dart';
import 'package:site_lens/media/native_media_auth_refresh.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';

import 'fake_web_host_api.dart';

class _RowNativeDownloads extends NativeDownloadRuntime {
  _RowNativeDownloads()
    : super(channel: const MethodChannel('fake_row_downloads'));

  final calls = <String>[];

  @override
  Future<Map<String, Object?>> start(
    MediaTask task,
    MediaCandidate candidate, {
    String? title,
    String? storageDirectory,
  }) async {
    calls.add('start:${candidate.mediaUrl}');
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

class _RowAuthRefreshBridge extends NativeMediaAuthRefresh {
  _RowAuthRefreshBridge(this.answer);

  MediaAuthorizationRefreshResult Function(MediaTask task) answer;

  @override
  Future<MediaAuthorizationRefreshResult> refresh(
    MediaTask task,
    MediaCandidate candidate,
  ) async => answer(task);
}

void main() {
  test('row action mapping follows the task state', () {
    expect(
      mediaTaskRowActionForState(MediaTaskState.playable),
      MediaTaskRowAction.play,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.downloading),
      MediaTaskRowAction.pause,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.paused),
      MediaTaskRowAction.pause,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.failed),
      MediaTaskRowAction.retry,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.queued),
      MediaTaskRowAction.pause,
    );
  });

  test(
    'batch pause includes queued members but resume only paused members',
    () {
      expect(mediaTaskCanPause(MediaTaskState.queued), isTrue);
      expect(mediaTaskCanPause(MediaTaskState.downloading), isTrue);
      expect(mediaTaskCanPause(MediaTaskState.paused), isFalse);
      expect(mediaTaskCanResume(MediaTaskState.paused), isTrue);
      expect(
        mediaTaskCanDiscardForExistingArtifact(MediaTaskState.queued),
        isTrue,
      );
      expect(
        mediaTaskCanDiscardForExistingArtifact(MediaTaskState.downloading),
        isFalse,
      );
      expect(
        mediaTaskCanDiscardForExistingArtifact(MediaTaskState.paused),
        isFalse,
      );
      expect(
        mediaTaskCanDiscardForExistingArtifact(MediaTaskState.completed),
        isFalse,
      );
      expect(mediaTaskCanResume(MediaTaskState.queued), isFalse);
    },
  );

  test(
    'row descriptions show exact playable, progress and retry information',
    () async {
      final candidate = MediaCandidate(
        id: 'row-candidate',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.test/watch/1'),
        mediaUrl: Uri.parse('https://cdn.example/1.mp4'),
        title: '示例系列 - 第1集',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
        episodeNumber: 1,
      );
      final store = MediaTaskStore();
      var task = await store.create(candidate);
      task = store.transition(task.id, MediaTaskState.downloading);
      task = store.updateProgress(task.id, 50, totalBytes: 100);

      expect(
        mediaTaskRowDescription(task, candidate: candidate),
        '下载中 · 50% · 50 B/100 B',
      );

      task = store.transition(task.id, MediaTaskState.completed);
      task = store.transition(task.id, MediaTaskState.playable);
      final artifact = MediaArtifact(
        taskId: task.id,
        location: '/tmp/第1集.mp4',
        name: '第1集.mp4',
        size: 100,
        durationMs: 90_000,
        createdAt: DateTime(2026),
      );
      expect(
        mediaTaskRowDescription(task, candidate: candidate, artifact: artifact),
        '可播放 · 100 B · 01:30',
      );

      task = store.transition(task.id, MediaTaskState.failed);
      expect(mediaTaskRowDescription(task, candidate: candidate), '点击重试');
    },
  );

  test(
    'HLS progress does not claim an exact total before completion',
    () async {
      final candidate = MediaCandidate(
        id: 'hls-row-candidate',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.test/watch/1'),
        mediaUrl: Uri.parse('https://cdn.example/1.m3u8'),
        title: '示例系列 - 第1集',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
        episodeNumber: 1,
      );
      final store = MediaTaskStore();
      var task = await store.create(candidate);
      task = store.transition(task.id, MediaTaskState.downloading);
      task = store.updateProgress(task.id, 512, totalBytes: 1024);

      expect(
        mediaTaskRowDescription(task, candidate: candidate),
        '下载中 · 已下载 512 B · 总大小未知',
      );
    },
  );

  group('来源页 entry', () {
    late Directory cache;
    late AppDatabase db;
    late AppController app;
    late _RowNativeDownloads native;
    late _RowAuthRefreshBridge bridge;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('site-lens-row-menu-');
      db = AppDatabase(NativeDatabase.memory());
      native = _RowNativeDownloads();
      bridge = _RowAuthRefreshBridge(
        (task) => const MediaAuthorizationRefreshResult(state: 'unchanged'),
      );
      app = AppController(
        db,
        api: FakeWebHostApi(),
        nativeDownloads: native,
        nativeMediaAuthRefresh: bridge,
        mediaDirectoryProvider: () async => cache,
      );
      addTearDown(() async {
        await app.shutdown();
        await db.close();
        if (cache.existsSync()) await cache.delete(recursive: true);
      });
      await app.load();
      // Pumps before the test zone exist: the session store, the settings
      // repository and the media catalog all do real async work, so they run
      // outside the fake-async zone instead of leaving pending microtasks.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    /// Stores a task. The store touches the database and the task metadata,
    /// both of which do real async work, so it runs inside [WidgetTester.runAsync]
    /// instead of inside the fake-async test zone.
    Future<MediaTask> store(
      WidgetTester tester,
      String sourceUrl, {
      bool pageRequired = false,
    }) async => (await tester.runAsync(() async {
      final candidate = MediaCandidate(
        id: 'row-menu-${sourceUrl.hashCode}',
        hostId: 7,
        generation: 3,
        // An empty argument stores a task with no source page at all.
        sourceUrl: Uri.parse(sourceUrl),
        mediaUrl: Uri.parse(
          sourceUrl.isEmpty
              ? 'https://cdn.example/index.m3u8?token=old'
              : 'https://cdn.example/index.m3u8?page=$sourceUrl',
        ),
        title: '示例系列 - 第1集',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
        episodeNumber: 1,
      );
      await db.saveMediaCandidate(candidate);
      var task = await app.mediaTasks.create(candidate);
      if (!pageRequired) return task;
      task = app.mediaTasks.transition(task.id, MediaTaskState.downloading);
      return app.mediaTasks.transition(
        task.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );
    }))!;

    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.light),
          home: MediaTasksScreen(app: app),
        ),
      );
      // One frame only: the screen owns a periodic poller, so settling would
      // wait for a timer that never stops.
      await tester.pump();
    }

    Future<void> openMenu(WidgetTester tester, {int at = 0}) async {
      await tester.tap(
        find.widgetWithIcon(IconButton, Icons.more_horiz).at(at),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('the menu offers 打开来源页 in every task state', (tester) async {
      await store(tester, 'https://site.example/watch/1');
      await store(tester, 'https://site.example/watch/2', pageRequired: true);
      await pumpScreen(tester);

      // Row 0 is queued and row 1 is waiting for the page: the entry is a
      // destination, not an operation, so a blocked transfer keeps it too.
      // The menu is a single popup, so each row is checked on its own pump
      // turn: reopening it in the same test would leave the first overlay's
      // timers pending against an already built popup.
      await openMenu(tester, at: 0);
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('刷新授权后重试'), findsNothing);
    });

    testWidgets('a page-required row keeps the source page entry', (
      tester,
    ) async {
      await store(tester, 'https://site.example/watch/1');
      await store(tester, 'https://site.example/watch/2', pageRequired: true);
      await pumpScreen(tester);

      await openMenu(tester, at: 1);
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('打开来源页'), findsOneWidget);
      expect(find.text('刷新授权后重试'), findsOneWidget);
    });

    testWidgets('a task without a source page hides the entry', (tester) async {
      await store(tester, '');
      await pumpScreen(tester);

      await openMenu(tester);

      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('打开来源页'), findsNothing);
    });

    testWidgets('the page-required retry reports the three states apart', (
      tester,
    ) async {
      final task = await store(
        tester,
        'https://site.example/watch/1',
        pageRequired: true,
      );
      bridge.answer = (value) => const MediaAuthorizationRefreshResult(
        state: 'reauthorize',
        reason: '授权状态未更新，请返回播放页重新授权',
      );
      await pumpScreen(tester);

      await tester.tap(find.text('点击重试').first);
      await tester.pumpAndSettle();

      expect(find.text('授权状态未更新，请返回播放页重新授权'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '打开来源页'), findsOneWidget);
      expect(
        app.mediaTasks.task(task.id)!.state,
        MediaTaskState.reauthorize,
        reason: 'the failure leaves no fake progress behind',
      );
      expect(native.calls, isEmpty);
    });

    testWidgets('an unchanged authorization says it did not change', (
      tester,
    ) async {
      final task = await store(
        tester,
        'https://site.example/watch/1',
        pageRequired: true,
      );
      bridge.answer = (value) => const MediaAuthorizationRefreshResult(
        state: 'unchanged',
        reason: '页面未重新请求主清单',
      );
      await pumpScreen(tester);

      await tester.tap(find.text('点击重试').first);
      await tester.pumpAndSettle();

      expect(find.text('授权未变化：页面未重新请求主清单'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '打开来源页'), findsOneWidget);
      expect(app.mediaTasks.task(task.id)!.state, MediaTaskState.reauthorize);
    });
  });
}
