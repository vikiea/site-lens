import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

class DelayedRead extends BrowserSessionStore {
  DelayedRead(super.db);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<BrowserSessionSnapshot> read() async {
    final value = await super.read();
    entered.complete();
    await release.future;
    return value;
  }
}

class FailSave extends BrowserSessionStore {
  FailSave(super.db);
  bool failNext = false;

  @override
  Future<void> save(List<SavedBrowserTab> tabs, String? activeId) {
    if (failNext) {
      failNext = false;
      throw StateError('保存失败');
    }
    return super.save(tabs, activeId);
  }
}

class FailCreate extends FakeWebHostApi {
  FailCreate(this.at);
  final int at;
  int calls = 0;
  @override
  Future<HostCapabilities> create(
    int id,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async {
    if (++calls == at) throw StateError('加载失败');
    return super.create(id, purpose, preferences);
  }
}

class HeldCreate extends FakeWebHostApi {
  HeldCreate(this.holdAt, {this.failAt = 0});
  final int holdAt;
  final int failAt;
  final entered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<HostCapabilities> create(
    int id,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async {
    final call = ++calls;
    if (call == holdAt) {
      entered.complete();
      await release.future;
    }
    if (call == failAt) throw StateError('delayed failure');
    return super.create(id, purpose, preferences);
  }
}

SavedBrowserTab record(String id) => SavedBrowserTab(
  id: id,
  initialUrl: Uri.parse('https://$id.example/'),
  currentUrl: Uri.parse('https://$id.example/'),
  title: id,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in ['open', 'close', 'disable', 'shutdown']) {
    test('late restoration never overrides $action during reading', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await BrowserSessionStore(db).save([record('a')], 'a');
      final delayed = DelayedRead(db);
      final app = AppController(
        db,
        api: FakeWebHostApi(),
        sessionStore: delayed,
      );
      await app.load();
      final restore = app.restoreSavedSessions();
      await delayed.entered.future;
      if (action == 'open') await app.openUrl(Uri.parse('https://b.example/'));
      if (action == 'close') await app.closeAllTabs();
      if (action == 'disable') await app.setRestoreBrowserSessions(false);
      if (action == 'shutdown') await app.shutdown();
      delayed.release.complete();
      await restore;
      expect(app.browserTabs.length, action == 'open' ? 1 : 0);
      if (action == 'open') {
        expect(app.activeBrowser!.currentUrl.host, 'b.example');
      }
      await app.shutdown();
    });
  }

  test('closing commits removal even when the next cold host fails', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await BrowserSessionStore(db).save([record('a'), record('b')], 'a');
    final app = AppController(db, api: FailCreate(2));
    await app.load();
    await app.restoreSavedSessions();
    await app.activateTab(app.browserTabs.first);
    app.browserVisible = true;
    final closed = app.browserTabs.first;
    expect(await app.closeTab(closed), isTrue);
    final saved = await BrowserSessionStore(db).read();
    expect(saved.tabs.map((t) => t.id), ['b']);
    expect(saved.activeId, 'b');
    expect(app.activeBrowser!.state, BrowserSessionState.failed);
    await app.shutdown();
  });

  test(
    'shutdown flushes title and navigation before the debounce runs',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final app = AppController(db, api: FakeWebHostApi());
      await app.load();
      final tab = await app.openUrl(Uri.parse('https://a.example/'));
      await app.hosts.onEvent(
        HostEvent(
          hostId: tab.host.id,
          generation: tab.host.generation,
          kind: 'title',
          url: 'https://a.example/new',
          detail: '新的标题',
        ),
      );
      await app.shutdown();
      final saved = (await BrowserSessionStore(db).read()).tabs.single;
      expect(saved.currentUrl.path, '/new');
      expect(saved.title, '新的标题');
    },
  );

  testWidgets(
    'cold load failure shows retry, switch and exit, never an endless spinner',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FailCreate(1));
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      await app.sessionStore.save([record('failed')], 'failed');
      await app.restoreSavedSessions();
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserScreen(app: app, site: app.browserTabs.single.site),
        ),
      );
      // Allow genuine host/asset I/O outside the widget fake clock.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('重新加载'), findsOneWidget);
      expect(find.text('切换标签'), findsOneWidget);
      expect(find.text('返回站点'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.runAsync(app.shutdown);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final recovery in ['retry', 'switch']) {
    testWidgets('failed startup recovers via $recovery and loads successor', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FailCreate(1));
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      await app.sessionStore.save([
        record('failed'),
        record('healthy'),
        record('next'),
      ], 'failed');
      await app.restoreSavedSessions();
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserScreen(app: app, site: app.browserTabs.first.site),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('重新加载'), findsOneWidget);
      if (recovery == 'retry') {
        await tester.tap(find.text('重新加载'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      } else {
        await tester.tap(find.text('切换标签'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('healthy.example/').first);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('重新加载'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(app.browserVisible, isTrue);
      // closeTab serializes the session write through a microtask queue. In a
      // widget test, wrapping this controller operation in runAsync waits on
      // the same fake-async boundary that must advance that queue.
      await app.closeTab(app.activeBrowser!);
      await tester.pumpAndSettle();
      expect(app.activeBrowser!.loadedHost, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.runAsync(app.shutdown);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'closing all tabs from the active browser route pops only that route',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FakeWebHostApi());
      addTearDown(() async {
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await tester.pump();
        await tester.runAsync(app.shutdown);
        await db.close();
      });
      await app.load();
      final host = HostSession(
        1,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'Android WebView test',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: '',
        ),
      );
      final tab = ActiveBrowserSession(
        Candidate(
          id: 0,
          url: Uri.parse('https://close-all.example/'),
          label: 'close-all',
        ),
        host,
      );
      app.browserTabs.add(tab);
      app.activeBrowser = tab;
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
      );
      await tester.runAsync(() async {
        unawaited(
          navigatorKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => BrowserScreen(app: app, site: tab.site),
            ),
          ),
        );
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(navigatorKey.currentState!.canPop(), isTrue);
      await tester.runAsync(() => app.closeAllTabs(persist: false));
      await tester.pump();
      await tester.pump();
      expect(navigatorKey.currentState!.canPop(), isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  test('closing a tab publishes removal before destroying its host', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeWebHostApi();
    final app = AppController(db, api: api);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });
    await app.load();
    final tab = await app.openUrl(Uri.parse('https://teardown.example/'));

    var removalWasPublishedBeforeDestroy = false;
    app.addListener(() {
      if (!app.browserTabs.contains(tab)) {
        removalWasPublishedBeforeDestroy |= api.destroyed.isEmpty;
      }
    });

    await app.closeTab(tab);
    expect(removalWasPublishedBeforeDestroy, isTrue);
    expect(api.destroyed, contains(tab.host.id));
  });

  test(
    'session persistence failure still destroys the closed tab host',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = FakeWebHostApi();
      final store = FailSave(db);
      final app = AppController(db, api: api, sessionStore: store);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      final tab = await app.openUrl(Uri.parse('https://save-failure.example/'));
      store.failNext = true;

      await app.closeTab(tab);

      expect(api.destroyed, contains(tab.host.id));
      expect(app.error, contains('标签记录保存失败'));
    },
  );

  testWidgets('late startup error cannot cover a healthy selected tab', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = HeldCreate(1, failAt: 1);
    final app = AppController(db, api: api);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });
    await app.load();
    await app.sessionStore.save([record('a'), record('b')], 'a');
    await app.restoreSavedSessions();
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserScreen(app: app, site: app.browserTabs.first.site),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    expect(api.entered.isCompleted, true);
    unawaited(app.activateTab(app.browserTabs[1]));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(app.activeBrowser!.loadedHost, isNotNull);
    api.release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(app.activeBrowser!.id, 'b');
    expect(find.text('重新加载'), findsNothing);
    await tester.runAsync(app.shutdown);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'retry completing after exit cannot reactivate browser visibility',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = HeldCreate(2, failAt: 1);
      final app = AppController(db, api: api);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      await app.sessionStore.save([record('a'), record('b')], 'a');
      await app.restoreSavedSessions();
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserScreen(app: app, site: app.browserTabs.first.site),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新加载'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(api.entered.isCompleted, true);
      await tester.pumpWidget(const SizedBox());
      api.release.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(app.browserVisible, false);
      await app.closeTab(app.browserTabs.first);
      expect(app.activeBrowser!.loadedHost, isNull);
      await tester.runAsync(app.shutdown);
    },
  );

  testWidgets('replacing a browser surface keeps the newest route visible', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    late final AppController app;
    late final ActiveBrowserSession first;
    late final ActiveBrowserSession second;
    await tester.runAsync(() async {
      app = AppController(db, api: FakeWebHostApi());
      await app.load();
      first = await app.openUrl(Uri.parse('https://first.example/'));
      second = await app.openUrl(Uri.parse('https://second.example/'));
      await app.activateTab(first);
    });
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: KeyedSubtree(
          key: const ValueKey('first-browser-route'),
          child: BrowserScreen(app: app, site: first.site),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(app.browserSurfaceActive, isTrue);

    await tester.runAsync(() => app.activateTab(second));
    await tester.pumpWidget(
      MaterialApp(
        home: KeyedSubtree(
          key: const ValueKey('second-browser-route'),
          child: BrowserScreen(app: app, site: second.site),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(app.browserSurfaceActive, isTrue);
    expect(app.browserVisible, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(app.browserSurfaceActive, isFalse);
    expect(app.browserVisible, isFalse);
  });

  testWidgets(
    'covered browser routes cannot overwrite the top route visibility',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      late final AppController app;
      late final ActiveBrowserSession first;
      late final ActiveBrowserSession second;
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.runAsync(() async {
        app = AppController(db, api: FakeWebHostApi());
        await app.load();
        first = await app.openUrl(Uri.parse('https://first.example/'));
        second = await app.openUrl(Uri.parse('https://second.example/'));
        await app.activateTab(first);
      });
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [browserRouteObserver],
          home: BrowserScreen(app: app, site: first.site),
        ),
      );
      await tester.pump();
      await tester.runAsync(() => app.activateTab(second));
      final route = MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(app: app, site: second.site),
      );
      unawaited(navigatorKey.currentState!.push<void>(route));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BrowserScreen, skipOffstage: false), findsNWidgets(2));

      var notifications = 0;
      void observed() => notifications++;
      app.addListener(observed);
      app.notifyListeners();
      await tester.pump();
      expect(notifications, lessThanOrEqualTo(2));
      expect(app.browserSurfaceActive, isTrue);
      expect(app.browserVisible, isTrue);

      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering route')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.browserSurfaceActive, isTrue);
      expect(app.browserVisible, isFalse);

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.browserSurfaceActive, isTrue);
      expect(app.browserVisible, isTrue);
      navigatorKey.currentState!.removeRoute(route);
      await tester.pump();
      expect(app.browserSurfaceActive, isTrue);
      expect(app.browserVisible, isTrue);
      app.removeListener(observed);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'first entry failure retries even before any tab metadata exists',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FailCreate(1));
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserScreen(
            app: app,
            site: Candidate(
              id: 0,
              url: Uri.parse('https://new.example/'),
              label: 'new',
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(app.browserTabs, isEmpty);
      await tester.tap(find.text('重新加载'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(app.activeBrowser!.loadedHost, isNotNull);
      expect(find.text('重新加载'), findsNothing);
      await tester.runAsync(app.shutdown);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
