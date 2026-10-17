import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../domain/models.dart';
import '../network/transport.dart';

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
  });

  final String pattern;
  final bool block;
  final bool cosmetic;
  final bool hostOnly;

  bool matches(Uri url) {
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
  return url.replace(query: query, fragment: '').toString();
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
  };

  FilterDiagnostic diagnose(
    Uri url, {
    FilterPolicy policy = const FilterPolicy(),
  }) {
    final decision = evaluate(url, policy: policy);
    return FilterDiagnostic(
      url: url,
      decision: decision,
      reason: decision == FilterDecision.block ? '规则命中' : '未命中规则',
    );
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
      if (line.startsWith('##') || line.startsWith('#@#')) {
        if (line.length > 3) {
          rules.add(
            FilterRule(
              pattern: line.substring(line.indexOf('#') + 2),
              block: true,
              cosmetic: true,
            ),
          );
        } else {
          unsupported.add(line);
        }
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
      final response = await http.fetch(
        source.url,
        connect: const {'*'},
        document: source.url,
        cancel: cancel,
        maxBytes: maxBytes,
      );
      if (response.status < 200 || response.status >= 300) {
        throw StateError('规则源 HTTP ${response.status}');
      }
      final text = utf8.decode(response.bytes);
      cancel.check();
      final id =
          'filter-${source.id}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      final snapshot = await store.publish(
        id: id,
        sourceId: source.id,
        version: source.version,
        sourceUrl: response.url,
        source: text,
        fileRef: source.fileRef ?? 'source-${source.id}',
      );
      await db?.saveFilterSnapshot(snapshot);
      await db?.saveFilterSource(
        FilterSource(
          id: source.id,
          label: source.label,
          url: source.url,
          profileId: source.profileId,
          kind: source.kind,
          version: source.version,
          license: source.license,
          sha256: snapshot.sha256,
          status: snapshot.state == FilterSnapshotState.valid
              ? FilterSourceStatus.valid
              : FilterSourceStatus.failed,
          fileRef: snapshot.fileRef,
          refreshedAt: snapshot.createdAt,
          error: snapshot.state == FilterSnapshotState.valid
              ? null
              : '规则存在未支持语法',
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
          error: error.toString().replaceAll(
            RegExp(r'https?://[^ ]+'),
            '<url>',
          ),
        ),
      );
      rethrow;
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
