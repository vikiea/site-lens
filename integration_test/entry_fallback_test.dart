import 'native_test_support.dart';

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/web_host.g.dart';

Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition,
  String description, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 150));
    if (condition()) return;
  }
  fail('Timed out waiting for $description');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fast-path entry falls back to a detection round and keeps the failed tab',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        switch (request.uri.path) {
          case '/publish':
            request.response.write(
              '<!doctype html><html><body><section id="latest-addresses">'
              '<h2>最新地址</h2>'
              '<a href="http://127.0.0.2:$port/good">可用入口</a>'
              '</section></body></html>',
            );
          case '/good':
            request.response.write(
              '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
              '<style>main{display:block;width:320px;height:240px}</style></head>'
              '<body><main><h1>good landing page</h1></main></body></html>',
            );
          case '/bad':
            // Loads fine but never contains the configured ready selector.
            request.response.write(
              '<!doctype html><html><body><div id="empty">no main here</div></body></html>',
            );
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final db = AppDatabase(NativeDatabase.memory());
      AppController? app;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const SiteLensApp(),
          ),
        );
        await waitFor(
          tester,
          () => find.byTooltip('添加站点').evaluate().isNotEmpty,
          'home panel',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeScreen)),
        );
        final controller = container.read(appControllerProvider);
        app = controller;
        await reportCapabilitiesForTest(controller);
        await waitFor(
          tester,
          () => controller.capabilities != null,
          'native host capability report',
        );

        final profileId = await db.createProfile('回落站', readySelector: 'main');
        await db.addProfilePage(
          profileId,
          Uri.parse('http://127.0.0.1:$port/publish'),
          '@latest-addresses',
        );
        // Point the fast path at a landing that loads but is never "ready".
        await db.setProfileLastLanding(
          profileId,
          Uri.parse('http://127.0.0.2:$port/bad'),
        );
        await controller.load();
        final profile = controller.profiles.single;

        final session = await controller.enterProfile(profile);
        expect(session, isNotNull);
        expect(session!.site.url.path, '/bad');

        // The watcher should time out on /bad, run a round and open /good.
        try {
          await waitFor(
            tester,
            () => controller.browserTabs.any(
              (tab) => tab.site.url.path == '/good',
            ),
            'automatic fallback to a ready landing',
            timeout: const Duration(seconds: 45),
          );
        } catch (error) {
          debugPrint(
            'FALLBACK_FAIL tabs=${controller.browserTabs.map((t) => t.site.url).toList()} '
            'notice=${controller.probes.notice} error=${controller.error} '
            'profiles=${controller.profiles.length} '
            'pages=${controller.profilePages.map((p) => p.error).toList()} '
            'candidates=${controller.sites.map((c) => c.url).toList()} '
            'results=${controller.probes.results.values.map((r) => '${r.candidateId}:${r.status.name}:${r.finalUrl}:${r.reason}').toList()}',
          );
          rethrow;
        }

        final paths = controller.browserTabs
            .map((tab) => tab.site.url.path)
            .toSet();
        expect(paths, contains('/bad'), reason: 'failed tab must stay visible');
        expect(paths, contains('/good'));
        // Both tabs are real browsing hosts, not popups.
        expect(
          controller.hosts.sessions.values
              .where((h) => h.purpose == HostPurpose.browsing)
              .length,
          2,
        );
      } finally {
        await app?.closeAllTabs();
        await tester.pumpWidget(const SizedBox());
        await server.close(force: true);
        await app?.shutdown();
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
