import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../filter/filter_service.dart';
import '../web_host/native_hosts.dart';
import 'glass_surface.dart';

/// Explains the filter snapshot bound to the current document.
///
/// This panel only displays metadata and redacted counters. It deliberately
/// never reads rule source, cookies, Web Storage, authorization headers or a
/// native cache path.
class FilterDiagnosticsPanel extends StatelessWidget {
  const FilterDiagnosticsPanel({
    super.key,
    required this.session,
    required this.engine,
    required this.snapshot,
    required this.policy,
  });

  final HostSession? session;
  final FilterEngine? engine;
  final FilterSnapshot? snapshot;
  final FilterPolicy policy;

  @override
  Widget build(BuildContext context) {
    final diagnostics = engine?.diagnostics ?? const <String, Object?>{};
    final currentUrl = session?.url;
    final state = snapshot?.state.name ?? FilterSnapshotState.missing.name;
    final reason = _degradedReason();
    return SiteLensGlassSurface(
      role: SiteLensSurfaceRole.panel,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('过滤诊断', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              reason ?? (policy.enabled ? '当前文档使用过滤策略' : '过滤策略已关闭'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            _line(context, '当前文档', _redactedCurrentUrl(currentUrl)),
            _line(context, '快照状态', state),
            _line(context, '快照版本', snapshot?.version ?? '无有效快照'),
            _line(context, '快照摘要', _shortHash(snapshot?.sha256)),
            _line(
              context,
              '阻止请求',
              '${session?.filterBlocked ?? diagnostics['blocked'] ?? 0}',
            ),
            _line(
              context,
              '放行请求',
              '${session?.filterAllowed ?? diagnostics['allowed'] ?? 0}',
            ),
            _line(
              context,
              '未支持规则',
              '${snapshot?.unsupportedRuleCount ?? diagnostics['unsupported'] ?? 0}',
            ),
            _line(context, '页面规则', '${diagnostics['cosmeticRules'] ?? 0}'),
          ],
        ),
      ),
    );
  }

  String? _degradedReason() {
    final current = session;
    if (current?.errorKind == 'filterUnavailable') {
      return '当前宿主未提供过滤接口，已降级并保留可证明的请求策略';
    }
    if (current != null && !current.capabilities.documentStart) {
      return '宿主不支持 document-start，页面规则和脚本化页面过滤已关闭';
    }
    if (snapshot?.state == FilterSnapshotState.degraded) {
      final count = snapshot?.unsupportedRuleCount ?? 0;
      return '当前使用安全兼容编译器；基础请求和页面规则继续生效，$count 条高级 uBlock 语法未执行。完整支持需要接入完整 uBlock 解析器和脚本运行时。';
    }
    if (snapshot?.state == FilterSnapshotState.failed ||
        snapshot?.state == FilterSnapshotState.corrupt) {
      return '快照不可用，继续使用上一有效快照或放行策略';
    }
    return null;
  }

  String _redactedCurrentUrl(String? value) {
    if (value == null || value.isEmpty) return '尚未加载';
    try {
      return redactUrl(Uri.parse(value));
    } catch (_) {
      return '地址不可用';
    }
  }

  String _shortHash(String? value) {
    if (value == null || value.isEmpty) return '无';
    return value.length <= 12 ? value : '${value.substring(0, 12)}…';
  }

  Widget _line(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
