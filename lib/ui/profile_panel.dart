import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'browser_entry.dart';
import 'glass_surface.dart';
import 'ui_util.dart';
import 'ui_primitives.dart';

/// First screen of the product: one panel card per curated site profile.
class ProfilesPanel extends StatelessWidget {
  const ProfilesPanel({
    super.key,
    required this.app,
    required this.onOpen,
    this.onEnterProfile,
    required this.onResume,
  });
  final AppController app;
  final void Function(SiteProfile) onOpen;
  final Future<void> Function(SiteProfile)? onEnterProfile;

  /// Returns to the running browsing session, shown as an in-page row.
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => RefreshIndicator(
      onRefresh: app.detect,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          4,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          ResumeBrowserBar(app: app, onResume: onResume),
          if (app.activeBrowser != null)
            const SizedBox(height: SiteLensMetrics.itemGap),
          if (app.probes.running || app.refreshing)
            const Padding(
              padding: EdgeInsets.only(bottom: SiteLensMetrics.itemGap),
              child: LinearProgressIndicator(),
            ),
          if (app.error != null) ...[
            SiteLensErrorBanner(text: app.error!, onDismiss: app.clearError),
            const SizedBox(height: SiteLensMetrics.itemGap),
          ],
          const SizedBox(height: SiteLensMetrics.itemGap),
          if (app.profiles.isEmpty)
            SiteLensEmptyState(
              icon: Icons.travel_explore,
              title: '还没有站点档案',
              message: '添加一个发布页，先检测，再按当前可用性进入站点。',
              action: FilledButton.icon(
                onPressed: () => showAddProfileDialog(context, app),
                icon: const Icon(Icons.add_link),
                label: const Text('添加站点'),
              ),
            ),
          for (final profile in app.profiles) ...[
            _ProfileCard(
              app: app,
              profile: profile,
              onOpen: () => onOpen(profile),
              onEnter: () => safely(context, () async {
                if (onEnterProfile != null) {
                  await onEnterProfile!(profile);
                } else {
                  onOpen(profile);
                }
              }),
            ),
            const SizedBox(height: SiteLensMetrics.listGap),
          ],
        ],
      ),
    ),
  );
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.app,
    required this.profile,
    required this.onOpen,
    required this.onEnter,
  });
  final AppController app;
  final SiteProfile profile;
  final VoidCallback onOpen;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = SiteLensColors.of(context);
    final ledger = app.probeLedgerFor(profile.id);
    final liveReady = ledger.live
        ? ledger.results.where((result) => result.verified).firstOrNull
        : null;
    final staleReady = app.latestReadyFor(profile.id);
    final recommended = liveReady ?? staleReady;
    final stale = liveReady == null && recommended != null;
    final candidates = app.sitesForProfile(profile.id);
    final resultByCandidate = {
      for (final result in ledger.results) result.candidateId: result,
    };
    final backups = candidates
        .where((candidate) => candidate.id != recommended?.candidateId)
        .toList();
    final readyLabel = recommended?.finalUrl?.toString();
    final actionLabel = profile.enabled ? (stale ? '尝试上次地址' : '进入站点') : '站点已停用';

    return SiteLensPanel(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(SiteLensMetrics.panelRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primary.withValues(alpha: 0.12),
                    foregroundColor: scheme.primary,
                    child: Text(profile.name.characters.take(1).toString()),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            healthBadge(
                              context,
                              app.healthFor(profile.id).state,
                            ),
                            if (stale) ...[
                              const SizedBox(width: 6),
                              SiteLensStatusBadge(
                                label: '上次成功',
                                icon: Icons.history,
                                color: colors.warning,
                                compact: true,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: profile.enabled,
                    onChanged: (enabled) => safely(context, () async {
                      await app.db.setProfileEnabled(profile.id, enabled);
                      await app.load();
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      stale
                          ? Icons.history
                          : recommended == null
                          ? Icons.location_off_outlined
                          : Icons.check_circle_outline,
                      color: stale
                          ? colors.warning
                          : recommended == null
                          ? scheme.onSurfaceVariant
                          : colors.ok,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            stale
                                ? '本轮暂无推荐'
                                : recommended == null
                                ? '还没有可用落点'
                                : '当前推荐地址',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          SiteLensCopyableText(
                            text: readyLabel ?? '打开详情页检测候选地址',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (recommended?.elapsed != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '首页就绪 ${recommended!.elapsed!.inMilliseconds} ms',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '检测此档案',
                      onPressed:
                          profile.enabled &&
                              !app.probes.running &&
                              !app.refreshing
                          ? () => safely(context, () async {
                              await app.detect(profileId: profile.id);
                            })
                          : null,
                      icon: const Icon(Icons.radar),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.alt_route,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      backups.isEmpty
                          ? '暂无备用地址'
                          : '备用地址 ${backups.length} 个 · ${_backupSummary(backups, resultByCandidate)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: profile.enabled && recommended != null
                      ? onEnter
                      : onOpen,
                  icon: Icon(
                    profile.enabled && recommended != null
                        ? Icons.login
                        : Icons.open_in_new,
                  ),
                  label: Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _backupSummary(
    List<Candidate> candidates,
    Map<int, ProbeResult> resultByCandidate,
  ) => candidates
      .take(2)
      .map((candidate) {
        final result = resultByCandidate[candidate.id];
        if (result == null) return candidate.label;
        return '${candidate.label} · ${statusLabel(result)}';
      })
      .join('、');
}

String profileSummary(AppController app, SiteProfile profile) {
  final ready = app.latestReadyFor(profile.id);
  final landing =
      ready?.finalUrl?.toString() ?? profile.lastLanding?.toString();
  final cost = ready?.elapsed;
  final checked = app.lastCheckedFor(profile.id) ?? profile.lastLandingAt;
  final count = app.sitesForProfile(profile.id).length;
  final parts = <String>[
    landing == null ? '最近可用落点：尚无' : '最近可用落点：$landing',
    if (cost != null) '最近首页就绪：${cost.inMilliseconds} ms',
    '上次检测：${clock(checked)}',
    '$count 个候选落点',
  ];
  return parts.join('\n');
}

Widget healthBadge(BuildContext context, ProfileHealthState state) {
  final colors = SiteLensColors.of(context);
  final (color, icon) = switch (state) {
    ProfileHealthState.ok => (colors.ok, Icons.check_circle_outline),
    ProfileHealthState.failing => (colors.danger, Icons.error_outline),
    ProfileHealthState.unknown => (
      Theme.of(context).colorScheme.outline,
      Icons.help_outline,
    ),
  };
  return Semantics(
    label: '后台存活检查：${healthLabel(state)}（尽力而为，不保证时效）',
    child: SiteLensStatusBadge(
      label: healthLabel(state),
      icon: icon,
      color: color,
      compact: true,
    ),
  );
}

/// Detail view for one profile: this round's ranking, candidates, history and
/// a collapsed advanced area for publishing pages / selectors.
class ProfileDetailScreen extends StatelessWidget {
  const ProfileDetailScreen({
    super.key,
    required this.app,
    required this.profile,
    required this.onEnter,
    required this.onEnterProfile,
    required this.onResume,
  });
  final AppController app;
  final SiteProfile profile;
  final void Function(Candidate) onEnter;

  /// Default entry: fast path from the last landing, with automatic fallback.
  final Future<void> Function(SiteProfile) onEnterProfile;

  /// Returns to an already-open browsing session, if any.
  final VoidCallback onResume;

  Future<void> _confirmDelete(
    BuildContext context,
    AppController app,
    SiteProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SiteLensAlertDialog(
        title: Text('删除“${profile.name}”？'),
        content: const Text(
          '该档案的发布页、健康状态、脚本绑定和配置会被删除；候选落点会移到“未归类”，对应的历史检测记录会保留。浏览器中属于该档案的标签页会关闭。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除档案'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await safely(context, () async {
      await app.deleteProfile(profile.id);
      if (context.mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      // Read the current row so edits/restores are reflected without reopening.
      final live =
          app.profiles.where((p) => p.id == profile.id).firstOrNull ?? profile;
      final ledger = app.probeLedgerFor(live.id);
      final current = ledger.results;
      final liveReady = ledger.live
          ? current.where((result) => result.verified).firstOrNull
          : null;
      final staleReady = app.latestReadyFor(live.id);
      final recommended = liveReady ?? staleReady;
      final staleRecommended = liveReady == null && recommended != null;
      final candidates = app.sitesForProfile(live.id);
      final backupCandidates = candidates
          .where((candidate) => candidate.id != recommended?.candidateId)
          .toList();
      final ids = candidates.map((c) => c.id).toSet();
      final history = app.history
          .where((r) => ids.contains(r.candidateId))
          .take(10)
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(live.name),
          actions: [
            PopupMenuButton<String>(
              tooltip: '档案操作',
              onSelected: (choice) => safely(context, () async {
                switch (choice) {
                  case 'detect':
                    await app.detect(profileId: live.id);
                  case 'verify':
                    await app.detect(
                      profileId: live.id,
                      all: true,
                      refreshSources: false,
                    );
                  case 'export':
                    await exportProfilePack(context, app, live);
                  case 'delete':
                    await _confirmDelete(context, app, live);
                }
              }),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'detect',
                  child: ListTile(
                    leading: Icon(Icons.radar),
                    title: Text('检测这一轮'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'verify',
                  child: ListTile(
                    leading: Icon(Icons.fact_check_outlined),
                    title: Text('全量首页验证'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    leading: Icon(Icons.ios_share),
                    title: Text('导出档案包'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除站点档案'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            SiteLensMetrics.pagePadding,
            4,
            SiteLensMetrics.pagePadding,
            32,
          ),
          children: [
            ResumeBrowserBar(app: app, onResume: onResume),
            if (app.activeBrowser != null)
              const SizedBox(height: SiteLensMetrics.itemGap),
            SiteLensPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      healthBadge(context, app.healthFor(live.id).state),
                      const SizedBox(width: 8),
                      SiteLensStatusBadge(
                        label: live.enabled ? '已启用' : '已停用',
                        icon: live.enabled
                            ? Icons.check_circle_outline
                            : Icons.pause_circle_outline,
                        color: live.enabled
                            ? SiteLensColors.of(context).ok
                            : Theme.of(context).colorScheme.outline,
                        compact: true,
                      ),
                      const Spacer(),
                      Text(
                        '上次检测：${clock(app.lastCheckedFor(live.id))}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SiteLensSectionHeader(
                    title: recommended == null ? '当前没有可用推荐' : '推荐落点',
                    subtitle: recommended == null
                        ? '先运行一轮检测，或检查发布页与核心 DOM 选择器。'
                        : '${recommended.finalUrl ?? recommended.entryUrl}${recommended.elapsed == null ? '' : ' · ${recommended.elapsed!.inMilliseconds} ms'}',
                  ),
                  if (recommended != null)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: SiteLensColors.of(context).wellTint,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: SiteLensColors.of(context).divider,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(
                              staleRecommended
                                  ? Icons.history
                                  : Icons.verified_outlined,
                              color: staleRecommended
                                  ? SiteLensColors.of(context).warning
                                  : SiteLensColors.of(context).ok,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: SiteLensCopyableText(
                                text:
                                    '${recommended.finalUrl ?? recommended.entryUrl}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: live.enabled && recommended != null
                          ? () => safely(context, () => onEnterProfile(live))
                          : live.enabled
                          ? () => safely(context, () => onEnterProfile(live))
                          : null,
                      icon: const Icon(Icons.login),
                      label: Text(
                        live.enabled
                            ? staleRecommended
                                  ? '尝试上次地址'
                                  : '进入站点'
                            : '站点已停用',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
            _DetectionPanel(
              app: app,
              profileId: live.id,
              ledger: ledger,
              current: current,
              backupCandidates: backupCandidates,
              history: history,
              onEnter: onEnter,
              onDetect: (app.probes.running || app.refreshing)
                  ? null
                  : () => safely(context, () => app.detect(profileId: live.id)),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
            _AdvancedArea(app: app, profile: live),
            const SizedBox(height: 24),
          ],
        ),
      );
    },
  );
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({required this.history});

  final List<ProbeResult> history;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('profile-history'),
    initiallyExpanded: true,
    tilePadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    title: const Text('历史'),
    subtitle: Text(history.isEmpty ? '暂无历史记录' : '最近 ${history.length} 条检测记录'),
    children: [
      if (history.isEmpty)
        const ListTile(contentPadding: EdgeInsets.zero, title: Text('暂无历史记录')),
      for (final result in history)
        ListTile(
          key: ValueKey<String>(
            'profile-history-entry-${result.candidateId}-${result.checkedAt.toIso8601String()}',
          ),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text('${statusLabel(result)} · ${clock(result.checkedAt)}'),
          subtitle: SiteLensCopyableText(
            text:
                '${result.finalUrl ?? result.entryUrl}${result.elapsed == null ? '' : ' · ${result.elapsed!.inMilliseconds} ms'}',
          ),
        ),
    ],
  );
}

class _DetectionPanel extends StatelessWidget {
  const _DetectionPanel({
    required this.app,
    required this.profileId,
    required this.ledger,
    required this.current,
    required this.backupCandidates,
    required this.history,
    required this.onEnter,
    required this.onDetect,
  });
  final AppController app;
  final int profileId;
  final ({int round, bool live, List<ProbeResult> results}) ledger;
  final List<ProbeResult> current;
  final List<Candidate> backupCandidates;
  final List<ProbeResult> history;
  final void Function(Candidate) onEnter;
  final VoidCallback? onDetect;

  @override
  Widget build(BuildContext context) {
    final notice = app.probes.profileId == profileId ? app.probes.notice : null;
    return SiteLensPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (notice != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SiteLensNotice(
                text: notice,
                tone: SiteLensNoticeTone.info,
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
            child: Row(
              children: [
                Icon(
                  ledger.live ? Icons.radar : Icons.history,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ledger.live ? '本轮检测' : '上一轮检测',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        ledger.live
                            ? '先按可访问性，再按首页就绪耗时排序'
                            : '结果来自上一轮检测，重新检测后会更新推荐',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text(
                  '${current.length} 个结果',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: onDetect,
                  icon: const Icon(Icons.radar, size: 16),
                  label: const Text('检测'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (current.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Text(
                '本轮还没有结果；从右上角开始检测。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (backupCandidates.isNotEmpty) ...[
            const Divider(height: 1),
            _BackupAddressesPanel(
              app: app,
              candidates: backupCandidates,
              current: current,
              onEnter: onEnter,
            ),
          ],
          const Divider(height: 1),
          _HistoryPanel(history: history),
        ],
      ),
    );
  }
}

class _BackupAddressesPanel extends StatelessWidget {
  const _BackupAddressesPanel({
    required this.app,
    required this.candidates,
    required this.current,
    required this.onEnter,
  });

  final AppController app;
  final List<Candidate> candidates;
  final List<ProbeResult> current;
  final void Function(Candidate) onEnter;

  @override
  Widget build(BuildContext context) {
    final resultByCandidate = {
      for (final result in current) result.candidateId: result,
    };
    return ExpansionTile(
      key: const ValueKey('profile-backup-addresses'),
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
      childrenPadding: EdgeInsets.zero,
      title: Text(
        '备用地址 · ${candidates.length}',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: const Text('当前推荐之外的候选地址'),
      children: [
        for (final candidate in candidates)
          _CompactCandidateRow(
            app: app,
            candidate: candidate,
            result: resultByCandidate[candidate.id],
            onEnter: onEnter,
          ),
      ],
    );
  }
}

class _CompactCandidateRow extends StatelessWidget {
  const _CompactCandidateRow({
    required this.app,
    required this.candidate,
    required this.result,
    required this.onEnter,
  });
  final AppController app;
  final Candidate candidate;
  final ProbeResult? result;
  final void Function(Candidate) onEnter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = result?.verified == true;
    return InkWell(
      onTap: () => onEnter(candidate),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              candidate.enabled
                  ? ready
                        ? Icons.check_circle_outline
                        : Icons.language_outlined
                  : Icons.pause_circle_outline,
              size: 20,
              color: ready
                  ? SiteLensColors.of(context).ok
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  SiteLensCopyableText(
                    text: candidate.url.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (result != null)
                    Text(
                      '${statusLabel(result!)}${result!.elapsed == null ? '' : ' · ${result!.elapsed!.inMilliseconds} ms'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '备用地址操作',
              onSelected: (choice) => safely(context, () async {
                if (choice == 'enter') {
                  onEnter(candidate);
                } else if (choice == 'toggle') {
                  await app.db.setCandidateEnabled(
                    candidate.id,
                    !candidate.enabled,
                  );
                  await app.load();
                } else if (choice == 'delete') {
                  await app.db.deleteCandidate(candidate.id);
                  await app.load();
                }
              }),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'enter', child: Text('进入')),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(candidate.enabled ? '禁用检测' : '启用检测'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('移除候选')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedArea extends StatelessWidget {
  const _AdvancedArea({required this.app, required this.profile});
  final AppController app;
  final SiteProfile profile;

  @override
  Widget build(BuildContext context) => SiteLensPanel(
    padding: EdgeInsets.zero,
    child: ExpansionTile(
      title: const Text('高级：发布页与选择器'),
      subtitle: const Text('默认折叠；改错也会保留缓存'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        for (final page in app.profilePages.where(
          (p) => p.profileId == profile.id,
        ))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: SiteLensCopyableText(text: page.url.toString()),
            subtitle: Text(
              '区域选择器：${page.regionSelector}\n${clock(page.refreshedAt)}${page.error == null ? '' : '\n${page.error}'}',
            ),
            trailing: IconButton(
              tooltip: '移除发布页',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => safely(context, () async {
                await app.db.deleteProfilePage(page.id);
                await app.load();
              }),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showAddProfilePageDialog(context, app, profile),
            icon: const Icon(Icons.add),
            label: const Text('添加发布页 / 备用发布页'),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('核心 DOM 选择器'),
          subtitle: Text(profile.readySelector),
          trailing: TextButton(
            onPressed: () => _editReadySelector(context),
            child: const Text('修改'),
          ),
        ),
        const Divider(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: (app.probes.running || app.refreshing)
                  ? null
                  : () => safely(context, () => app.rescoutProfile(profile)),
              icon: const Icon(Icons.travel_explore),
              label: const Text('重新侦察'),
            ),
            TextButton.icon(
              onPressed: () => safely(context, () async {
                final restored = await app.restoreProfileConfig(profile.id);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(restored ? '已回退到上次成功配置' : '还没有可回退的成功配置'),
                  ),
                );
              }),
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('回退到上次成功配置'),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> _editReadySelector(BuildContext context) async {
    final value = await promptText(
      context,
      title: '核心 DOM 选择器',
      initial: profile.readySelector,
      hintText: '例如 main',
      helperText: '首页已就绪 = 该选择器可见且有内容',
    );
    if (!context.mounted || value == null || value.isEmpty) return;
    await app.db.setProfileReadySelector(profile.id, value);
    await app.load();
  }
}

class _NewProfile {
  const _NewProfile(this.name, this.readySelector, this.pageUrl, this.region);
  final String name;
  final String readySelector;
  final Uri? pageUrl;
  final String region;
}

Future<void> exportProfilePack(
  BuildContext context,
  AppController app,
  SiteProfile profile,
) async {
  final bytes = await app.packs.export(profile.id);
  final uri = await FilePicker.saveFile(
    fileName: '${profile.name}.sitepack.zip',
    bytes: bytes,
    mimeType: 'application/zip',
    dialogTitle: '导出档案包',
  );
  if (uri == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('已导出档案包：${uri.pathSegments.last}')));
}

Future<void> importProfilePack(BuildContext context, AppController app) async {
  final picked = await FilePicker.pickFiles(type: FileType.any);
  if (picked.isEmpty) return;
  final bytes = await picked.single.readAsBytes();
  final preview = await app.packs.inspect(bytes);
  final approved = await app.db.packApproved(preview.fingerprint);
  // Identity-based guard: a byte-identical pack whose imported profile still
  // exists must not create a second copy, even if that profile was renamed.
  final importedId = int.tryParse(
    await app.db.setting('pack_profile_${preview.fingerprint}') ?? '',
  );
  if (approved &&
      importedId != null &&
      app.profiles.any((p) => p.id == importedId)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('该档案包已导入过：${preview.profileName}')),
      );
    }
    return;
  }
  if (!approved) {
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SiteLensAlertDialog(
        title: Text('导入「${preview.profileName}」？'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('发布页：${preview.pages.length} 个'),
                const SizedBox(height: 8),
                const Text('包内脚本（导入后默认关闭，需在本机确认权限与依赖后才能启用）：'),
                for (final script in preview.scripts) ...[
                  const Divider(),
                  Text(
                    script.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('权限：${script.metadata.grants.join(', ')}'),
                  Text('网络域名：${script.metadata.connect.join(', ')}'),
                  if (script.resources.isNotEmpty)
                    Text(
                      '固定资源：${script.resources.map((r) => r.name).join(', ')}',
                    ),
                ],
                if (preview.scripts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('（这个包不含脚本）'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Approval is recorded by `packs.import` inside its own transaction, so a
    // failed import cannot leave a fingerprint that skips the next prompt.
  }
  await app.packs.import(preview);
  await app.load();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入「${preview.profileName}」；脚本默认关闭，请手动确认')),
    );
  }
}

Future<void> showAddProfileDialog(
  BuildContext context,
  AppController app,
) async {
  final result = await showDialog<_NewProfile>(
    context: context,
    builder: (_) => _AddProfileDialog(app: app),
  );
  if (result == null) return;
  try {
    final pageUrl = result.pageUrl;
    await app.db.transaction(() async {
      final id = await app.db.createProfile(
        result.name,
        readySelector: result.readySelector,
      );
      if (pageUrl != null) {
        await app.db.addProfilePage(id, pageUrl, result.region);
      }
    });
    await app.load();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _AddProfileDialog extends StatefulWidget {
  const _AddProfileDialog({required this.app});
  final AppController app;
  @override
  State<_AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<_AddProfileDialog> {
  final url = TextEditingController();
  final name = TextEditingController();
  final region = TextEditingController(text: '@latest-addresses');
  final ready = TextEditingController(text: 'main');
  bool reconning = false;
  bool manual = false;
  ReconResult? recon;
  String? error;

  @override
  void dispose() {
    // Dismissing the dialog must not leave a discovery WebView probing for
    // up to ~15s + selector inference.
    widget.app.cancelRecon();
    url.dispose();
    name.dispose();
    region.dispose();
    ready.dispose();
    super.dispose();
  }

  Future<void> _recon() async {
    setState(() {
      reconning = true;
      error = null;
    });
    try {
      final result = await widget.app.recon(url.text);
      if (!mounted) return;
      setState(() {
        recon = result;
        manual = true;
        region.text = result.regionSelector;
        if (result.inferredReadySelector != null) {
          ready.text = result.inferredReadySelector!;
        }
        if (name.text.trim().isEmpty) {
          final title = result.title.trim();
          name.text = title.isEmpty
              ? result.url.host
              : title.substring(0, title.length.clamp(0, 40));
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        manual = true; // Fall back to the manual selector form.
      });
    } finally {
      if (mounted) setState(() => reconning = false);
    }
  }

  void _submit() {
    try {
      final label = name.text.trim();
      if (label.isEmpty) throw const FormatException('档案名称不能为空');
      final selector = ready.text.trim();
      if (selector.isEmpty) throw const FormatException('核心 DOM 选择器不能为空');
      final raw = url.text.trim();
      final uri = raw.isEmpty ? null : userUri(raw);
      if (uri != null && region.text.trim().isEmpty) {
        throw const FormatException('最新地址区域不能为空');
      }
      Navigator.pop(
        context,
        _NewProfile(label, selector, uri, region.text.trim()),
      );
    } catch (e) {
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => SiteLensAlertDialog(
    title: const Text('添加站点档案'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '站点地址（发布页或任意入口）',
                helperText: '粘一个 URL，App 会侦察最新地址区域并推断核心 DOM 选择器',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: reconning ? null : _recon,
                  icon: const Icon(Icons.travel_explore),
                  label: Text(reconning ? '侦察中…' : '开始侦察'),
                ),
                if (!manual)
                  TextButton(
                    onPressed: () => setState(() => manual = true),
                    child: const Text('手动填写'),
                  ),
              ],
            ),
            if (reconning) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (recon != null) _ReconReport(result: recon!),
            if (manual) ...[
              const Divider(),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '档案名称'),
              ),
              const SizedBox(height: SiteLensMetrics.formGap),
              TextField(
                controller: region,
                decoration: const InputDecoration(
                  labelText: '最新地址区域（自动识别或 CSS）',
                ),
              ),
              const SizedBox(height: SiteLensMetrics.formGap),
              TextField(
                controller: ready,
                decoration: const InputDecoration(
                  labelText: '核心 DOM 选择器',
                  helperText: '首页已就绪 = 该选择器可见且有内容',
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('创建档案')),
    ],
  );
}

class _ReconReport extends StatelessWidget {
  const _ReconReport({required this.result});
  final ReconResult result;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '侦察结果${result.title.isEmpty ? '' : '：${result.title}'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (result.finalUrl != null)
            Text(
              '落点：${result.finalUrl}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 6),
          Text(
            result.regionFound
                ? '最新地址区域：命中（高亮前 ${result.links.length} 条链接）'
                : '最新地址区域：未命中，请手动填写选择器',
          ),
          Text(
            '推断 ready 选择器：${result.inferredReadySelector ?? '未推断出，默认 main'}',
          ),
          if (result.challenge)
            Text('⚠️ 命中验证码/人机验证', style: TextStyle(color: scheme.error)),
          if (result.interactionRequired)
            Text('⚠️ 需要登录或页面交互', style: TextStyle(color: scheme.error)),
          if (result.note != null) Text(result.note!),
          for (final link in result.links)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '• $link',
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> showAddProfilePageDialog(
  BuildContext context,
  AppController app,
  SiteProfile profile,
) async {
  final result = await showDialog<(Uri, String)>(
    context: context,
    builder: (_) => const _AddProfilePageDialog(),
  );
  if (result == null) return;
  try {
    await app.db.addProfilePage(profile.id, result.$1, result.$2);
    await app.load();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _AddProfilePageDialog extends StatefulWidget {
  const _AddProfilePageDialog();
  @override
  State<_AddProfilePageDialog> createState() => _AddProfilePageDialogState();
}

class _AddProfilePageDialogState extends State<_AddProfilePageDialog> {
  final url = TextEditingController();
  final region = TextEditingController(text: '@latest-addresses');

  @override
  void dispose() {
    url.dispose();
    region.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      Navigator.pop(context, (userUri(url.text), region.text.trim()));
    } catch (e) {
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => SiteLensAlertDialog(
    title: const Text('添加发布页 / 备用发布页'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '发布页地址'),
          ),
          TextField(
            controller: region,
            decoration: const InputDecoration(labelText: '最新地址区域（自动识别或 CSS）'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('添加')),
    ],
  );
}
