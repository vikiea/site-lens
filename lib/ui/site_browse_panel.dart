import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'profile_panel.dart';
import 'ui_primitives.dart';

/// 站外浏览: the 浏览出口 workspace. Site profiles stay the main list, and the
/// open browsing sessions are one row above them — returning to a running tab
/// from anywhere, or opening a new one, without leaving this tab.
///
/// Scripts, ad filtering and the rest of the older tooling do not live here:
/// they stay reachable from 设置, never from the first screen.
class SiteBrowsePanel extends StatelessWidget {
  const SiteBrowsePanel({
    super.key,
    required this.app,
    required this.onOpen,
    required this.onResume,
    required this.onNewTab,
    this.onEnterProfile,
    this.onResumeTab,
  });

  final AppController app;
  final void Function(SiteProfile) onOpen;
  final Future<void> Function(SiteProfile)? onEnterProfile;
  final VoidCallback onResume;
  final ValueChanged<ActiveBrowserSession>? onResumeTab;
  final VoidCallback onNewTab;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final tabs = app.browserTabs;
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              SiteLensMetrics.pagePadding,
              8,
              SiteLensMetrics.pagePadding,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: SiteLensPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SiteLensCompactRow(
                      leading: const Icon(Icons.tab_outlined, size: 20),
                      title: const Text('浏览会话'),
                      subtitle: Text(
                        tabs.isEmpty ? '没有打开的标签页' : '${tabs.length} 个标签页',
                      ),
                      trailing: SiteLensCompactIconButton(
                        icon: const Icon(Icons.add),
                        tooltip: '新建标签页',
                        onPressed: onNewTab,
                      ),
                      onTap: tabs.isEmpty ? null : onResume,
                    ),
                    if (tabs.isNotEmpty) ...[
                      const SiteLensPanelDivider(),
                      for (final tab in tabs) ...[
                        SiteLensCompactRow(
                          leading: const Icon(Icons.public, size: 18),
                          title: Text(tab.title),
                          subtitle: Text(tab.lastUrl.toString()),
                          onTap: () =>
                              (onResumeTab ?? (_) => onResume()).call(tab),
                        ),
                        if (tab != tabs.last) const SiteLensPanelDivider(),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: SiteLensSectionHeader(
              title: '站点档案',
              subtitle: '每个站点的发布页、绑定脚本与健康状态',
            ),
          ),
          // The site list keeps its own bounded, lazy viewport; this page only
          // gives it room under the session row.
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.55,
              child: ProfilesPanel(
                app: app,
                onOpen: onOpen,
                onEnterProfile: onEnterProfile,
                onResume: onResume,
              ),
            ),
          ),
        ],
      );
    },
  );
}
