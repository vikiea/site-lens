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
  int _channelChangeGeneration = 0;
  bool _channelChangeInFlight = false;

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
    if (value == _channel || _controller.busy || _channelChangeInFlight) return;
    final previous = _channel;
    final app = widget.app;
    final generation = ++_channelChangeGeneration;
    setState(() {
      _channel = value;
      _channelChangeInFlight = true;
    });
    try {
      await _controller.setChannel(value);
      if (generation != _channelChangeGeneration) return;
      if (app != null && app.settings.updateChannel != value) {
        await app.updateSettings({'updateChannel': value.name});
      }
    } catch (error) {
      if (generation == _channelChangeGeneration) {
        // updateSettings publishes settings only after the database commit.
        // A later host failure must retain that committed preference instead
        // of making the page and update service disagree with storage.
        final committed = app?.settings.updateChannel ?? previous;
        try {
          await _controller.setChannel(committed);
        } catch (_) {
          // Keep the original failure visible; the controller will expose its
          // current channel if a best-effort rollback cannot complete.
        }
        if (mounted) {
          setState(() => _channel = _controller.channel);
          showError(context, error);
        }
      }
    } finally {
      if (mounted && generation == _channelChangeGeneration) {
        setState(() => _channelChangeInFlight = false);
      }
    }
  }

  Future<void> _initializeUpdatePage() async {
    final generation = _channelChangeGeneration;
    try {
      await _controller.setChannel(widget.channel);
      if (!mounted || generation != _channelChangeGeneration) return;
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
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _UpdatePreferencesRows(
                  channel: _channel,
                  busy: _controller.busy || _channelChangeInFlight,
                  onChannelChanged: _changeChannel,
                ),
                const SiteLensPanelDivider(),
                SiteLensCompactRow(
                  leading: const Icon(
                    Icons.phone_android_outlined,
                    size: SiteLensMetrics.compactIconSize,
                  ),
                  title: const Text('当前版本'),
                  subtitle: Text(
                    _controller.currentVersion?.toString() ?? '读取应用版本中…',
                  ),
                  trailing: _controller.checking
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed:
                              _controller.busy ||
                                  _controller.checking ||
                                  _channelChangeInFlight
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

class _UpdatePreferencesRows extends StatelessWidget {
  const _UpdatePreferencesRows({
    required this.channel,
    required this.busy,
    required this.onChannelChanged,
  });

  final UpdateChannel channel;
  final bool busy;
  final ValueChanged<UpdateChannel> onChannelChanged;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SiteLensCompactRow(
        leading: const Icon(Icons.tune_outlined, size: 18),
        title: const Text('更新渠道'),
        trailing: SiteLensMenuSelector<UpdateChannel>(
          label: '选择更新渠道',
          value: channel,
          options: const [
            SiteLensMenuOption(value: UpdateChannel.stable, label: '稳定版'),
            SiteLensMenuOption(value: UpdateChannel.beta, label: '测试版'),
          ],
          onSelected: busy ? null : onChannelChanged,
        ),
      ),
      const SiteLensSettingsDivider(),
      const _UpdateGitHubTokenEntry(),
    ],
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
    if (_busy) return;
    final result = await showDialog<_UpdateTokenResult>(
      context: context,
      builder: (_) => _UpdateTokenDialog(configured: _configured == true),
    );
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
          ? '已配置，稳定版和测试版优先使用 API'
          : '未配置，将优先尝试匿名 API，失败后解析发布页',
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

/// Own the input for the whole route lifetime, including its exit animation.
/// showDialog's result completes before the exiting TextField is unmounted.
class _UpdateTokenDialog extends StatefulWidget {
  const _UpdateTokenDialog({required this.configured});
  final bool configured;

  @override
  State<_UpdateTokenDialog> createState() => _UpdateTokenDialogState();
}

class _UpdateTokenDialogState extends State<_UpdateTokenDialog> {
  final _controller = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, _UpdateTokenResult.save(_controller.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('GitHub API Token'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        onFieldSubmitted: (_) => _save(),
        validator: (value) {
          try {
            return GitHubTokenStore.normalize(value) == null
                ? 'GitHub Token 不能为空'
                : null;
          } on FormatException catch (error) {
            return error.message;
          }
        },
        decoration: const InputDecoration(
          hintText: '粘贴 ghp_ 或 github_pat_ Token',
          helperText: '仅保存在系统安全存储，不会进入备份或日志。',
        ),
      ),
    ),
    actions: [
      if (widget.configured)
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const _UpdateTokenResult.clear()),
          child: const Text('清除'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _UpdateTokenResult {
  const _UpdateTokenResult.save(this.value) : clear = false;
  const _UpdateTokenResult.clear() : value = null, clear = true;

  final String? value;
  final bool clear;
}
