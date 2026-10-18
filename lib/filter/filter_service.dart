import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../domain/models.dart';
import '../network/transport.dart';

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

  /// Name of an audited, built-in scriptlet. Remote rule text is never
  /// evaluated as JavaScript; unknown names stay in diagnostics.
  final String? scriptlet;
  final List<String> scriptletArgs;

  bool matches(Uri url) {
    if (cosmetic) return false;
    final target = url.removeFragment().toString().toLowerCase();
    final value = pattern.toLowerCase();
    if (value.isEmpty) return false;
    if (hostOnly || value.startsWith('||')) {
      final host = value.substring(2).split(RegExp(r'[/:^]')).first;
      return host.isNotEmpty &&
          (url.host.toLowerCase() == host ||
              url.host.toLowerCase().endsWith('.$host'));
    }
    final needle = value.replaceAll('*', '');
    return needle.isNotEmpty && target.contains(needle);
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
    for (final rule in rules) {
      if (rule.matches(url)) {
        if (rule.block) {
          blockedCount++;
        } else {
          allowedCount++;
        }
        return rule.block ? FilterDecision.block : FilterDecision.allow;
      }
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
  }) {
    final decision = evaluate(url, policy: policy);
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
      final exception = line.startsWith('@@||');
      final hostRule = line.startsWith('||') || line.startsWith('@@||');
      final pattern = exception ? line.substring(2) : line;
      if (pattern.contains('##') || pattern.contains('#@#')) {
        unsupported.add(line);
        continue;
      }
      if (!RegExp(r'^[\w.*|:/?=_\-^$]+$').hasMatch(pattern)) {
        unsupported.add(line);
        continue;
      }
      rules.add(
        FilterRule(pattern: pattern, block: !exception, hostOnly: hostRule),
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
  FilterSnapshotStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  FilterEngine? _active;
  FilterSnapshot? _activeSnapshot;
  FilterEngine? get activeEngine => _active;
  FilterSnapshot? get activeSnapshot => _activeSnapshot;

  void clear() {
    _active = null;
    _activeSnapshot = null;
  }

  Future<FilterSnapshot> publish({
    required String id,
    required int? sourceId,
    required String version,
    required Uri sourceUrl,
    required String source,
    required String fileRef,
  }) async {
    final bytes = utf8.encode(source);
    final digest = sha256.convert(bytes).toString();
    final directory = await _directoryProvider();
    final root = Directory('${directory.path}/filter_snapshots');
    await root.create(recursive: true);
    final safeRef = _safeFileRef(fileRef);
    final destination = File('${root.path}/$safeRef.rules');
    final staging = File('${root.path}/.$safeRef.tmp');
    final compiled = const FilterCompiler().compile(source, snapshotId: id);
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
    _active = compiled.engine;
    _activeSnapshot = snapshot;
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
    _active = result.engine;
    _activeSnapshot = snapshot;
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
    this.maxBytes = 10 * 1024 * 1024,
  }) : http = http ?? ControlledHttp();

  final FilterSnapshotStore store;
  final AppDatabase? db;
  final ControlledHttp http;
  final int maxBytes;

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
  }) async {
    final cancel = cancellation ?? Cancellation();
    final previous = store.activeSnapshot;
    final pending = FilterSource(
      id: source.id,
      label: source.label,
      url: source.url,
      profileId: source.profileId,
      kind: source.kind,
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
        fileRef: source.fileRef ?? 'source-${source.id}',
      );
      await db?.saveFilterSnapshot(snapshot);
      await db?.saveFilterSource(
        FilterSource(
          id: source.id,
          label: source.label,
          url: loaded.url,
          profileId: source.profileId,
          kind: source.kind,
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
              : '已生效；${snapshot.unsupportedRuleCount} 条规则语法未支持',
        ),
      );
      return snapshot;
    } catch (error) {
      // The active store intentionally remains on [previous]. Keep this local
      // fallback assertion as a regression guard for future store changes.
      assert(identical(previous, store.activeSnapshot));
      await db?.saveFilterSource(
        FilterSource(
          id: source.id,
          label: source.label,
          url: source.url,
          profileId: source.profileId,
          kind: source.kind,
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
