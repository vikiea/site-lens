import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import '../domain/models.dart';
import '../settings/app_settings.dart' show AppPolicy;
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_util.dart';

/// One fixed row of seven controls: back, forward, reload, home, tabs, exit,
/// more. The count is a product decision, not a function of the screen width,
/// because the toolbar must never change shape under the user's thumb.
const browserToolbarItemCount = 7;

/// Width of one control in the fixed browser toolbar, including the sheet's
/// own side inset. Narrow screens get narrower cells rather than fewer of them.
double browserToolbarItemWidth(double available) =>
    (available - 2 * SiteLensMetrics.toolbarInset) / browserToolbarItemCount;

/// In-page "get back to the WebView" row. Shown on the site panel and the
/// profile detail, where leaving a browsing session would otherwise bury it.
///
/// It sits in the page instead of floating over it: one compact row, no
/// elevation, and closing tabs stays in the browsing list where it belongs.
class ResumeBrowserBar extends StatelessWidget {
  const ResumeBrowserBar({
    super.key,
    required this.app,
    required this.onResume,
  });
  final AppController app;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final active = app.activeBrowser;
    if (active == null) return const SizedBox.shrink();
    final extra = app.browserTabs.length - 1;
    return SiteLensPanel(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.open_in_browser, size: 20),
        title: Text(
          extra > 0
              ? '切回 ${active.site.label} +$extra'
              : '切回 ${active.site.label}',
        ),
        subtitle: Text(
          extra > 0 ? '共 ${app.browserTabs.length} 个标签页正在运行' : '浏览会话仍在后台运行',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onResume,
      ),
    );
  }
}

String tabHost(ActiveBrowserSession tab) {
  final current = tab.currentUrl;
  return current.host.isNotEmpty ? current.host : tab.site.label;
}

String tabPath(ActiveBrowserSession tab) {
  final current = tab.currentUrl;
  if (current.host.isEmpty) return tab.site.url.toString();
  final path = current.path.isEmpty ? '/' : current.path;
  return '${current.host}$path';
}

Future<void> _copyBrowserTabUrl(
  BuildContext context,
  ActiveBrowserSession tab,
) async {
  final url = tab.currentUrl.toString();
  if (url.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已复制标签页链接'), duration: Duration(seconds: 1)),
  );
}

/// One tab in the switcher grid. The "thumbnail" is a stylised preview of the
/// tab's current document (label + host + path), not a live capture.
class BrowserTabCard extends StatelessWidget {
  const BrowserTabCard({
    super.key,
    required this.tab,
    required this.active,
    required this.onSelect,
    required this.onClose,
  });
  final ActiveBrowserSession tab;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  String get stateLabel => switch (tab.state) {
    BrowserSessionState.unloaded => '待加载',
    BrowserSessionState.loading => '加载中',
    BrowserSessionState.ready => '继续浏览',
    BrowserSessionState.failed => '重新加载',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: active,
      button: true,
      label: '标签页 ${tab.title}，$stateLabel',
      child: SiteLensGlassSurface(
        radius: 20,
        child: InkWell(
          onTap: onSelect,
          onLongPress: () => _copyBrowserTabUrl(context, tab),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      active ? Icons.check_circle : Icons.public,
                      size: 16,
                      color: active ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tabHost(tab),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭标签页',
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      tab.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        stateLabel,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    if (active)
                      Text(
                        '当前',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.primary),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  tabPath(tab),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet tab switcher: a grid of open tabs to pick from.
Future<void> showTabSwitcher(
  BuildContext context,
  AppController app, {
  void Function(ActiveBrowserSession)? onActivated,
  VoidCallback? onAdd,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => SafeArea(
    child: ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final tabs = app.browserTabs;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 10, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '标签页 ${tabs.length}/${AppPolicy.maxBrowserTabs}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onAdd,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建'),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: SiteLensMetrics.itemGap,
                    crossAxisSpacing: SiteLensMetrics.itemGap,
                    childAspectRatio: 0.92,
                  ),
                  itemCount: tabs.length,
                  itemBuilder: (cardContext, index) {
                    final tab = tabs[index];
                    return BrowserTabCard(
                      tab: tab,
                      active: identical(tab, app.activeBrowser),
                      onSelect: () {
                        Navigator.pop(sheetContext);
                        unawaited(
                          safely(context, () async {
                            await app.activateTab(tab);
                            if (identical(app.activeBrowser, tab)) {
                              onActivated?.call(tab);
                            }
                          }),
                        );
                      },
                      onClose: () => unawaited(
                        safely(context, () async {
                          await app.closeTab(tab);
                        }),
                      ),
                    );
                  },
                ),
              ),
              if (tabs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    '还没有打开的标签页',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        );
      },
    ),
  ),
);

/// The 「浏览器」 bottom-navigation page: the always-available way back into an
/// open browsing session, even after leaving it from a nested screen.
class BrowserTabsPage extends StatelessWidget {
  const BrowserTabsPage({
    super.key,
    required this.app,
    required this.onResume,
    required this.onNewTab,
  });
  final AppController app;
  final void Function(ActiveBrowserSession) onResume;
  final VoidCallback onNewTab;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final tabs = app.browserTabs;
      if (tabs.isEmpty) {
        return SiteLensEmptyState(
          icon: Icons.tab_unselected,
          title: '还没有打开的标签页',
          message: '从「站点」进入一个档案后，未关闭的浏览会话会出现在这里。',
          action: TextButton.icon(
            onPressed: onNewTab,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建标签页'),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          4,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          Text(
            '打开的标签页 ${tabs.length}/${AppPolicy.maxBrowserTabs}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: SiteLensMetrics.itemGap),
          for (final tab in tabs) ...[
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.public, size: 20),
                title: Text(
                  tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: SiteLensCopyableText(
                  text: tabPath(tab),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (identical(tab, app.activeBrowser))
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    IconButton(
                      tooltip: '关闭标签页（销毁 WebView）',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => safely(context, () => app.closeTab(tab)),
                    ),
                  ],
                ),
                onTap: () => onResume(tab),
                onLongPress: () => _copyBrowserTabUrl(context, tab),
              ),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
          ],
        ],
      );
    },
  );
}

/// Asks for an HTTP(S) URL and opens it as a new browsing tab.
Future<void> promptNewTab(
  BuildContext context,
  AppController app, {
  String? initial,
}) async {
  final input = await promptText(
    context,
    title: '新建标签页',
    initial: initial,
    keyboardType: TextInputType.url,
    confirmLabel: '打开',
    helperText: '直接写 example.com 就是 https://example.com；结尾 / 也可省略',
  );
  if (input == null || input.isEmpty) return;
  try {
    // The scheme is optional for typed input: `example.com` is an address, not
    // a reason to make the user type a prefix by hand.
    final target = userUri(input);
    await app.openUrl(target, label: target.host);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
