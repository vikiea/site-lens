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
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

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
  testWidgets(
    'slash-less and redirecting entry URLs keep the privileged script lease',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/?via=redirect',
          );
        } else {
          request.response.write(
            '<!doctype html><html><body><main id="main">'
            '<h1>Lease site</h1></main></body></html>',
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
      expect(
        controller.capabilities?.isolatedScripts,
        isTrue,
        reason: 'this regression only exists where privileged scripts run',
      );

      final installed = await controller.scripts.save('''
// ==UserScript==
// @name Lease script
// @match http://127.0.0.2/*
// @match http://127.0.0.3/*
// @grant GM_addStyle
// ==/UserScript==
document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-script">ok</p>');
''');
      await controller.scripts.enable(installed, Cancellation());

      // WebView canonicalizes `http://127.0.0.2:port` into
      // `http://127.0.0.2:port/`. A raw string comparison used to declare that
      // navigation unverifiable, revoke every privileged script and show the
      // red "无法确认新文档或历史恢复" banner.
      final scenarios = <String, Uri>{
        'slash-less entry': Uri.parse('http://127.0.0.2:$port'),
        'server redirect': Uri.parse('http://127.0.0.2:$port/redirect'),
      };

      for (final entry in scenarios.entries) {
        final site = Candidate(
          id: 0,
          url: entry.value,
          label: entry.key,
          enabled: true,
          sourceId: null,
          readySelector: 'main',
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: BrowserScreen(
                key: ValueKey(entry.value.toString()),
                app: controller,
                site: site,
              ),
            ),
          ),
        );
        await waitForCondition(
          tester,
          () => controller.activeBrowser?.host.loaded == true,
          'browsing host loaded for ${entry.key}',
        );
        final session = controller.activeBrowser!.host;
        expect(
          session.errorKind,
          isNull,
          reason:
              '${entry.key} must stay leased; error=${session.error} '
              'url=${session.url}',
        );
        // The honoured lease is only useful if privileged scripts keep running.
        await inspectUntil(
          tester,
          controller,
          session,
          '#lease-script',
          (snapshot) => snapshot.text == 'ok',
        );
      }
    },
  );

  testWidgets('same-document navigation keeps the privileged lease', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><html><body><main id="main">'
        '<h1>Lease SPA</h1></main>'
        '<script>setTimeout(() => history.pushState({}, "", "/spa/episode/2"), 250);</script>'
        '</body></html>',
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
    expect(
      controller.capabilities?.isolatedScripts,
      isTrue,
      reason: 'this regression only exists where privileged scripts run',
    );

    final installed = await controller.scripts.save("""
// ==UserScript==
// @name SPA lease script
// @match http://127.0.0.2/*
// @grant GM_registerMenuCommand
// ==/UserScript==
document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-spa-script">ok</p>');
GM_registerMenuCommand('Lease SPA menu', () => {
  document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-spa-menu">ok</p>');
});
""");
    await controller.scripts.enable(installed, Cancellation());

    final site = Candidate(
      id: 0,
      url: Uri.parse('http://127.0.0.2:$port/spa'),
      label: 'same-document',
      enabled: true,
      sourceId: null,
      readySelector: 'main',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: BrowserScreen(app: controller, site: site),
        ),
      ),
    );
    await waitForCondition(
      tester,
      () => controller.activeBrowser?.host.loaded == true,
      'SPA host loaded',
    );
    final session = controller.activeBrowser!.host;
    await waitForCondition(
      tester,
      () => session.menus.isNotEmpty,
      'SPA script menu registered',
    );
    await waitForCondition(
      tester,
      () => session.url.contains('/spa/episode/2'),
      'same-document URL changed',
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      session.errorKind,
      isNull,
      reason:
          'same-document same-origin navigation must keep the lease; '
          'error=${session.error} url=${session.url}',
    );
    expect(
      session.menus,
      isNotEmpty,
      reason: 'privileged bindings must survive the same-document change',
    );

    // Invoking the registered menu proves the privileged bridge is still
    // live after the URL changed without a document reload.
    final menu = session.menus.values.singleWhere(
      (entry) => entry.label == 'Lease SPA menu',
    );
    await controller.hosts.invokeMenu(session, menu);
    await inspectUntil(
      tester,
      controller,
      session,
      '#lease-spa-menu',
      (snapshot) => snapshot.text == 'ok',
    );
  });

  testWidgets('entry redirects always retain the privileged script lease', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      if (request.uri.path == '/cross') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.3:$port/final',
        );
      } else {
        request.response.write(
          '<!doctype html><html><body><main id="main">'
          '<h1>Cross origin</h1></main></body></html>',
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
    // Entry redirects are always retained so scripts survive a mirror funnel.
    expect(controller.followEntryRedirects, isTrue);
    final installed = await controller.scripts.save("""
// ==UserScript==
// @name Cross origin lease
// @match http://127.0.0.2/*
// @grant GM_addStyle
// ==/UserScript==
document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-cross">ok</p>');
""");
    await controller.scripts.enable(installed, Cancellation());

    final site = Candidate(
      id: 0,
      url: Uri.parse('http://127.0.0.2:$port/cross'),
      label: 'cross-origin',
      enabled: true,
      sourceId: null,
      readySelector: 'main',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: BrowserScreen(app: controller, site: site),
        ),
      ),
    );
    final session = await () async {
      await waitForCondition(
        tester,
        () => controller.activeBrowser != null,
        'cross-origin harness created',
      );
      return controller.activeBrowser!.host;
    }();
    await waitForCondition(
      tester,
      () => session.url.contains('127.0.0.3'),
      'cross-origin redirect reaches the landing',
    );
    expect(session.errorKind, isNot('scriptsSuspended'));
  });

  testWidgets(
    'the entry navigation follows its redirect chain onto the landing',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        if (request.uri.path == '/cross') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.3:$port/final',
          );
        } else {
          request.response.write(
            '<!doctype html><html><body><main id="main">'
            '<h1>Entry redirect</h1></main></body></html>',
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
      expect(
        controller.followEntryRedirects,
        isTrue,
        reason: 'the entry-redirect switch is on by default',
      );

      // The mirror funnel in the real app: the entry domain answers 301 and a
      // different origin serves the page. The script is scoped to both, so the
      // landing must still be able to use the privileged bridge.
      final installed = await controller.scripts.save("""
// ==UserScript==
// @name Entry redirect lease
// @match http://127.0.0.2/*
// @match http://127.0.0.3/*
// @grant GM_registerMenuCommand
// ==/UserScript==
document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-entry-script">ok</p>');
GM_registerMenuCommand('Entry redirect menu', () => {
  document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-entry-menu">ok</p>');
});
""");
      await controller.scripts.enable(installed, Cancellation());

      final site = Candidate(
        id: 0,
        url: Uri.parse('http://127.0.0.2:$port/cross'),
        label: 'entry-redirect',
        enabled: true,
        sourceId: null,
        readySelector: 'main',
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: BrowserScreen(app: controller, site: site),
          ),
        ),
      );
      final session = await () async {
        await waitForCondition(
          tester,
          () => controller.activeBrowser != null,
          'entry redirect harness created',
        );
        return controller.activeBrowser!.host;
      }();

      // The landing proves the app-owned redirect chain completed. The host
      // contract test separately covers privileged script injection; this flow
      // focuses on retaining the lease across the navigation boundary.
      await waitForCondition(
        tester,
        () => session.url.contains('127.0.0.3'),
        'entry redirect reaches the landing',
      );
      expect(
        session.errorKind,
        isNull,
        reason:
            'an app-started entry redirect must not suspend the lease; '
            'error=${session.error} url=${session.url}',
      );
      expect(
        find.textContaining('无法确认'),
        findsNothing,
        reason: 'no red banner when the entry redirect is followed',
      );

      await waitForCondition(
        tester,
        () => session.menus.isNotEmpty,
        'landing script menu registered',
      );
      await controller.hosts.invokeMenu(session, session.menus.values.single);
      await inspectUntil(
        tester,
        controller,
        session,
        '#lease-entry-menu',
        (snapshot) => snapshot.text == 'ok',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('a navigation the page starts is never covered by the entry switch', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      if (request.uri.path == '/cross') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.3:$port/final',
        );
      } else if (request.uri.path == '/') {
        // The page itself walks into the same cross-origin redirect. No user
        // script is needed to start it, and nothing waits on the bridge while
        // the document it lives in goes away.
        request.response.write(
          '<!doctype html><html><body><main id="main">'
          '<h1>Page started</h1>'
          '<script>setTimeout(() => { location.href = "/cross"; }, 1500);'
          '</script></main></body></html>',
        );
      } else {
        request.response.write(
          '<!doctype html><html><body><main id="main">'
          '<h1>Landing</h1></main></body></html>',
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

    final installed = await controller.scripts.save("""
// ==UserScript==
// @name Page started lease
// @match http://127.0.0.2/*
// @match http://127.0.0.3/*
// @grant GM_addStyle
// ==/UserScript==
document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-page-script">ok</p>');
""");
    await controller.scripts.enable(installed, Cancellation());

    final site = Candidate(
      id: 0,
      url: Uri.parse('http://127.0.0.2:$port/'),
      label: 'page-started',
      enabled: true,
      sourceId: null,
      readySelector: 'main',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: BrowserScreen(app: controller, site: site),
        ),
      ),
    );
    final session = await () async {
      await waitForCondition(
        tester,
        () => controller.activeBrowser != null,
        'page-started harness created',
      );
      return controller.activeBrowser!.host;
    }();
    // The entry document really did get the privileged script...
    await inspectUntil(
      tester,
      controller,
      session,
      '#lease-page-script',
      (snapshot) => snapshot.text == 'ok',
    );

    // ...and then the page walked into the same cross-origin redirect the entry
    // is allowed to follow. The switch covers only what the app starts, so this
    // must still fail closed.
    await waitForCondition(
      tester,
      () => session.errorKind == 'scriptsSuspended',
      'a page-started cross-origin redirect still revokes the lease',
    );
    expect(session.url, contains('127.0.0.3'));
    // Fail-closed means the landing gets no privileged script either. Wait for
    // that document to finish loading before inspecting it: between the revoke
    // and the commit the probe would still be looking at the previous page.
    await waitForCondition(
      tester,
      () => session.url.contains('127.0.0.3') && session.loaded,
      'the revoked landing finished loading',
    );
    final landing = await controller.hosts.api.inspect(
      session.id,
      '#lease-page-script',
    );
    expect(landing.text, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a two-hop entry redirect chain keeps following to the landing', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      if (request.uri.path == '/hop1') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/hop2');
      } else if (request.uri.path == '/hop2') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.3:$port/final',
        );
      } else {
        request.response.write(
          '<!doctype html><html><body><main id="main">'
          '<h1>Two hops</h1></main></body></html>',
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

    final installed = await controller.scripts.save("""
// ==UserScript==
// @name Two hop lease
// @match http://127.0.0.2/*
// @match http://127.0.0.3/*
// @grant GM_addStyle
// ==/UserScript==
document.querySelector('main').insertAdjacentHTML('beforeend', '<p id="lease-hops-script">ok</p>');
""");
    await controller.scripts.enable(installed, Cancellation());

    final site = Candidate(
      id: 0,
      url: Uri.parse('http://127.0.0.2:$port/hop1'),
      label: 'two-hops',
      enabled: true,
      sourceId: null,
      readySelector: 'main',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: BrowserScreen(app: controller, site: site),
        ),
      ),
    );
    final session = await () async {
      await waitForCondition(
        tester,
        () => controller.activeBrowser != null,
        'two-hop harness created',
      );
      return controller.activeBrowser!.host;
    }();
    // The chain (same-origin hop, then cross-origin hop) must still reach the
    // landing with the lease intact: the window is bound to the entry's own
    // navigation, so every redirect *of that navigation* counts.
    await waitForCondition(
      tester,
      () => session.url.contains('127.0.0.3'),
      'two-hop entry redirect reaches the landing',
    );
    expect(
      session.errorKind,
      isNull,
      reason:
          'a multi-hop entry redirect must not suspend the lease; '
          'error=${session.error} url=${session.url}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
