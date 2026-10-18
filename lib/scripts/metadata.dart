import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/models.dart';

const maxScriptBytes = 16 * 1024 * 1024;
const scriptSourcePlaceholder = '__SITE_LENS_SOURCE__';

/// Grants that do not require the native bridge, so the script can run in the
/// page world without giving up isolation for any privileged capability.
const pageWorldGrants = <String>{'unsafeWindow'};

const supportedGrants = <String>{
  'GM_getValue',
  'GM_setValue',
  'GM_deleteValue',
  'GM_listValues',
  'GM_addStyle',
  'GM_registerMenuCommand',
  'GM_unregisterMenuCommand',
  'GM_xmlhttpRequest',
  'GM_info',
  'GM_setClipboard',
  'GM_notification',
  'GM_openInTab',
  'GM_addValueChangeListener',
  'GM_removeValueChangeListener',
  'GM_log',
  'GM_addElement',
  'GM_getResourceText',
  'GM_getResourceURL',
  'GM.getValue',
  'GM.setValue',
  'GM.deleteValue',
  'GM.listValues',
  'GM.addStyle',
  'GM.registerMenuCommand',
  'GM.unregisterMenuCommand',
  'GM.xmlHttpRequest',
  'GM.info',
  'GM.setClipboard',
  'GM.notification',
  'GM.openInTab',
  'GM.addValueChangeListener',
  'GM.removeValueChangeListener',
  'GM.log',
  'GM.addElement',
  'GM.getResourceText',
  'GM.getResourceURL',
  'SiteLens.registerMedia',
};

/// One `@resource <name> <url>` declaration. Snapshot semantics match
/// `@require`: downloaded once at confirmation, then frozen.
class ScriptResource {
  const ScriptResource(this.name, this.url);
  final String name;
  final Uri url;
}

/// Stable content fingerprint of a script's source. Two profiles holding the
/// same bytes share this value, which is how "这 N 处是同一份" is detected.
String scriptContentHash(String source) =>
    sha256.convert(utf8.encode(source)).toString();

class UrlRule {
  UrlRule(this.pattern) : regex = _compile(pattern);
  final String pattern;
  final String regex;

  /// Matches [uri] against this rule.
  ///
  /// A URL whose path is empty is compared as `/?...`: browsers always resolve
  /// `https://host` to the document `/`, and `*://*/*` (or any `host/*` pattern)
  /// has to cover it. Without this, `https://host` matched *no* rule at all,
  /// which silently disabled scripts — and their GM requests — on every address
  /// that was recorded without a trailing slash.
  bool matches(Uri uri) {
    final target = uri.removeFragment();
    final normalized = target.path.isEmpty
        ? target.replace(path: '/').toString()
        : target.toString();
    return RegExp(regex).hasMatch(normalized);
  }

  static String _compile(String value) {
    final m = RegExp(
      r'^(\*|https?)://(\*|\*\.[a-zA-Z0-9.-]+|[a-zA-Z0-9.-]+)(/.*)$',
    ).firstMatch(value);
    if (m == null) throw FormatException('不支持的 URL 匹配规则：$value');
    final scheme = m[1] == '*' ? 'https?' : m[1]!;
    final host = m[2]!;
    final h = host == '*'
        ? r'[^/:?#]+'
        : host.startsWith('*.')
        ? '(?:[^/:?#]+\\.)?${RegExp.escape(host.substring(2))}'
        : RegExp.escape(host);
    final path = m[3]!.split('*').map(RegExp.escape).join('.*');
    // Explicit ports are accepted in URLs, but not in metadata host patterns.
    return '^$scheme://$h(?::[0-9]+)?$path\$';
  }
}

class ScriptMetadata {
  ScriptMetadata({
    required this.name,
    required this.namespace,
    required this.version,
    required this.description,
    required this.matches,
    required this.excludes,
    required this.runAt,
    required this.grants,
    required this.connect,
    required this.requires,
    required this.resources,
    required this.errors,
  });
  final String name;
  final String namespace;
  final String version;
  final String description;
  final List<UrlRule> matches;
  final List<UrlRule> excludes;
  final String runAt;
  final Set<String> grants;
  final Set<String> connect;
  final List<Uri> requires;
  final List<ScriptResource> resources;
  final List<String> errors;

  /// Grants that need the native bridge and therefore the isolated world.
  Set<String> get privilegedGrants => grants
      .where((grant) => grant != 'none' && !pageWorldGrants.contains(grant))
      .toSet();

  /// A script with no privileged grant runs in the page world. That is the only
  /// place where `unsafeWindow` can honestly alias the page's own `window`,
  /// because an isolated world cannot share page JavaScript objects.
  bool get pageWorld => privilegedGrants.isEmpty;
  bool get canEnable => errors.isEmpty;
  bool matchesUrl(Uri url) =>
      matches.any((r) => r.matches(url)) &&
      !excludes.any((r) => r.matches(url));
  String digest(
    String source,
    List<PinnedDependency> deps, [
    List<PinnedResource> resources = const [],
    ScriptNetworkMode networkMode = ScriptNetworkMode.declared,
    String? approvalReason,
  ]) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'source': source,
            'dependencies': deps
                .map((d) => {'url': d.url.toString(), 'hash': d.hash})
                .toList(),
            if (resources.isNotEmpty)
              'resources': resources
                  .map((r) => {'name': r.name, 'hash': r.hash})
                  .toList(),
            'networkMode': networkMode.name,
            'approvalReason': approvalReason,
          }),
        ),
      )
      .toString();

  /// Digest format used before network authorization was added. It is only
  /// accepted during a one-time migration of an existing local approval; new
  /// approvals always use [digest].
  String legacyDigest(
    String source,
    List<PinnedDependency> deps, [
    List<PinnedResource> resources = const [],
  ]) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'source': source,
            'dependencies': deps
                .map((d) => {'url': d.url.toString(), 'hash': d.hash})
                .toList(),
            if (resources.isNotEmpty)
              'resources': resources
                  .map((r) => {'name': r.name, 'hash': r.hash})
                  .toList(),
          }),
        ),
      )
      .toString();
  String get rulesJson => jsonEncode({
    'matches': matches.map((r) => r.regex).toList(),
    'excludes': excludes.map((r) => r.regex).toList(),
  });

  factory ScriptMetadata.parse(String source) {
    final errors = <String>[];
    final fields = <String, List<String>>{};
    final start = RegExp(
      r'^\s*//\s*==UserScript==\s*$',
      multiLine: true,
    ).firstMatch(source);
    if (start == null) {
      errors.add('缺少完整的 UserScript 元数据区');
    } else {
      final remainder = source.substring(start.end);
      final end = RegExp(
        r'^\s*//\s*==/UserScript==\s*$',
        multiLine: true,
      ).firstMatch(remainder);
      if (end == null) {
        errors.add(
          'UserScript 元数据区未闭合，可能只粘贴了头部：缺少 // ==/UserScript== 和脚本主体；请复制完整 .user.js 或使用文件导入',
        );
      }
      final block = end == null ? remainder : remainder.substring(0, end.start);
      for (final line in block.split(RegExp(r'\r?\n'))) {
        final m = RegExp(r'^\s*//\s*@([\w:-]+)(?:\s+(.*?))?\s*$')
            .firstMatch(line);
        if (m != null) {
          fields.putIfAbsent(m[1]!, () => []).add(m[2]?.trim() ?? '');
          continue;
        }
        if (end == null && line.trim().isNotEmpty) {
          // An unterminated header ends at the first non-comment line. Never
          // treat arbitrary script code as additional metadata.
          break;
        }
      }
    }
    const allowed = {
      'name',
      'namespace',
      'version',
      'description',
      'author',
      'homepage',
      'homepageURL',
      'supportURL',
      'license',
      'icon',
      'downloadURL',
      'updateURL',
      'match',
      'include',
      'exclude',
      'exclude-match',
      'run-at',
      'grant',
      'connect',
      'require',
      'resource',
      'noframes',
    };
    for (final key in fields.keys) {
      final localizedNameOrDescription = RegExp(
        r'^(name|description):[A-Za-z0-9_-]+$',
      ).hasMatch(key);
      if (!allowed.contains(key) && !localizedNameOrDescription) {
        errors.add('首版不支持 @$key，禁止启用');
      }
    }
    List<UrlRule> rules(String key) {
      final result = <UrlRule>[];
      for (final pattern in fields[key] ?? <String>[]) {
        try {
          result.add(UrlRule(pattern));
        } on FormatException catch (e) {
          errors.add(e.message.toString());
        }
      }
      return result;
    }

    final matches = [...rules('match'), ...rules('include')];
    final excludes = [...rules('exclude'), ...rules('exclude-match')];
    if (matches.isEmpty) errors.add('至少需要一个有效 @match');
    final grants = (fields['grant'] ?? ['none']).toSet();
    final privileged = grants
        .where((grant) => grant != 'none' && !pageWorldGrants.contains(grant))
        .toSet();
    if (grants.contains('none') && privileged.isNotEmpty) {
      errors.add('@grant none 不能与 GM 特权权限混用');
    }
    for (final grant in grants) {
      if (grant != 'none' &&
          !pageWorldGrants.contains(grant) &&
          !supportedGrants.contains(grant)) {
        errors.add('不支持权限 $grant');
      }
    }
    if (grants.contains('unsafeWindow') && privileged.isNotEmpty) {
      errors.add(
        'unsafeWindow 不能与 GM 特权权限混用：特权脚本必须运行在隔离环境，无法读写网页 window。'
        '请移除 unsafeWindow，或只保留 unsafeWindow（脚本将运行在网页环境，且没有原生存储与网络权限）',
      );
    }
    final runAt = fields['run-at']?.singleOrNull ?? 'document-end';
    if ((fields['run-at']?.length ?? 0) > 1 ||
        !['document-start', 'document-end', 'document-idle'].contains(runAt)) {
      errors.add('不支持 @run-at $runAt');
    }
    final connect = <String>{};
    for (final host in fields['connect'] ?? <String>[]) {
      final normalized = host.toLowerCase();
      if (normalized != '*' &&
          normalized != 'self' &&
          !RegExp(r'^(\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$')
              .hasMatch(normalized)) {
        errors.add('不支持 @connect $host（使用域名、*.域名、self 或 *）');
      } else {
        connect.add(normalized);
      }
    }
    final requires = <Uri>[];
    for (final value in fields['require'] ?? <String>[]) {
      try {
        final url = webUri(value);
        if (url.scheme != 'https') {
          throw const FormatException('@require 必须使用 HTTPS');
        }
        requires.add(url);
      } on FormatException catch (e) {
        errors.add(e.message.toString());
      }
    }
    if (requires.length > 8) errors.add('首版每脚本最多 8 个依赖');
    final resourceEntries = <ScriptResource>[];
    final resourceNames = <String>{};
    for (final value in fields['resource'] ?? <String>[]) {
      final parts = value.split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[0].isEmpty) {
        errors.add('@resource 需要「名称 URL」两个字段');
        continue;
      }
      final name = parts[0];
      if (!resourceNames.add(name)) {
        errors.add('@resource 名称重复：$name');
        continue;
      }
      try {
        final url = webUri(parts.sublist(1).join(' '));
        if (url.scheme != 'https') {
          throw const FormatException('@resource 必须使用 HTTPS');
        }
        resourceEntries.add(ScriptResource(name, url));
      } on FormatException catch (e) {
        errors.add(e.message.toString());
      }
    }
    if (resourceEntries.length > 8) errors.add('首版每脚本最多 8 个 @resource');
    final sourceBytes = utf8.encode(source).length;
    if (sourceBytes > maxScriptBytes) {
      errors.add(
        '脚本 ${(sourceBytes / 1024 / 1024).toStringAsFixed(1)} MiB，超过 16 MiB 运行上限',
      );
    }
    final localizedName = fields.entries
        .where((entry) => entry.key.startsWith('name:'))
        .expand((entry) => entry.value)
        .firstOrNull;
    return ScriptMetadata(
      name: fields['name']?.firstOrNull ?? localizedName ?? '未命名脚本',
      namespace: fields['namespace']?.firstOrNull ?? '',
      version: fields['version']?.firstOrNull ?? '',
      description:
          fields['description']?.firstOrNull ??
          fields['description:zh-CN']?.firstOrNull ??
          '',
      matches: matches,
      excludes: excludes,
      runAt: runAt,
      grants: grants,
      connect: connect,
      requires: requires,
      resources: resourceEntries,
      errors: errors,
    );
  }
}
