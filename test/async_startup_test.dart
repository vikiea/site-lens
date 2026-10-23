import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/diagnostics/error_log.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'fake_web_host_api.dart';

class HeldStartupDatabase extends AppDatabase {
  HeldStartupDatabase() : super(NativeDatabase.memory());
  final mediaEntered = Completer<void>();
  final mediaRelease = Completer<void>();
  final filtersEntered = Completer<void>();
  final filtersRelease = Completer<void>();
  bool mediaFails = false;
  bool profilesFail = false;
  bool filtersFail = false;
  int mediaReads = 0;
  Completer<void>? nextFilterEntered;
  Completer<void>? nextFilterRelease;

  @override
  Future<List<MediaTask>> mediaTasks() async {
    mediaReads++;
    if (!mediaEntered.isCompleted) mediaEntered.complete();
    await mediaRelease.future;
    if (mediaFails) throw StateError('media read failed');
    return super.mediaTasks();
  }

  @override
  Future<FilterSnapshot?> latestFilterSnapshot() async {
    if (!filtersEntered.isCompleted) filtersEntered.complete();
    await filtersRelease.future;
    if (nextFilterEntered case final entered?) {
      if (!entered.isCompleted) entered.complete();
    }
    await nextFilterRelease?.future;
    if (filtersFail) throw StateError('filter read failed');
    return super.latestFilterSnapshot();
  }

  @override
  Future<List<SiteProfile>> profiles() {
    if (profilesFail) throw StateError('profile read failed');
    return super.profiles();
  }

  void release() {
    if (!mediaRelease.isCompleted) mediaRelease.complete();
    if (!filtersRelease.isCompleted) filtersRelease.complete();
    final retryRelease = nextFilterRelease;
    if (retryRelease != null && !retryRelease.isCompleted) {
      retryRelease.complete();
    }
  }
}

MediaCandidate candidate() => MediaCandidate(
  id: 'new-media',
  hostId: 1,
  generation: 1,
  sourceUrl: Uri.parse('https://site.example/watch'),
  mediaUrl: Uri.parse('https://site.example/video.mp4'),
  title: '视频',
  mime: 'video/mp4',
  source: MediaCandidateSource.dom,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HeldStartupDatabase db;
  late AppController app;
  late FakeWebHostApi api;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('site-lens-startup-');
    AppErrorLogger.pendingDirectoryProvider = () async => directory;
    db = HeldStartupDatabase();
    api = FakeWebHostApi();
    app = AppController(
      db,
      api: api,
      mediaDirectoryProvider: () async => directory,
    );
    final profileId = await db.createProfile('已保存站点');
    await BrowserSessionStore(db).save([
      SavedBrowserTab(
        id: 'saved-tab',
        initialUrl: Uri.parse('https://site.example/'),
        currentUrl: Uri.parse('https://site.example/chapter'),
        title: '已保存标签',
        profileId: profileId,
      ),
    ], 'saved-tab');
  });
  tearDown(() async {
    db.release();
    try {
      await app.shutdown();
    } finally {
      await db.close();
      AppErrorLogger.pendingDirectoryProvider = null;
      await directory.delete(recursive: true);
    }
  });

  test(
    'home and saved tabs are usable while media and filters remain pending',
    () async {
      final initialized = app.initialize();
      expect(identical(initialized, app.initialize()), isTrue);
      await initialized;
      await Future.wait([db.mediaEntered.future, db.filtersEntered.future]);
      expect(app.persistentStateLoaded, isTrue);
      expect(app.profiles.single.name, '已保存站点');
      expect(app.browserTabs.single.title, '已保存标签');
      expect(app.activeBrowser!.loadedHost, isNull);
      expect(app.mediaReady, isFalse);
      expect(api.created, isEmpty);
      expect(() => app.mediaTasks.create(candidate()), throwsStateError);
      final loading = app.activateTab(app.activeBrowser!);
      await Future<void>.delayed(Duration.zero);
      expect(api.created, isEmpty);
      db.filtersRelease.complete();
      await loading;
      expect(api.created, hasLength(1));
      expect(app.mediaReady, isFalse);
      db.mediaRelease.complete();
      await app.startupSettled;
      await db.saveMediaCandidate(candidate());
      final task = app.mediaTasks.create(candidate());
      await app.mediaTasks.flush(task.id);
      expect((await db.mediaTasks()).single.id, task.id);
    },
  );

  test(
    'closing a tab while waiting for filters never creates its host',
    () async {
      await app.initialize();
      await db.filtersEntered.future;
      final tab = app.activeBrowser!;
      final open = app.activateTab(tab);
      final result = expectLater(open, throwsA(isA<Exception>()));
      await app.closeTab(tab);
      db.release();
      await result;
      await app.startupSettled;
      expect(api.created, isEmpty);
      expect((await app.sessionStore.read()).tabs, isEmpty);
    },
  );

  test(
    'failed media recovery leaves writes fenced but browser usable',
    () async {
      db.mediaFails = true;
      await app.initialize();
      db.release();
      await app.startupSettled;
      expect(app.mediaReady, isFalse);
      expect(app.mediaStartupError, isNotNull);
      expect(() => app.mediaTasks.create(candidate()), throwsStateError);
      await app.activateTab(app.activeBrowser!);
      expect(api.created, hasLength(1));
    },
  );

  test('unknown profiles do not erase a saved profile association', () async {
    db.profilesFail = true;
    await app.initialize();
    expect(app.activeBrowser!.site.profileId, isNotNull);
    db.release();
    await app.startupSettled;
  });

  test(
    'failed media recovery stays failed until an explicit restore',
    () async {
      db.mediaFails = true;
      await app.initialize();
      db.release();
      await app.startupSettled;
      expect(db.mediaReads, 1);
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(app.mediaTasks.ready, throwsStateError);
      }
      expect(db.mediaReads, 1);
      expect(app.mediaTasks.available, isFalse);
      db.mediaFails = false;
      await app.mediaTasks.restore();
      await app.mediaTasks.ready;
      expect(db.mediaReads, 2);
      expect(app.mediaTasks.available, isTrue);
    },
  );

  test(
    'failed rule preparation blocks navigation while home remains available',
    () async {
      db.filtersFail = true;
      await app.initialize();
      db.release();
      await app.startupSettled;
      expect(app.persistentStateLoaded, isTrue);
      await expectLater(app.activateTab(app.activeBrowser!), throwsStateError);
      expect(api.created, isEmpty);
    },
  );

  test(
    'shutdown waits for deferred recovery before database closure',
    () async {
      await app.initialize();
      await Future.wait([db.mediaEntered.future, db.filtersEntered.future]);
      var stopped = false;
      final shutdown = app.shutdown().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      db.release();
      await shutdown;
      expect(stopped, isTrue);
    },
  );

  test(
    'navigation retries successfully after failed rule preparation',
    () async {
      db.filtersFail = true;
      await app.initialize();
      db.release();
      await app.startupSettled;
      db.filtersFail = false;
      await app.activateTab(app.activeBrowser!);
      expect(api.created, hasLength(1));
    },
  );

  test('shutdown waits for an accepted browser preparation retry', () async {
    db.filtersFail = true;
    await app.initialize();
    db.release();
    await app.startupSettled;
    db.filtersFail = false;
    db.nextFilterEntered = Completer<void>();
    db.nextFilterRelease = Completer<void>();
    final open = app.activateTab(app.activeBrowser!);
    final cancelled = expectLater(open, throwsA(isA<Exception>()));
    await db.nextFilterEntered!.future;
    var stopped = false;
    final shutdown = app.shutdown().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    db.nextFilterRelease!.complete();
    await cancelled;
    await shutdown;
    expect(stopped, isTrue);
    expect(api.created, isEmpty);
  });
}
