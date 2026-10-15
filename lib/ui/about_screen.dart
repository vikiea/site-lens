import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/update_service.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.packageInfoLoader});

  final Future<PackageInfo> Function()? packageInfoLoader;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    (widget.packageInfoLoader?.call() ?? PackageInfo.fromPlatform()).then((
      value,
    ) {
      if (mounted) setState(() => _info = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return SiteLensPageScaffold(
      title: '关于 Site Lens',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          SiteLensGlassSurface(
            role: SiteLensSurfaceRole.panel,
            child: Padding(
              padding: const EdgeInsets.all(SiteLensMetrics.panelPadding),
              child: Column(
                children: [
                  Icon(
                    Icons.travel_explore,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '择站 · Site Lens',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '整理站点入口，轻松发现与浏览',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          SiteLensSectionHeader(title: '应用信息'),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _detailRow('版本', info == null ? '读取中…' : info.version),
                const Divider(height: 1, indent: 18, endIndent: 18),
                _detailRow('正式包标识', 'dev.vikiea.site_lens'),
                const Divider(height: 1, indent: 18, endIndent: 18),
                _detailRow('许可证', 'GPL-3.0-or-later'),
              ],
            ),
          ),
          SiteLensSectionHeader(title: '项目'),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: SiteLensActionRow(
              icon: Icons.code,
              title: 'GitHub 仓库',
              subtitle: '查看源代码、Issue 和发布记录',
              onTap: () =>
                  _openUrl(Uri.parse('https://github.com/$siteLensRepository')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => ListTile(
    title: Text(label),
    trailing: Text(value, style: Theme.of(context).textTheme.bodyMedium),
  );

  Future<void> _openUrl(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开链接')));
    }
  }
}
