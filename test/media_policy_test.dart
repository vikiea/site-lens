import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'fake_web_host_api.dart';

class UnsupportedMediaApi extends FakeWebHostApi {
  @override
  Future<bool> setHostActivity(
    int id,
    bool current,
    bool visible,
    bool foreground,
    bool background,
  ) async {
    await super.setHostActivity(id, current, visible, foreground, background);
    return false;
  }
}

class HeldUnsupportedMediaApi extends UnsupportedMediaApi {
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false;
  @override
  Future<bool> setHostActivity(
    int id,
    bool current,
    bool visible,
    bool foreground,
    bool background,
  ) async {
    if (hold && current && visible && foreground) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.setHostActivity(id, current, visible, foreground, background);
  }
}

class DestroyedHostMediaApi extends FakeWebHostApi {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> setHostActivity(
    int id,
    bool current,
    bool visible,
    bool foreground,
    bool background,
  ) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    throw PlatformException(code: 'host_destroyed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('media policy follows current tab, route coverage, lifecycle and user setting', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final api = FakeWebHostApi();
    final app = AppController(db, api: api);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });
    await app.load();
    final a = await app.openUrl(Uri.parse('https://a.example/'));
    final b = await app.openUrl(Uri.parse('https://b.example/'));
    app.browserVisible = true;
    await app.syncMediaPolicy();
    expect(api.activity[a.host.id]![0], false);
    expect(api.activity[b.host.id], [true, true, true, false]);
    app.browserVisible = false;
    await app.syncMediaPolicy();
    expect(api.activity[b.host.id], [true, false, true, false]);
    await app.setAllowBackgroundPlayback(true);
    app.didChangeAppLifecycleState(AppLifecycleState.paused);
    await app.syncMediaPolicy();
    expect(api.activity[b.host.id], [true, false, false, true]);
    await app.activateTab(a);
    await app.syncMediaPolicy();
    expect(api.activity[b.host.id]![0], false);
    expect(api.activity[a.host.id]![0], true);
    await app.setAllowBackgroundPlayback(false);
    await app.syncMediaPolicy();
    expect(api.activity[a.host.id]![3], false);
  });

  test(
    'host_destroyed from a removed host is treated as stale policy work',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = DestroyedHostMediaApi();
      final app = AppController(db, api: api);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      final tab = await app.openUrl(Uri.parse('https://stale.example/'));
      app.browserVisible = true;
      final pending = app.syncMediaPolicy();
      await api.entered.future;
      tab.host.disposed = true;
      app.hosts.sessions.remove(tab.host.id);
      api.release.complete();
      await pending;
      expect(app.error, isNull);
    },
  );
  test(
    'unsupported Android closes a hidden host and retains cold metadata',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = UnsupportedMediaApi();
      final app = AppController(db, api: api);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      await app.load();
      final tab = await app.openUrl(Uri.parse('https://example.com/'));
      final id = tab.host.id;
      app.browserVisible = true;
      await app.syncMediaPolicy();
      expect(tab.loadedHost, isNotNull);
      app.browserVisible = false;
      await app.syncMediaPolicy();
      expect(api.destroyed, contains(id));
      expect(tab.loadedHost, isNull);
      expect(app.browserTabs.single.id, tab.id);
      expect(tab.currentUrl, Uri.parse('https://example.com/'));
    },
  );
  for (final change in ['hide', 'blur', 'switch']) {
    test(
      'late unsupported reply after $change closes the previously visible host',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final api = HeldUnsupportedMediaApi();
        final app = AppController(db, api: api);
        addTearDown(() async {
          await app.shutdown();
          await db.close();
        });
        await app.load();
        final a = await app.openUrl(Uri.parse('https://a.example/'));
        final b = await app.openUrl(Uri.parse('https://b.example/'));
        await app.activateTab(a);
        await app.syncMediaPolicy();
        final id = a.host.id;
        a.host.url = 'https://a.example/chapter';
        a.title = '保留标题';
        api.hold = true;
        app.browserVisible = true;
        final pending = app.syncMediaPolicy();
        await api.entered.future;
        if (change == 'hide') app.browserVisible = false;
        if (change == 'blur') {
          app.didChangeAppLifecycleState(AppLifecycleState.paused);
        }
        if (change == 'switch') await app.activateTab(b);
        api.release.complete();
        await pending;
        await app.syncMediaPolicy();
        expect(api.destroyed, contains(id));
        expect(a.loadedHost, isNull);
        expect(a.currentUrl.path, '/chapter');
        expect(a.title, '保留标题');
        expect(app.browserTabs, contains(a));
        app.didChangeAppLifecycleState(AppLifecycleState.resumed);
        app.browserVisible = true;
        await app.activateTab(a);
        await app.syncMediaPolicy();
        expect(a.loadedHost, isNotNull);
      },
    );
  }
}
