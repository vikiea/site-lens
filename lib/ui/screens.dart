import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../network/transport.dart';
import '../scripts/metadata.dart';
import '../web_host/native_hosts.dart';
import '../web_host/web_host.g.dart';
import 'app_controller.dart';
import 'navigation_observer.dart';
import 'data_management_screen.dart';
import 'about_screen.dart';
import 'software_update_screen.dart';
import 'app_theme.dart';
import '../settings/app_settings.dart' show AppPolicy;
import 'glass_surface.dart';
import 'browser_entry.dart';
import 'profile_panel.dart';
import 'ui_util.dart';
import 'ui_primitives.dart';

enum AppDestination { sites, browser, settings }

class SiteLensBottomNavigationItem {
  const SiteLensBottomNavigationItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.semanticLabel,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String? semanticLabel;
}

/// A compact destination cell where the icon and label share one selected
/// background. Material NavigationBar's stock indicator only wraps the icon;
/// this small row keeps the pair visually together like the reference UI.
class SiteLensBottomNavigation extends StatelessWidget {
  const SiteLensBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<SiteLensBottomNavigationItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final dark = theme.brightness == Brightness.dark;
    final selectedFill = scheme.primary.withValues(alpha: dark ? 0.30 : 0.12);

    return SizedBox(
      height:
          SiteLensMetrics.navBarHeight - SiteLensMetrics.navCapsuleInset * 2,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            for (var index = 0; index < items.length; index++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Semantics(
                    button: true,
                    selected: index == selectedIndex,
                    label: items[index].semanticLabel ?? items[index].label,
                    child: Tooltip(
                      message: items[index].label,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => onDestinationSelected(index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: index == selectedIndex
                                ? selectedFill
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                index == selectedIndex
                                    ? items[index].selectedIcon
                                    : items[index].icon,
                                size: SiteLensMetrics.navIconSize,
                                color: index == selectedIndex
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                items[index].label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelSmall?.copyWith(
                                  fontSize: SiteLensMetrics.navLabelSize,
                                  fontWeight: index == selectedIndex
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: index == selectedIndex
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int page = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scheduleMicrotask(
      () => safely(context, ref.read(appControllerProvider).initialize),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A background survival run may have finished while we were paused; surface
    // its notice as soon as the user comes back.
    if (state == AppLifecycleState.resumed) {
      scheduleMicrotask(
        () => safely(
          context,
          ref.read(appControllerProvider).drainBackgroundNotice,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final destinations = <AppDestination>[
          AppDestination.sites,
          AppDestination.browser,
          AppDestination.settings,
        ];
        final destination =
            destinations[page.clamp(0, destinations.length - 1)];
        return SiteLensGlassGroup(
          // One backdrop read for the whole screen: the top bar, the panels and
          // the bottom bar share it instead of taking a full-screen capture each.
          child: Scaffold(
            appBar: AppBar(
              title: Text(switch (destination) {
                AppDestination.sites => '择站',
                AppDestination.browser => '浏览',
                AppDestination.settings => '设置',
              }),
              // The top bar is the same glass layer as the bottom one: both sit
              // above the content on the app backdrop.
              flexibleSpace: const SiteLensGlassSurface(
                role: SiteLensSurfaceRole.chrome,
                radius: 0,
                child: SizedBox.shrink(),
              ),
              actions: const [],
            ),
            body: SafeArea(
              child: switch (destination) {
                AppDestination.sites => ProfilesPanel(
                  app: app,
                  onOpen: (profile) => _openProfile(app, profile),
                  onResume: () => _resume(app),
                ),
                AppDestination.browser => BrowserTabsPage(
                  app: app,
                  onResume: (tab) => _resumeTab(app, tab),
                  onNewTab: () =>
                      safely(context, () => promptNewTab(context, app)),
                ),
                AppDestination.settings => SettingsPage(app: app),
              },
            ),
            // A fixed, single-row labelled glass capsule: destinations never
            // wrap, move or shrink, and the surface refracts the app backdrop.
            bottomNavigationBar: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  SiteLensMetrics.navHorizontalInset,
                  SiteLensMetrics.navCapsuleInset,
                  SiteLensMetrics.navHorizontalInset,
                  SiteLensMetrics.navCapsuleInset,
                ),
                child: SiteLensNavigationSurface(
                  radius: SiteLensMetrics.navRadius,
                  child: SiteLensBottomNavigation(
                    selectedIndex: page.clamp(0, destinations.length - 1),
                    onDestinationSelected: (value) =>
                        setState(() => page = value),
                    items: [
                      const SiteLensBottomNavigationItem(
                        icon: Icons.travel_explore_outlined,
                        selectedIcon: Icons.travel_explore,
                        label: '站点',
                      ),
                      SiteLensBottomNavigationItem(
                        icon: app.browserTabs.isEmpty
                            ? Icons.tab_unselected
                            : Icons.tab_outlined,
                        selectedIcon: Icons.tab,
                        label: '浏览',
                        semanticLabel: app.browserTabs.isEmpty
                            ? '浏览'
                            : '浏览，${app.browserTabs.length} 个标签',
                      ),
                      const SiteLensBottomNavigationItem(
                        icon: Icons.tune_outlined,
                        selectedIcon: Icons.tune,
                        label: '设置',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _open(AppController app, Candidate site) {
    app.cancel('已进入浏览，检测已停止；不会自动切换站点');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(app: app, site: site),
      ),
    );
  }

  Future<void> _enterProfile(AppController app, SiteProfile profile) async {
    final session = await app.enterProfile(profile);
    if (session == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(app: app, site: session.site),
      ),
    );
  }

  void _openProfile(AppController app, SiteProfile profile) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileDetailScreen(
          app: app,
          profile: profile,
          onEnter: (site) => _open(app, site),
          onEnterProfile: (p) => _enterProfile(app, p),
          onResume: () => _resume(app),
        ),
      ),
    );
  }

  void _resume(AppController app) {
    final session = app.activeBrowser;
    if (session == null) return;
    _resumeTab(app, session);
  }

  Future<void> _resumeTab(AppController app, ActiveBrowserSession tab) async {
    if (!app.browserTabs.contains(tab)) return;
    await safely(context, () async {
      await app.activateTab(tab);
      if (!mounted ||
          !app.browserTabs.contains(tab) ||
          !identical(app.activeBrowser, tab)) {
        return;
      }
      app.cancel('已切回浏览，检测已停止');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BrowserScreen(app: app, site: tab.site),
        ),
      );
    });
  }
}

/// (group label, note, scripts) in display order: profiles first, then 未绑定.
List<(String, String, List<InstalledScript>)> scriptGroups(
  AppController app, {
  int? profileId,
}) => [
  for (final profile in app.profiles.where(
    (p) => profileId == null || p.id == profileId,
  ))
    (profile.name, '随档案一起导出/导入', app.scriptsForProfile(profile.id)),
  ('未绑定', '暂未归属任何档案，按 @match 全局生效', app.unboundScripts),
];

class ScriptManagementScreen extends StatelessWidget {
  const ScriptManagementScreen({super.key, required this.app, this.profileId});
  final AppController app;
  final int? profileId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('脚本管理'),
        actions: [
          IconButton(
            tooltip: '粘贴新脚本',
            icon: const Icon(Icons.add),
            onPressed: () => editScript(context, app),
          ),
        ],
      ),
      body: SafeArea(
        child: ScriptsPage(app: app, profileId: profileId),
      ),
    ),
  );
}

class ScriptsPage extends StatelessWidget {
  const ScriptsPage({super.key, required this.app, this.profileId});
  final AppController app;
  final int? profileId;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(
      SiteLensMetrics.pagePadding,
      4,
      SiteLensMetrics.pagePadding,
      32,
    ),
    children: [
      SiteLensPanel(
        padding: EdgeInsets.zero,
        child: SwitchListTile(
          title: const Text('全局关闭脚本'),
          subtitle: const Text('故障恢复入口：撤销当前桥并重载浏览页'),
          value: app.scriptsDisabled,
          onChanged: (value) =>
              safely(context, () => app.disableAllScripts(value)),
        ),
      ),
      OutlinedButton.icon(
        onPressed: () => safely(context, () async {
          final result = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['js'],
          );
          if (result.isEmpty) return;
          final file = result.single;
          if (!file.name.endsWith('.user.js')) {
            throw const FormatException('请选择 .user.js 文件');
          }
          if ((await file.length() ?? 0) > maxScriptBytes) {
            throw const FormatException('脚本超过 16 MiB 运行上限');
          }
          final bytes = await file.readAsBytes();
          await app.scripts.save(utf8.decode(bytes));
          await app.load();
        }),
        icon: const Icon(Icons.file_upload_outlined),
        label: const Text('导入 .user.js（默认关闭）'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '主框架限定；不是完整 Tampermonkey。网络不附带登录 Cookie。修改脚本后必须重新确认。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (app.installed.isEmpty)
        const SiteLensEmptyState(
          icon: Icons.code,
          title: '还没有脚本',
          message: '点击右上角粘贴，或从文件导入一个 .user.js。',
        ),
      for (final group in scriptGroups(app, profileId: profileId)) ...[
        _ScriptGroupHeader(label: group.$1, note: group.$2),
        if (group.$3.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '（这一组还没有脚本）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final script in group.$3) ...[
          _scriptCard(context, script),
          const SizedBox(height: SiteLensMetrics.itemGap),
        ],
      ],
    ],
  );

  Widget _scriptCard(BuildContext context, InstalledScript script) {
    final meta = ScriptMetadata.parse(script.source);
    final environment = meta.pageWorld
        ? (meta.grants.contains('unsafeWindow')
              ? '网页环境 · unsafeWindow 可用 · 无原生存储/网络权限'
              : '网页环境 · 无原生存储/网络权限')
        : '隔离环境 · 已声明权限';
    final issue = meta.errors.isEmpty ? '' : ' · 不可启用：${meta.errors.first}';
    return SiteLensPanel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          SwitchListTile(
            title: Text(meta.name),
            subtitle: Text('$environment$issue'),
            value: script.enabled,
            onChanged: (enabled) => safely(context, () async {
              if (!enabled) {
                await app.db.setScriptEnabled(script.id, false);
              } else {
                if (!context.mounted ||
                    !await confirmScript(context, app, script)) {
                  return;
                }
                await app.scripts.enable(script, Cancellation());
              }
              await app.load();
            }),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => editScript(context, app, script: script),
                child: const Text('编辑'),
              ),
              TextButton(
                onPressed: () => editScriptOwnership(context, app, script),
                child: const Text('归属档案'),
              ),
              TextButton(
                onPressed: () => scriptDetails(context, app, script),
                child: const Text('权限与错误'),
              ),
              IconButton(
                tooltip: '删除脚本及其存储',
                onPressed: () => safely(context, () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (c) => SiteLensAlertDialog(
                      title: const Text('删除脚本？'),
                      content: const Text('该脚本的本地存储与固定依赖也将删除，无法撤销。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await app.db.deleteScript(script.id);
                    await app.load();
                  }
                }),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScriptGroupHeader extends StatelessWidget {
  const _ScriptGroupHeader({required this.label, required this.note});
  final String label;
  final String note;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(width: 8),
        Expanded(
          child: Text(note, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

/// Bind or unbind [script] across profiles. Binding is ownership metadata (it
/// groups the scripts tab and travels with a profile pack); execution is still
/// governed by @match. A script may legitimately stay unbound.
Future<void> editScriptOwnership(
  BuildContext context,
  AppController app,
  InstalledScript script,
) async {
  final hash = scriptContentHash(script.source);
  final selected = app.profileScriptLinks
      .where((l) => l.scriptId == script.id)
      .map((l) => l.profileId)
      .toSet();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => SiteLensAlertDialog(
        title: Text('「${script.name}」归属档案'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.sameContentCount(script) > 1
                      ? '这 ${app.sameContentCount(script)} 处是同一份内容；任一处更新后都需要重新确认权限。'
                      : '选中的档案会连同这份脚本一起导出/导入；不选表示「未绑定」，按 @match 全局生效。',
                ),
                const SizedBox(height: 8),
                if (app.profiles.isEmpty) const Text('还没有站点档案。'),
                for (final profile in app.profiles)
                  CheckboxListTile(
                    dense: true,
                    title: Text(profile.name),
                    subtitle:
                        app.profileScriptLinks.any(
                          (l) =>
                              l.profileId == profile.id &&
                              l.contentHash == hash,
                        )
                        ? const Text('同一份内容已在此档案')
                        : null,
                    value: selected.contains(profile.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected.add(profile.id);
                      } else {
                        selected.remove(profile.id);
                      }
                    }),
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
            child: const Text('保存归属'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return;
  await app.db.transaction(() async {
    for (final profile in app.profiles) {
      if (selected.contains(profile.id)) {
        await app.db.linkProfileScript(profile.id, script.id, hash);
      } else {
        await app.db.unlinkProfileScript(profile.id, script.id);
      }
    }
  });
  await app.load();
}

Future<bool> confirmScript(
  BuildContext context,
  AppController app,
  InstalledScript script,
) async {
  final meta = ScriptMetadata.parse(script.source);
  if (!meta.canEnable) throw StateError(meta.errors.join('\n'));
  if (app.capabilities?.documentStart != true) {
    throw StateError('缺少安全生命周期注入能力，无法启用脚本');
  }
  if (!meta.pageWorld && app.capabilities?.isolatedScripts != true) {
    throw StateError('本机缺少安全隔离与同环境消息能力，不能启用特权脚本');
  }
  return await showDialog<bool>(
        context: context,
        builder: (c) => SiteLensAlertDialog(
          title: Text('确认启用 ${meta.name}'),
          content: SingleChildScrollView(
            child: Text(
              '执行范围：\n${meta.matches.map((r) => r.pattern).join('\n')}\n排除：${meta.excludes.map((r) => r.pattern).join(', ')}\n时机：${meta.runAt}\n权限：${meta.grants.join(', ')}\n网络域名：${meta.connect.join(', ')}\n\n依赖（确认后下载并固定字节，不自动更新）：\n${meta.requires.join('\n')}\n\n'
              '${meta.pageWorld ? '网页环境：脚本与页面共享同一个 window，页面可以读取或干扰脚本，脚本也没有原生存储与网络权限。' : '隔离环境：脚本运行在独立世界，仍共享 DOM，并不保密页面内容。'}\n来源不可信时不要启用。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认权限与依赖'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> scriptDetails(
  BuildContext context,
  AppController app,
  InstalledScript script,
) async {
  final deps = await app.db.dependencies(script.id);
  final errors = await app.db.scriptErrors(script.id);
  final meta = ScriptMetadata.parse(script.source);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => SiteLensAlertDialog(
      title: Text(meta.name),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: SelectableText(
            '权限：${meta.grants.join(', ')}\n@connect：${meta.connect.join(', ')}\n确认状态：${script.approvedDigest == null ? '未确认' : '已固定'}\n${meta.errors.join('\n')}\n\n固定依赖 SHA-256：\n${deps.map((d) => '${d.url}\n${d.hash}').join('\n\n')}\n\n最近执行错误：\n${errors.isEmpty ? '暂无' : errors.join('\n\n')}',
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
}

Future<void> editScript(
  BuildContext context,
  AppController app, {
  InstalledScript? script,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ScriptEditor(app: app, script: script),
    ),
  );
}

class ScriptEditor extends StatefulWidget {
  const ScriptEditor({super.key, required this.app, this.script});
  final AppController app;
  final InstalledScript? script;
  @override
  State<ScriptEditor> createState() => _ScriptEditorState();
}

class _ScriptEditorState extends State<ScriptEditor> {
  late final TextEditingController source = TextEditingController(
    text: widget.script?.source ?? '// ==UserScript==\n// @name        我的样式脚本\n// @match       https://example.com/*\n// @run-at      document-end\n// @grant       GM_addStyle\n// ==/UserScript==\n\nGM_addStyle("body { line-height: 1.6; }");\n',
  );
  bool saving = false;
  @override
  void dispose() {
    source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('脚本编辑'),
      actions: [
        TextButton(
          onPressed: saving
              ? null
              : () => safely(context, () async {
                  setState(() => saving = true);
                  try {
                    final metadata = ScriptMetadata.parse(source.text);
                    await widget.app.scripts.save(
                      source.text,
                      id: widget.script?.id,
                    );
                    await widget.app.load();
                    if (context.mounted && metadata.errors.isNotEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(metadata.errors.first),
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                    if (context.mounted) Navigator.pop(context);
                  } finally {
                    if (mounted) setState(() => saving = false);
                  }
                }),
          child: const Text('保存并关闭'),
        ),
      ],
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('保存后默认关闭，需要重新确认权限和依赖。'),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: source,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '粘贴完整 .user.js：必须包含 // ==/UserScript==、@match 和脚本主体；大脚本建议导入文件',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppController get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final colors = SiteLensColors.of(context);
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: ListView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          _sectionLabel(context, '外观'),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _rowTitle(context, Icons.brightness_6_outlined, '明暗模式'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: SiteLensSegmented<ThemeModePreference>(
                    value: app.themeModePreference,
                    onChanged: (value) => safely(
                      context,
                      () => app.setThemeModePreference(value),
                    ),
                    options: const [
                      (
                        ThemeModePreference.system,
                        '系统',
                        Icons.brightness_auto_outlined,
                      ),
                      (
                        ThemeModePreference.light,
                        '浅色',
                        Icons.light_mode_outlined,
                      ),
                      (
                        ThemeModePreference.dark,
                        '深色',
                        Icons.dark_mode_outlined,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  leading: const Icon(Icons.opacity_outlined, size: 20),
                  title: const Text('不透明度'),
                  subtitle: Text('${app.settings.glassOpacity} / 100'),
                  trailing: SizedBox(
                    width: 170,
                    child: Slider(
                      min: 1,
                      max: 100,
                      divisions: 99,
                      value: app.settings.glassOpacity.toDouble(),
                      label: '${app.settings.glassOpacity}',
                      onChanged: (value) => safely(
                        context,
                        () =>
                            app.updateSettings({'glassOpacity': value.round()}),
                      ),
                    ),
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                // The presets stay out of the way until asked for: one collapsed
                // block instead of a bottom sheet over the page.
                ExpansionTile(
                  key: const PageStorageKey<String>('theme-presets'),
                  leading: const Icon(Icons.palette_outlined, size: 20),
                  title: const Text('主题色'),
                  subtitle: Text(app.themePreset.label),
                  initiallyExpanded: false,
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in ThemePresetId.values)
                          _ThemePresetChip(
                            preset: preset,
                            selected: preset == app.themePreset,
                            onTap: () => safely(
                              context,
                              () => app.setThemePreset(preset),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          _sectionLabel(context, '浏览'),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('恢复上次标签'),
                  subtitle: const Text('重启后恢复列表，选择标签时加载'),
                  value: app.restoreBrowserSessions,
                  onChanged: (value) => safely(
                    context,
                    () => app.setRestoreBrowserSessions(value),
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  leading: const Icon(Icons.code, size: 20),
                  title: const Text('脚本管理'),
                  subtitle: Text('${app.installed.length} 个脚本 · 管理权限与启用状态'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ScriptManagementScreen(app: app),
                    ),
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  leading: const Icon(Icons.storage_outlined, size: 20),
                  title: const Text('数据管理'),
                  subtitle: const Text('完整备份、恢复与默认偏好'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DataManagementScreen(app: app),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _sectionLabel(context, '高级与诊断'),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('当前标签后台播放（Android）'),
                  subtitle: Text(
                    app.mediaSupported
                        ? '离开浏览页后继续播放，可从系统媒体通知暂停或停止'
                        : '打开网页后检查播放能力；默认离开即暂停',
                  ),
                  value: app.allowBackgroundPlayback,
                  onChanged: (app.mediaSupported || app.allowBackgroundPlayback)
                      ? (value) => safely(
                          context,
                          () => app.setAllowBackgroundPlayback(value),
                        )
                      : null,
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                SwitchListTile(
                  title: const Text('自动隐藏浏览控件'),
                  subtitle: const Text('停止操作 3 秒后收起，点击浮动把手展开'),
                  value: app.settings.autoHideBrowserControls,
                  onChanged: (value) => safely(
                    context,
                    () =>
                        app.updateSettings({'autoHideBrowserControls': value}),
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                SwitchListTile(
                  title: const Text('后台存活检查'),
                  subtitle: const Text('仅充电 + WiFi，每天最多两次；只做 HTTP 初筛'),
                  value: app.backgroundHealthCheck,
                  onChanged: (value) => safely(
                    context,
                    () => app.setBackgroundHealthCheck(value),
                  ),
                ),
                _Details(
                  key: const ValueKey('details-background-health'),
                  text:
                      '只做 HTTP 初筛，不启动 WebView，因此不会干扰登录状态与用户脚本。'
                      '触发条件需要同时满足充电与 WiFi，并且每天最多两次。'
                      '这是尽力而为的后台任务：系统可能延迟或跳过，结果不保证时效。',
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                SwitchListTile(
                  title: const Text('浏览页下拉刷新（Android）'),
                  subtitle: const Text('默认关闭：下拉手势属于页面和用户脚本'),
                  value: app.pullToRefresh,
                  onChanged: (value) =>
                      safely(context, () => app.setPullToRefresh(value)),
                ),
                _Details(
                  key: const ValueKey('details-pull-refresh'),
                  text: '打开后，页面处于顶部时下拉即刷新当前页。关闭时下拉手势完全交给页面。',
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                SwitchListTile(
                  title: const Text('同站点标签页互相替换'),
                  subtitle: const Text('打开同一档案的新落点时复用已有标签；默认允许多标签'),
                  value: app.settings.replaceSameSiteTabs,
                  onChanged: (value) => safely(
                    context,
                    () => app.updateSettings({'replaceSameSiteTabs': value}),
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  leading: const Icon(
                    Icons.health_and_safety_outlined,
                    size: 20,
                  ),
                  title: const Text('检查宿主能力'),
                  subtitle: Text(
                    app.hostCapabilityError ??
                        _hostCapabilitySummary(app.capabilities),
                  ),
                  isThreeLine: app.capabilities != null,
                  trailing: const Icon(Icons.play_circle_outline),
                  onTap: app.checkingHostCapabilities
                      ? null
                      : () async {
                          String notice;
                          try {
                            final capabilities = await app
                                .checkHostCapabilities();
                            notice = _hostCapabilitiesNotice(capabilities);
                          } catch (_) {
                            notice = '检查未完成，请重试';
                          }
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(notice)));
                        },
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                _Details(
                  key: const ValueKey('details-support-boundary'),
                  title: '支持边界',
                  text:
                      'Android 8.0+ / iOS 15+，实际增强能力以运行时检查为准。浏览保留各域名登录；'
                      '发现与检测无用户脚本、独立 Cookie 和存储。\n\n'
                      '没有代理、没有破解、不忽略 TLS 错误、不接管播放器、不承诺视频质量。'
                      'GM 支持应用声明的子集及固定资源；脚本授权仅作用于主框架。'
                      '脚本市场、自动更新不支持。\n\n'
                      'unsafeWindow 只在没有 GM 特权权限的脚本里支持：这类脚本运行在网页环境，'
                      'unsafeWindow 就是页面自己的 window，但同时也失去原生存储与网络权限。'
                      'unsafeWindow 与 GM 特权权限混用仍会阻止启用。\n\n'
                      'iOS 真机需要签名与设备验证；工程可编译不代表真机兼容。数据仅存本机。',
                  startsOpen: false,
                ),
              ],
            ),
          ),
          _sectionLabel(context, '关于与更新'),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                SiteLensActionRow(
                  icon: Icons.info_outline,
                  title: '关于 Site Lens',
                  subtitle: '版本、许可证与项目链接',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AboutScreen(),
                    ),
                  ),
                ),
                Divider(height: 1, indent: 18, endIndent: 18),
                SiteLensActionRow(
                  icon: Icons.system_update_outlined,
                  title: '软件更新',
                  subtitle: '检查最新版本',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SoftwareUpdateScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SiteLensMetrics.sectionGap),
          Center(
            child: Text(
              '择站 · Site Lens',
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: colors.sectionLabel),
            ),
          ),
        ],
      ),
    );
  }

  String _hostCapabilitySummary(HostCapabilities? capabilities) {
    if (capabilities == null) return '点击检查网页增强能力';
    return '脚本增强：${_capabilityLabel(capabilities.isolatedScripts)}\n'
        '页面注入：${_capabilityLabel(capabilities.documentStart)} · '
        '检测隔离：${_capabilityLabel(capabilities.privateProbes)}';
  }

  String _hostCapabilitiesNotice(HostCapabilities capabilities) {
    final complete =
        capabilities.isolatedScripts &&
        capabilities.documentStart &&
        capabilities.privateProbes;
    return complete ? '网页增强能力可用' : '网页增强能力受限，部分功能不可用';
  }

  String _capabilityLabel(bool value) => value ? '支持' : '不可用';

  Widget _sectionLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(6, SiteLensMetrics.sectionGap, 6, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontSize: 13.5,
        color: SiteLensColors.of(context).sectionLabel,
        letterSpacing: 0.4,
      ),
    ),
  );

  Widget _rowTitle(BuildContext context, IconData icon, String title) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
          ],
        ),
      );
}

/// One theme preset in the collapsed 主题色 block: a swatch, a name and the
/// current selection. No bottom sheet stands between the tap and the change.
class _ThemePresetChip extends StatelessWidget {
  const _ThemePresetChip({
    required this.preset,
    required this.selected,
    required this.onTap,
  });
  final ThemePresetId preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = '主题色 ${preset.label}';
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Tooltip(
        message: preset.label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: preset.seed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? scheme.primary : Colors.white,
                    width: selected ? 3 : 2,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.24),
                            blurRadius: 0,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: selected
                    ? Icon(
                        Icons.check,
                        size: 22,
                        color:
                            ThemeData.estimateBrightnessForColor(preset.seed) ==
                                Brightness.dark
                            ? Colors.white
                            : Colors.black,
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row of mutually exclusive choices, styled as part of the glass language
/// rather than as a Material box: a translucent track with a pill for the
/// current value, equal widths and no inner dividers.
class SiteLensSegmented<T> extends StatelessWidget {
  const SiteLensSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    required this.options,
  });
  final T value;
  final ValueChanged<T> onChanged;
  final List<(T, String, IconData)> options;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = SiteLensColors.of(context);
    return Container(
      height: SiteLensMetrics.segmentedHeight,
      padding: const EdgeInsets.all(SiteLensMetrics.segmentedInset),
      decoration: BoxDecoration(
        // The surrounding panel is white in light mode at high opacity. Use
        // the recessed well tint for the track so the selector remains
        // separated from that surface instead of disappearing into it.
        color: colors.wellTint,
        borderRadius: BorderRadius.circular(
          SiteLensMetrics.segmentedHeight / 2,
        ),
        border: Border.all(color: colors.panelBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (option, label, icon) in options)
            Expanded(
              child: Semantics(
                selected: option == value,
                button: true,
                label: label,
                child: InkWell(
                  onTap: () => onChanged(option),
                  borderRadius: BorderRadius.circular(
                    (SiteLensMetrics.segmentedHeight -
                            SiteLensMetrics.segmentedInset * 2) /
                        2,
                  ),
                  child: AnimatedContainer(
                    height: double.infinity,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: option == value
                          ? scheme.primary.withValues(alpha: 0.20)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(
                        (SiteLensMetrics.segmentedHeight -
                                SiteLensMetrics.segmentedInset * 2) /
                            2,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 16,
                          color: option == value
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            label,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: option == value
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A collapsed "详情" disclosure used for long safety and diagnostic text: the
/// row stays short, and the full wording is one tap away instead of gone.
class _Details extends StatelessWidget {
  const _Details({
    super.key,
    required this.text,
    this.title = '详情',
    this.startsOpen = false,
  });
  final String text;
  final String title;
  final bool startsOpen;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      initiallyExpanded: startsOpen,
      tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
      title: Text(title, style: Theme.of(context).textTheme.labelMedium),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.app, required this.site});
  final AppController app;
  final Candidate site;
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> with RouteAware {
  bool _covered = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ModalRoute<dynamic>) {
      browserRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _covered = true;
    widget.app.browserVisible = false;
  }

  @override
  void didPopNext() {
    _covered = false;
    widget.app.browserVisible = true;
  }

  String? error;

  /// Key on the floating controls, so a drag can measure what it is moving.
  final _controlsKey = GlobalKey();

  /// The host error the user dismissed, and the tab it was dismissed on.
  ///
  /// The dismissal only lasts as long as that exact error stays continuously
  /// visible: once the error clears (or the active tab changes) it is re-armed,
  /// so the same failure coming back later shows the banner again. The platform
  /// state itself is never touched — the app does not pretend the page is fine.
  String? _dismissedError;
  int? _dismissedHostId;
  Timer? _hideTimer;
  bool _navigationVisible = false;
  late bool _autoHideEnabled;
  int _toolbarHolds = 0;
  int _lastInteraction = 0;
  int _lastHostId = -1;

  ActiveBrowserSession? get _tab => widget.app.activeBrowser;
  HostSession? get host => _tab?.loadedHost;
  List<ActiveBrowserSession> get _tabs => widget.app.browserTabs;

  @override
  void initState() {
    super.initState();
    _autoHideEnabled = widget.app.settings.autoHideBrowserControls;
    widget.app.addListener(_appChanged);
    widget.app.hosts.changed.addListener(_changed);
    // Deferred: opening a tab notifies the controller, and doing that from
    // initState would rebuild listeners during the current build.
    scheduleMicrotask(() => unawaited(_start()));
  }

  void _appChanged() {
    final autoHide = widget.app.settings.autoHideBrowserControls;
    if (autoHide != _autoHideEnabled) {
      _autoHideEnabled = autoHide;
      _hideTimer?.cancel();
      if (autoHide && _navigationVisible) {
        _armHideTimer();
      }
    }
    if (host != null && !host!.disposed && _tab?.failure == null) {
      error = null;
      widget.app.browserVisible = !_covered;
    }
    _syncDismissal();
    if (mounted) setState(() {});
  }

  /// Re-arms the dismissed banner: a different tab, or an error that went away,
  /// means the next occurrence is a new thing to tell the user about.
  void _syncDismissal() {
    final current = host;
    if (current == null || current.error == null) {
      _dismissedError = null;
      _dismissedHostId = null;
      return;
    }
    // The dismissal belongs to one occurrence of one error: another tab, or any
    // other error text shown in the meantime (A -> B -> A), re-arms it so the
    // repeat is visible instead of being swallowed by the earlier dismissal.
    if (_dismissedError != null &&
        (current.id != _dismissedHostId || current.error != _dismissedError)) {
      _dismissedError = null;
      _dismissedHostId = null;
    }
  }

  void _changed() {
    final current = host;
    if (current != null) {
      if (current.id != _lastHostId) {
        _lastHostId = current.id;
        _lastInteraction = current.interactions;
      } else if (current.interactions != _lastInteraction) {
        // Page gestures never reveal the toolbar. Only the floating handle and
        // the toolbar controls are allowed to change its visibility.
        _lastInteraction = current.interactions;
      }
    }
    _syncDismissal();
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final selected = widget.app.activeBrowser;
    try {
      if (selected != null && identical(selected.site, widget.site)) {
        await widget.app.ensureTabLoaded(selected);
      } else {
        await widget.app.openBrowser(widget.site);
      }
      if (!mounted) return;
      widget.app.browserVisible = !_covered;
      setState(() => error = null);
    } catch (e) {
      if (mounted && identical(widget.app.activeBrowser, selected)) {
        setState(() => error = e.toString());
      }
    }
  }

  @override
  void dispose() {
    browserRouteObserver.unsubscribe(this);
    widget.app.browserVisible = false;
    widget.app.removeListener(_appChanged);
    widget.app.hosts.changed.removeListener(_changed);
    _hideTimer?.cancel();
    // Tabs are owned by AppController so the home floating entry can restore
    // the same native WebView without recreating it.
    super.dispose();
  }

  /// Moves the floating controls by [details.delta], in the fraction space the
  /// controller persists. The fraction keeps the control inside the viewport for
  /// any child size, so a wide card cannot be dragged off-screen — it assumes the
  /// control is smaller than the drag area, which holds for every layout the app
  /// targets (an extreme sub-phone width folds the card instead).
  void _moveControls(DragUpdateDetails details) {
    final media = MediaQuery.of(context);
    final child =
        (_controlsKey.currentContext?.findRenderObject() as RenderBox?)?.size ??
        Size.zero;
    final freeWidth = math.max(1.0, media.size.width - 24 - child.width);
    final freeHeight = math.max(
      1.0,
      media.size.height -
          24 -
          media.padding.top -
          media.padding.bottom -
          child.height,
    );
    final current = widget.app.browserControlsFraction;
    unawaited(
      widget.app.setBrowserControlsFraction(
        Offset(
          current.dx + details.delta.dx / freeWidth,
          current.dy + details.delta.dy / freeHeight,
        ),
        persist: false,
      ),
    );
  }

  /// Writes the dragged position once, when the gesture ends: the in-flight
  /// updates only touch memory, and drift serialises writes on its single
  /// connection, so the last gesture wins.
  Future<void> _persistControls() =>
      widget.app.setBrowserControlsFraction(widget.app.browserControlsFraction);

  void _showNavigation() {
    if (!mounted) return;
    setState(() => _navigationVisible = true);
    _armHideTimer();
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    if (!mounted ||
        !_navigationVisible ||
        _toolbarHolds > 0 ||
        !widget.app.settings.autoHideBrowserControls) {
      return;
    }
    _hideTimer = Timer(AppPolicy.hideControlsAfter, () {
      if (mounted &&
          widget.app.settings.autoHideBrowserControls &&
          _toolbarHolds == 0) {
        setState(() => _navigationVisible = false);
      }
    });
  }

  void _keepNavigationVisible() => _armHideTimer();

  /// Transient surfaces hold the toolbar open: its countdown resumes when the
  /// sheet or menu closes instead of expiring behind it.
  Future<T> _withToolbarHeld<T>(Future<T> Function() action) async {
    _toolbarHolds++;
    _hideTimer?.cancel();
    try {
      return await action();
    } finally {
      _toolbarHolds--;
      _keepNavigationVisible();
    }
  }

  Future<bool> _goBack() async {
    _keepNavigationVisible();
    final current = host;
    if (current == null) return false;
    return widget.app.hosts.api.goBack(current.id);
  }

  Future<void> _goForward() async {
    _keepNavigationVisible();
    final current = host;
    if (current == null) return;
    await widget.app.hosts.api.goForward(current.id);
  }

  Future<void> _reload() async {
    _keepNavigationVisible();
    final current = host;
    if (current == null) return;
    await widget.app.hosts.api.reload(current.id);
  }

  Future<void> _goHome() async {
    _keepNavigationVisible();
    final current = host;
    final tab = _tab;
    if (current == null || tab == null) return;
    await widget.app.hosts.navigate(current, tab.site.url);
  }

  bool get _currentTabIsInaccessible {
    final tab = _tab;
    final current = host;
    if (tab == null) return false;
    if (tab.failure != null || error != null || current?.error != null) {
      return true;
    }
    return switch (current?.errorKind) {
      'networkError' || 'certificateError' || 'httpError' => true,
      _ => false,
    };
  }

  /// Leaves the browsing UI. A failed/inaccessible tab is closed first so it
  /// cannot occupy a slot or reappear as a dead restored session.
  void _exitToHome() {
    unawaited(_exitToHomeAsync());
  }

  Future<void> _exitToHomeAsync() async {
    final tab = _tab;
    if (tab != null && _currentTabIsInaccessible) {
      await widget.app.closeTab(tab);
    }
    widget.app.cancel('已退出浏览页');
    _hideTimer?.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  /// Really destroys the current tab's native WebView.
  Future<void> _closeTab() async {
    _keepNavigationVisible();
    final tab = _tab;
    if (tab == null) return;
    final remaining = await widget.app.closeTab(tab);
    if (!mounted) return;
    if (!remaining) _exitToHome();
  }

  Future<void> _addTab() => _withToolbarHeld(() async {
    final current = _tab?.currentUrl.toString();
    await promptNewTab(
      context,
      widget.app,
      initial: current != null && current.isNotEmpty
          ? current
          : (_tab?.site.url.toString() ?? ''),
    );
  });

  Future<void> _openTabSwitcher() => _withToolbarHeld(
    () =>
        showTabSwitcher(context, widget.app, onAdd: () => unawaited(_addTab())),
  );

  Future<void> _retryTab() async {
    final tab = _tab;
    if (tab == null || error != null) {
      await _start();
      return;
    }
    if (mounted) setState(() => error = null);
    await safely(context, () async {
      await widget.app.ensureTabLoaded(tab);
      if (!mounted) return;
      widget.app.browserVisible = !_covered;
      setState(() => error = null);
    });
  }

  Future<void> _systemBack() async {
    if (await _goBack()) return;
    _exitToHome();
  }

  Widget _webContent() {
    final current = host;
    if (error != null || _tab?.failure != null || current?.disposed == true) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _tab?.failure ?? error ?? current?.error ?? '网页进程已退出，请重新加载',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => unawaited(_retryTab()),
                  child: const Text('重新加载'),
                ),
                TextButton(
                  onPressed: () => unawaited(_openTabSwitcher()),
                  child: const Text('切换标签'),
                ),
                TextButton(onPressed: _exitToHome, child: const Text('返回站点')),
              ],
            ),
          ),
        ),
      );
    }
    if (current == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (Platform.isAndroid) {
      // Keyed by the session *object*, not its numeric host id: a fresh session
      // can reuse an id (a new AppController starts ids at 1), and Flutter would
      // then reuse the previous platform view element and keep pointing at the
      // destroyed native host — a new document would never report "loaded".
      return AndroidView(
        key: ValueKey(current),
        viewType: 'site_lens/web_host',
        creationParams: {'hostId': current.id},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (Platform.isIOS) {
      return UiKitView(
        key: ValueKey(current),
        viewType: 'site_lens/web_host',
        creationParams: {'hostId': current.id},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Text(
          '仅支持 Android / iOS 网页宿主',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = host;
    final tab = _tab;
    final padding = MediaQuery.paddingOf(context);
    final bottomInset = padding.bottom;
    final topInset = padding.top;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_systemBack());
      },
      child: SiteLensGlassGroup(
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // Keep the web viewport below the system status bar so the site's
              // own top toolbar stays visible and tappable instead of being
              // swallowed by the status bar window.
              Padding(
                padding: EdgeInsets.only(top: topInset),
                child: _webContent(),
              ),
              if (current?.error != null && current!.error != _dismissedError)
                Positioned(
                  top: topInset + 8,
                  left: 12,
                  right: 12,
                  child: _BrowserNotice(
                    text: current.error!,
                    action: TextButton(
                      onPressed: () => safely(
                        context,
                        () => widget.app.disableAllScripts(true),
                      ),
                      child: const Text('关闭全部脚本'),
                    ),
                    onDismiss: () => setState(() {
                      _dismissedError = current.error;
                      _dismissedHostId = current.id;
                    }),
                  ),
                ),
              if (current != null && !current.capabilities.isolatedScripts)
                Positioned(
                  top: topInset + 8,
                  left: 12,
                  right: 12,
                  child: const _BrowserNotice(
                    tone: _NoticeTone.warning,
                    text: '本机不支持安全隔离，特权脚本已关闭；普通浏览不受影响。',
                  ),
                ),
              // The toolbar is pinned to the bottom edge and overlays the page,
              // so the WebView keeps its size while the bar is open.
              if (tab != null && _navigationVisible)
                Positioned(
                  left: SiteLensMetrics.toolbarInset,
                  right: SiteLensMetrics.toolbarInset,
                  bottom: bottomInset + SiteLensMetrics.toolbarInset,
                  child: Listener(
                    key: const ValueKey('browser-navigation'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) => _keepNavigationVisible(),
                    onPointerMove: (_) => _keepNavigationVisible(),
                    onPointerUp: (_) => _keepNavigationVisible(),
                    child: _BrowserNavigation(
                      tabsCount: _tabs.length,
                      onTabs: () => unawaited(_openTabSwitcher()),
                      onBack: () => unawaited(_goBack()),
                      onForward: () => unawaited(_goForward()),
                      onReload: () => unawaited(_reload()),
                      onHome: () => unawaited(_goHome()),
                      onExit: _exitToHome,
                      onMore: () => unawaited(_openMoreActions()),
                    ),
                  ),
                ),
              // Only the handle moves. Pages — and the user scripts running in
              // them — often own the bottom edge, and only the user knows where
              // they must not overlap. Dragging moves it; a tap opens the bar.
              if (tab != null && !_navigationVisible)
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: SiteLensMetrics.toolbarInset,
                      right: SiteLensMetrics.toolbarInset,
                      top: topInset + SiteLensMetrics.toolbarInset,
                      bottom: bottomInset + SiteLensMetrics.toolbarInset,
                    ),
                    child: Align(
                      alignment: Alignment(
                        widget.app.browserControlsFraction.dx * 2 - 1,
                        widget.app.browserControlsFraction.dy * 2 - 1,
                      ),
                      child: GestureDetector(
                        key: _controlsKey,
                        behavior: HitTestBehavior.opaque,
                        onTap: _showNavigation,
                        onPanUpdate: _moveControls,
                        onPanEnd: (_) => unawaited(_persistControls()),
                        child: const _BrowserHandle(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The "代码" button: run a command a script registered, and show which
  /// scripts are live here — the menu list is empty whenever no *active* script
  /// called `GM_registerMenuCommand`, and saying so beats an empty sheet.
  Future<void> _menus() => _withToolbarHeld(_showMenusSheet);

  /// The occasional and destructive actions. A sheet, not a popup menu: an
  /// Android popup menu is composited below the WebView's platform view, so
  /// over the page it is unreadable. Sheets render correctly above it.
  Future<void> _openMoreActions() => _withToolbarHeld(() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add, size: 20),
              title: const Text('新建标签页'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_addTab());
              },
            ),
            ListTile(
              leading: const Icon(Icons.code, size: 20),
              title: const Text('脚本菜单与恢复'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_menus());
              },
            ),
            ListTile(
              leading: const Icon(Icons.close, size: 20),
              title: const Text('关闭当前标签页'),
              subtitle: const Text('销毁这个标签页的 WebView'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_closeTab());
              },
            ),
          ],
        ),
      ),
    );
  });

  Future<void> _showMenusSheet() async {
    final tab = _tab;
    final current = host;
    final menus = current?.menus.values.toList() ?? const <ScriptMenu>[];
    final active = tab == null
        ? const <InstalledScript>[]
        : widget.app.activeScriptsFor(tab);
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('当前文档脚本菜单')),
            for (final menu in menus)
              ListTile(
                title: Text(menu.label),
                leading: const Icon(Icons.play_arrow),
                onTap: () {
                  Navigator.pop(c);
                  safely(
                    context,
                    () => widget.app.hosts.invokeMenu(current!, menu),
                  );
                },
              ),
            if (menus.isEmpty)
              const ListTile(
                title: Text('没有脚本菜单'),
                subtitle: Text(
                  '菜单只来自脚本里的 GM_registerMenuCommand；脚本没写、没启用，或 @match 不覆盖当前页面时这里就是空的（下一条列出本次实际生效的脚本）。',
                ),
              ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('本站脚本'),
              onTap: () {
                Navigator.pop(c);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ScriptManagementScreen(
                      app: widget.app,
                      profileId: _tab?.site.profileId,
                    ),
                  ),
                );
              },
            ),
            const Divider(),
            ListTile(
              title: const Text('本次文档生效脚本'),
              subtitle: Text(
                tab == null || active.isNotEmpty
                    ? active.map((s) => s.name).join('、')
                    : widget.app.scriptActivityReason(tab),
              ),
            ),
            if (widget.app.scriptsDisabled)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('重新启用脚本并刷新'),
                subtitle: const Text('全局关闭是持久开关；它关着时任何 @match 都不会生效'),
                onTap: () {
                  Navigator.pop(c);
                  safely(context, () async {
                    await widget.app.disableAllScripts(false);
                    await widget.app.reloadScripts();
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重新加载脚本并刷新页面'),
              subtitle: const Text('在「脚本管理」页改过脚本/授权后，用它让本页生效'),
              onTap: () {
                Navigator.pop(c);
                safely(context, () async {
                  await widget.app.reloadScripts();
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.shield),
              title: const Text('关闭全部脚本并重载（恢复）'),
              onTap: () {
                Navigator.pop(c);
                safely(context, () => widget.app.disableAllScripts(true));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The browser toolbar: one fixed row of seven equal controls, pinned to the
/// bottom edge over the page. It never wraps, scrolls or folds — the controls
/// stay where the user learned to find them.
/// One cell of the fixed toolbar: a tooltip, a glyph, and the action it runs.
class _ToolbarAction {
  const _ToolbarAction(this.tooltip, this.icon, this.run, {this.badge});
  final String tooltip;
  final IconData icon;
  final VoidCallback run;
  final int? badge;
}

class _BrowserNavigation extends StatelessWidget {
  const _BrowserNavigation({
    required this.tabsCount,
    required this.onTabs,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onHome,
    required this.onExit,
    required this.onMore,
  });
  final int tabsCount;
  final VoidCallback onTabs;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onHome;
  final VoidCallback onExit;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    // The row is built from one list so the count the layout test pins
    // (`browserToolbarItemCount`) is the count the widget actually renders.
    final actions = <_ToolbarAction>[
      _ToolbarAction('后退', Icons.arrow_back_ios_new, onBack),
      _ToolbarAction('前进', Icons.arrow_forward_ios, onForward),
      _ToolbarAction('刷新', Icons.refresh, onReload),
      _ToolbarAction('回到首页（浏览器不退出）', Icons.home_outlined, onHome),
      _ToolbarAction('标签页（缩略图选择）', Icons.tab, onTabs, badge: tabsCount),
      _ToolbarAction('退出浏览器到首页（保留标签页）', Icons.exit_to_app, onExit),
      _ToolbarAction('更多浏览器操作', Icons.more_horiz, onMore),
    ];
    assert(
      actions.length == browserToolbarItemCount,
      'the toolbar is a fixed $browserToolbarItemCount-control row',
    );
    return SiteLensGlassSurface(
      role: SiteLensSurfaceRole.platformView,
      radius: SiteLensMetrics.toolbarRadius,
      child: SizedBox(
        height: SiteLensMetrics.toolbarHeight,
        child: Row(
          children: [
            for (final action in actions)
              Expanded(
                child: _BrowserNavButton(
                  tooltip: action.tooltip,
                  icon: action.icon,
                  badge: action.badge,
                  onPressed: action.run,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One control of the fixed toolbar. The glyph is bare — the toolbar's own
/// glass is the only surface — and the whole cell is the tap target.
class _BrowserNavButton extends StatelessWidget {
  const _BrowserNavButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.badge,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, size: SiteLensMetrics.toolbarIconSize);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.expand(),
      icon: badge == null || badge! < 1
          ? glyph
          : Badge(label: Text('$badge'), child: glyph),
    );
  }
}

/// The one movable control in the browsing view: a semi-transparent handle the
/// user drags where the page's own controls are not. Tapping it reveals the
/// toolbar; the toolbar itself is fixed.
class _BrowserHandle extends StatelessWidget {
  const _BrowserHandle();
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '展开浏览工具栏（可拖动）',
    child: SiteLensGlassSurface(
      role: SiteLensSurfaceRole.platformView,
      radius: 18,
      child: SizedBox(
        width: 60,
        height: 36,
        child: Icon(
          Icons.keyboard_arrow_up,
          size: 16,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
  );
}

/// What the notice is telling the user: a degraded capability (warning) or a
/// failure (error). The colour role follows, so one surface serves both.
enum _NoticeTone { warning, error }

class _BrowserNotice extends StatelessWidget {
  const _BrowserNotice({
    required this.text,
    this.tone = _NoticeTone.error,
    this.action,
    this.onDismiss,
  });
  final String text;
  final _NoticeTone tone;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => SiteLensGlassSurface(
    role: SiteLensSurfaceRole.platformView,
    radius: 18,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Icon(
            tone == _NoticeTone.error
                ? Icons.error_outline
                : Icons.info_outline,
            color: tone == _NoticeTone.error
                ? SiteLensColors.of(context).danger
                : SiteLensColors.of(context).warning,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
          ?action,
          if (onDismiss != null)
            IconButton(
              tooltip: '清除这条提示',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    ),
  );
}
