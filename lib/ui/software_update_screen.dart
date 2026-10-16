import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/update_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';

class SoftwareUpdateScreen extends ConsumerStatefulWidget {
  const SoftwareUpdateScreen({super.key, this.controller});

  /// Test seam: production reads [updateControllerProvider] so one download
  /// survives the page.
  final UpdateController? controller;

  @override
  ConsumerState<SoftwareUpdateScreen> createState() =>
      _SoftwareUpdateScreenState();
}

class _SoftwareUpdateScreenState extends ConsumerState<SoftwareUpdateScreen> {
  late final UpdateController _controller =
      widget.controller ?? ref.read(updateControllerProvider);
  UpdateDownloadState? _lastState;
  String? _autoInstalledTag;

  @override
  void initState() {
    super.initState();
    _controller.setUpdateScreenVisible(true);
    _controller.addListener(_onControllerChanged);
    _lastState = _controller.downloadState;
    unawaited(_controller.openUpdatePage());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.setUpdateScreenVisible(false);
    super.dispose();
  }

  /// A download that completes while this page is on screen continues into the
  /// installer, exactly as before. Anywhere else it only raises the notice.
  void _onControllerChanged() {
    final state = _controller.downloadState;
    final previous = _lastState;
    _lastState = state;
    if (state != UpdateDownloadState.ready ||
        previous == UpdateDownloadState.ready) {
      return;
    }
    if (!mounted || !_controller.service.platform.supportsApkInstall) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final release = _controller.release;
    if (release == null || _autoInstalledTag == release.tagName) return;
    _autoInstalledTag = release.tagName;
    _controller.dismissNotice();
    unawaited(_controller.install());
  }

  @override
  Widget build(BuildContext context) => SiteLensPageScaffold(
    title: '软件更新',
    body: ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          SiteLensSectionHeader(
            title: '当前版本',
            subtitle: _controller.currentVersion == null
                ? '读取应用版本中…'
                : '${_controller.currentVersion} · '
                      '下载由你主动开始；离开页面后会继续，完成后在应用内提示。',
          ),
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_android_outlined),
                  title: const Text('Site Lens'),
                  subtitle: Text(
                    _controller.release == null
                        ? '获取最新版本信息'
                        : '发现 ${_controller.release!.tagName}',
                  ),
                  trailing: _controller.checking
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _controller.busy || _controller.checking
                              ? null
                              : () => _controller.check(),
                          child: const Text('检查更新'),
                        ),
                ),
                if (_controller.checkMessage != null) ...[
                  const Divider(height: 1, indent: 18, endIndent: 18),
                  ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(_controller.checkMessage!),
                  ),
                ],
                if (_controller.installMessage != null) ...[
                  const Divider(height: 1, indent: 18, endIndent: 18),
                  ListTile(
                    leading: Icon(
                      Icons.lock_open_outlined,
                      color: SiteLensColors.of(context).warning,
                    ),
                    title: Text(_controller.installMessage!),
                  ),
                ],
                if (_controller.error != null) ...[
                  const Divider(height: 1, indent: 18, endIndent: 18),
                  ListTile(
                    leading: Icon(
                      Icons.error_outline,
                      color: SiteLensColors.of(context).danger,
                    ),
                    title: Text(_controller.error!),
                  ),
                ],
              ],
            ),
          ),
          if (_controller.stalePartials.isNotEmpty) ...[
            SiteLensSectionHeader(title: '未完成的下载'),
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.history_outlined),
                title: const Text('存在旧版本未完成下载'),
                subtitle: Text(
                  _controller.stalePartials
                      .map(
                        (partial) =>
                            '${partial.tagName} · 已下载 '
                            '${updateFormatBytes(partial.received)}',
                      )
                      .join('；'),
                ),
                isThreeLine: _controller.stalePartials.length > 1,
                trailing: TextButton(
                  onPressed: () => _controller.deleteStalePartials(),
                  child: const Text('清理'),
                ),
              ),
            ),
          ],
          if (_controller.release != null) ...[
            SiteLensSectionHeader(title: '可用更新'),
            SiteLensPanel(
              padding: const EdgeInsets.all(SiteLensMetrics.panelPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _controller.release!.tagName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _controller.release!.apkName,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_controller.release!.body.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      _controller.release!.body.trim(),
                      maxLines: 12,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 14),
                  _buildDownloadArea(context),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _buildDownloadArea(BuildContext context) {
    final release = _controller.release!;
    final publishPage = OutlinedButton(
      onPressed: () => _openUrl(release.htmlUrl),
      child: const Text('打开发布页'),
    );
    if (!_controller.service.platform.supportsApkInstall) {
      return Wrap(spacing: 8, runSpacing: 8, children: [publishPage]);
    }
    final fraction = _controller.fraction;
    final state = _controller.downloadState;
    final progress = _controller.total == null
        ? '已下载 ${updateFormatBytes(_controller.received)}'
        : '已下载 ${updateFormatBytes(_controller.received)} / '
              '${updateFormatBytes(_controller.total!)}'
              '${_controller.percent == null ? '' : '（${_controller.percent}%）'}';
    switch (state) {
      case UpdateDownloadState.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 8),
            Text('正在下载 $progress · 离开页面后会继续'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _controller.pause,
                  icon: const Icon(Icons.pause_outlined),
                  label: const Text('暂停'),
                ),
                publishPage,
              ],
            ),
          ],
        );
      case UpdateDownloadState.verifying:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('正在校验下载文件，完成后即可安装…'),
          ],
        );
      case UpdateDownloadState.paused:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 8),
            Text(
              _controller.pauseReason == UpdatePauseReason.user
                  ? '已暂停 · $progress'
                  : '下载中断 · $progress',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _controller.resume,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: const Text('继续下载'),
                ),
                OutlinedButton(
                  onPressed: _controller.deleteDownload,
                  child: const Text('删除下载'),
                ),
                publishPage,
              ],
            ),
          ],
        );
      case UpdateDownloadState.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已下载完成 · $progress'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _controller.install,
                  icon: const Icon(Icons.install_mobile_outlined),
                  label: const Text('安装更新'),
                ),
                OutlinedButton(
                  onPressed: _controller.deleteDownload,
                  child: const Text('删除下载'),
                ),
                publishPage,
              ],
            ),
          ],
        );
      case UpdateDownloadState.idle:
      case UpdateDownloadState.failed:
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => _controller.startDownload(
                restart: state == UpdateDownloadState.failed,
              ),
              icon: const Icon(Icons.download_outlined),
              label: Text(
                state == UpdateDownloadState.failed ? '重新下载' : '下载更新',
              ),
            ),
            publishPage,
          ],
        );
    }
  }

  Future<void> _openUrl(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开发布页')));
    }
  }
}
