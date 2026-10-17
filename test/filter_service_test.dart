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
  });
}
