part of 'screens.dart';

/// The settings home is a calm index of everyday controls. Categories stay
/// visible; workflow-heavy features keep their focused second-level screens.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => _settingsList([
      _settingsSection('外观', [
        _settingsRowTitle(context, Icons.brightness_6_outlined, '明暗模式'),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
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
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
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
        if (app.settings.glassQualityMode != SiteLensGlassQualityMode.standard)
          _settingsSwitch(
            context,
            title: '高质量覆盖全部面板',
            subtitle:
                app.settings.glassQualityMode ==
                    SiteLensGlassQualityMode.automatic
                ? '自动选择高质量时应用于内容面板'
                : '应用于内容面板、弹窗和卡片',
            value: app.settings.highQualityAllSurfaces,
            onChanged: app.setHighQualityAllSurfaces,
          ),
        _ThemePresetRow(app: app),
      ], dividers: false),
      _settingsSection('浏览', [
        _settingsSwitch(
          context,
          title: '恢复上次标签',
          subtitle: '重启后恢复上次打开的标签',
          value: app.restoreBrowserSessions,
          onChanged: app.setRestoreBrowserSessions,
        ),
        _settingsSwitch(
          context,
          title: '同站点标签页互相替换',
          subtitle: '打开同一档案的新落点时复用已有标签',
          value: app.settings.replaceSameSiteTabs,
          onChanged: (value) =>
              app.updateSettings({'replaceSameSiteTabs': value}),
        ),
        _settingsSwitch(
          context,
          title: '自动隐藏浏览控件',
          subtitle: '停止操作后自动收起，点击把手即可展开',
          value: app.settings.autoHideBrowserControls,
          onChanged: (value) =>
              app.updateSettings({'autoHideBrowserControls': value}),
        ),
        _settingsSwitch(
          context,
          title: '下拉刷新',
          subtitle: '页面位于顶部时可以下拉刷新',
          value: app.pullToRefresh,
          onChanged: app.setPullToRefresh,
        ),
        _settingsLink(
          context,
          title: '广告与反跟踪',
          icon: Icons.shield_outlined,
          subtitle: app.filterPolicy.enabled
              ? '已启用 · ${app.filterSourceList.length} 个规则源'
              : '规则源、拦截域名与例外',
          page: () => FilterSettingsScreen(app: app),
        ),
        _settingsLink(
          context,
          title: '脚本管理',
          icon: Icons.code,
          subtitle: '${app.installed.length} 个已安装脚本',
          page: () => ScriptManagementScreen(app: app),
        ),
      ]),
      _settingsSection('媒体', [
        _settingsSwitch(
          context,
          title: '当前标签后台播放',
          subtitle: app.mediaSupported ? '离开浏览页后继续播放' : '打开网页后检查播放能力',
          value: app.allowBackgroundPlayback,
          enabled: app.mediaSupported || app.allowBackgroundPlayback,
          onChanged: app.setAllowBackgroundPlayback,
        ),
        _settingsLink(
          context,
          title: '媒体管理',
          icon: Icons.video_library_outlined,
          subtitle: '下载、播放、导出与保存目录',
          page: () => MediaManagementScreen(app: app),
        ),
        _settingsLink(
          context,
          title: '播放器手势',
          icon: Icons.swipe_vertical_outlined,
          subtitle: app.playerVerticalGesture.label,
          page: () => PlayerGesturesScreen(app: app),
        ),
      ]),
      _settingsSection('数据与诊断', [
        _settingsSwitch(
          context,
          title: '后台存活检查',
          subtitle: '在合适时机检查站点是否可访问',
          value: app.backgroundHealthCheck,
          onChanged: app.setBackgroundHealthCheck,
        ),
        _settingsLink(
          context,
          title: '备份与恢复',
          icon: Icons.storage_outlined,
          subtitle: '导出、恢复与默认偏好',
          page: () => DataManagementScreen(app: app),
        ),
        _settingsLink(
          context,
          title: '设备能力',
          icon: Icons.health_and_safety_outlined,
          subtitle: '查看设备支持情况与当前策略',
          page: () => DeviceDiagnosticsScreen(app: app),
        ),
        _settingsLink(
          context,
          title: '错误日志',
          icon: Icons.bug_report_outlined,
          subtitle: '查看经过脱敏的应用错误记录',
          page: () => ErrorLogsScreen(app: app),
        ),
      ]),
      _settingsSection('应用', [
        _settingsLink(
          context,
          title: '关于',
          icon: Icons.info_outline,
          subtitle: '版本、许可证与项目链接',
          page: () => const AboutScreen(),
        ),
        _UpdateEntryRow(app: app),
      ]),
      const SizedBox(height: SiteLensMetrics.sectionGap),
      Center(
        child: Text(
          '择站 · Site Lens',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: SiteLensColors.of(context).sectionLabel),
        ),
      ),
    ], key: const PageStorageKey('settings-overview')),
  );
}

class _OpacitySetting extends StatelessWidget {
  const _OpacitySetting({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context).scale(1);
      final inline = constraints.maxWidth >= 280 * scaler;
      if (!inline) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SiteLensCompactRow(
              leading: const Icon(Icons.opacity_outlined, size: 18),
              title: const Text('不透明度'),
              subtitle: Text('${app.settings.glassOpacity} / 100'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: _GlassOpacitySlider(app: app, width: double.infinity),
            ),
          ],
        );
      }
      final sliderWidth = (constraints.maxWidth - 164)
          .clamp(110.0, 180.0)
          .toDouble();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.opacity_outlined, size: 18),
            const SizedBox(width: 8),
            const Text('不透明度', maxLines: 1, softWrap: false),
            const SizedBox(width: 8),
            Text(
              '${app.settings.glassOpacity} / 100',
              maxLines: 1,
              softWrap: false,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(width: 8),
            _GlassOpacitySlider(app: app, width: sliderWidth),
          ],
        ),
      );
    },
  );
}

class _ThemePresetRow extends StatelessWidget {
  const _ThemePresetRow({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => SiteLensCompactRow(
    leading: Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: app.themePreset.seed,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.20),
        ),
      ),
    ),
    title: const Text('主题色'),
    trailing: SiteLensMenuSelector<ThemePresetId>(
      label: '选择主题色',
      value: app.themePreset,
      onSelected: (value) => safely(context, () => app.setThemePreset(value)),
      options: [
        for (final preset in ThemePresetId.values)
          SiteLensMenuOption(value: preset, label: preset.label),
      ],
    ),
  );
}

Widget _settingsSwitch(
  BuildContext context, {
  required String title,
  required String subtitle,
  required bool value,
  required Future<void> Function(bool value) onChanged,
  bool enabled = true,
}) => SiteLensCompactRow(
  title: Text(title),
  subtitle: Text(subtitle),
  onTap: enabled ? () => safely(context, () => onChanged(!value)) : null,
  trailing: Switch.adaptive(
    value: value,
    onChanged: enabled
        ? (next) => safely(context, () => onChanged(next))
        : null,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  ),
);

Widget _settingsLink(
  BuildContext context, {
  required String title,
  required IconData icon,
  required String subtitle,
  required Widget Function() page,
}) => SiteLensActionRow(
  icon: icon,
  title: title,
  subtitle: subtitle,
  onTap: () =>
      Navigator.of(context)
          .push<void>(MaterialPageRoute<void>(builder: (_) => page())),
);

Widget _settingsSection(
  String title,
  List<Widget> rows, {
  bool dividers = true,
}) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    SiteLensSectionHeader(title: title),
    _settingsPanel(rows, dividers: dividers),
  ],
);

Widget _settingsList(List<Widget> children, {Key? key}) => ListView(
  key: key,
  physics: const ClampingScrollPhysics(),
  padding: const EdgeInsets.fromLTRB(
    SiteLensMetrics.pagePadding,
    0,
    SiteLensMetrics.pagePadding,
    32,
  ),
  children: children,
);

Widget _settingsPanel(List<Widget> rows, {bool dividers = true}) =>
    SiteLensPanel(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (dividers && i > 0) const SiteLensSettingsDivider(),
            rows[i],
          ],
        ],
      ),
    );

Widget _settingsRowTitle(BuildContext context, IconData icon, String title) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
        ],
      ),
    );
