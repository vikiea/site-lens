import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'browser_entry.dart';
import 'glass_surface.dart';
import 'ui_util.dart';
import 'ui_primitives.dart';

/// First screen of the product: one card per curated site profile.
class ProfilesPanel extends StatelessWidget {
  const ProfilesPanel({
    super.key,
    required this.app,
    required this.onOpen,
    required this.onResume,
  });
  final AppController app;
  final void Function(SiteProfile) onOpen;

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
          SiteLensPanel(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我的站点', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('每个档案维护自己的发布页、候选落点与脚本；进站前先跑一轮检测，按「首页就绪耗时」择优。'),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => showAddProfileDialog(context, app),
                        icon: const Icon(Icons.add_link),
                        label: const Text('添加站点'),
                      ),
                      OutlinedButton.icon(
                        onPressed: app.profiles.isEmpty
                            ? null
                            : () => safely(context, () => app.detect()),
                        icon: const Icon(Icons.radar),
                        label: const Text('全部检测'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => safely(
                          context,
                          () => importProfilePack(context, app),
                        ),
                        icon: const Icon(Icons.file_download_outlined),
                        label: const Text('导入档案包'),
                      ),
                      if (app.probes.running || app.refreshing)
                        TextButton(
                          onPressed: () => app.cancel(),
                          child: const Text('取消'),
                        ),
                    ],
                  ),
                  if (app.probes.running || app.refreshing) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (app.probes.notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(app.probes.notice!),
                    ),
                  if (app.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SiteLensErrorBanner(
                        text: app.error!,
                        onDismiss: app.clearError,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SiteLensMetrics.itemGap),
          if (app.profiles.isEmpty)
            // No second call to action here: the panel above already owns the
            // primary 「添加站点」 button, and two of them only compete.
            const SiteLensEmptyState(
              icon: Icons.travel_explore,
              title: '还没有站点档案',
              message: '添加一个发布页即可开始：先跑一轮检测，再按首页就绪耗时择优。',
            ),
          for (final profile in app.profiles) ...[
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(profile.name.characters.take(1).toString()),
                ),
                title: Text(profile.name),
                subtitle: SiteLensCopyableText(
                  text: profileSummary(app, profile),
                ),
                isThreeLine: true,
                trailing: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    healthBadge(context, app.healthFor(profile.id).state),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => onOpen(profile),
              ),
            ),
            const SizedBox(height: SiteLensMetrics.listGap),
          ],
        ],
      ),
    ),
  );
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
      final candidates = app.sitesForProfile(live.id);
      final ids = candidates.map((c) => c.id).toSet();
      final history = app.history
          .where((r) => ids.contains(r.candidateId))
          .take(10)
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(live.name),
          actions: [
            IconButton(
              tooltip: '删除站点档案',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(context, app, live),
            ),
            IconButton(
              tooltip: '导出档案包',
              icon: const Icon(Icons.ios_share),
              onPressed: () =>
                  safely(context, () => exportProfilePack(context, app, live)),
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
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        healthBadge(context, app.healthFor(live.id).state),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '核心 DOM 选择器：${live.readySelector}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: (app.probes.running || app.refreshing)
                              ? null
                              : () => safely(
                                  context,
                                  () => app.detect(profileId: profile.id),
                                ),
                          icon: const Icon(Icons.radar),
                          label: const Text('检测这一轮'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: (app.probes.running || app.refreshing)
                              ? null
                              : () =>
                                    safely(context, () => onEnterProfile(live)),
                          icon: const Icon(Icons.login),
                          label: Text(
                            live.lastLanding == null ? '检测后进入' : '进入站点（快路径）',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: (app.probes.running || app.refreshing)
                              ? null
                              : () => safely(
                                  context,
                                  () => app.detect(
                                    all: true,
                                    refreshSources: false,
                                  ),
                                ),
                          child: const Text('全量首页验证'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            _SectionTitle(ledger.live ? '本轮择优（按首页就绪耗时）' : '上一轮择优（按首页就绪耗时）'),
            if (current.isEmpty)
              const SiteLensPanel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  title: Text('本轮还没有结果'),
                  subtitle: Text('点上面的「检测这一轮」，或下拉刷新。'),
                ),
              )
            else if (!ledger.live)
              const SiteLensPanel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(Icons.history),
                  title: Text('这是最后一轮的落点与耗时'),
                  subtitle: Text(
                    '进入浏览会停止检测，所以旧结果不再参与推荐；上面的数字是本轮结束时记录的，重新检测可刷新。',
                  ),
                ),
              ),
            for (final r in current)
              _ResultTile(
                app: app,
                result: r,
                onEnter: onEnter,
                stale: !ledger.live,
              ),
            _SectionTitle('候选落点（${candidates.length}）'),
            for (final site in candidates) ...[
              SiteLensPanel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(
                    site.enabled ? Icons.language : Icons.pause_circle_outline,
                  ),
                  title: Text(site.label),
                  subtitle: SiteLensCopyableText(text: site.url.toString()),
                  trailing: PopupMenuButton<String>(
                    onSelected: (choice) => safely(context, () async {
                      if (choice == 'enter') {
                        onEnter(site);
                        return;
                      }
                      if (choice == 'toggle') {
                        await app.db.setCandidateEnabled(
                          site.id,
                          !site.enabled,
                        );
                      }
                      if (choice == 'delete') {
                        await app.db.deleteCandidate(site.id);
                      }
                      await app.load();
                    }),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'enter', child: Text('进入')),
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(site.enabled ? '禁用检测' : '启用检测'),
                      ),
                      const PopupMenuItem(value: 'delete', child: Text('移除候选')),
                    ],
                  ),
                  onTap: () => onEnter(site),
                ),
              ),
              const SizedBox(height: SiteLensMetrics.listGap),
            ],
            _SectionTitle('历史'),
            if (history.isEmpty)
              const SiteLensPanel(
                padding: EdgeInsets.zero,
                child: ListTile(title: Text('暂无历史记录')),
              ),
            for (final r in history)
              ListTile(
                dense: true,
                title: Text('${statusLabel(r)} · ${clock(r.checkedAt)}'),
                subtitle: SiteLensCopyableText(
                  text:
                      '${r.finalUrl ?? r.entryUrl}${r.elapsed == null ? '' : ' · ${r.elapsed!.inMilliseconds} ms'}',
                ),
              ),
            const SizedBox(height: 8),
            _AdvancedArea(app: app, profile: live),
            const SizedBox(height: 24),
          ],
        ),
      );
    },
  );
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.app,
    required this.result,
    required this.onEnter,
    this.stale = false,
  });
  final AppController app;
  final ProbeResult result;
  final void Function(Candidate) onEnter;

  /// True when the row comes from a round that is no longer live, so an old
  /// timing cannot be mistaken for this round's recommendation.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final site = app.sites.where((c) => c.id == result.candidateId).firstOrNull;
    final ready = result.verified;
    final scheme = Theme.of(context).colorScheme;
    return SiteLensPanel(
      padding: EdgeInsets.zero,
      child: ListTile(
        selected: ready && !stale,
        selectedTileColor: scheme.primary.withValues(alpha: 0.12),
        // A stale row is muted, not dead: the same entry is still the way into
        // that落点, and the arrow it draws would otherwise lie.
        textColor: stale ? scheme.onSurfaceVariant : null,
        iconColor: stale ? scheme.onSurfaceVariant : null,
        leading: Icon(
          stale
              ? Icons.history
              : ready
              ? Icons.verified_outlined
              : Icons.info_outline,
        ),
        title: Text(site?.label ?? result.entryUrl.host),
        subtitle: Text(
          '${stale ? '上一轮 · ' : ''}${statusLabel(result)}${result.elapsed == null ? '' : ' · ${result.elapsed!.inMilliseconds} ms'}\n${result.finalUrl ?? result.entryUrl}${result.reason == null ? '' : '\n${result.reason}'}',
        ),
        isThreeLine: true,
        trailing: site == null ? null : const Icon(Icons.arrow_forward),
        onTap: site == null ? null : () => onEnter(site),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => SiteLensSectionHeader(title: text);
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
