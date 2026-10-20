import 'native_test_support.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';

// Harness bound, not a product assertion: bringing up the platform WebView on
// a cold emulator can take tens of seconds, which used to surface as a random
// "host loaded" timeout. It still fails when the page genuinely never loads.
Future<void> waitForCondition(
  WidgetTester tester,
  bool Function() condition,
  String description, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail('Timed out waiting for $description');
}

Future<void> waitDuration(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'another landing is a new tab and the script menu explains itself',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><body style="margin:0"><main id="main">'
          '<h1>${request.uri.path}</h1></main></body></html>',
        );
        await request.response.close();
      });

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(appControllerProvider);
      addTearDown(controller.shutdown);
      await controller.initialize();
      await reportCapabilitiesForTest(controller);

      final installed = await controller.scripts.save("""
// ==UserScript==
// @name Menu owner
// @match http://127.0.0.2/*
// @grant GM_registerMenuCommand
// ==/UserScript==
GM_registerMenuCommand('菜单条目', () => {});
""");
      await controller.scripts.enable(installed, Cancellation());
      // Enabling writes through ScriptService; the panel-facing list is a
      // separate snapshot, exactly as the scripts page refreshes it.
      await controller.load();
      expect(controller.installed, hasLength(1));

      Candidate landing(String path) => Candidate(
        id: 0,
        url: Uri.parse('http://127.0.0.2:$port$path'),
        label: path,
        enabled: true,
        sourceId: null,
        readySelector: 'main',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: BrowserScreen(app: controller, site: landing('/a')),
          ),
        ),
      );
      await waitForCondition(
        tester,
        () => controller.activeBrowser?.host.loaded == true,
        'first landing loaded',
      );
      final firstTab = controller.browserTabs.single;

      // Exactly what the profile panel does when the user picks another mirror:
      // the landing you were reading must survive as its own tab.
      await controller.openBrowser(landing('/b'));
      expect(controller.browserTabs, hasLength(2));
      expect(controller.browserTabs.first, same(firstTab));
      expect(
        firstTab.host.disposed,
        isFalse,
        reason: 'switching mirrors must not destroy the previous tab',
      );
      await waitForCondition(
        tester,
        () =>
            controller.activeBrowser?.host.loaded == true &&
            controller.activeBrowser!.site.url.path == '/b',
        'second landing loaded',
      );

      // Switching back needs no reload: the first document is still alive.
      await controller.activateTab(firstTab);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.activeBrowser!.host.url, contains('/a'));

      // The "代码" button lists registered menus and, when there are none, says
      // why: which scripts actually apply to this document.
      // The toolbar itself, so "a drag must not open it" has something that
      // actually appears when it opens.
      final menuButton = find.byKey(const ValueKey('browser-navigation'));
      await waitForCondition(
        tester,
        () => controller.activeBrowser!.host.menus.isNotEmpty,
        'registered menu arrived from the script',
      );
      await waitForCondition(
        tester,
        () => controller.activeBrowser!.host.url.contains('/a'),
        'first landing is the active document again',
      );
      // Reveal the bar through the always-visible handle: it is a plain Flutter
      // widget, unlike a page tap whose gesture has to cross the platform view
      // (that path is covered by the auto-hide test).
      final handle = find.byIcon(Icons.keyboard_arrow_up);
      await waitForCondition(
        tester,
        () => handle.evaluate().isNotEmpty,
        'navigation handle',
      );
      // The floating controls start bottom-centre and the user can drag them
      // anywhere: pages (and the scripts running in them) commonly own the
      // bottom edge, and only the user knows where they must not overlap.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final startRect = tester.getRect(handle);
      expect(
        (startRect.center.dx - screen.width / 2).abs(),
        lessThan(screen.width * 0.15),
        reason: 'the handle starts in the middle',
      );
      expect(
        startRect.bottom,
        greaterThan(screen.height * 0.8),
        reason: 'the handle starts at the bottom',
      );
      expect(
        controller.browserControlsFraction,
        const Offset(0.5, 1),
        reason: 'default position',
      );

      // Drag it to the upper-left of the page: it must move, must not open the
      // bar on the way, and must remember where it was left.
      final drag = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 400));
      await drag.moveBy(const Offset(-120, -260));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        menuButton.evaluate(),
        isEmpty,
        reason: 'a drag is not a tap: it must not open the bar',
      );
      final movedRect = tester.getRect(find.byIcon(Icons.keyboard_arrow_up));
      expect(
        movedRect.center.dx,
        lessThan(startRect.center.dx - 80),
        reason: 'the handle followed the drag horizontally',
      );
      expect(
        movedRect.center.dy,
        lessThan(startRect.center.dy - 180),
        reason: 'the handle followed the drag vertically',
      );
      expect(controller.browserControlsFraction.dx, lessThan(0.4));
      expect(controller.browserControlsFraction.dy, lessThan(0.8));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await waitForCondition(
        tester,
        () =>
            menuButton.evaluate().isNotEmpty ||
            find.byTooltip(browserMoreTooltip).evaluate().isNotEmpty,
        'navigation bar with the script menu or more button',
      );
      // The toolbar is pinned: it opens along the bottom edge regardless of
      // where the handle was dragged to, in one fixed row of seven controls.
      final navRect = tester.getRect(
        find.byKey(const ValueKey('browser-navigation')),
      );
      expect(
        (navRect.center.dx - screen.width / 2).abs(),
        lessThan(screen.width * 0.1),
        reason: 'the toolbar is fixed to the bottom centre',
      );
      expect(
        navRect.bottom,
        greaterThan(screen.height * 0.85),
        reason: 'the toolbar sits on the bottom edge',
      );
      expect(
        find.byTooltip(browserExitTooltip),
        findsOneWidget,
        reason: 'exit is one of the seven fixed controls',
      );
      // Only three occasional or destructive actions stay in 更多.
      final collapsed = await openBrowserMoreIfNeeded(
        tester,
        browserScriptsTooltip,
      );
      expect(collapsed, isTrue, reason: 'these actions live in 更多 now');
      expect(find.text(browserNewTabTooltip), findsOneWidget);
      expect(find.text(browserScriptsTooltip), findsOneWidget);
      expect(find.text(browserCloseTabTooltip), findsOneWidget);
      expect(find.text(browserExitTooltip), findsNothing);
      await tester.tap(find.text(browserScriptsTooltip));
      await tester.pumpAndSettle();
      expect(find.text('当前文档脚本菜单'), findsOneWidget);
      expect(find.text('菜单条目'), findsOneWidget);
      expect(find.text('本次文档生效脚本'), findsOneWidget);
      expect(find.textContaining('Menu owner'), findsWidgets);
      expect(find.text('重新加载脚本并刷新页面'), findsOneWidget);

      // Hand the single test process over clean: unmount the screens (closing
      // the sheet) and destroy every WebView, so a late platform event cannot
      // be attributed to the next test.
      await tester.pumpWidget(const SizedBox());
      await controller.closeAllTabs();
      expect(controller.browserTabs, isEmpty);
    },
  );

  testWidgets('target=_blank and window.open become closed-loop app tabs', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      switch (request.uri.path) {
        case '/second':
        case '/third':
          request.response.write(
            '<!doctype html><html><body><main id="main">'
            '<h1>${request.uri.path}</h1></main></body></html>',
          );
        default:
          request.response.write(
            '<!doctype html><html><body style="margin:0">'
            '<a id="blank" href="/second" target="_blank" '
            'style="display:block;height:260px;background:#123;color:#fff">blank link</a>'
            '<button id="popup" style="display:block;width:100%;height:260px;font-size:24px" '
            'onclick="window.open(\'/third\', \'_blank\')">window.open</button>'
            '<main id="main">root</main></body></html>',
          );
      }
      await request.response.close();
    });

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final controller = container.read(appControllerProvider);
    addTearDown(controller.shutdown);
    await controller.initialize();
    await reportCapabilitiesForTest(controller);

    final root = Candidate(
      id: 0,
      url: Uri.parse('http://127.0.0.2:$port/'),
      label: 'root',
      enabled: true,
      sourceId: null,
      readySelector: 'main',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: BrowserScreen(app: controller, site: root),
        ),
      ),
    );
    await waitForCondition(
      tester,
      () => controller.activeBrowser?.host.loaded == true,
      'root tab loaded',
    );
    expect(controller.browserTabs.length, 1);

    final view = find.byType(AndroidView);
    final origin = tester.getTopLeft(view);

    // A real gesture is required: WebView refuses scripted popups.
    await tester.tapAt(origin + const Offset(60, 80));
    await waitForCondition(
      tester,
      () => controller.browserTabs.length == 2,
      'target=_blank link opened a tab',
    );
    expect(controller.activeBrowser!.site.url.path, '/second');

    await controller.activateTab(controller.browserTabs.first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(origin + const Offset(60, 380));
    await waitForCondition(
      tester,
      () => controller.browserTabs.length == 3,
      'window.open opened a tab',
    );
    expect(controller.activeBrowser!.site.url.path, '/third');

    // Closing a background tab keeps the active one; closing the last tab
    // would return to the home screen.
    final closed = controller.browserTabs[1];
    expect(await controller.closeTab(closed), isTrue);
    expect(controller.browserTabs.length, 2);
    expect(controller.activeBrowser!.site.url.path, '/third');
    expect(closed.host.disposed, isTrue);

    // The tab switcher lives on the navigation bar (it must not take its own
    // row) and opens a grid of tab cards. The dedicated floating handle is the
    // only opener; page taps belong to the WebView.
    final tabButton = find.byTooltip('标签页（缩略图选择）');
    Future<void> revealNavigation() async {
      if (tabButton.evaluate().isNotEmpty) return;
      final handle = find.byIcon(Icons.keyboard_arrow_up);
      await waitForCondition(
        tester,
        () => handle.evaluate().isNotEmpty,
        'navigation handle',
      );
      await tester.tap(handle);
      await waitForCondition(
        tester,
        () => tabButton.evaluate().isNotEmpty,
        'tab button visible after handle tap',
      );
    }

    await revealNavigation();
    expect(tabButton, findsOneWidget);
    await tester.tap(tabButton);
    await tester.pumpAndSettle();
    expect(find.text('标签页 2/8'), findsOneWidget);
    await tester.tap(find.text('127.0.0.2/').last);
    await tester.pumpAndSettle();
    expect(controller.activeBrowser!.site.url.path, '/');
  });

  testWidgets(
    'bar touches extend auto-hide; page touches do not; pull refreshes',
    (tester) async {
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path != '/') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        requests++;
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        request.response.write(
          '<!doctype html><html><body><main id="main">reload-$requests</main></body></html>',
        );
        await request.response.close();
      });

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(appControllerProvider);
      addTearDown(controller.shutdown);
      await controller.initialize();
      await reportCapabilitiesForTest(controller);

      final root = Candidate(
        id: 0,
        url: Uri.parse('http://127.0.0.2:$port/'),
        label: 'timer-root',
        enabled: true,
        sourceId: null,
        readySelector: 'main',
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: BrowserScreen(app: controller, site: root),
          ),
        ),
      );
      await waitForCondition(
        tester,
        () => controller.activeBrowser?.host.loaded == true,
        'timer root loaded',
      );

      final nav = find.byKey(const ValueKey('browser-navigation'));
      final page = find.byType(AndroidView);
      await waitForCondition(
        tester,
        () => nav.evaluate().isEmpty,
        'initial navigation bar auto-hides',
        timeout: const Duration(seconds: 8),
      );

      // Establish a known reveal instant via the dedicated handle, then touch
      // the page again at 2s. The original 3s deadline must still hide the bar.
      final handle = find.byIcon(Icons.keyboard_arrow_up);
      await waitForCondition(
        tester,
        () => handle.evaluate().isNotEmpty,
        'navigation handle',
      );
      await tester.tap(handle);
      await waitForCondition(
        tester,
        () => nav.evaluate().isNotEmpty,
        'handle reveals hidden navigation',
      );
      await waitDuration(tester, const Duration(seconds: 2));
      await tester.tapAt(tester.getCenter(page));
      await waitDuration(tester, const Duration(seconds: 2));
      expect(
        nav,
        findsNothing,
        reason: 'page touches must not restart the hide countdown',
      );

      // Touch the bar at 2s; this must restart the timer, so it remains visible
      // after the original 3s deadline. The pointer goes down on the bar and
      // then leaves it: a plain tap on a cell would run that control (the bar
      // has no padding of its own any more, every cell is the tap target).
      await waitForCondition(
        tester,
        () => handle.evaluate().isNotEmpty,
        'navigation handle for bar-touch check',
      );
      await tester.tap(handle);
      await waitForCondition(
        tester,
        () => nav.evaluate().isNotEmpty,
        'handle reveals navigation for bar-touch check',
      );
      await waitDuration(tester, const Duration(seconds: 2));
      final rect = tester.getRect(nav);
      final touch = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 50));
      await touch.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 50));
      await touch.up();
      await waitDuration(tester, const Duration(seconds: 2));
      expect(
        nav,
        findsOneWidget,
        reason: 'a touch inside the bar must restart the hide countdown',
      );
      await waitForCondition(
        tester,
        () => nav.evaluate().isEmpty,
        'navigation bar hides after the reset deadline',
        timeout: const Duration(seconds: 6),
      );

      // Pull-to-refresh is a WebView gesture outside the bar, and it is off by
      // default (the page owns the gesture): the user has to ask for it first.
      final before = requests;
      await controller.setPullToRefresh(true);
      await tester.drag(find.byType(AndroidView), const Offset(0, 280));
      await waitForCondition(
        tester,
        () => requests > before,
        'pull-to-refresh reloads the document',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        controller.activeBrowser!.host.errorKind,
        isNull,
        reason: 'pull-to-refresh must prepare a new lease before reloading',
      );

      // The gesture is optional: with the switch off it belongs to the page and
      // to the scripts running in it, so the very same drag must not reload
      // anything.
      await controller.setPullToRefresh(false);
      final paused = requests;
      await tester.drag(find.byType(AndroidView), const Offset(0, 280));
      await waitDuration(tester, const Duration(seconds: 3));
      expect(
        requests,
        paused,
        reason: 'the app must not own the pull gesture while the switch is off',
      );

      // And it comes back without recreating the host or the tab.
      await controller.setPullToRefresh(true);
      await tester.drag(find.byType(AndroidView), const Offset(0, 280));
      await waitForCondition(
        tester,
        () => requests > paused,
        'pull-to-refresh applies again after the switch is turned back on',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
