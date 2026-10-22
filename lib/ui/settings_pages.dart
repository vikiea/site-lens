part of 'screens.dart';

/// Settings pages contain a small number of ordinary panels and one page scroll owner.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => _settingsList([
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '外观与玻璃',
          Icons.palette_outlined,
          () => AppearanceSettingsScreen(app: app),
          subtitle: '明暗、主题色、不透明度与质量',
        ),
        _settingsLink(
          context,
          app,
          '浏览设置',
          Icons.public,
          () => BrowserSettingsScreen(app: app),
          subtitle: '标签、控件、过滤与脚本',
        ),
        _settingsLink(
          context,
          app,
          '媒体管理',
          Icons.video_library_outlined,
          () => MediaManagementScreen(app: app),
          subtitle: '下载、播放、导出与投屏',
        ),
      ]),
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '数据管理',
          Icons.storage_outlined,
          () => DataManagementScreen(app: app),
          subtitle: '备份、恢复与默认偏好',
        ),
        _settingsLink(
          context,
          app,
          '设备能力与平台策略',
          Icons.health_and_safety_outlined,
          () => DeviceDiagnosticsScreen(app: app),
          subtitle: '查看实际能力、授权状态和当前策略',
        ),
        _settingsLink(
          context,
          app,
          '后台与诊断',
          Icons.settings_backup_restore_outlined,
          () => BackgroundSettingsScreen(app: app),
          subtitle: '后台任务、错误日志与支持边界',
        ),
        _settingsLink(
          context,
          app,
          '关于与更新',
          Icons.info_outline,
          () => UpdateSettingsScreen(app: app),
          subtitle: '版本、更新渠道与项目链接',
        ),
      ]),
    ], key: const PageStorageKey('settings-overview')),
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

class _SettingsSubpage extends StatelessWidget {
  const _SettingsSubpage({
    required this.app,
    required this.title,
    required this.panels,
  });
  final AppController app;
  final String title;
  final List<Widget> Function(BuildContext) panels;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => SiteLensPageScaffold(
      title: title,
      body: SiteLensGlassGroup(
        child: _settingsList(panels(context), key: PageStorageKey(title)),
      ),
    ),
  );
}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => _SettingsSubpage(
    app: app,
    title: '外观与玻璃',
    panels: (context) => [
      _settingsPanel([
        _settingsRowTitle(context, Icons.brightness_6_outlined, '明暗模式'),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
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
      ]),
      _settingsPanel([
        LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth <
                400 * MediaQuery.textScalerOf(context).scale(1);
            final title = ListTile(
              leading: const Icon(Icons.opacity_outlined, size: 20),
              title: const Text('不透明度'),
              subtitle: Text('${app.settings.glassOpacity} / 100'),
              trailing: compact ? null : _GlassOpacitySlider(app: app),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                if (compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                    child: _GlassOpacitySlider(
                      app: app,
                      width: double.infinity,
                    ),
                  ),
              ],
            );
          },
        ),
      ]),
      _settingsPanel([
        _settingsRowTitle(context, Icons.speed_outlined, '玻璃质量'),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
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
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
          leading: const SizedBox(width: 20),
          title: const Text('当前有效质量'),
          subtitle: Text(app.effectiveGlassQuality.label),
        ),
        if (app.settings.glassQualityMode != SiteLensGlassQualityMode.standard)
          SwitchListTile(
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
      ]),
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '主题色',
          Icons.palette_outlined,
          () => ThemePresetSettingsScreen(app: app),
          subtitle: app.themePreset.label,
        ),
      ]),
    ],
  );
}

class ThemePresetSettingsScreen extends StatelessWidget {
  const ThemePresetSettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => _SettingsSubpage(
    app: app,
    title: '主题色',
    panels: (context) => [
      for (final presets in [
        ThemePresetId.values.take(6),
        ThemePresetId.values.skip(6),
      ])
        SiteLensPanel(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                _ThemePresetChip(
                  preset: preset,
                  selected: preset == app.themePreset,
                  onTap: () =>
                      safely(context, () => app.setThemePreset(preset)),
                ),
            ],
          ),
        ),
    ],
  );
}

class BrowserSettingsScreen extends StatelessWidget {
  const BrowserSettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => _SettingsSubpage(
    app: app,
    title: '浏览设置',
    panels: (context) => [
      _settingsPanel([
        SwitchListTile(
          title: const Text('恢复上次标签'),
          subtitle: const Text('重启后恢复列表，选择标签时加载'),
          value: app.restoreBrowserSessions,
          onChanged: (value) =>
              safely(context, () => app.setRestoreBrowserSessions(value)),
        ),
        SwitchListTile(
          title: const Text('同站点标签页互相替换'),
          subtitle: const Text('打开同一档案的新落点时复用已有标签；默认允许多标签'),
          value: app.settings.replaceSameSiteTabs,
          onChanged: (value) => safely(
            context,
            () => app.updateSettings({'replaceSameSiteTabs': value}),
          ),
        ),
      ]),
      _settingsPanel([
        SwitchListTile(
          title: const Text('自动隐藏浏览控件'),
          subtitle: const Text('停止操作 3 秒后收起，点击浮动把手展开'),
          value: app.settings.autoHideBrowserControls,
          onChanged: (value) => safely(
            context,
            () => app.updateSettings({'autoHideBrowserControls': value}),
          ),
        ),
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
      ]),
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '广告与反跟踪',
          Icons.shield_outlined,
          () => FilterSettingsScreen(app: app),
          subtitle: '规则源、拦截域名与例外',
        ),
        _settingsLink(
          context,
          app,
          '脚本管理',
          Icons.code,
          () => ScriptManagementScreen(app: app),
          subtitle: '${app.installed.length} 个脚本',
        ),
      ]),
    ],
  );
}

class BackgroundSettingsScreen extends StatelessWidget {
  const BackgroundSettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => _SettingsSubpage(
    app: app,
    title: '后台与诊断',
    panels: (context) => [
      _settingsPanel([
        SwitchListTile(
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
      ]),
      _settingsPanel([
        SwitchListTile(
          title: const Text('后台存活检查'),
          subtitle: const Text('仅充电 + WiFi，每天最多两次；只做 HTTP 初筛'),
          value: app.backgroundHealthCheck,
          onChanged: (value) =>
              safely(context, () => app.setBackgroundHealthCheck(value)),
        ),
        _Details(
          key: const ValueKey('details-background-health'),
          text:
              '只做 HTTP 初筛，不启动 WebView，因此不会干扰登录状态与用户脚本。'
              '触发条件需要同时满足充电与 WiFi，并且每天最多两次。'
              '这是尽力而为的后台任务：系统可能延迟或跳过，结果不保证时效。',
        ),
      ]),
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '错误日志',
          Icons.bug_report_outlined,
          () => ErrorLogsScreen(app: app),
          subtitle: '经过脱敏的应用错误记录',
        ),
        _settingsLink(
          context,
          app,
          '支持边界',
          Icons.help_outline,
          () => SupportSettingsScreen(app: app),
        ),
      ]),
    ],
  );
}

class SupportSettingsScreen extends StatelessWidget {
  const SupportSettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => _SettingsSubpage(
    app: app,
    title: '支持边界',
    panels: (context) => [
      _settingsPanel([
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
          startsOpen: true,
        ),
      ]),
    ],
  );
}

class UpdateSettingsScreen extends StatelessWidget {
  const UpdateSettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => _SettingsSubpage(
    app: app,
    title: '关于与更新',
    panels: (context) => [
      _settingsPanel([
        _settingsLink(
          context,
          app,
          '关于 Site Lens',
          Icons.info_outline,
          () => const AboutScreen(),
          subtitle: '版本、许可证与项目链接',
        ),
      ]),
      _settingsPanel([
        ListTile(
          leading: const Icon(Icons.alt_route_outlined),
          title: const Text('更新渠道'),
          subtitle: Text(app.settings.updateChannel.description),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: SiteLensSegmented<UpdateChannel>(
            value: app.settings.updateChannel,
            onChanged: (value) => safely(
              context,
              () => app.updateSettings({'updateChannel': value.name}),
            ),
            options: const [
              (UpdateChannel.stable, '稳定版', Icons.verified_outlined),
              (UpdateChannel.beta, '测试版', Icons.science_outlined),
            ],
          ),
        ),
        if (app.settings.updateChannel == UpdateChannel.beta) ...[
          const Divider(height: 1, indent: 18, endIndent: 18),
          const _GitHubTokenEntry(),
        ],
        const Divider(height: 1, indent: 18, endIndent: 18),
        _UpdateEntryRow(app: app),
      ]),
    ],
  );
}

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
