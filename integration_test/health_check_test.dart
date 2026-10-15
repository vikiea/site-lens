import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/discovery/health_checker.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/domain/models.dart';
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
  testWidgets('manual survival check is HTTP-only and gated by conditions', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><html><body><main><h1>alive landing page</h1></main></body></html>',
      );
      await request.response.close();
    });
    final port = server.port;

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
      await controller.load();

      final id = await db.createProfile('存活站', readySelector: 'main');
      await db.addCandidate(
        Uri.parse('http://127.0.0.2:$port/site'),
        label: '落点',
        profileId: id,
      );
      await controller.load();

      // 1) Conditions not met -> skipped, and provably no HTTP request at all.
      final hostsBefore = controller.hosts.sessions.length;
      requests = 0;
      final skipped = await controller.runHealthCheckOnce(
        conditions: const HealthConditions(charging: false, wifi: true),
      );
      expect(skipped.outcome, HealthRunOutcome.skippedConditions);
      expect(requests, 0);
      expect(
        controller.hosts.sessions.length,
        hostsBefore,
        reason: 'a background check must never create a WebView host',
      );

      // 2) Conditions met -> it runs the HTTP-only probe against the landing.
      requests = 0;
      final ran = await controller.runHealthCheckOnce(
        conditions: const HealthConditions(charging: true, wifi: true),
      );
      expect(ran.outcome, HealthRunOutcome.ran);
      expect(requests, greaterThan(0));
      expect(
        controller.hosts.sessions.length,
        hostsBefore,
        reason: 'no renderer process may be started by the survival check',
      );
      final health = await db.profileHealth(id);
      expect(health.lastCheckedAt, isNotNull);
      expect(health.consecutiveFailures, 0);
      expect(health.state, ProfileHealthState.ok);
    } finally {
      await app?.closeAllTabs();
      await tester.pumpWidget(const SizedBox());
      await server.close(force: true);
      await app?.shutdown();
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
