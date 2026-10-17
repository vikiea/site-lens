import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/filter/filter_service.dart';

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
}
