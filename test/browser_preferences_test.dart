import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/settings_repository.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeWebHostApi api;
  late AppController app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    api = FakeWebHostApi();
    app = AppController(db, api: api);
    await app.load();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  test(
    'entry redirects are always enabled while pull refresh is configurable',
    () async {
      expect(app.followEntryRedirects, isTrue);
      expect(app.pullToRefresh, isFalse);
      expect(app.hostPreferences.followEntryRedirects, isTrue);
      expect(app.hostPreferences.pullToRefresh, isFalse);

      await app.setPullToRefresh(true);
      expect(app.hostPreferences.followEntryRedirects, isTrue);
      expect(app.hostPreferences.pullToRefresh, isTrue);
      expect((await SettingsRepository(db).read()).pullToRefresh, isTrue);
    },
  );

  test('new hosts and live hosts keep entry redirects enabled', () async {
    await app.openUrl(Uri.parse('https://a.example/'), label: 'a');
    final host = app.hosts.sessions.values.single;
    api.applied.clear();

    await app.setPullToRefresh(true);

    expect(api.createdWith[host.id]!.followEntryRedirects, isTrue);
    expect(api.applied.single.followEntryRedirects, isTrue);
    expect(api.applied.single.pullToRefresh, isTrue);
  });

  test(
    'legacy independent redirect values cannot weaken the fixed policy',
    () async {
      await db.setSetting('followEntryRedirects', '');
      final reopened = AppController(db, api: FakeWebHostApi());
      addTearDown(reopened.shutdown);
      await reopened.load();
      expect(reopened.followEntryRedirects, isTrue);
      expect(reopened.hosts.preferences.followEntryRedirects, isTrue);
      expect(
        SettingsRepository(db).update({'followEntryRedirects': false}),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
