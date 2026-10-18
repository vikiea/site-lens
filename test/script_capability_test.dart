import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';

import 'fake_web_host_api.dart';

const _script =
    '// ==UserScript==\n'
    '// @name Preflight\n'
    '// @match https://example.com/*\n'
    '// ==/UserScript==\n'
    'console.log("preflight");\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeWebHostApi api;
  late AppController app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    api = FakeWebHostApi();
    app = AppController(db, api: api);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  testWidgets(
    'enabling a script checks host capabilities when no browser tab exists',
    (tester) async {
      var result = false;
      final script = const InstalledScript(
        id: 'preflight',
        name: 'Preflight',
        source: _script,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await confirmScript(context, app, script);
              },
              child: const Text('启用'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();

      expect(api.created, [1]);
      expect(api.destroyed, [1]);
      expect(find.text('确认启用 Preflight'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    },
  );
}
