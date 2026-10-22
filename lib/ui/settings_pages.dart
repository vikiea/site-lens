part of 'screens.dart';

/// The settings overview keeps finite preference groups on one page. Long or
/// workflow-heavy features still open their dedicated screens.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => _settingsList([
      _SettingsOverviewPanel(
        title: '外观',
        icon: Icons.palette_outlined,
        subtitle: '明暗、不透明度、玻璃质量与主题色',
        initiallyExpanded: true,
        child: _AppearanceOverview(app: app),
      ),
      _SettingsOverviewPanel(
        title: '浏览',
        icon: Icons.public,
        subtitle: '标签、控件、过滤与脚本',
        child: _BrowserOverview(app: app),
      ),
      _SettingsOverviewPanel(
        title: '媒体',
        icon: Icons.video_library_outlined,
        subtitle: '播放、导出、任务与手势',
        child: _MediaOverview(app: app),
      ),
      _SettingsOverviewPanel(
        title: '数据与诊断',
        icon: Icons.health_and_safety_outlined,
        subtitle: '备份、恢复、设备能力与错误日志',
        child: _DataAndDiagnosticsOverview(app: app),
      ),
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '关于',
          Icons.info_outline,
          () => const AboutScreen(),
          subtitle: '版本、许可证与项目链接',
        ),
        _UpdateEntryRow(app: app),
      ]),
    ], key: const PageStorageKey('settings-overview')),
  );
}

class _SettingsOverviewPanel extends StatelessWidget {
  const _SettingsOverviewPanel({
    required this.title,
    required this.icon,
    required this.subtitle,
    required this.child,
    this.initiallyExpanded = false,
  });

  final String title;
  final IconData icon;
  final String subtitle;
  final Widget child;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => SiteLensSettingsPanel(
    title: title,
    icon: icon,
    subtitle: subtitle,
    initiallyExpanded: initiallyExpanded,
    child: child,
  );
}

class _AppearanceOverview extends StatelessWidget {
  const _AppearanceOverview({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final accordion = SiteLensAccordionController();
    return ListenableBuilder(
      listenable: accordion,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _settingsRowTitle(context, Icons.brightness_6_outlined, '明暗模式'),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: SiteLensSegmented<ThemeModePreference>(
              value: app.themeModePreference,
              onChanged: (value) =>
                  safely(context, () => app.setThemeModePreference(value)),
              options: const [
                (
                  ThemeModePreference.system,
                  '系统',
                  Icons.brightness_auto_outlined,
                ),
                (ThemeModePreference.light, '浅色', Icons.light_mode_outlined),
                (ThemeModePreference.dark, '深色', Icons.dark_mode_outlined),
              ],
            ),
          ),
          _OpacitySetting(app: app),
          _settingsRowTitle(context, Icons.speed_outlined, '玻璃质量'),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: SiteLensSegmented<SiteLensGlassQualityMode>(
              value: app.settings.glassQualityMode,
              onChanged: (value) =>
                  safely(context, () => app.setGlassQualityMode(value)),
              options: const [
                (
                  SiteLensGlassQualityMode.automatic,
                  '自动',
                  Icons.auto_awesome_outlined,
                ),
                (SiteLensGlassQualityMode.standard, '标准', Icons.tune_outlined),
                (SiteLensGlassQualityMode.high, '高质量', Icons.hd_outlined),
              ],
            ),
          ),
          SiteLensCompactRow(
            title: const Text('当前有效质量'),
            subtitle: Text(app.effectiveGlassQuality.label),
          ),
          if (app.settings.glassQualityMode !=
              SiteLensGlassQualityMode.standard)
            SwitchListTile(
              dense: true,
              title: const Text('高质量覆盖全部面板'),
              subtitle: Text(
                app.settings.glassQualityMode ==
                        SiteLensGlassQualityMode.automatic
                    ? '自动选择高质量时应用于内容面板'
                    : '应用于内容面板、弹窗和卡片',
              ),
              value: app.settings.highQualityAllSurfaces,
              onChanged: (value) =>
                  safely(context, () => app.setHighQualityAllSurfaces(value)),
            ),
          SiteLensAccordion(
            id: 'theme-presets',
            controller: accordion,
            title: const Text('主题色'),
            subtitle: Text(app.themePreset.label),
            leading: const Icon(Icons.palette_outlined, size: 18),
            details: (context) => Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in ThemePresetId.values)
                    _ThemePresetChip(
                      preset: preset,
                      selected: preset == app.themePreset,
                      onTap: () =>
                          safely(context, () => app.setThemePreset(preset)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OpacitySetting extends StatelessWidget {
  const _OpacitySetting({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context).scale(1);
      final compact = constraints.maxWidth < 400 * scaler;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SiteLensCompactRow(
            leading: const Icon(Icons.opacity_outlined, size: 18),
            title: const Text('不透明度'),
            subtitle: Text('${app.settings.glassOpacity} / 100'),
            trailing: compact ? null : _GlassOpacitySlider(app: app),
          ),
          if (compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: _GlassOpacitySlider(app: app, width: double.infinity),
            ),
        ],
      );
    },
  );
}

class _BrowserOverview extends StatelessWidget {
  const _BrowserOverview({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final accordion = SiteLensAccordionController();
    return ListenableBuilder(
      listenable: accordion,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            dense: true,
            title: const Text('恢复上次标签'),
            subtitle: const Text('重启后恢复列表，选择标签时加载'),
            value: app.restoreBrowserSessions,
            onChanged: (value) =>
                safely(context, () => app.setRestoreBrowserSessions(value)),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('同站点标签页互相替换'),
            subtitle: const Text('打开同一档案的新落点时复用已有标签；默认允许多标签'),
            value: app.settings.replaceSameSiteTabs,
            onChanged: (value) => safely(
              context,
              () => app.updateSettings({'replaceSameSiteTabs': value}),
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('自动隐藏浏览控件'),
            subtitle: const Text('停止操作 3 秒后收起，点击浮动把手展开'),
            value: app.settings.autoHideBrowserControls,
            onChanged: (value) => safely(
              context,
              () => app.updateSettings({'autoHideBrowserControls': value}),
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('浏览页下拉刷新（Android）'),
            subtitle: const Text('默认关闭：下拉手势属于页面和用户脚本'),
            value: app.pullToRefresh,
            onChanged: (value) =>
                safely(context, () => app.setPullToRefresh(value)),
          ),
          SiteLensAccordion(
            id: 'pull-refresh-details',
            controller: accordion,
            title: const Text('下拉刷新详情'),
            details: (_) => const Text('打开后，页面处于顶部时下拉即刷新当前页。关闭时下拉手势完全交给页面。'),
          ),
          const SiteLensPanelDivider(),
          _settingsLink(
            context,
            app,
            '广告与反跟踪',
            Icons.shield_outlined,
            () => FilterSettingsScreen(app: app),
            subtitle: app.filterPolicy.enabled
                ? '${app.filterSourceList.length} 个规则源 · 已启用'
                : '规则源、拦截域名与例外',
          ),
          const SiteLensPanelDivider(),
          _settingsLink(
            context,
            app,
            '脚本管理',
            Icons.code,
            () => ScriptManagementScreen(app: app),
            subtitle: '${app.installed.length} 个脚本',
          ),
        ],
      ),
    );
  }
}

class _MediaOverview extends StatefulWidget {
  const _MediaOverview({required this.app});
  final AppController app;

  @override
  State<_MediaOverview> createState() => _MediaOverviewState();
}

class _MediaOverviewState extends State<_MediaOverview> {
  AppController get app => widget.app;

  Future<void> _pickMp4Directory() async {
    final selected = Platform.isAndroid && app.nativeExports != null
        ? await app.nativeExports!.pickDirectory()
        : await FilePicker.getDirectoryPath(dialogTitle: '选择 MP4 保存目录');
    if (selected == null || selected.trim().isEmpty) return;
    await app.setMp4ExportDirectory(selected);
    if (mounted) showShortToast(context, 'MP4 保存目录已更新');
  }

  String _directoryLabel() {
    final value = app.mp4ExportDirectory?.trim();
    if (value == null || value.isEmpty) return '未配置，保存在应用媒体库';
    return readableMediaLocation(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SwitchListTile(
        dense: true,
        title: const Text('当前标签后台播放（Android）'),
        subtitle: Text(
          app.mediaSupported
              ? '离开浏览页后继续播放，可从系统媒体通知暂停或停止'
              : '打开网页后检查播放能力；默认离开即暂停',
        ),
        value: app.allowBackgroundPlayback,
        onChanged: (app.mediaSupported || app.allowBackgroundPlayback)
            ? (value) =>
                  safely(context, () => app.setAllowBackgroundPlayback(value))
            : null,
      ),
      SwitchListTile(
        dense: true,
        title: const Text('下载完成自动导出 MP4'),
        subtitle: const Text('保留原始 HLS，MP4 只保存一份到媒体库或指定目录'),
        value: app.autoConvertToMp4,
        onChanged: (value) =>
            safely(context, () => app.setAutoConvertToMp4(value)),
      ),
      SiteLensActionRow(
        icon: Icons.folder_outlined,
        title: 'MP4 保存目录',
        subtitle: _directoryLabel(),
        onTap: () => safely(context, _pickMp4Directory),
      ),
      if (app.mp4ExportDirectory != null) ...[
        const SiteLensPanelDivider(),
        SiteLensCompactRow(
          title: const Text('恢复应用媒体库'),
          subtitle: const Text('清除目录配置，后续 MP4 只保存在应用媒体库'),
          trailing: TextButton(
            onPressed: () =>
                safely(context, () => app.setMp4ExportDirectory(null)),
            child: const Text('清除'),
          ),
        ),
      ],
      const SiteLensPanelDivider(),
      _settingsLink(
        context,
        app,
        '媒体任务',
        Icons.download_for_offline_outlined,
        () => MediaTasksScreen(app: app),
        subtitle: '查看后台下载、播放和导出状态',
      ),
      const SiteLensPanelDivider(),
      _PlayerGestureInline(app: app),
    ],
  );
}

class _PlayerGestureInline extends StatelessWidget {
  const _PlayerGestureInline({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final accordion = SiteLensAccordionController();
    return ListenableBuilder(
      listenable: accordion,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SiteLensCompactRow(
            leading: const Icon(Icons.swipe_vertical_outlined, size: 18),
            title: const Text('上下滑动'),
            trailing: SiteLensMenuSelector<PlayerVerticalGestureMode>(
              label: '选择上下滑动操作',
              value: app.playerVerticalGesture,
              onSelected: (value) =>
                  safely(context, () => app.setPlayerVerticalGesture(value)),
              options: [
                for (final mode in PlayerVerticalGestureMode.values)
                  SiteLensMenuOption(value: mode, label: mode.label),
              ],
            ),
          ),
          SiteLensAccordion(
            id: 'gesture-help',
            controller: accordion,
            title: const Text('手势说明'),
            details: (context) => const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('左右滑动：快进 / 快退'),
                SizedBox(height: 6),
                Text('长按：临时 2 倍速'),
                SizedBox(height: 6),
                Text('双击：播放 / 暂停'),
                SizedBox(height: 6),
                Text('单击：显示 / 隐藏控制栏'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DataAndDiagnosticsOverview extends StatelessWidget {
  const _DataAndDiagnosticsOverview({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final accordion = SiteLensAccordionController();
    return ListenableBuilder(
      listenable: accordion,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            dense: true,
            title: const Text('后台存活检查'),
            subtitle: const Text('仅充电 + WiFi，每天最多两次；只做 HTTP 初筛'),
            value: app.backgroundHealthCheck,
            onChanged: (value) =>
                safely(context, () => app.setBackgroundHealthCheck(value)),
          ),
          SiteLensAccordion(
            id: 'background-health-details',
            controller: accordion,
            title: const Text('后台存活检查详情'),
            details: (_) => const Text(
              '只做 HTTP 初筛，不启动 WebView，因此不会干扰登录状态与用户脚本。'
              '触发条件需要同时满足充电与 WiFi，并且每天最多两次。'
              '这是尽力而为的后台任务：系统可能延迟或跳过，结果不保证时效。',
            ),
          ),
          const SiteLensPanelDivider(),
          _DataActionsPanel(app: app),
          const SiteLensPanelDivider(),
          _settingsLink(
            context,
            app,
            '设备能力与平台策略',
            Icons.health_and_safety_outlined,
            () => DeviceDiagnosticsScreen(app: app),
            subtitle: '查看实际能力、授权状态和当前策略',
          ),
          const SiteLensPanelDivider(),
          _settingsLink(
            context,
            app,
            '错误日志',
            Icons.bug_report_outlined,
            () => ErrorLogsScreen(app: app),
            subtitle: '查看经过脱敏的应用错误记录',
          ),
          const SiteLensPanelDivider(),
          SiteLensAccordion(
            id: 'support-boundary',
            controller: accordion,
            title: const Text('支持边界'),
            leading: const Icon(Icons.help_outline, size: 18),
            details: (_) => const Text(
              'Android 8.0+ / iOS 15+，实际增强能力以运行时检查为准。浏览保留各域名登录；'
              '发现与检测无用户脚本、独立 Cookie 和存储。没有代理、没有破解、不忽略 TLS 错误、'
              '不接管播放器、不承诺视频质量。数据仅存本机。',
            ),
          ),
        ],
      ),
    );
  }
}

class _DataActionsPanel extends StatefulWidget {
  const _DataActionsPanel({required this.app});
  final AppController app;

  @override
  State<_DataActionsPanel> createState() => _DataActionsPanelState();
}

class _DataActionsPanelState extends State<_DataActionsPanel> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await safely(context, action);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _export() async {
    final data = await widget.app.exportBackup();
    final result = await FilePicker.saveFile(
      bytes: data,
      fileName:
          'site-lens-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}.backup.zip',
      mimeType: 'application/zip',
      dialogTitle: '保存完整备份',
    );
    if (result != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('完整备份已保存')));
    }
  }

  Future<void> _restore() async {
    final selected = await FilePicker.pickFiles(type: FileType.any);
    if (selected.isEmpty) return;
    final size = await selected.single.length();
    if (size == null || size > BackupService.maxBytes) {
      throw const FormatException('备份超过 64 MB 限制');
    }
    final snapshot = await widget.app.inspectBackup(
      await selected.single.readAsBytes(),
    );
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => SiteLensAlertDialog(
        title: const Text('替换本机业务数据？'),
        content: Text(
          '备份时间：${snapshot.createdAt}\n${snapshot.profiles} 个档案，${snapshot.scripts} 个脚本。\n\n恢复前会保留当前数据的安全备份；所有导入脚本关闭，确认权限后再启用。网页登录不会迁移。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复备份'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.app.restoreBackup(snapshot);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('业务数据已恢复，脚本需要重新确认；恢复前备份已保留在本机')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SiteLensCompactRow(
        leading: const Icon(Icons.backup_outlined, size: 18),
        title: const Text('导出完整备份'),
        subtitle: const Text('保存为 .backup.zip 文件'),
        onTap: _busy ? null : () => _run(_export),
      ),
      SiteLensCompactRow(
        leading: const Icon(Icons.restore, size: 18),
        title: const Text('恢复完整备份'),
        subtitle: const Text('校验后替换，并保留恢复前的数据'),
        onTap: _busy ? null : () => _run(_restore),
      ),
      SiteLensCompactRow(
        leading: const Icon(Icons.settings_backup_restore, size: 18),
        title: const Text('恢复默认偏好'),
        subtitle: const Text('保留档案、脚本、脚本停用状态及浏览记录'),
        onTap: _busy ? null : () => _run(widget.app.resetPreferences),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: LinearProgressIndicator(),
        ),
    ],
  );
}

Widget _settingsLink(
  BuildContext context,
  AppController app,
  String title,
  IconData icon,
  Widget Function() page, {
  String? subtitle,
}) => SiteLensActionRow(
  icon: icon,
  title: title,
  subtitle: subtitle,
  onTap: () =>
      Navigator.of(context)
          .push<void>(MaterialPageRoute(builder: (_) => page())),
);

Widget _settingsList(List<Widget> children, {Key? key}) => ListView.separated(
  key: key,
  padding: const EdgeInsets.fromLTRB(
    SiteLensMetrics.pagePadding,
    12,
    SiteLensMetrics.pagePadding,
    32,
  ),
  itemCount: children.length,
  itemBuilder: (_, index) => children[index],
  separatorBuilder: (_, _) => const SizedBox(height: SiteLensMetrics.itemGap),
);

Widget _settingsPanel(List<Widget> rows) => SiteLensPanel(
  padding: EdgeInsets.zero,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const Divider(height: 1, indent: 18, endIndent: 18),
        rows[i],
      ],
    ],
  ),
);

Widget _settingsRowTitle(BuildContext context, IconData icon, String title) =>
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
