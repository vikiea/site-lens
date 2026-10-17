import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';

Future<void> waitFor(WidgetTester tester, bool Function() ok, String label) async {
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (ok()) return;
  }
  fail('timed out: $label');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('hddj repro current', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db);
    try {
      await app.initialize();
      await app.updateSettings({'autoHideBrowserControls': false});
      final tab = await app.openUrl(Uri.parse('https://hddj.tv/dizhi/'));
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [browserRouteObserver],
        home: BrowserScreen(app: app, site: tab.site),
      ));
      await waitFor(tester, () => tab.host.loaded || tab.host.errorKind != null, 'hddj load');
      final snapshot = await app.hosts.api.inspect(tab.host.id, 'body');
      print('HDDJ_LOADED=${tab.host.loaded} ERROR=${tab.host.errorKind} URL=${tab.host.url}');
      print('HDDJ_TITLE=${snapshot.title}');
      print('HDDJ_LINKS=${jsonEncode(snapshot.links.take(80).toList())}');
      print('HDDJ_TEXT=${snapshot.text.substring(0, snapshot.text.length.clamp(0, 4000))}');
      await File('/tmp/site-lens-hddj-ready').writeAsString('host=${tab.host.id}\nurl=${tab.host.url}\n');
      await Future<void>.delayed(const Duration(seconds: 180));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      await db.close();
    }
  });
}
