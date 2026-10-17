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
    'URL-first reconnoitre reports region, ready selector and blocks',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        switch (request.uri.path) {
          case '/publish':
            request.response.write(
              '<!doctype html><html><head><title>闭环发布页</title></head><body>'
              '<section id="latest-addresses"><h2>最新地址</h2>'
              '<a href="http://127.0.0.1:$port/publish">本站</a>'
              '<a href="http://127.0.0.2:$port/site">入口一</a>'
              '<a href="http://127.0.0.3:$port/site">入口二</a>'
              '</section></body></html>',
            );
          case '/captcha':
            request.response.write(
              '<!doctype html><html><body><div class="g-recaptcha"></div></body></html>',
            );
          case '/login':
            request.response.write(
              '<!doctype html><html><body>'
              '<input type="password" style="width:200px;height:32px">'
              '</body></html>',
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
        addTearDown(controller.shutdown);
        app = controller;
        await reportCapabilitiesForTest(controller);

        // 1) A normal publishing page: region found + ready selector inferred.
        final result = await controller.recon('http://127.0.0.1:$port/publish');
        expect(result.challenge, isFalse);
        expect(result.interactionRequired, isFalse);
        expect(result.regionFound, isTrue);
        expect(
          result.links.map((u) => u.host),
          containsAll(['127.0.0.2', '127.0.0.3']),
        );
        expect(result.regionSelector, '@latest-addresses');
        // The user still confirms before anything is persisted.
        expect(await db.profiles(), isEmpty);
        expect(await db.profilePages(), isEmpty);

        // 2) Captcha and login pages are reported instead of guessed at.
        final captcha = await controller.recon(
          'http://127.0.0.1:$port/captcha',
        );
        expect(captcha.challenge, isTrue);
        expect(captcha.note, isNotNull);

        final login = await controller.recon('http://127.0.0.1:$port/login');
        expect(login.interactionRequired, isTrue);
      } finally {
        await app?.closeAllTabs();
        await tester.pumpWidget(const SizedBox());
        await server.close(force: true);
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
