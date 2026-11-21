import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

/// ADR-0004 "明确不暴露" as an executable check.
///
/// The adapter is the only legal home for site-specific logic, so nothing
/// site-specific may appear in the names of its members, parameters, types or
/// the values of its enums: encryption schemes, signing parameters, the shape
/// of a site's domain pool, the underlying client, retry policy.
void main() {
  // Matched against every identifier declared in the contract file.
  final forbidden = <String, RegExp>{
    '加密方案': RegExp(
      r'aes|rsa|cipher|encrypt|decrypt|enc\b',
      caseSensitive: false,
    ),
    '签名参数': RegExp(
      r'signature|signkey|sign_|signing|hmac|\bsign\b',
      caseSensitive: false,
    ),
    '域名池形状': RegExp(
      r'domainpool|domain_pool|mirrorpool|hostpool',
      caseSensitive: false,
    ),
    '底层客户端': RegExp(
      r'httpclient|dio\b|okhttp|cookiejar|response\b',
      caseSensitive: false,
    ),
    '重试策略': RegExp(r'retry|backoff|back_off|jitter', caseSensitive: false),
    '设备标识': RegExp(
      r'deviceid|device_id|deviceidentifier',
      caseSensitive: false,
    ),
  };

  test('契约文件里的每个声明都不含站点专有名词', () {
    final source = _contractSource();
    final names = _declaredNames(source);
    expect(names.length, greaterThan(40), reason: '扫描没有读到契约的声明');

    final violations = <String>[];
    for (final name in names) {
      for (final entry in forbidden.entries) {
        if (entry.value.hasMatch(name)) {
          violations.add('$name (${entry.key})');
        }
      }
    }
    expect(violations, isEmpty, reason: '适配器契约暴露了站点专有概念');
  });

  test('契约不引用传输层或持久层类型', () {
    final source = _contractSource();
    final imports = RegExp(
      r"^import\s+'([^']+)';",
      multiLine: true,
    ).allMatches(source).map((m) => m.group(1)!).toList();
    for (final uri in imports) {
      final allowed =
          uri == 'dart:async' ||
          uri.startsWith('package:') ||
          uri.endsWith('models.dart');
      expect(allowed, isTrue, reason: '契约多引用了 $uri');
    }
    // Prose may name these layers; imports may not.
    final banned = <Matcher>[
      startsWith('package:flutter'),
      equals('dart:io'),
      equals('dart:convert'),
      contains('../network/'),
      contains('../data/'),
      contains('../web_host/'),
      contains('../settings/'),
    ];
    for (final ban in banned) {
      expect(imports, isNot(contains(ban)));
    }
  });
}

/// Reads the contract file whether the test runs from the repository root
/// (`flutter test`) or from a host harness elsewhere.
String _contractSource() {
  // `flutter test` runs with the package root as the working directory.
  final direct = File('lib/domain/site_adapter.dart');
  if (direct.existsSync()) return direct.readAsStringSync();
  // A host harness elsewhere can still read it from the library's own path.
  final fromLibrary = File.fromUri(
    Isolate.resolvePackageUriSync(
      Uri.parse('package:site_lens/domain/site_adapter.dart'),
    )!,
  );
  if (fromLibrary.existsSync()) return fromLibrary.readAsStringSync();
  throw StateError('找不到契约文件 lib/domain/site_adapter.dart');
}

/// Every identifier a reader of the file would call a declared name: type
/// names, member names, parameter names and enum values, with comments and
/// string literals removed first so prose can keep explaining the same words.
Set<String> _declaredNames(String source) {
  final code = source
      .split('\n')
      .where((line) {
        final trimmed = line.trimLeft();
        return !trimmed.startsWith('//');
      })
      .join('\n')
      .replaceAll(RegExp(r"'[^'\n]*'"), "''");
  final names = <String>{};
  // An identifier that follows a type, or opens a declaration call/field.
  final patterns = [
    RegExp(r'\b(?:class|enum|extension|typedef)\s+([A-Za-z_]\w*)'),
    RegExp(
      r'^\s*(?:abstract\s+)?(?:interface\s+)?(?:sealed\s+)?(?:final\s+)?'
      r'(?:base\s+)?(?:class|enum|extension)\s+([A-Za-z_]\w*)',
      multiLine: true,
    ),
    RegExp(r'\b(?:final|const)\s+[\w<>,\? ]+?\s([A-Za-z_]\w*)\s*[;=]'),
    RegExp(r'^\s*[A-Za-z_][\w<>,\? ]*\s([A-Za-z_]\w*)\s*\(', multiLine: true),
    RegExp(r'\bthis\.([A-Za-z_]\w*)'),
    RegExp(r'^\s*([a-z][A-Za-z0-9_]*),?\s*$', multiLine: true),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(code)) {
      final name = match.group(1);
      if (name == null || _dartKeywords.contains(name)) continue;
      names.add(name);
    }
  }
  return names;
}

const _dartKeywords = {
  'abstract',
  'await',
  'base',
  'bool',
  'class',
  'const',
  'default',
  'enum',
  'extend',
  'extends',
  'factory',
  'final',
  'Future',
  'get',
  'implements',
  'interface',
  'int',
  'library',
  'List',
  'Map',
  'new',
  'operator',
  'required',
  'return',
  'sealed',
  'set',
  'static',
  'String',
  'super',
  'this',
  'toString',
  'Uri',
  'void',
  'with',
};
