import 'package:site_lens/web_host/web_host.g.dart';

import 'dart:async';

import 'package:site_lens/network/transport.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/browser_entry.dart';
import 'package:site_lens/web_host/native_hosts.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeWebHostApi api;
  late AppController app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    api = FakeWebHostApi();
    app = AppController(db, api: api);
    await app.load();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  test('opening another landing keeps the tab that is already open', () async {
    await app.openUrl(
      Uri.parse('https://a.example/'),
      label: 'a',
      profileId: 1,
    );
    expect(app.browserTabs, hasLength(1));
    final first = app.browserTabs.single;

    await app.openUrl(
      Uri.parse('https://b.example/'),
      label: 'b',
      profileId: 1,
    );

    // The older landing must survive: one profile is not limited to one tab.
    expect(app.browserTabs, hasLength(2));
    expect(app.browserTabs.first, same(first));
    expect(
      api.destroyed,
      isEmpty,
      reason: 'nothing may be destroyed implicitly',
    );
    expect(app.activeBrowser!.site.url, Uri.parse('https://b.example/'));

    // Re-opening the *same* URL reuses that tab instead of duplicating it.
    await app.openUrl(
      Uri.parse('https://a.example/'),
      label: 'a',
      profileId: 1,
    );
    expect(app.browserTabs, hasLength(2));
    expect(app.activeBrowser, same(first));
  });

  test('concurrent opens reserve the tab limit', () async {
    final futures = [
      for (var i = 0; i < AppController.maxBrowserTabs + 1; i++)
        app.openUrl(Uri.parse('https://parallel$i.example/')),
    ];
    await expectLater(Future.wait(futures), throwsA(isA<StateError>()));
    expect(app.browserTabs, hasLength(AppController.maxBrowserTabs));
  });

  test('same address concurrent opens share one host', () async {
    final tabs = await Future.wait(
      List.generate(3, (_) => app.openUrl(Uri.parse('https://same.example/'))),
    );
    expect(app.browserTabs, hasLength(1));
    expect(api.created, hasLength(1));
    expect(tabs.every((tab) => identical(tab, tabs.first)), isTrue);
  });

  test('close-all cancels a host while navigation is still pending', () async {
    final gated = _GatedApi();
    final controller = AppController(db, api: gated);
    addTearDown(controller.dispose);
    await controller.load();
    final opening = controller.openUrl(Uri.parse('https://delayed.example/'));
    final cancelled = expectLater(opening, throwsA(isA<StateError>()));
    await gated.entered.future;
    await controller.closeAllTabs();
    gated.release.complete();
    await cancelled;
    expect(controller.browserTabs, isEmpty);
    expect(gated.destroyed, hasLength(1));
  });

  test(
    'renderer invalidation preserves metadata and replaces the host on resume',
    () async {
      final tab = await app.openUrl(Uri.parse('https://recover.example/'));
      final old = tab.host;
      await app.hosts.onEvent(
        HostEvent(
          hostId: old.id,
          generation: old.generation,
          kind: 'hostInvalidated',
          url: 'https://recover.example/',
          detail: 'renderer exited',
        ),
      );
      expect(old.disposed, isTrue);
      expect(app.hosts.sessions.containsKey(old.id), isFalse);
      expect(app.browserTabs, contains(tab));
      expect(api.destroyed, contains(old.id));
      await app.activateTab(tab);
      expect(tab.host.disposed, isFalse);
      expect(tab.host.id, isNot(old.id));
      expect(app.browserTabs, hasLength(1));
    },
  );

  test('the tab strip still refuses to grow past its bound', () async {
    for (var i = 0; i < AppController.maxBrowserTabs; i++) {
      await app.openUrl(Uri.parse('https://site$i.example/'));
    }
    expect(app.browserTabs, hasLength(AppController.maxBrowserTabs));
    await expectLater(
      app.openUrl(Uri.parse('https://one-too-many.example/')),
      throwsA(isA<StateError>()),
    );
    expect(app.browserTabs, hasLength(AppController.maxBrowserTabs));
  });

  testWidgets('新建标签页 accepts an address without a scheme', (tester) async {
    // Only the dialog + typed-input path is under test here: the recording
    // controller keeps real host creation (and its asset IO) out of the
    // widget-test zone, where such a future never completes.
    final recording = _RecordingApp(db);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => promptNewTab(context, recording),
              child: const Text('新建'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'example.com/watch?v=1');
    await tester.tap(find.widgetWithText(FilledButton, '打开'));
    await tester.pumpAndSettle();

    expect(recording.opened, Uri.parse('https://example.com/watch?v=1'));
    // The prompt must not outlive its field: disposing the controller while the
    // dialog is still animating out is what this catches.
    expect(tester.takeException(), isNull);
  });

  group('the browser sheet can explain an empty 生效脚本 row', () {
    Future<ActiveBrowserSession> openTab() async {
      final tab = await app.openUrl(Uri.parse('https://mirror.example/'));
      return tab;
    }

    test('names the global switch first', () async {
      await app.openUrl(Uri.parse('https://mirror.example/'));
      await app.disableAllScripts(true);
      final session = app.browserTabs.single;
      expect(app.scriptActivityReason(session), contains('全局「关闭全部脚本」已打开'));
    });

    test('says when nothing is imported', () async {
      final session = await openTab();
      expect(app.scriptActivityReason(session), contains('还没有导入任何脚本'));
    });

    test(
      'says when a script is enabled but the host has none registered',
      () async {
        // Enabled without an approval digest: registration refuses it (and logs
        // why), which is the case that used to look like "no script matches".
        await db.saveScript(
          const InstalledScript(id: 's1', name: 'S', source: '// v1'),
        );
        await db.setScriptEnabled('s1', true);
        await app.load();
        final session = await openTab();
        expect(session.host.registered, isEmpty);
        expect(app.scriptActivityReason(session), contains('宿主里没有已注册脚本'));
      },
    );

    test('names the scripts whose @match does not cover the address', () async {
      // Registered by hand: approving a script writes its source through
      // path_provider, which a pure unit test has no implementation for, and
      // this branch only needs "the host holds an enabled script".
      await db.saveScript(
        const InstalledScript(
          id: 's1',
          name: 'Other domain only',
          source:
              '// ==UserScript==\n// @name Other domain only\n'
              '// @match https://other.example/*\n// @grant GM_addStyle\n'
              '// ==/UserScript==\n',
        ),
      );
      await db.setScriptEnabled('s1', true);
      await app.load();
      final session = await openTab();
      // The native side reports the document URL through an event; the fake API
      // has no events, so the test stands in for it.
      session.host.url = 'https://mirror.example/';
      session.host.registered['s1'] = 'rev';
      final reason = app.scriptActivityReason(session);
      expect(reason, contains('Other domain only'));
      expect(reason, contains('@match'));
      expect(reason, contains('https://mirror.example/'));
    });
  });

  test('the floating controls start bottom-centre and can be moved anywhere', () async {
    expect(app.browserControlsFraction, const Offset(0.5, 1));

    await app.setBrowserControlsFraction(const Offset(0.2, 0.35));
    expect(app.browserControlsFraction, const Offset(0.2, 0.35));

    // Clamped into the viewport fraction space, so a wild drag cannot park the
    // controls off-screen.
    await app.setBrowserControlsFraction(const Offset(-3, 9));
    expect(app.browserControlsFraction, const Offset(0, 1));

    // Persisted, and read back by the next load (a fresh session keeps it).
    await app.setBrowserControlsFraction(const Offset(0.1, 0.9));
    app.browserControlsFraction = const Offset(0.5, 1);
    await app.load();
    expect(app.browserControlsFraction, const Offset(0.1, 0.9));
  });

  test('typed addresses may omit the scheme', () {
    expect(userUri('example.com/x').toString(), 'https://example.com/x');
    expect(userUri(' example.com/x ').toString(), 'https://example.com/x');
    expect(userUri('example.com:8443/x').port, 8443);
    // An explicit scheme is respected, not silently upgraded.
    expect(userUri('http://example.com/x').toString(), 'http://example.com/x');
    expect(() => userUri('ftp://example.com/'), throwsFormatException);
    expect(() => userUri('user:pw@example.com'), throwsFormatException);
    expect(() => userUri('   '), throwsFormatException);
  });
}

/// Records what a typed address turns into without touching native hosts.
class _RecordingApp extends AppController {
  _RecordingApp(super.db);
  Uri? opened;

  @override
  Future<ActiveBrowserSession> openUrl(
    Uri url, {
    String? label,
    int? profileId,
    Candidate? candidate,
    Cancellation? cancelToken,
  }) async {
    opened = url;
    return ActiveBrowserSession(
      Candidate(id: 0, url: url, label: label ?? url.host, enabled: true),
      HostSession(
        99,
        HostPurpose.browsing,
        HostCapabilities(
          platform: 'test',
          isolatedScripts: true,
          documentStart: true,
          privateProbes: true,
          reason: '',
        ),
      ),
    );
  }
}

class _GatedApi extends FakeWebHostApi {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> navigate(int hostId, String url) async {
    entered.complete();
    await release.future;
    await super.navigate(hostId, url);
  }
}
