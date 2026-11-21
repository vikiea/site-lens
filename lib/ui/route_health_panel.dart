import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/route_health.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

/// 站点详情页上的 出口与基站 panel (ADR-0006).
///
/// It answers three questions the badge alone cannot: which 出口 are usable
/// right now, which base stations the app is talking to, and — when something
/// failed — which 出口 failed and why. It is presentation only: nothing here
/// sorts, ranks or recommends, and the aggregate badge comes straight from
/// [RouteDetailView.record].
class RouteHealthPanel extends StatelessWidget {
  const RouteHealthPanel({super.key, required this.view});

  final RouteDetailView view;

  @override
  Widget build(BuildContext context) {
    final record = view.record;
    final aggregate = record.state;
    return SiteLensPanel(
      key: const ValueKey('route-health-panel'),
      scrollingContent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              KeyedSubtree(
                key: const ValueKey('route-health-badge'),
                child: _aggregateBadge(context, aggregate),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  routeFailureSentence(record) ?? '各出口的可用性',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _routeRows(context),
          const SizedBox(height: 14),
          _stations(context),
        ],
      ),
    );
  }

  Widget _aggregateBadge(BuildContext context, ProfileHealthState state) {
    final colors = SiteLensColors.of(context);
    final (color, icon) = switch (state) {
      ProfileHealthState.ok => (colors.ok, Icons.check_circle_outline),
      ProfileHealthState.failing => (colors.danger, Icons.error_outline),
      ProfileHealthState.unknown => (
        Theme.of(context).colorScheme.outline,
        Icons.help_outline,
      ),
    };
    return SiteLensStatusBadge(
      label: healthLabel(state),
      icon: icon,
      color: color,
      compact: true,
    );
  }

  Widget _routeRows(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SiteLensColors.of(context);
    return Column(
      key: const ValueKey('route-health-routes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final route in view.attemptedRoutes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_routeIcon(route), size: 18, color: colors.divider),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        routeLabel(route),
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        _routeDetail(view.observationFor(route)),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _routeDetail(RouteObservation? observation) {
    final state = observation?.effectiveState ?? RouteHealthState.unknown;
    final at = observation?.checkedAt;
    final when = at == null ? '' : ' · ${_clock(at)}';
    return switch (state) {
      RouteHealthState.ok => '可用$when',
      RouteHealthState.unknown => '未检查',
      RouteHealthState.failing =>
        '${routeFailureCategoryLabel(observation?.effectiveCategory) ?? '不可用'}'
            '${_failedHost(observation)}',
    };
  }

  String _failedHost(RouteObservation? observation) {
    final host = observation?.failedPage?.host;
    return host == null ? '' : ' · $host';
  }

  Widget _stations(BuildContext context) {
    final theme = Theme.of(context);
    final stations = view.currentStations;
    return Column(
      key: const ValueKey('route-health-stations'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SiteLensSectionHeader(
          title: '当前可用基站',
          // The empty answer lives in the subtitle, so the words appear once
          // and a reader never has to tell a header from a body line.
          subtitle: stations.isEmpty ? '当前没有可用基站' : '共 ${stations.length} 个',
        ),
        if (stations.isNotEmpty)
          for (final station in stations)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    station.preferred ? Icons.star : Icons.dns_outlined,
                    size: 16,
                    color: station.preferred
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SiteLensCopyableText(
                      text: _originText(station.origin),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (station.preferred)
                    Text('首选', style: theme.textTheme.labelSmall),
                ],
              ),
            ),
      ],
    );
  }

  static String _originText(Uri origin) => origin.hasPort
      ? '${origin.scheme}://${origin.host}:${origin.port}'
      : '${origin.scheme}://${origin.host}';

  static IconData _routeIcon(SiteRoute route) => switch (route) {
    SiteRoute.direct => Icons.settings_ethernet,
    SiteRoute.browse => Icons.public,
  };
}

String _clock(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
