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
              '<main><header><h1>闭环站点最新地址</h1></header>'
              '<section><h2>官方地址列表</h2>'
              '<a href="/publish">发布页</a>'
              '<a href="/hop?to=http%3A%2F%2F127.0.0.2%3A$port%2Fsite">入口一</a>'
              '<a href="/hop?to=http%3A%2F%2F127.0.0.3%3A$port%2Fsite">入口二</a>'
              '<a href="https://docs.example/guide">使用文档</a>'
              '<a href="https://social.example/">社区</a>'
              '</section></main></body></html>',
            );
          case '/captcha':
            request.response.write(
              '<!doctype html><html><body><div class="g-recaptcha"></div></body></html>',
            );
          case '/plain':
            request.response.write(
              '<!doctype html><html><body><div id="main">'
              '<h4>最新地址</h4><ul>'
              '<li><a href="https://mirror.example/">https://mirror.example/</a></li>'
              '<li><a href="https://docs.example/guide">使用文档</a></li>'
              '</ul></div></body></html>',
            );
          case '/legacy':
            request.response.write(
              '<!doctype html><html><body><main>'
              '<h1>地址发布页回家看看</h1>'
              '<div class="content"><a href="https://legacy.example/">立即进入</a>'
              '<a href="https://docs.example/guide">文档</a></div>'
              '</main></body></html>',
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

        final plain = await controller.recon('http://127.0.0.1:$port/plain');
        expect(plain.regionFound, isTrue);
        expect(plain.links.map((u) => u.host), ['mirror.example']);

        final legacy = await controller.recon('http://127.0.0.1:$port/legacy');
        expect(legacy.regionFound, isTrue);
        expect(legacy.links.map((u) => u.host), ['legacy.example']);

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
