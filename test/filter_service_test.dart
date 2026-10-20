import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'dart:io';
import 'dart:convert';

import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/filter/filter_service.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test('compiles cosmetic rules and only allow-listed scriptlets', () {
    final result = const FilterCompiler().compile(
      'example.com##.sponsor\n'
      'example.com##+js(set-constant,tracker.enabled,false)\n'
      'example.com##+js(unknown,tracker)\n'
      '||ads.example^\n',
      snapshotId: 'test',
    );
    expect(result.engine.rules, hasLength(3));
    expect(result.engine.rules.where((rule) => rule.cosmetic), hasLength(2));
    expect(
      result.engine.rules
          .singleWhere((rule) => rule.scriptlet != null)
          .scriptlet,
      'set-constant',
    );
    expect(
      result.unsupportedRules,
      contains('example.com##+js(unknown,tracker)'),
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://ads.example/banner.js'),
        policy: const FilterPolicy(enabled: true),
      ),
      FilterDecision.block,
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://example.com/article'),
        policy: const FilterPolicy(enabled: true),
      ),
      FilterDecision.allow,
    );
    expect(
      result.engine.cosmeticSelectors(Uri.parse('https://example.com/article')),
      ['.sponsor'],
    );
  });

  test(
    'cosmetic exceptions cancel only their selector and never block requests',
    () {
      final result = const FilterCompiler().compile(
        'example.com##.sponsor\n'
        'example.com#@#.sponsor\n'
        'other.example##.sponsor\n',
        snapshotId: 'cosmetic',
      );
      expect(
        result.engine.cosmeticSelectors(Uri.parse('https://example.com/')),
        isEmpty,
      );
      expect(
        result.engine.cosmeticSelectors(Uri.parse('https://other.example/')),
        ['.sponsor'],
      );
      expect(
        result.engine.evaluate(
          Uri.parse('https://example.com/article'),
          policy: const FilterPolicy(enabled: true),
        ),
        FilterDecision.allow,
      );
    },
  );

  test(
    'cosmetic domain lists honor exclusions and reject unsupported semantics',
    () {
      final result = const FilterCompiler().compile(
        'example.com,~news.example##.sponsor\n'
        'example.com##div:has-text(ad)\n',
        snapshotId: 'cosmetic-domains',
      );
      expect(
        result.engine.cosmeticSelectors(Uri.parse('https://example.com/')),
        ['.sponsor'],
      );
      expect(
        result.engine.cosmeticSelectors(Uri.parse('https://news.example/')),
        isEmpty,
      );
      expect(
        result.unsupportedRules,
        contains('example.com##div:has-text(ad)'),
      );
      expect(result.engine.rules, hasLength(1));
    },
  );

  test('request exceptions and supported ABP options are deterministic', () {
    final result = const FilterCompiler().compile(
      '||ads.example^\n'
      '@@||ads.example/allowed^\n'
      '||tracker.example^\$third-party\n'
      '||private.example^\$domain=site.example|~news.example\n',
      snapshotId: 'request-options',
    );
    const policy = FilterPolicy(enabled: true);
    expect(
      result.engine.evaluate(
        Uri.parse('https://ads.example/blocked'),
        policy: policy,
      ),
      FilterDecision.block,
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://ads.example/allowed'),
        policy: policy,
      ),
      FilterDecision.allow,
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://tracker.example/pixel'),
        policy: policy,
        context: FilterRequestContext(
          document: Uri.parse('https://site.example/'),
          thirdParty: true,
        ),
      ),
      FilterDecision.block,
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://tracker.example/pixel'),
        policy: policy,
        context: FilterRequestContext(
          document: Uri.parse('https://tracker.example/'),
          thirdParty: false,
        ),
      ),
      FilterDecision.allow,
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://private.example/x'),
        policy: policy,
        context: FilterRequestContext(
          document: Uri.parse('https://site.example/'),
        ),
      ),
      FilterDecision.block,
    );
    expect(
      result.engine.evaluate(
        Uri.parse('https://private.example/x'),
        policy: policy,
        context: FilterRequestContext(
          document: Uri.parse('https://news.example/'),
        ),
      ),
      FilterDecision.allow,
    );
  });

  test('diagnostics redact query values and expose degraded rule state', () {
    final result = const FilterCompiler().compile(
      'example.com##+js(unsupported,foo)\n',
      snapshotId: 'degraded',
    );
    final diagnostic = result.engine.diagnose(
      Uri.parse('https://example.com/a?token=secret'),
      policy: const FilterPolicy(enabled: true),
    );
    expect(diagnostic.toJson()['url'], 'https://example.com/a?token=%E2%80%A6');
    expect(diagnostic.reason, contains('未支持'));
    expect(result.engine.diagnostics['degraded'], isTrue);
  });

  test(
    'built-in sources fall back to a mirror after the primary fails',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-filter-');
      addTearDown(() => root.delete(recursive: true));
      final primary = Uri.parse(
        'https://easylist-downloads.adblockplus.org/easylist.txt',
      );
      final mirror = Uri.parse('https://easylist.to/easylist/easylist.txt');
      final http = _FilterHttp(primary, mirror);
      final source = FilterSource(
        id: 1,
        label: 'EasyList（广告）',
        url: primary,
        kind: 'builtin',
      );
      final snapshot = await FilterSourceManager(
        store: FilterSnapshotStore(directoryProvider: () async => root),
        http: http,
      ).refresh(source);
      expect(snapshot.sourceUrl, mirror);
      expect(http.calls, [primary, mirror]);
    },
  );

  test(
    'rebuilds one active bundle from the newest snapshot of each source',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-bundle-');
      addTearDown(() => root.delete(recursive: true));
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = FilterSnapshotStore(directoryProvider: () async => root);
      final manager = FilterSourceManager(store: store, db: db);
      await db.saveFilterSource(
        FilterSource(
          id: 1,
          label: '广告',
          url: Uri.parse('https://filters.example/ads.txt'),
        ),
      );
      await db.saveFilterSource(
        FilterSource(
          id: 2,
          label: '跟踪',
          url: Uri.parse('https://filters.example/privacy.txt'),
        ),
      );
      for (final item in [
        (1, 'https://filters.example/ads.txt', '||ads.example^'),
        (2, 'https://filters.example/privacy.txt', '||tracker.example^'),
      ]) {
        final snapshot = await store.publish(
          id: 'source-${item.$1}',
          sourceId: item.$1,
          version: '1',
          sourceUrl: Uri.parse(item.$2),
          source: item.$3,
          fileRef: 'source-${item.$1}',
        );
        await db.saveFilterSnapshot(snapshot);
      }
      final bundle = await manager.rebuildBundle();
      expect(bundle, isNotNull);
      expect(bundle!.sourceId, isNull);
      expect(store.activeSnapshot!.id, bundle.id);
      final engine = store.activeEngine!;
      const policy = FilterPolicy(enabled: true);
      expect(
        engine.evaluate(Uri.parse('https://ads.example/a'), policy: policy),
        FilterDecision.block,
      );
      expect(
        engine.evaluate(Uri.parse('https://tracker.example/a'), policy: policy),
        FilterDecision.block,
      );
    },
  );

  test('returns only explicit profile policies for inheritance', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.saveFilterPolicy(const FilterPolicy(enabled: true), profileId: 7);
    final policies = await db.explicitProfileFilterPolicies();
    expect(policies.keys, {7});
    expect(policies[7]!.enabled, isTrue);
    expect(policies.containsKey(8), isFalse);
  });
}

class _FilterHttp extends ControlledHttp {
  _FilterHttp(this.primary, this.mirror);
  final Uri primary;
  final Uri mirror;
  final calls = <Uri>[];

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
    calls.add(url);
    if (url == primary) throw const SocketException('primary unavailable');
    if (url != mirror) throw StateError('unexpected source');
    return FetchResponse(
      url: url,
      status: 200,
      bytes: utf8.encode('[Adblock Plus 2.0]\n||ads.example^\n'),
      headers: const {},
    );
  }
}
