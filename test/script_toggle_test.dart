import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/settings_repository.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

class _HeldScriptApi extends FakeWebHostApi {
  final entered = Completer<void>();
  final release = Completer<void>();
  final registrations = <int, List<ScriptRegistration>>{};
  int expected = 1;

  @override
  Future<void> registerScripts(
    int hostId,
    List<ScriptRegistration> scripts,
  ) async {
    registrations[hostId] = scripts;
    if (registrations.length == expected && !entered.isCompleted) {
      entered.complete();
    }
    await release.future;
  }
}

class _ToggleApp extends AppController {
  _ToggleApp(super.db, {required super.api});
  int loads = 0;

  @override
  Future<void> load({bool suppressCorruption = false}) {
    loads++;
    return super.load(suppressCorruption: suppressCorruption);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'script switch paints durable state before all native reloads finish',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = _HeldScriptApi()..expected = 2;
      final app = _ToggleApp(db, api: api);
      await app.load();
      final one = await app.hosts.create(HostPurpose.browsing);
      final two = await app.hosts.create(HostPurpose.browsing);
      one.registered['old'] = 'revision';
      two.registered['old'] = 'revision';
      final preferencesBefore = api.applied.length;
      final seen = <bool>[];
      app.addListener(() => seen.add(app.scriptsDisabled));

      final toggle = app.disableAllScripts(true);
      await api.entered.future;
      expect(app.scriptsDisabled, isTrue);
      expect(app.changingScripts, isTrue);
      expect(seen, contains(true));
      expect((await SettingsRepository(db).read()).scriptsDisabled, isTrue);
      expect(api.registrations.values, everyElement(isEmpty));
      expect(one.registered, isEmpty);
      expect(two.registered, isEmpty);
      expect(api.reloaded, isEmpty);
      expect(api.applied.length, preferencesBefore);

      api.release.complete();
      await toggle;
      expect(api.reloaded, unorderedEquals([one.id, two.id]));
      expect(app.changingScripts, isFalse);
      expect(
        app.loads,
        1,
        reason: 'toggling must not reload unrelated databases',
      );
      await app.hosts.destroy(one);
      await app.hosts.destroy(two);
      await app.shutdown();
      await db.close();
    },
  );

  test(
    'opposing script changes serialize while revocation is pending',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = _HeldScriptApi();
      final app = _ToggleApp(db, api: api);
      await app.load();
      final host = await app.hosts.create(HostPurpose.browsing);

      final disabled = app.disableAllScripts(true);
      await api.entered.future;
      final enabled = app.disableAllScripts(false);
      expect(app.scriptsDisabled, isTrue);
      expect((await SettingsRepository(db).read()).scriptsDisabled, isTrue);
      api.release.complete();
      await Future.wait([disabled, enabled]);

      expect(app.scriptsDisabled, isFalse);
      expect(app.changingScripts, isFalse);
      expect((await SettingsRepository(db).read()).scriptsDisabled, isFalse);
      expect(api.reloaded, [host.id, host.id]);
      await app.hosts.destroy(host);
      await app.shutdown();
      await db.close();
    },
  );
}
