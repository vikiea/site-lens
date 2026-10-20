import 'native_test_support.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for ${finder.toString()}');
}

Future<void> waitForCondition(
  WidgetTester tester,
  bool Function() condition,
  String description, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail('Timed out waiting for $description');
}

Future<PageSnapshot> inspectUntil(
  WidgetTester tester,
  AppController app,
  HostSession host,
  String selector,
  bool Function(PageSnapshot) accepts, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  PageSnapshot? last;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    try {
      last = await app.hosts.api
          .inspect(host.id, selector)
          .timeout(const Duration(seconds: 2));
      if (accepts(last)) return last;
    } catch (_) {}
  }
  fail('Timed out waiting for $selector; last=${last?.text}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android product flow: source, recommendation, browser and scripts', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      switch (request.uri.path) {
        case '/publish':
          request.response.write(
            '<!doctype html><html><body><section id="latest-addresses">'
            '<h2>最新地址</h2>'
            '<a href="http://127.0.0.2:$port/site">可用入口</a>'
            '</section></body></html>',
          );
        case '/site':
          request.response.write(
            '<!doctype html><html><body><main><h1>Android flow site</h1></main></body></html>',
          );
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final db = AppDatabase(NativeDatabase.memory());
    AppController? app;
    HostSession? browser;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const SiteLensApp(),
        ),
      );
      await pumpUntil(tester, find.byTooltip('添加站点'));
      expect(find.widgetWithText(FilledButton, '添加站点'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      final controller = container.read(appControllerProvider);
      app = controller;
      await reportCapabilitiesForTest(controller);
      await waitForCondition(
        tester,
        () => controller.capabilities != null,
        'native host capability report',
      );
      expect(controller.capabilities!.privateProbes, isTrue);
      expect(controller.capabilities!.documentStart, isTrue);

      // Default entry: paste a URL, let the app reconnoitre, then confirm.
      await tester.tap(find.byTooltip('添加站点'));
      await pumpUntil(tester, find.text('添加站点档案'));
      await tester.enterText(
        find.byType(TextField).first,
        'http://127.0.0.1:$port/publish',
      );
      await tester.tap(find.widgetWithText(FilledButton, '开始侦察'));
      await pumpUntil(tester, find.textContaining('侦察结果'));
      // The recon report must have found the latest-addresses region.
      expect(find.textContaining('最新地址区域：命中'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), '闭环站点');
      await tester.tap(find.widgetWithText(FilledButton, '创建档案'));
      // Let the dialog tear down so its EditableText no longer matches.
      await tester.pumpAndSettle();
      await pumpUntil(tester, find.text('闭环站点'));

      // Open the profile and run a round of discovery + verification.
      await tester.tap(find.text('闭环站点').first);
      await pumpUntil(tester, find.widgetWithText(FilledButton, '检测'));
      await tester.tap(find.widgetWithText(FilledButton, '检测'));
      try {
        await waitForCondition(
          tester,
          () =>
              !controller.refreshing &&
              !controller.probes.running &&
              controller.probes.recommendations.isNotEmpty,
          'completed discovery with a verified landing',
          timeout: const Duration(seconds: 35),
        );
      } catch (error) {
        debugPrint(
          'FLOW_FAIL error=${controller.error} notice=${controller.probes.notice} '
          'running=${controller.probes.running} results=${controller.probes.results.length}',
        );
        rethrow;
      }
      expect((await db.candidates()).single.url.host, '127.0.0.2');
      expect((await db.profilePages()).single.error, isNull);
      expect(controller.probes.recommendations.single.verified, isTrue);
      await pumpUntil(tester, find.widgetWithText(FilledButton, '进入站点'));

      await tester.tap(find.widgetWithText(FilledButton, '进入站点'));
      await waitForCondition(
        tester,
        () => controller.hosts.sessions.values
            .where(
              (session) =>
                  session.purpose == HostPurpose.browsing && session.loaded,
            )
            .isNotEmpty,
        'browsing host loaded',
        timeout: const Duration(seconds: 20),
      );
      browser = controller.hosts.sessions.values.firstWhere(
        (session) => session.purpose == HostPurpose.browsing && session.loaded,
      );
      final initial = await inspectUntil(
        tester,
        app,
        browser,
        'main',
        (snapshot) => snapshot.ready,
      );
      expect(initial.text, contains('Android flow site'));
      final nativeView = find.byType(AndroidView);
      expect(nativeView, findsOneWidget);
      // Browser page gestures never reveal the toolbar. Use the dedicated
      // floating handle, which is the only opener in the product contract.
      final handle = find.byIcon(Icons.keyboard_arrow_up);
      await waitForCondition(
        tester,
        () => handle.evaluate().isNotEmpty,
        'navigation handle',
      );
      await tester.tap(handle);
      await waitForBrowserActionOrMore(tester, browserBackTooltip);
      expect(find.byTooltip('前进'), findsOneWidget);
      // Exit is one of the seven fixed toolbar controls; 更多 holds the rest.
      expect(find.byTooltip(browserExitTooltip), findsOneWidget);
      expect(find.byTooltip(browserMoreTooltip), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byTooltip('后退'), findsNothing);

      if (controller.capabilities!.isolatedScripts) {
        final largePadding = '// ${'x' * (600 * 1024)}\n';
        final installed = await controller.scripts.save('''
  // ==UserScript==
  // @name Android flow script
  // @match http://127.0.0.2/*
  // @run-at document-end
	        // @grant GM_addStyle
	        // @grant GM_registerMenuCommand
	        // @grant GM_info
	        // @grant GM_setClipboard
	        // @grant GM.setClipboard
	        // @grant GM.setValue
	        // @grant GM_addValueChangeListener
	        // ==/UserScript==
	        $largePadding
	        document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="flow-script">script-ready</p>');
	        document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="flow-info"></p><p id="flow-clipboard"></p><p id="flow-change"></p>');
	        document.querySelector('#flow-info').textContent = GM_info.script.name;
	        GM_addValueChangeListener('flow-key', (key, oldValue, newValue) => {
	          document.querySelector('#flow-change').textContent = key + ':' + newValue;
	        });
	        GM.setValue('flow-key', 'next');
	        GM.setClipboard('copied').then(() => {
	          document.querySelector('#flow-clipboard').textContent = 'copied';
	        });
	        GM_addStyle('#flow-script { color: lime; }');
          GM_registerMenuCommand('Flow menu', () => {
            document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="flow-menu">menu-clicked</p>');
          });
          ''');
        await controller.scripts.enable(installed, Cancellation());
        await controller.load();
        await controller.hosts.configure(browser);
        await controller.hosts.api.reload(browser.id);
        await inspectUntil(
          tester,
          app,
          browser,
          '#flow-script',
          (snapshot) => snapshot.text == 'script-ready',
        );
        await inspectUntil(
          tester,
          app,
          browser,
          '#flow-info',
          (snapshot) => snapshot.text == 'Android flow script',
        );
        await inspectUntil(
          tester,
          app,
          browser,
          '#flow-clipboard',
          (snapshot) => snapshot.text == 'copied',
        );
        await inspectUntil(
          tester,
          app,
          browser,
          '#flow-change',
          (snapshot) => snapshot.text == 'flow-key:next',
        );
        await waitForCondition(
          tester,
          () => browser!.menus.values.any((menu) => menu.label == 'Flow menu'),
          'user script menu registration',
        );
        final menu = browser.menus.values.singleWhere(
          (entry) => entry.label == 'Flow menu',
        );
        await controller.hosts.invokeMenu(browser, menu);
        await inspectUntil(
          tester,
          app,
          browser,
          '#flow-menu',
          (snapshot) => snapshot.text == 'menu-clicked',
        );

        await controller.disableAllScripts(true);
        await waitForCondition(
          tester,
          () => browser!.menus.isEmpty,
          'script menu cleanup after global disable',
        );
        final clean = await inspectUntil(
          tester,
          app,
          browser,
          '#flow-script',
          (snapshot) => snapshot.text.isEmpty,
        );
        expect(clean.text, isEmpty);
      } else {
        debugPrint(
          'FLOW_SCRIPT_FAIL_CLOSED ${controller.capabilities!.platform}: ${controller.capabilities!.reason}',
        );
      }
      final exitHandle = find.byIcon(Icons.keyboard_arrow_up);
      await waitForCondition(
        tester,
        () => exitHandle.evaluate().isNotEmpty,
        'navigation handle for exit',
      );
      await tester.tap(exitHandle);
      await waitForBrowserActionOrMore(tester, browserExitTooltip);
      await tapBrowserAction(tester, browserExitTooltip);
      // Exiting the browser returns to the profile detail; go back to the panel.
      await pumpUntil(tester, find.widgetWithText(FilledButton, '检测'));
      await tester.pageBack();
      // Both the site panel and the profile detail carry a "切回" float; wait
      // for the detail route to finish popping before tapping a single one.
      await tester.pumpAndSettle();
      await pumpUntil(tester, find.textContaining('切回 闭环站点'));
      // Exactly one quick-entry float must remain once the detail route is
      // gone; assert that instead of silently tapping `.first`.
      expect(find.textContaining('切回 闭环站点'), findsOneWidget);
      await tester.tap(find.textContaining('切回 闭环站点'));
      await pumpUntil(tester, find.byType(AndroidView));
      expect(controller.activeBrowser, isNotNull);
    } finally {
      if (browser != null) await app?.hosts.destroy(browser);
      await tester.pumpWidget(const SizedBox());
      await server.close(force: true);
      await app?.shutdown();
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
