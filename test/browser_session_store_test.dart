import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';

void main() {
  late AppDatabase db;
  late BrowserSessionStore sessions;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = BrowserSessionStore(db);
  });
  tearDown(() => db.close());

  test(
    'stores entry and current addresses separately, with no host state',
    () async {
      await sessions.save([
        SavedBrowserTab(
          id: 'tab_a',
          initialUrl: Uri.parse('https://entry.example/'),
          currentUrl: Uri.parse('https://read.example/chapter#page'),
          title: '阅读',
          profileId: 2,
          selectorOverride: 'article',
        ),
      ], 'tab_a');
      final saved = await sessions.read();
      expect(saved.activeId, 'tab_a');
      expect(saved.tabs.single.initialUrl.host, 'entry.example');
      expect(saved.tabs.single.currentUrl.fragment, 'page');
      expect(saved.tabs.single.selectorOverride, 'article');
      final json =
          jsonDecode((await db.setting(AppPolicy.browserSessionsKey))!) as Map;
      expect((json['tabs'] as List).single, isNot(contains('hostId')));
      await sessions.clear();
      expect((await sessions.read()).tabs, isEmpty);
    },
  );

  test(
    'bad entries are skipped and never converted into executable addresses',
    () async {
      await db.setSetting(
        AppPolicy.browserSessionsKey,
        jsonEncode({
          'version': 1,
          'activeId': 'unsafe',
          'tabs': [
            {
              'id': 'unsafe',
              'initialUrl': 'javascript:alert(1)',
              'currentUrl': 'file:///etc/passwd',
            },
          ],
        }),
      );
      final value = await sessions.read();
      expect(value.tabs, isEmpty);
      expect(value.discarded, 1);
      expect(value.activeId, isNull);
    },
  );
}
