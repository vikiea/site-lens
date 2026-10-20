import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const configured = String.fromEnvironment('SITE_LENS_TEST_SITES');
  final sites = configured
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty);
  for (final site in sites) {
    final uri = Uri.parse(site);
    testWidgets('configured entry loads in the app WebView: ${uri.host}', (
      tester,
    ) async {
      expect(uri.scheme, 'https');
      expect(uri.userInfo, isEmpty);
      expect(uri.query, isEmpty);
      expect(uri.fragment, isEmpty);
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db);
      try {
        await app.initialize();
        final tab = await app.openUrl(uri);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [browserRouteObserver],
            home: BrowserScreen(app: app, site: tab.site),
          ),
        );
        final timeout = DateTime.now().add(const Duration(seconds: 60));
        while (!tab.host.loaded &&
            tab.host.errorKind == null &&
            DateTime.now().isBefore(timeout)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tab.host.errorKind, isNull, reason: tab.host.error);
        expect(tab.host.loaded, isTrue);
        final snapshot = await app.hosts.api.inspect(tab.host.id, 'body');
        expect(snapshot.text.trim(), isNotEmpty);
        debugPrint(
          'CONFIGURED_ENTRY_PASS host=${uri.host} links=${snapshot.links.length}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
  if (sites.isEmpty) {
    test(
      'real sites require explicit local configuration',
      () {},
      skip: 'Set SITE_LENS_TEST_SITES in .env.local',
    );
  }
}
