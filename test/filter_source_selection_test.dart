import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/filter/filter_service.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory root;
  late FilterSnapshotStore store;
  late FilterSourceManager manager;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('filter-selection-');
    store = FilterSnapshotStore(directoryProvider: () async => root);
    manager = FilterSourceManager(store: store, db: db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<FilterSource> seed(int id, String rules, {bool enabled = true}) async {
    final source = FilterSource(
      id: id,
      label: '源$id',
      kind: id == 1 ? 'builtin' : 'list',
      url: Uri.parse('https://filters.example/$id.txt'),
      enabled: enabled,
    );
    await db.saveFilterSource(source);
    final snapshot = await store.publish(
      id: 'source-$id',
      sourceId: id,
      version: '1',
      sourceUrl: source.url,
      source: rules,
      fileRef: 'source-$id',
      activate: false,
    );
    await db.saveFilterSnapshot(snapshot);
    return source;
  }

  test('source JSON defaults existing subscriptions to enabled', () {
    final legacy = {'id': 1, 'label': '旧源', 'url': 'https://filters.example/a'};
    expect(FilterSource.fromJson(legacy).enabled, isTrue);
    final disabled = FilterSource.fromJson({...legacy, 'enabled': false});
    expect(FilterSource.fromJson(disabled.toJson()).enabled, isFalse);
  });

  test(
    'built-in and custom switches retain caches and rebuild after restart',
    () async {
      await seed(1, '||ads.example^\nexample.com,~news.example##.sponsor');
      await seed(
        2,
        '||tracker.example^\nexample.com##+js(set-constant,tracker,false)\nexample.com##+js(unsupported,x)',
      );
      await manager.rebuildBundle();
      expect(store.activeEngine!.rules, hasLength(4));
      expect(store.activeSnapshot!.unsupportedRuleCount, 1);
      final originalDigest = store.activeSnapshot!.sha256;
      await manager.setEnabled(2, false);
      expect(store.activeEngine!.rules, hasLength(2));
      expect(store.activeSnapshot!.unsupportedRuleCount, 0);
      expect(
        store.activeEngine!.cosmeticSelectors(
          Uri.parse('https://news.example/'),
        ),
        isEmpty,
      );
      expect(
        store.activeEngine!.cosmeticSelectors(
          Uri.parse('https://example.com/'),
        ),
        ['.sponsor'],
      );
      await manager.setEnabled(1, false);
      expect(store.activeEngine!.rules, isEmpty);
      final restored = FilterSnapshotStore(directoryProvider: () async => root);
      await FilterSourceManager(store: restored, db: db).rebuildBundle();
      expect(restored.activeEngine!.rules, isEmpty);
      await manager.setEnabled(1, true);
      await manager.setEnabled(2, true);
      expect(store.activeSnapshot!.sha256, originalDigest);
      final sources = await db.latestFilterSnapshotsBySource();
      expect(sources, hasLength(2));
      for (final snapshot in sources) {
        expect(await File(snapshot.fileRef).exists(), isTrue);
      }
    },
  );

  test(
    'refresh cannot overwrite a queued disable or resurrect a deleted source',
    () async {
      final source = await seed(2, '||old.example^');
      final http = _PendingFilterHttp();
      manager = FilterSourceManager(store: store, db: db, http: http);
      final refreshed = manager.refresh(source);
      await http.started.future;
      final disabled = manager.setEnabled(source.id, false);
      http.result.complete('||new.example^');
      await refreshed;
      await disabled;
      expect((await db.filterSources()).single.enabled, isFalse);
      expect(store.activeEngine!.rules, isEmpty);
      await manager.delete(source.id);
      await expectLater(manager.refresh(source), throwsStateError);
      expect(await db.filterSources(), isEmpty);
      expect(store.activeSnapshot, isNull);
    },
  );

  test(
    'refreshing a disabled source caches success and preserves failure state',
    () async {
      final source = await seed(2, '||old.example^', enabled: false);
      for (final fail in [false, true]) {
        final http = _PendingFilterHttp();
        manager = FilterSourceManager(store: store, db: db, http: http);
        final refresh = manager.refresh(source);
        final completion = fail
            ? expectLater(refresh, throwsStateError)
            : refresh;
        await http.started.future;
        if (fail) {
          http.result.completeError(StateError('HTTP 503'));
        } else {
          http.result.complete('||new.example^');
        }
        await completion;
        expect((await db.filterSources()).single.enabled, isFalse);
        expect(store.activeEngine!.rules, isEmpty);
      }
    },
  );

  test('built-in reseeding preserves a disabled source', () async {
    await db.saveFilterSource(
      FilterSource(
        id: 1,
        label: builtInFilterSources.first.label,
        url: Uri.parse('https://old.example/rules'),
        kind: 'builtin',
        enabled: false,
        status: FilterSourceStatus.failed,
      ),
    );
    final app = AppController(db, api: FakeWebHostApi());
    try {
      await app.load();
      final source = (await db.filterSources()).firstWhere(
        (item) => item.id == 1,
      );
      expect(source.enabled, isFalse);
      expect(source.url.toString(), builtInFilterSources.first.url);
    } finally {
      await app.shutdown();
    }
  });

  test('AppController cold load retains a mirror bundle when its source file is corrupt', () async {
    final spec = builtInFilterSources.first;
    final primary = Uri.parse(spec.url);
    final mirror = Uri.parse(spec.fallbackUrls.first);
    final source = FilterSource(
      id: 1,
      label: spec.label,
      url: primary,
      kind: 'builtin',
    );
    await db.saveFilterSource(source);
    await db.setSetting(
      'filterSourceSeedVersion',
      builtInFilterSourceSeedVersion,
    );
    final http = _RedirectedFilterHttp(mirror);
    manager = FilterSourceManager(store: store, db: db, http: http);
    final bundle = await manager.refresh(source);
    final raw = (await db.latestFilterSnapshotsBySource()).single;
    expect(raw.sourceUrl, mirror);
    expect((await db.filterSources()).single.url, primary);
    await File(raw.fileRef).writeAsString('tampered');
    store.clear();
    final app = AppController(db, api: FakeWebHostApi());
    try {
      await app.load();
      expect(app.filterSnapshots.activeSnapshot?.id, bundle.id);
      expect(app.filterSnapshots.activeEngine?.rules, hasLength(1));
      expect(app.filterSourceList.single.url, primary);
      expect(
        app.filterSnapshots.activeEngine!.evaluate(
          Uri.parse('https://ads.example/banner'),
          policy: const FilterPolicy(enabled: true),
        ),
        FilterDecision.block,
      );
    } finally {
      await app.shutdown();
    }
  });

  test('cold reopen verifies an exact-selection bundle when a source file is corrupt', () async {
    await db.close();
    final databaseFile = File('${root.path}/filters.sqlite');
    db = AppDatabase(NativeDatabase(databaseFile));
    manager = FilterSourceManager(store: store, db: db);
    await seed(1, '||ads.example^');
    await seed(2, '||tracker.example^');
    final bundle = (await manager.rebuildBundle())!;
    final raw = (await db.latestFilterSnapshotsBySource()).first;
    await File(raw.fileRef).writeAsString('tampered');
    await db.close();
    db = AppDatabase(NativeDatabase(databaseFile));
    final reopened = FilterSnapshotStore(directoryProvider: () async => root);
    manager = FilterSourceManager(store: reopened, db: db);
    final restored = await manager.rebuildBundle();
    expect(restored!.id, bundle.id);
    expect(reopened.activeEngine!.rules, hasLength(2));
    final otherId = raw.sourceId == 1 ? 2 : 1;
    await expectLater(manager.setEnabled(otherId, false), throwsStateError);
    expect(
      (await db.filterSources())
          .firstWhere((source) => source.id == otherId)
          .enabled,
      isTrue,
    );
  });

  test(
    'failed selection changes roll back the switch and active bundle',
    () async {
      final first = await seed(1, '||ads.example^');
      await seed(2, '||tracker.example^');
      await manager.rebuildBundle();
      final previousEngine = store.activeEngine;
      final previousSnapshot = store.activeSnapshot;
      final corrupted = (await db.latestFilterSnapshotsBySource()).firstWhere(
        (snapshot) => snapshot.sourceId == first.id,
      );
      await File(corrupted.fileRef).writeAsString('tampered');

      await expectLater(manager.setEnabled(2, false), throwsStateError);
      expect(
        (await db.filterSources())
            .firstWhere((source) => source.id == 2)
            .enabled,
        isTrue,
      );
      expect(store.activeEngine!.rules, hasLength(2));
      expect(store.activeEngine, same(previousEngine));
      expect(store.activeSnapshot, same(previousSnapshot));

      await expectLater(manager.delete(2), throwsStateError);
      expect(
        (await db.filterSources()).map((source) => source.id),
        contains(2),
      );
      expect(store.activeEngine!.rules, hasLength(2));
      expect(await db.latestFilterSnapshotsBySource(), hasLength(2));
      expect(store.activeEngine, same(previousEngine));
      expect(store.activeSnapshot, same(previousSnapshot));
    },
  );
}

class _PendingFilterHttp extends ControlledHttp {
  final started = Completer<void>();
  final result = Completer<String>();

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
    int routeAttempt = 0,
  }) async {
    started.complete();
    return FetchResponse(
      url: url,
      status: 200,
      headers: const {},
      bytes: utf8.encode(await result.future),
    );
  }
}

class _RedirectedFilterHttp extends ControlledHttp {
  _RedirectedFilterHttp(this.finalUrl);
  final Uri finalUrl;

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
    int routeAttempt = 0,
  }) async => FetchResponse(
    url: finalUrl,
    status: 200,
    headers: const {},
    bytes: utf8.encode('||ads.example^'),
  );
}
