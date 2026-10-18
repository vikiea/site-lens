import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/scripts/metadata.dart';
import 'package:site_lens/domain/models.dart';

String source([String lines = '']) =>
    '// ==UserScript==\n// @name Contract\n// @match *://*.example.com/*\n$lines\n// ==/UserScript==\n';
void main() {
  test('match is host bounded, includes subdomains and excludes fragments', () {
    final rule = UrlRule('*://*.example.com/a*');
    expect(rule.matches(Uri.parse('https://example.com/abc#x')), isTrue);
    expect(
      rule.matches(Uri.parse('http://x.y.example.com:80/abc?q=1')),
      isTrue,
    );
    expect(rule.matches(Uri.parse('https://example.com.evil/abc')), isFalse);
    expect(rule.matches(Uri.parse('https://evilexample.com/abc')), isFalse);
    expect(rule.matches(Uri.parse('file://example.com/abc')), isFalse);
  });
  test('an address without a path still matches a /* pattern', () {
    // Browsers resolve `https://host` to the document `/`; a rule that demanded
    // a literal path matched nothing there, which silently disabled scripts on
    // every address recorded without a trailing slash.
    final all = UrlRule('*://*/*');
    expect(all.matches(Uri.parse('https://host')), isTrue);
    expect(all.matches(Uri.parse('https://host/')), isTrue);
    expect(all.matches(Uri.parse('https://host?a=1')), isTrue);
    expect(all.matches(Uri.parse('https://host:8443')), isTrue);
    expect(all.matches(Uri.parse('https://host/deep/path#frag')), isTrue);
    // Still bounded: the scheme and host parts are not loosened by this.
    expect(UrlRule('https://*/*').matches(Uri.parse('http://host')), isFalse);
    expect(
      UrlRule('*://*.example.com/*').matches(Uri.parse('https://evil.com')),
      isFalse,
    );
  });
  test('exact paths match without synthesizing an empty hash fragment', () {
    final r = UrlRule('https://example.com/exact');
    expect(r.matches(Uri.parse('https://example.com/exact#anchor')), isTrue);
    expect(
      webUri('https://example.com/exact#anchor').toString(),
      'https://example.com/exact',
    );
  });
  test('metadata scopes, phase and grants are explicit', () {
    final m = ScriptMetadata.parse(
      source(
        '// @exclude https://*.example.com/private/*\n// @run-at document-start\n// @grant GM.getValue\n// @connect api.example.com\n// @require https://cdn.example.com/library.js',
      ),
    );
    expect(m.errors, isEmpty);
    expect(m.pageWorld, isFalse);
    expect(m.runAt, 'document-start');
    expect(m.requires.single.host, 'cdn.example.com');
    expect(m.matchesUrl(Uri.parse('https://example.com/private/x')), isFalse);
  });

  test('supports URL-compatible include and exclude-match aliases', () {
    final m = ScriptMetadata.parse(
      source(
        '// @include https://player.example.com/*\n'
        '// @exclude-match https://player.example.com/private/*',
      ),
    );
    expect(m.errors, isEmpty);
    expect(m.matchesUrl(Uri.parse('https://player.example.com/watch')), isTrue);
    expect(
      m.matchesUrl(Uri.parse('https://player.example.com/private/x')),
      isFalse,
    );
  });
  test('localized name and description metadata are accepted', () {
    final m = ScriptMetadata.parse(
      '// ==UserScript==\n'
      '// @name Player\n'
      '// @name:zh-CN 播放器\n'
      '// @description:en Two-line description\n'
      '// @match *://example.com/*\n'
      '// @grant GM_addStyle\n'
      '// ==/UserScript==\n',
    );
    expect(m.errors, isEmpty);
    expect(m.name, 'Player');
  });
  test('extended GM grants are recognized', () {
    final m = ScriptMetadata.parse(
      source(
        '// @grant GM_info\n'
        '// @grant GM_setClipboard\n'
        '// @grant GM_notification\n'
        '// @grant GM_openInTab\n'
        '// @grant GM_addValueChangeListener\n'
        '// @grant GM_removeValueChangeListener',
      ),
    );
    expect(m.errors, isEmpty);
    expect(m.canEnable, isTrue);
    expect(m.grants, contains('GM_notification'));
  });
  test('unterminated metadata names the script and explains truncation', () {
    final m = ScriptMetadata.parse(
      '// ==UserScript==\n'
      '// @name Truncated header\n'
      '// @match *://example.com/*\n'
      '// @grant GM_download',
    );
    expect(m.name, 'Truncated header');
    expect(m.canEnable, isFalse);
    expect(m.errors, contains(contains('元数据区未闭合')));
    expect(m.errors, contains(contains('GM_download')));
  });
  test('unsupported critical semantics prevent enabling', () {
    for (final line in [
      '// @grant GM_download',
      '// @run-at context-menu',
      '// @match <all_urls>',
      '// @require http://example.com/insecure.js',
    ]) {
      expect(
        ScriptMetadata.parse(source(line)).canEnable,
        isFalse,
        reason: line,
      );
    }
    expect(
      ScriptMetadata.parse(source('// @grant none\n// @grant GM_getValue'))
          .canEnable,
      isFalse,
    );
    expect(ScriptMetadata.parse('alert(1)').canEnable, isFalse);
  });
  test(
    'unsafeWindow is page-world only and never mixes with GM privileges',
    () {
      final pageOnly = ScriptMetadata.parse(source('// @grant unsafeWindow'));
      expect(pageOnly.errors, isEmpty);
      expect(pageOnly.canEnable, isTrue);
      expect(pageOnly.pageWorld, isTrue);
      expect(pageOnly.privilegedGrants, isEmpty);

      // `none` plus unsafeWindow is the same contract written two ways.
      final explicit = ScriptMetadata.parse(
        source('// @grant none\n// @grant unsafeWindow'),
      );
      expect(explicit.errors, isEmpty);
      expect(explicit.pageWorld, isTrue);

      final mixed = ScriptMetadata.parse(
        source('// @grant unsafeWindow\n// @grant GM_setValue'),
      );
      expect(mixed.canEnable, isFalse);
      expect(mixed.pageWorld, isFalse);
      expect(mixed.errors, contains(contains('unsafeWindow 不能与 GM 特权权限混用')));
    },
  );
  test('approval digest changes with source or fixed dependency bytes', () {
    final s = source('// @require https://cdn.example.com/lib.js');
    final m = ScriptMetadata.parse(s);
    final a = PinnedDependency(url: m.requires.single, hash: 'a', bytes: [97]);
    final b = PinnedDependency(url: m.requires.single, hash: 'b', bytes: [98]);
    expect(m.digest(s, [a]), isNot(m.digest(s, [b])));
    expect(m.digest(s, [a]), isNot(m.digest('$s\n// edit', [a])));
  });
}
