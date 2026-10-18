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

  /// StandardMessageCodec ultimately crosses Android Binder. Refuse an
  /// oversized rule payload before the native call so a large public list
  /// degrades visibly instead of crashing the WebView or Flutter process.
  static const maxFilterRulePayloadBytes = 512 * 1024;

  static const safeFilterSnapshotFields = <String>{
    'id',
    'version',
    'sha256',
    'state',
    'rules',
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
  }) {
    final rules =
        engine?.rules
            .map(
              (rule) => <String, Object?>{
                'pattern': rule.pattern,
                'block': rule.block,
                'cosmetic': rule.cosmetic,
                'hostOnly': rule.hostOnly,
                'domain': rule.domain,
                'domains': rule.domains,
                'excludedDomains': rule.excludedDomains,
                'exception': rule.exception,
                'resourceTypes': rule.resourceTypes.toList(growable: false),
                'thirdParty': rule.thirdParty,
                'scriptlet': rule.scriptlet,
                'scriptletArgs': rule.scriptletArgs,
              },
            )
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
    final encodedRules = jsonEncode(rules);
    if (encodedRules.length > maxFilterRulePayloadBytes) {
      throw StateError('过滤快照过大，当前宿主暂不加载');
    }
    return FilterSnapshotDto(
      id: value?.id ?? '',
      version: value?.version ?? '',
      sha256: value?.sha256 ?? '',
      state: value?.state.name ?? FilterSnapshotState.missing.name,
      rules: encodedRules,
    );
  }
}
