import 'dart:convert';

import '../domain/models.dart';
import '../filter/filter_service.dart';
import 'web_host.g.dart';

/// Converts the immutable Dart filter model to the narrow Pigeon contract.
///
/// The generated Pigeon records are intentionally mutable and may be extended
/// by a future host implementation. Keeping the allow-list and the conversion
/// here makes a review fail loudly when credentials, storage or local paths are
/// accidentally added to the native boundary.
class HostDtoCodec {
  const HostDtoCodec._();

  /// Application budget for an inline platform-channel message. Larger rules
  /// use the verified private-file transport prepared by FilterPayloadStore.
  static const maxFilterRulePayloadBytes = 512 * 1024;

  static const safeFilterSnapshotFields = <String>{
    'id',
    'version',
    'sha256',
    'state',
    'rules',
    'rulesFileId',
    'rulesBytes',
  };

  static const safeFilterPolicyFields = <String>{
    'enabled',
    'pageFiltering',
    'domainExceptions',
    'blockedDomains',
  };

  static const safeFilterContextFields = <String>{
    'hostId',
    'generation',
    'sourceUrl',
    'snapshotId',
  };

  static const sensitiveFieldNames = <String>{
    'cookie',
    'cookies',
    'authorization',
    'webStorage',
    'localPath',
    'nativePath',
    'capabilityToken',
    'gmValues',
  };

  static HostFilterContextDto context(HostFilterContext value) =>
      HostFilterContextDto(
        hostId: value.hostId,
        generation: value.generation,
        sourceUrl: value.sourceUrl.toString(),
        snapshotId: value.snapshotId,
      );

  static FilterPolicyDto policy(FilterPolicy value) => FilterPolicyDto(
    enabled: value.enabled,
    pageFiltering: value.pageFiltering,
    domainExceptions: value.domainExceptions.toList(growable: false),
    blockedDomains: value.blockedDomains.toList(growable: false),
  );

  static FilterSnapshotDto snapshot({
    FilterSnapshot? value,
    FilterEngine? engine,
    String? rulesJson,
  }) {
    final encodedRules = rulesJson ?? encodeRules(engine?.rules ?? const []);
    if (utf8.encode(encodedRules).length > maxFilterRulePayloadBytes) {
      throw StateError('过滤快照需要应用内文件装载');
    }
    return FilterSnapshotDto(
      id: value?.id ?? '',
      version: value?.version ?? '',
      sha256: value?.sha256 ?? '',
      state: value?.state.name ?? FilterSnapshotState.missing.name,
      rules: encodedRules,
    );
  }

  static String encodeRules(List<FilterRule> rules) =>
      encodeRuleMaps(rules.map(encodeRule).toList(growable: false));

  static Map<String, Object?> encodeRule(FilterRule rule) => rule.toHostJson();

  static String encodeRuleMaps(List<Map<String, Object?>> rules) =>
      jsonEncode(rules);
}
