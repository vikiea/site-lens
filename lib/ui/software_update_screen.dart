import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../settings/app_settings.dart';
import '../update/github_token_store.dart';
import '../update/update_controller.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

class SoftwareUpdateScreen extends ConsumerStatefulWidget {
  /// Test seam: production reads [updateControllerProvider] so one download
  /// survives the page.
  final UpdateController? controller;
  final UpdateChannel channel;
  final AppController? app;

  const SoftwareUpdateScreen({
    super.key,
    this.controller,
    this.channel = UpdateChannel.stable,
    this.app,
  });

  @override
  ConsumerState<SoftwareUpdateScreen> createState() =>
      _SoftwareUpdateScreenState();
}

class _SoftwareUpdateScreenState extends ConsumerState<SoftwareUpdateScreen> {
  late final UpdateController _controller =
      widget.controller ?? ref.read(updateControllerProvider);
  UpdateDownloadState? _lastState;
  String? _autoInstalledTag;
  late UpdateChannel _channel;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _controller.setUpdateScreenVisible(true);
    _controller.addListener(_onControllerChanged);
    _lastState = _controller.downloadState;
    unawaited(_initializeUpdatePage());
  }

  Future<void> _changeChannel(UpdateChannel value) async {
    if (value == _channel || _controller.busy) return;
    try {
      await _controller.setChannel(value);
      if (!mounted) return;
      setState(() => _channel = value);
      final app = widget.app;
      if (app != null) {
        await app.updateSettings({'updateChannel': value.name});
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _initializeUpdatePage() async {
    try {
      await _controller.setChannel(widget.channel);
      if (!mounted) return;
      await _controller.openUpdatePage();
    } catch (_) {
      // The page remains usable; an explicit check exposes the normal
      // controller error state without racing the channel switch.
    }
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
          _UpdatePreferencesPanel(
            app: widget.app,
            channel: _channel,
            busy: _controller.busy,
            onChannelChanged: _changeChannel,
          ),
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
                SiteLensCompactRow(
                  leading: const Icon(
                    Icons.phone_android_outlined,
                    size: SiteLensMetrics.compactIconSize,
                  ),
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
                  const SiteLensPanelDivider(),
                  SiteLensCompactRow(
                    leading: const Icon(
                      Icons.schedule_outlined,
                      size: SiteLensMetrics.compactIconSize,
                    ),
                    title: Text(_controller.checkMessage!),
                  ),
                ],
                if (_controller.installMessage != null) ...[
                  const SiteLensPanelDivider(),
                  SiteLensCompactRow(
                    leading: Icon(
                      Icons.lock_open_outlined,
                      color: SiteLensColors.of(context).warning,
                      size: SiteLensMetrics.compactIconSize,
                    ),
                    title: Text(_controller.installMessage!),
                  ),
                ],
                if (_controller.error != null) ...[
                  const SiteLensPanelDivider(),
                  SiteLensCompactRow(
                    leading: Icon(
                      Icons.error_outline,
                      color: SiteLensColors.of(context).danger,
                      size: SiteLensMetrics.compactIconSize,
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
              child: SiteLensCompactRow(
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

class _UpdatePreferencesPanel extends StatefulWidget {
  const _UpdatePreferencesPanel({
    required this.app,
    required this.channel,
    required this.busy,
    required this.onChannelChanged,
  });

  final AppController? app;
  final UpdateChannel channel;
  final bool busy;
  final ValueChanged<UpdateChannel> onChannelChanged;

  @override
  State<_UpdatePreferencesPanel> createState() =>
      _UpdatePreferencesPanelState();
}

class _UpdatePreferencesPanelState extends State<_UpdatePreferencesPanel> {
  @override
  Widget build(BuildContext context) => SiteLensPanel(
    padding: EdgeInsets.zero,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SiteLensCompactRow(
          leading: const Icon(Icons.tune_outlined, size: 18),
          title: const Text('更新渠道'),
          subtitle: Text(widget.channel.description),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: SegmentedButton<UpdateChannel>(
            segments: const [
              ButtonSegment(
                value: UpdateChannel.stable,
                label: Text('稳定版'),
                icon: Icon(Icons.verified_outlined),
              ),
              ButtonSegment(
                value: UpdateChannel.beta,
                label: Text('测试版'),
                icon: Icon(Icons.science_outlined),
              ),
            ],
            selected: {widget.channel},
            onSelectionChanged: widget.busy
                ? null
                : (values) {
                    if (values.isNotEmpty) {
                      widget.onChannelChanged(values.first);
                    }
                  },
          ),
        ),
        if (widget.channel == UpdateChannel.beta) ...[
          const SiteLensSettingsDivider(),
          const _UpdateGitHubTokenEntry(),
        ],
      ],
    ),
  );
}

class _UpdateGitHubTokenEntry extends StatefulWidget {
  const _UpdateGitHubTokenEntry();

  @override
  State<_UpdateGitHubTokenEntry> createState() =>
      _UpdateGitHubTokenEntryState();
}

class _UpdateGitHubTokenEntryState extends State<_UpdateGitHubTokenEntry> {
  final _store = GitHubTokenStore();
  bool? _configured;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final configured = await _store.hasToken();
    if (mounted) setState(() => _configured = configured);
  }

  Future<void> _edit() async {
    final controller = TextEditingController();
    final result = await showDialog<_UpdateTokenResult>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('GitHub API Token'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            hintText: '粘贴 ghp_ 或 github_pat_ Token',
            helperText: '仅保存在系统安全存储，不会进入备份或日志。',
          ),
        ),
        actions: [
          if (_configured == true)
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, const _UpdateTokenResult.clear()),
              child: const Text('清除'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              _UpdateTokenResult.save(controller.text),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (result.clear) {
        await _store.clear();
      } else {
        await _store.save(result.value!);
      }
      if (mounted) {
        setState(() {
          _configured = !result.clear;
          _busy = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.clear ? 'GitHub Token 已清除' : 'GitHub Token 已安全保存',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Token 未保存：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => SiteLensCompactRow(
    leading: const Icon(Icons.key_outlined, size: 18),
    title: const Text('GitHub API Token'),
    subtitle: Text(
      _configured == null
          ? '读取安全存储中…'
          : _configured == true
          ? '已配置，用于提高测试渠道查询额度'
          : '未配置，测试渠道可能受 GitHub 匿名限流影响',
    ),
    trailing: _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : TextButton(
            onPressed: _edit,
            child: Text(_configured == true ? '管理' : '设置'),
          ),
    onTap: _busy ? null : _edit,
  );
}

class _UpdateTokenResult {
  const _UpdateTokenResult.save(this.value) : clear = false;
  const _UpdateTokenResult.clear() : value = null, clear = true;

  final String? value;
  final bool clear;
}
