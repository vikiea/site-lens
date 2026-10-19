import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
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
      await tester.runAsync(() => app.closeTab(app.activeBrowser!));
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
      await tester.runAsync(() => app.closeTab(app.browserTabs.first));
      expect(app.activeBrowser!.loadedHost, isNull);
      await tester.runAsync(app.shutdown);
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
