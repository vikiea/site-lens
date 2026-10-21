import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../domain/models.dart';
import '../network/transport.dart';

/// Resource guards for subscription input and the compiled bundle. The old
/// 512 KiB platform-channel budget is handled separately by
/// the host payload store, which switches to an app-private file transport.
class FilterLoadLimits {
  const FilterLoadLimits._();

  static const maxSourceBytes = 10 * 1024 * 1024;
  static const maxPayloadBytes = 32 * 1024 * 1024;
  static const maxRuleCount = 300000;
}

class BuiltInFilterSourceSpec {
  const BuiltInFilterSourceSpec({
    required this.key,
    required this.label,
    required this.url,
    required this.license,
    this.fallbackUrls = const <String>[],
  });

  final String key;
  final String label;
  final String url;
  final String license;
  final List<String> fallbackUrls;
}

/// Recommended public lists are seeded as source metadata only. Their rule
/// text is downloaded after the user opens the filter settings and refreshes a
/// source, so APKs do not bundle third-party list contents or stale snapshots.
const builtInFilterSourceSeedVersion = 'v3';
const builtInFilterSources = <BuiltInFilterSourceSpec>[
  BuiltInFilterSourceSpec(
    key: 'easylist',
    label: 'EasyList（广告）',
    url: 'https://easylist-downloads.adblockplus.org/easylist.txt',
    license: 'GPL-3.0',
    fallbackUrls: [
      'https://easylist.to/easylist/easylist.txt',
      'https://filters.adtidy.org/extension/chromium/filters/2.txt',
    ],
  ),
  BuiltInFilterSourceSpec(
    key: 'easyprivacy',
    label: 'EasyPrivacy（跟踪）',
    url: 'https://easylist-downloads.adblockplus.org/easyprivacy.txt',
    license: 'GPL-3.0',
    fallbackUrls: [
      'https://easylist.to/easylist/easyprivacy.txt',
      'https://filters.adtidy.org/extension/chromium/filters/3.txt',
    ],
  ),
  BuiltInFilterSourceSpec(
    key: 'easylistchina',
    label: 'EasyList China（中文广告）',
    url: 'https://easylist-downloads.adblockplus.org/easylistchina.txt',
    license: 'GPL-3.0',
    fallbackUrls: [
      'https://filters.adtidy.org/extension/chromium/filters/224.txt',
    ],
  ),
  BuiltInFilterSourceSpec(
    key: 'ublock-filters',
    label: 'uBlock filters（基础）',
    url: 'https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssets@master/filters/filters.txt',
    license: 'GPL-3.0',
    fallbackUrls: [
      'https://ublockorigin.github.io/uAssets/filters/filters.txt',
      'https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt',
      'https://ghproxy.net/https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt',
      'https://filters.adtidy.org/extension/chromium/filters/2.txt',
    ],
  ),
];

enum FilterResourceType {
  document,
  script,
  image,
  stylesheet,
  font,
  media,
  subdocument,
  xhr,
  other,
}

class FilterRequestContext {
  const FilterRequestContext({
    this.document,
    this.resourceType,
    this.thirdParty,
  });

  final Uri? document;
  final FilterResourceType? resourceType;
  final bool? thirdParty;
}

/// A deliberately small, deterministic rule representation.  The native
/// request callback can evaluate this object without touching disk, Dart, or
/// the network.  Unknown syntax is retained as diagnostics and follows the
/// configured fail-closed default.
class FilterRule {
  const FilterRule({
    required this.pattern,
    required this.block,
    this.cosmetic = false,
    this.hostOnly = false,
    this.domain,
    this.domains = const <String>[],
    this.excludedDomains = const <String>[],
    this.exception = false,
    this.resourceTypes = const <String>{},
    this.thirdParty,
    this.scriptlet,
    this.scriptletArgs = const <String>[],
  });

  final String pattern;
  final bool block;
  final bool cosmetic;
  final bool hostOnly;
  final String? domain;
  final List<String> domains;
  final List<String> excludedDomains;
  final bool exception;
  final Set<String> resourceTypes;
  final bool? thirdParty;

  /// Name of an audited, built-in scriptlet. Remote rule text is never
  /// evaluated as JavaScript; unknown names stay in diagnostics.
  final String? scriptlet;
  final List<String> scriptletArgs;

  /// Narrow host representation; credentials and local file paths never enter
  /// the compiled payload. Kept here so preflight uses the transport encoding.
  Map<String, Object?> toHostJson() => {
    'pattern': pattern,
    if (!block) 'block': false,
    if (cosmetic) 'cosmetic': true,
    if (hostOnly) 'hostOnly': true,
    if (domain != null) 'domain': domain,
    if (domains.isNotEmpty) 'domains': domains,
    if (excludedDomains.isNotEmpty) 'excludedDomains': excludedDomains,
    if (exception) 'exception': true,
    if (resourceTypes.isNotEmpty)
      'resourceTypes': resourceTypes.toList(growable: false),
    if (thirdParty != null) 'thirdParty': thirdParty,
    if (scriptlet != null) 'scriptlet': scriptlet,
    if (scriptletArgs.isNotEmpty) 'scriptletArgs': scriptletArgs,
  };

  bool matches(
    Uri url, {
    FilterRequestContext context = const FilterRequestContext(),
  }) {
    if (cosmetic) return false;
    if (resourceTypes.isNotEmpty &&
        (context.resourceType == null ||
            !resourceTypes.contains(context.resourceType!.name))) {
      return false;
    }
    if (thirdParty != null &&
        (context.thirdParty == null || context.thirdParty != thirdParty)) {
      return false;
    }
    if (domains.isNotEmpty || excludedDomains.isNotEmpty) {
      final documentHost = context.document?.host.toLowerCase();
      if (documentHost == null) return false;
      final excluded = excludedDomains.any(
        (value) => documentHost == value || documentHost.endsWith('.$value'),
      );
      if (excluded) return false;
      if (domains.isNotEmpty &&
          !domains.any(
            (value) =>
                documentHost == value || documentHost.endsWith('.$value'),
          )) {
        return false;
      }
    }
    final target = url.removeFragment().toString().toLowerCase();
    final value = pattern.toLowerCase();
    if (value.isEmpty) return false;
    if (hostOnly || value.startsWith('||')) {
      final raw = value.substring(2);
      final hostEnd = raw.indexOf(RegExp(r'[/^:]'));
      final host = (hostEnd < 0 ? raw : raw.substring(0, hostEnd));
      if (host.isEmpty ||
          !(url.host.toLowerCase() == host ||
              url.host.toLowerCase().endsWith('.$host'))) {
        return false;
      }
      if (hostEnd < 0) return true;
      final suffix = raw.substring(hostEnd);
      if (suffix == '^') return true;
      final targetPath = '${url.path}${url.hasQuery ? '?${url.query}' : ''}';
      final needle = suffix.replaceAll('^', '');
      return targetPath.contains(needle.replaceAll('*', ''));
    }
    final expression = value.split('*').map(RegExp.escape).join('.*');
    return expression.isNotEmpty && RegExp(expression).hasMatch(target);
  }

  bool cosmeticApplies(Uri url) {
    if (!cosmetic) return false;
    final host = url.host.toLowerCase();
    final excluded = excludedDomains.any(
      (value) => host == value || host.endsWith('.$value'),
    );
    if (excluded) return false;
    final included = domains.isEmpty
        ? (domain == null || domain!.trim().isEmpty || domain!.trim() == '*'
              ? const <String>[]
              : <String>[domain!.trim().toLowerCase()])
        : domains;
    if (included.isEmpty) return true;
    return included.any(
      (value) => value == '*' || host == value || host.endsWith('.$value'),
    );
  }
}

class FilterDiagnostic {
  const FilterDiagnostic({
    required this.url,
    required this.decision,
    required this.reason,
  });
  final Uri url;
  final FilterDecision decision;
  final String reason;

  Map<String, Object?> toJson() => {
    'url': redactUrl(url),
    'decision': decision.name,
    'reason': reason,
  };
}

String redactUrl(Uri url) {
  final query = url.queryParameters.keys.map((key) => '$key=…').join('&');
  return Uri(
    scheme: url.scheme,
    userInfo: '',
    host: url.host,
    port: url.hasPort ? url.port : null,
    path: url.path,
    query: query,
  ).toString();
}

class FilterEngine {
  FilterEngine({
    required this.snapshotId,
    required this.rules,
    this.defaultDecision = FilterDecision.allow,
  });

  final String snapshotId;
  final List<FilterRule> rules;
  final FilterDecision defaultDecision;
  int blockedCount = 0;
  int allowedCount = 0;
  int unsupportedCount = 0;

  FilterDecision evaluate(
    Uri url, {
    FilterPolicy policy = const FilterPolicy(),
    FilterRequestContext context = const FilterRequestContext(),
  }) {
    final host = url.host.toLowerCase();
    if (policy.domainExceptions.any((d) => host == d || host.endsWith('.$d'))) {
      allowedCount++;
      return FilterDecision.allow;
    }
    if (policy.blockedDomains.any((d) => host == d || host.endsWith('.$d'))) {
      blockedCount++;
      return FilterDecision.block;
    }
    if (!policy.enabled) {
      allowedCount++;
      return FilterDecision.allow;
    }
    var blocked = false;
    var excepted = false;
    for (final rule in rules) {
      if (!rule.matches(url, context: context)) continue;
      if (rule.exception || !rule.block) {
        excepted = true;
      } else {
        blocked = true;
      }
    }
    if (excepted) {
      allowedCount++;
      return FilterDecision.allow;
    }
    if (blocked) {
      blockedCount++;
      return FilterDecision.block;
    }
    switch (defaultDecision) {
      case FilterDecision.allow:
        allowedCount++;
      case FilterDecision.block:
        blockedCount++;
      case FilterDecision.unsupported:
        unsupportedCount++;
    }
    return defaultDecision;
  }

  Map<String, Object?> get diagnostics => {
    'snapshotId': snapshotId,
    'blocked': blockedCount,
    'allowed': allowedCount,
    'unsupported': unsupportedCount,
    'cosmeticRules': rules.where((rule) => rule.cosmetic).length,
    'degraded': unsupportedCount > 0,
  };

  /// Returns the audited CSS selectors that apply to [url]. Exception rules
  /// are applied after block rules so a site can opt out of one selector.
  List<String> cosmeticSelectors(Uri url) {
    final blocked = <String>{};
    for (final rule in rules.where((rule) => rule.cosmetic)) {
      if (!rule.cosmeticApplies(url)) continue;
      if (rule.exception) {
        blocked.remove(rule.pattern);
      } else if (rule.block) {
        blocked.add(rule.pattern);
      }
    }
    return List.unmodifiable(blocked);
  }

  FilterDiagnostic diagnose(
    Uri url, {
    FilterPolicy policy = const FilterPolicy(),
    FilterRequestContext context = const FilterRequestContext(),
  }) {
    final decision = evaluate(url, policy: policy, context: context);
    final reason = decision == FilterDecision.block
        ? '请求规则命中'
        : decision == FilterDecision.unsupported || unsupportedCount > 0
        ? '规则语义未支持，已按默认策略处理'
        : '未命中请求规则';
    return FilterDiagnostic(url: url, decision: decision, reason: reason);
  }
}

class FilterCompileResult {
  const FilterCompileResult({
    required this.engine,
    required this.unsupportedRules,
  });
  final FilterEngine engine;
  final List<String> unsupportedRules;
}

class FilterCompiler {
  const FilterCompiler();

  FilterCompileResult compile(String source, {required String snapshotId}) {
    final rules = <FilterRule>[];
    final unsupported = <String>[];
    for (final raw in source.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('!') || line.startsWith('[')) {
        continue;
      }
      if (line.contains('#@#+js(')) {
        // Scriptlet exceptions need a paired runtime cancellation model. Do
        // not miscompile them as CSS selectors; report them as unsupported.
        unsupported.add(line);
        continue;
      }
      final cosmeticMatch = RegExp(r'^(?:[^#\s]+)?##(?!\+js)(.+)$')
          .firstMatch(line);
      final exceptionCosmeticMatch = RegExp(r'^(?:[^#\s]+)?#@#(.+)$')
          .firstMatch(line);
      if (cosmeticMatch != null || exceptionCosmeticMatch != null) {
        final cosmetic =
            cosmeticMatch?.group(1) ?? exceptionCosmeticMatch!.group(1)!;
        if (cosmetic.isNotEmpty && _isSupportedCosmeticSelector(cosmetic)) {
          final match = cosmeticMatch ?? exceptionCosmeticMatch!;
          final prefix = match.group(0)!.split('#').first;
          final domains = <String>[];
          final excludedDomains = <String>[];
          for (final rawDomain in prefix.split(',')) {
            final value = rawDomain.trim().toLowerCase();
            if (value.isEmpty || value == '*') continue;
            if (!_isValidDomainToken(value)) {
              domains.clear();
              excludedDomains.clear();
              break;
            }
            if (value.startsWith('~')) {
              final excluded = value.substring(1);
              if (excluded.isEmpty || !_isValidDomainToken(excluded)) {
                domains.clear();
                excludedDomains.clear();
                break;
              }
              excludedDomains.add(excluded);
            } else {
              domains.add(value);
            }
          }
          final domainSyntaxValid =
              prefix.isEmpty ||
              (domains.isNotEmpty || excludedDomains.isNotEmpty) &&
                  prefix.split(',').every((raw) {
                    final value = raw.trim().toLowerCase();
                    return value == '*' || _isValidDomainToken(value);
                  });
          if (!domainSyntaxValid) {
            unsupported.add(line);
            continue;
          }
          rules.add(
            FilterRule(
              pattern: cosmetic,
              block: cosmeticMatch != null,
              cosmetic: true,
              domain: prefix.isEmpty ? '*' : prefix,
              domains: List.unmodifiable(domains),
              excludedDomains: List.unmodifiable(excludedDomains),
              exception: exceptionCosmeticMatch != null,
            ),
          );
        } else {
          unsupported.add(line);
        }
        continue;
      }
      final scriptletMatch = RegExp(
        r'^(?:(\*|[A-Za-z0-9.-]+))?##\+js\(([^,()\s]+)(?:,(.*))?\)$',
      ).firstMatch(line);
      if (scriptletMatch != null) {
        final name = scriptletMatch.group(2)!;
        const supported = {'abort-on-property-read', 'set-constant'};
        if (!supported.contains(name)) {
          unsupported.add(line);
          continue;
        }
        final domain = scriptletMatch.group(1) ?? '*';
        rules.add(
          FilterRule(
            pattern: domain,
            block: false,
            cosmetic: true,
            hostOnly: domain != '*',
            scriptlet: name,
            scriptletArgs: (scriptletMatch.group(3) ?? '')
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .take(4)
                .toList(growable: false),
          ),
        );
        continue;
      }
      final exception = line.startsWith('@@');
      final withoutException = exception ? line.substring(2) : line;
      final optionSeparator = withoutException.indexOf('\$');
      final pattern = optionSeparator < 0
          ? withoutException
          : withoutException.substring(0, optionSeparator);
      final options = optionSeparator < 0
          ? const <String>[]
          : withoutException
                .substring(optionSeparator + 1)
                .split(',')
                .map((value) => value.trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toList(growable: false);
      final hostRule = pattern.startsWith('||');
      if (pattern.contains('##') || pattern.contains('#@#')) {
        unsupported.add(line);
        continue;
      }
      if (!RegExp(r'^[\w.*|:/?=_\-^]+$').hasMatch(pattern)) {
        unsupported.add(line);
        continue;
      }
      final domains = <String>[];
      final excludedDomains = <String>[];
      final resourceTypes = <String>{};
      bool? thirdParty;
      var optionsValid = true;
      for (final option in options) {
        if (option.startsWith('domain=')) {
          for (final rawDomain in option.substring(7).split('|')) {
            if (rawDomain.startsWith('~')) {
              excludedDomains.add(rawDomain.substring(1));
            } else {
              domains.add(rawDomain);
            }
          }
          continue;
        }
        if (option == 'third-party') {
          thirdParty = true;
          continue;
        }
        if (option == '~third-party') {
          thirdParty = false;
          continue;
        }
        const aliases = {
          'document': 'document',
          'subdocument': 'subdocument',
          'script': 'script',
          'image': 'image',
          'stylesheet': 'stylesheet',
          'font': 'font',
          'media': 'media',
          'xhr': 'xhr',
          'xmlhttprequest': 'xhr',
        };
        final type = aliases[option];
        if (type == null) {
          optionsValid = false;
          break;
        }
        resourceTypes.add(type);
      }
      if (!optionsValid ||
          [
            ...domains,
            ...excludedDomains,
          ].any((domain) => !_isValidDomainToken(domain))) {
        unsupported.add(line);
        continue;
      }
      rules.add(
        FilterRule(
          pattern: pattern,
          block: !exception,
          hostOnly: hostRule,
          exception: exception,
          domains: List.unmodifiable(domains),
          excludedDomains: List.unmodifiable(excludedDomains),
          resourceTypes: Set.unmodifiable(resourceTypes),
          thirdParty: thirdParty,
        ),
      );
    }
    final engine = FilterEngine(
      snapshotId: snapshotId,
      rules: List.unmodifiable(rules),
    )..unsupportedCount = unsupported.length;
    return FilterCompileResult(
      engine: engine,
      unsupportedRules: List.unmodifiable(unsupported),
    );
  }

  static bool _isValidDomainToken(String value) {
    final token = value.startsWith('~') ? value.substring(1) : value;
    return token == '*' ||
        RegExp(
          r'^(?:\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$',
          caseSensitive: false,
        ).hasMatch(token);
  }

  static bool _isSupportedCosmeticSelector(String selector) {
    final value = selector.trim();
    if (value.isEmpty || value.length > 256) return false;
    if (value.contains(RegExp(r'[{};]')) ||
        value.toLowerCase().contains(
          RegExp(
            r':(?:has-text|contains|matches-css|xpath|style|remove-attr|remove-class)',
          ),
        )) {
      return false;
    }
    // Keep the native document-start runtime selector-only. This grammar
    // covers ordinary element/class/id/attribute selectors and combinators;
    // anything requiring a rule-specific evaluator is reported unsupported.
    return RegExp(r'''^[A-Za-z0-9_.*#\-\[\]="': >+~(),]+$''').hasMatch(value);
  }
}

/// Atomic snapshot publisher.  It writes a temp file, verifies the digest,
/// then renames it and only afterwards returns the immutable metadata.
class FilterSnapshotStore {
  FilterSnapshotStore({
    Future<Directory> Function()? directoryProvider,
    this.maxRuleCount = FilterLoadLimits.maxRuleCount,
    this.maxPayloadBytes = FilterLoadLimits.maxPayloadBytes,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final int maxRuleCount;
  final int maxPayloadBytes;
  final Future<Directory> Function() _directoryProvider;
  FilterEngine? _active;
  FilterSnapshot? _activeSnapshot;
  FilterEngine? get activeEngine => _active;
  FilterSnapshot? get activeSnapshot => _activeSnapshot;

  void clear() {
    _active = null;
    _activeSnapshot = null;
  }

  void _validateLoadable(FilterEngine engine) {
    if (engine.rules.length > maxRuleCount) {
      throw StateError('过滤规则数量超过内存保护上限（$maxRuleCount 条），请减少启用的规则源');
    }
    // Count the exact JSON/UTF-8 representation one rule at a time. A preflight
    // must not build an additional complete map/JSON/byte copy of the bundle.
    var size = 2; // []
    for (var index = 0; index < engine.rules.length; index++) {
      size += utf8.encode(jsonEncode(engine.rules[index].toHostJson())).length;
      if (index > 0) size++;
      if (size > maxPayloadBytes) {
        throw StateError(
          '过滤规则超过内存保护上限（${maxPayloadBytes ~/ (1024 * 1024)} MiB），请减少启用的规则源',
        );
      }
    }
  }

  Future<FilterSnapshot> publish({
    required String id,
    required int? sourceId,
    required String version,
    required Uri sourceUrl,
    required String source,
    required String fileRef,
    bool activate = true,
  }) async {
    final compiled = const FilterCompiler().compile(source, snapshotId: id);
    _validateLoadable(compiled.engine);
    final bytes = utf8.encode(source);
    final digest = sha256.convert(bytes).toString();
    final directory = await _directoryProvider();
    final root = Directory('${directory.path}/filter_snapshots');
    await root.create(recursive: true);
    final safeRef = _safeFileRef(fileRef);
    final destination = File('${root.path}/$safeRef.rules');
    final staging = File('${root.path}/.$safeRef.tmp');
    try {
      await staging.writeAsBytes(bytes, flush: true);
      final check = sha256.convert(await staging.readAsBytes()).toString();
      if (check != digest) throw StateError('规则快照摘要不匹配');
      await staging.rename(destination.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete();
      rethrow;
    }
    final snapshot = FilterSnapshot(
      id: id,
      sourceId: sourceId,
      version: version,
      sourceUrl: sourceUrl,
      sha256: digest,
      state: compiled.unsupportedRules.isEmpty
          ? FilterSnapshotState.valid
          : FilterSnapshotState.degraded,
      createdAt: DateTime.now().toUtc(),
      fileRef: destination.path,
      unsupportedRuleCount: compiled.unsupportedRules.length,
    );
    if (activate) {
      _active = compiled.engine;
      _activeSnapshot = snapshot;
    }
    return snapshot;
  }

  static String _safeFileRef(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      throw const FormatException('规则快照文件名无效');
    }
    return cleaned.length > 160 ? cleaned.substring(0, 160) : cleaned;
  }

  Future<FilterCompileResult> load(FilterSnapshot snapshot) async {
    if (snapshot.state == FilterSnapshotState.corrupt ||
        snapshot.fileRef.isEmpty) {
      throw StateError('规则快照不可用');
    }
    final result = await compileSnapshot(snapshot);
    _active = result.engine;
    _activeSnapshot = snapshot;
    return result;
  }

  Future<FilterCompileResult> compileSnapshot(FilterSnapshot snapshot) async {
    if (snapshot.state == FilterSnapshotState.corrupt ||
        snapshot.fileRef.isEmpty) {
      throw StateError('规则快照不可用');
    }
    final file = File(snapshot.fileRef);
    if (!await file.exists()) throw StateError('规则快照文件缺失');
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != snapshot.sha256) {
      throw StateError('规则快照文件摘要不匹配');
    }
    final result = const FilterCompiler().compile(
      utf8.decode(bytes),
      snapshotId: snapshot.id,
    );
    _validateLoadable(result.engine);
    return result;
  }
}

/// Downloads, compiles and atomically publishes a rule source. A failed
/// refresh leaves the previous active snapshot untouched and records only a
/// redacted error in metadata.
class FilterSourceManager {
  FilterSourceManager({
    required this.store,
    this.db,
    ControlledHttp? http,
    this.maxBytes = FilterLoadLimits.maxSourceBytes,
  }) : http = http ?? ControlledHttp();

  final FilterSnapshotStore store;
  final AppDatabase? db;
  final ControlledHttp http;
  final int maxBytes;

  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<FilterSnapshot?> setEnabled(int id, bool enabled) => _serial(
    () => _changeSelection(
      (database) => database.customStatement(
        'UPDATE filter_sources SET enabled=? WHERE id=?',
        [enabled ? 1 : 0, id],
      ),
    ),
  );

  Future<FilterSnapshot?> delete(int id) => _serial(
    () => _changeSelection((database) => database.deleteFilterSource(id)),
  );

  Future<FilterSnapshot?> _changeSelection(
    Future<void> Function(AppDatabase) change,
  ) async {
    final previousEngine = store._active;
    final previousSnapshot = store._activeSnapshot;
    try {
      return await db!.transaction(() async {
        await change(db!);
        return _rebuildBundle();
      });
    } catch (_) {
      // Roll back the in-memory installation along with Drift's transaction.
      // This also preserves the exact engine already bound to live hosts.
      store._active = previousEngine;
      store._activeSnapshot = previousSnapshot;
      rethrow;
    }
  }

  /// Rebuilds one deterministic active bundle from the newest usable snapshot
  /// of every source. Existing source snapshots remain independently stored so
  /// a failed refresh can fall back without losing the previous source.
  Future<FilterSnapshot?> rebuildBundle() => _serial(_rebuildBundle);

  Future<FilterSnapshot?> _rebuildBundle({
    bool allowHistoricalFallback = true,
  }) async {
    final database = db;
    if (database == null) return store.activeSnapshot;
    final sourceSnapshots = await database.latestFilterSnapshotsBySource();
    final snapshotsBySource = <int, FilterSnapshot>{
      for (final snapshot in sourceSnapshots)
        if (snapshot.sourceId != null) snapshot.sourceId!: snapshot,
    };
    if (snapshotsBySource.isEmpty) {
      store.clear();
      return null;
    }
    final parts = <String>[];
    var unsupported = 0;
    final enabledMetadata = (await database.filterSources())
        .where((source) => source.enabled)
        .toList();
    final members = enabledMetadata.map((source) => source.id).toList()..sort();
    final selectedSnapshots = [
      for (final id in members)
        if (snapshotsBySource[id] != null) snapshotsBySource[id]!,
    ];
    final selection = [
      for (final id in members)
        [
          id,
          enabledMetadata
              .firstWhere((source) => source.id == id)
              .url
              .toString(),
          snapshotsBySource[id]?.id ?? '',
          snapshotsBySource[id]?.sha256 ?? '',
        ],
    ];
    final version =
        'bundle-v3-${sha256.convert(utf8.encode(jsonEncode(selection)))}';
    try {
      for (final snapshot in selectedSnapshots.reversed) {
        final sourceId = snapshot.sourceId;
        if (sourceId == null) continue;
        final compiled = await store.compileSnapshot(snapshot);
        unsupported += snapshot.unsupportedRuleCount;
        parts.add('! Site Lens source ${snapshot.sourceId}\n');
        parts.addAll(compiled.engine.rules.map((rule) => _ruleToSource(rule)));
      }
    } catch (error, stack) {
      if (!allowHistoricalFallback) Error.throwWithStackTrace(error, stack);
      for (final bundle in await database.filterBundles(version)) {
        try {
          await store.load(bundle);
          return bundle;
        } catch (_) {
          // Try another verified bundle with the exact same source selection.
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
    final source = parts.join('\n');
    final first = selectedSnapshots.isNotEmpty
        ? selectedSnapshots.first
        : sourceSnapshots.first;
    final bundleId =
        'filter-bundle-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final bundle = await store.publish(
      id: bundleId,
      sourceId: null,
      version: version,
      sourceUrl: first.sourceUrl,
      source: source,
      fileRef: 'bundle-${sha256.convert(utf8.encode(source)).toString()}',
    );
    final result = bundle.unsupportedRuleCount == unsupported
        ? bundle
        : FilterSnapshot(
            id: bundle.id,
            sourceId: bundle.sourceId,
            version: bundle.version,
            sourceUrl: bundle.sourceUrl,
            sha256: bundle.sha256,
            state: unsupported == 0
                ? FilterSnapshotState.valid
                : FilterSnapshotState.degraded,
            createdAt: bundle.createdAt,
            fileRef: bundle.fileRef,
            unsupportedRuleCount: unsupported,
            error: unsupported == 0 ? null : '已合并；$unsupported 条规则语法未支持',
          );
    await database.saveFilterSnapshot(result);
    await store.load(result);
    return result;
  }

  String _ruleToSource(FilterRule rule) {
    if (rule.scriptlet != null) {
      final domain = rule.pattern == '*' ? '' : rule.pattern;
      final args = rule.scriptletArgs.join(',');
      return '$domain##+js(${rule.scriptlet}${args.isEmpty ? '' : ',$args'})';
    }
    if (rule.cosmetic) {
      final included = rule.domains.isEmpty
          ? [if (rule.domain != null && rule.domain != '*') rule.domain!]
          : rule.domains;
      final domains = [
        ...included,
        ...rule.excludedDomains.map((domain) => '~$domain'),
      ].join(',');
      return '$domains${rule.exception ? '#@#' : '##'}${rule.pattern}';
    }
    final options = <String>[];
    if (rule.domains.isNotEmpty || rule.excludedDomains.isNotEmpty) {
      final domainOptions = [
        ...rule.domains,
        ...rule.excludedDomains.map((domain) => '~$domain'),
      ]..sort();
      options.add('domain=${domainOptions.join('|')}');
    }
    if (rule.thirdParty == true) options.add('third-party');
    if (rule.thirdParty == false) options.add('~third-party');
    final resourceTypes = rule.resourceTypes.toList()..sort();
    options.addAll(resourceTypes);
    final suffix = options.isEmpty ? '' : '\$${options.join(',')}';
    return '${rule.exception ? '@@' : ''}${rule.pattern}$suffix';
  }

  List<Uri> _candidateUrls(FilterSource source) {
    final spec = builtInFilterSources.where(
      (item) => item.label == source.label,
    );
    final urls = <String>[source.url.toString()];
    if (spec.isNotEmpty) urls.addAll(spec.first.fallbackUrls);
    return urls.map(webUri).toSet().toList(growable: false);
  }

  Future<FilterSnapshot> refresh(
    FilterSource source, {
    Cancellation? cancellation,
  }) => _serial(() => _refresh(source, cancellation: cancellation));

  Future<FilterSnapshot> _refresh(
    FilterSource source, {
    Cancellation? cancellation,
  }) async {
    if (db != null) {
      source =
          (await db!.filterSources())
              .where((item) => item.id == source.id)
              .firstOrNull ??
          (throw StateError('规则源不存在'));
    }
    final cancel = cancellation ?? Cancellation();
    final previous = store.activeSnapshot;
    final previousEngine = store.activeEngine;
    final pending = FilterSource(
      id: source.id,
      label: source.label,
      url: source.url,
      profileId: source.profileId,
      kind: source.kind,
      enabled: source.enabled,
      version: source.version,
      license: source.license,
      sha256: source.sha256,
      status: FilterSourceStatus.downloading,
      fileRef: source.fileRef,
      refreshedAt: source.refreshedAt,
      error: null,
    );
    await db?.saveFilterSource(pending);
    try {
      FetchResponse? response;
      Object? lastError;
      for (final url in _candidateUrls(source)) {
        try {
          final candidate = await http.fetch(
            url,
            connect: const {'*'},
            document: url,
            cancel: cancel,
            maxBytes: maxBytes,
          );
          if (candidate.status < 200 || candidate.status >= 300) {
            throw StateError('规则源 HTTP ${candidate.status}');
          }
          response = candidate;
          break;
        } catch (error) {
          lastError = error;
          cancel.check();
          // Android installations may expose the site through a configured
          // system proxy while a direct socket is unavailable. Built-in lists
          // are fixed public hosts, so retry them through the platform HTTP
          // stack without extending this path to arbitrary user URLs.
          if (db != null && source.kind == 'builtin') {
            try {
              final candidate = await _fetchThroughPlatform(
                url,
                cancel,
                maxBytes,
              );
              if (candidate.status < 200 || candidate.status >= 300) {
                throw StateError('规则源 HTTP ${candidate.status}');
              }
              response = candidate;
              break;
            } catch (platformError) {
              lastError = platformError;
              cancel.check();
            }
          }
        }
      }
      final loaded = response ?? (throw lastError ?? StateError('规则源不可用'));
      final text = utf8.decode(loaded.bytes);
      cancel.check();
      final id =
          'filter-${source.id}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      final snapshot = await store.publish(
        id: id,
        sourceId: source.id,
        version: source.version,
        sourceUrl: loaded.url,
        source: text,
        fileRef: '$id-${sha256.convert(loaded.bytes)}',
        activate: db == null,
      );
      if (db == null) return snapshot;
      return await db!.transaction(() async {
        await db!.saveFilterSnapshot(snapshot);
        await db!.saveFilterSource(
          FilterSource(
            id: source.id,
            label: source.label,
            // Keep the subscription identity stable across mirror fallback.
            // The actual transport URL belongs to the snapshot metadata.
            url: source.url,
            profileId: source.profileId,
            kind: source.kind,
            enabled: source.enabled,
            version: source.version,
            license: source.license,
            sha256: snapshot.sha256,
            status: snapshot.state == FilterSnapshotState.valid
                ? FilterSourceStatus.valid
                : FilterSourceStatus.degraded,
            fileRef: snapshot.fileRef,
            refreshedAt: snapshot.createdAt,
            error: snapshot.state == FilterSnapshotState.valid
                ? null
                : '已缓存；${snapshot.unsupportedRuleCount} 条规则语法未支持',
          ),
        );
        final bundle = await _rebuildBundle(allowHistoricalFallback: false);
        if (bundle == null) throw StateError('没有可用规则快照');
        return bundle;
      });
    } catch (error) {
      // Roll back the active pointers with the source/bundle database transaction.
      store._active = previousEngine;
      store._activeSnapshot = previous;
      await db?.saveFilterSource(
        FilterSource(
          id: source.id,
          label: source.label,
          url: source.url,
          profileId: source.profileId,
          kind: source.kind,
          enabled: source.enabled,
          version: source.version,
          license: source.license,
          sha256: source.sha256,
          status: FilterSourceStatus.failed,
          fileRef: source.fileRef,
          refreshedAt: source.refreshedAt,
          error: readableError(error),
        ),
      );
      rethrow;
    }
  }

  Future<FetchResponse> _fetchThroughPlatform(
    Uri url,
    Cancellation cancel,
    int maxBytes,
  ) async {
    final client = HttpClient()
      ..findProxy = HttpClient.findProxyFromEnvironment;
    cancel.onCancel(() => client.close(force: true));
    var current = url;
    try {
      for (var redirects = 0; redirects <= 5; redirects++) {
        cancel.check();
        NetworkPolicy.validateTarget(current, const {'*'}, url);
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Site-Lens filter refresh',
        );
        final response = await request.close();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
            location != null) {
          if (redirects == 5) throw StateError('规则源重定向过多');
          final next = webUri(current.resolve(location).toString());
          if (current.scheme == 'https' && next.scheme != 'https') {
            throw StateError('规则源禁止 HTTPS 降级');
          }
          current = next;
          continue;
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          cancel.check();
          if (bytes.length + chunk.length > maxBytes) {
            throw StateError('规则源超过 $maxBytes 字节');
          }
          bytes.addAll(chunk);
        }
        final headers = <String, String>{};
        response.headers.forEach((key, values) {
          headers[key] = values.join(', ');
        });
        return FetchResponse(
          url: current,
          status: response.statusCode,
          bytes: bytes,
          headers: headers,
        );
      }
      throw StateError('规则源重定向过多');
    } finally {
      client.close(force: true);
    }
  }
}

class FilterPolicyResolver {
  const FilterPolicyResolver();

  FilterPolicy resolve({
    FilterPolicy global = const FilterPolicy(),
    FilterPolicy? profile,
    Uri? domain,
  }) {
    final selected = profile ?? global;
    if (domain == null) return selected;
    final host = domain.host.toLowerCase();
    final exception = selected.domainExceptions.any(
      (d) => host == d || host.endsWith('.$d'),
    );
    return exception ? selected.copyWith(enabled: false) : selected;
  }
}
