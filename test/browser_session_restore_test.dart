import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'restored tabs do not create hosts until selected, and survive dispose',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final firstApi = FakeWebHostApi();
      final first = AppController(db, api: firstApi);
      await first.load();
      final tab = await first.openUrl(Uri.parse('https://entry.example/'));
      final savedId = tab.id;
      tab.host.url = 'https://entry.example/chapter';
      // Selecting writes the latest URL synchronously into the snapshot.
      await first.activateTab(tab);
      await first.shutdown();
      final api = FakeWebHostApi();
      final reopened = AppController(db, api: api);
      addTearDown(reopened.dispose);
      await reopened.load();
      await reopened.restoreSavedSessions();
      expect(api.created, isEmpty);
      expect(reopened.browserTabs, hasLength(1));
      final restored = reopened.browserTabs.single;
      expect(restored.id, savedId);
      expect(restored.loadedHost, isNull);
      await reopened.activateTab(restored);
      expect(api.created, hasLength(1));
      expect(
        api.navigated.values.single.single,
        'https://entry.example/chapter',
      );
      expect(restored.site.url.toString(), 'https://entry.example/');
    },
  );

  test(
    'disabling restore keeps live tabs but removes the restart snapshot',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final app = AppController(db, api: FakeWebHostApi());
      await app.load();
      await app.openUrl(Uri.parse('https://a.example/'));
      await app.setRestoreBrowserSessions(false);
      expect(app.browserTabs, hasLength(1));
      expect((await app.sessionStore.read()).tabs, isEmpty);
      await app.setRestoreBrowserSessions(true);
      expect((await app.sessionStore.read()).tabs, hasLength(1));
      await app.closeAllTabs();
      expect((await app.sessionStore.read()).tabs, isEmpty);
      await app.shutdown();
    },
  );
}
