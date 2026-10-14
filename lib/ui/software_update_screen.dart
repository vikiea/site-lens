import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/update_service.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';

class SoftwareUpdateScreen extends StatefulWidget {
  const SoftwareUpdateScreen({super.key, this.service});

  final UpdateService? service;

  @override
  State<SoftwareUpdateScreen> createState() => _SoftwareUpdateScreenState();
}

class _SoftwareUpdateScreenState extends State<SoftwareUpdateScreen>
    with WidgetsBindingObserver {
  late final UpdateService _service = widget.service ?? UpdateService();
  ReleaseInfo? _release;
  File? _downloadedApk;
  String? _message;
  String? _error;
  String? _currentVersion;
  bool _checking = false;
  bool _downloading = false;
  int _received = 0;
  int? _total;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.packageInfo.then((info) {
      if (mounted) {
        setState(() => _currentVersion = '${info.version}+${info.buildNumber}');
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _release != null) {
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) => SiteLensPageScaffold(
    title: '软件更新',
    body: ListView(
      padding: const EdgeInsets.fromLTRB(
        SiteLensMetrics.pagePadding,
        12,
        SiteLensMetrics.pagePadding,
        32,
      ),
      children: [
        SiteLensSectionHeader(
          title: '当前版本',
          subtitle: _currentVersion == null
              ? '读取应用版本中…'
              : '$_currentVersion · 更新由你主动触发，应用不会在后台自动下载。',
        ),
        SiteLensPanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.phone_android_outlined),
                title: const Text('Site Lens'),
                subtitle: Text(
                  _release == null
                      ? '点击检查 GitHub Release'
                      : '发现 ${_release!.tagName}',
                ),
                trailing: _checking
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : FilledButton.tonal(
                        onPressed: _checking || _downloading ? null : _check,
                        child: const Text('检查更新'),
                      ),
              ),
              if (_message != null) ...[
                const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(_message!),
                ),
              ],
              if (_error != null) ...[
                const Divider(height: 1, indent: 18, endIndent: 18),
                ListTile(
                  leading: Icon(
                    Icons.error_outline,
                    color: SiteLensColors.of(context).danger,
                  ),
                  title: Text(_error!),
                ),
              ],
            ],
          ),
        ),
        if (_release != null) ...[
          SiteLensSectionHeader(title: '可用更新'),
          SiteLensPanel(
            padding: const EdgeInsets.all(SiteLensMetrics.panelPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _release!.tagName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  _release!.apkName,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_release!.body.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    _release!.body.trim(),
                    maxLines: 12,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 14),
                if (_downloading) ...[
                  LinearProgressIndicator(
                    value: _total == null || _total == 0
                        ? null
                        : _received / _total!,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _total == null || _total == 0
                        ? '正在下载…'
                        : '正在下载 ${_formatBytes(_received)} / ${_formatBytes(_total!)}',
                  ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _downloadedApk == null
                            ? _download
                            : _install,
                        icon: Icon(
                          _downloadedApk == null
                              ? Icons.download_outlined
                              : Icons.install_mobile_outlined,
                        ),
                        label: Text(_downloadedApk == null ? '下载更新' : '安装更新'),
                      ),
                      OutlinedButton(
                        onPressed: () => _openUrl(_release!.htmlUrl),
                        child: const Text('打开发布页'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    ),
  );

  Future<void> _check() async {
    if (_downloading) return;
    await _service.clearDownload();
    if (!mounted) return;
    setState(() {
      _checking = true;
      _message = null;
      _error = null;
      _release = null;
      _downloadedApk = null;
    });
    try {
      final release = await _service.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _release = release;
        _message = release == null ? '当前已是最新版本' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _readableError(error));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download() async {
    final release = _release;
    if (release == null) return;
    setState(() {
      _downloading = true;
      _received = 0;
      _total = release.apkSize;
      _error = null;
    });
    try {
      final apk = await _service.download(
        release,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _downloadedApk = apk);
      await _install();
    } catch (error) {
      if (mounted) setState(() => _error = _readableError(error));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _install() async {
    final apk = _downloadedApk;
    if (apk == null) return;
    if (!Platform.isAndroid || !_service.platform.supportsApkInstall) {
      await _openUrl(_release?.htmlUrl ?? Uri.parse(siteLensReleasePage));
      return;
    }
    try {
      if (!await _service.platform.canInstallPackages()) {
        await _service.platform.openInstallPermissionSettings();
        if (mounted) {
          setState(() => _message = '请允许 Site Lens 安装未知来源应用，然后再次点击安装更新');
        }
        return;
      }
      _service.retainForInstaller();
      await _service.platform.verifyAndInstall(apk, _release!);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? 'APK 校验或安装失败');
    } catch (error) {
      if (mounted) setState(() => _error = _readableError(error));
    }
  }

  Future<void> _openUrl(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      setState(() => _error = '无法打开发布页');
    }
  }

  String _readableError(Object error) => switch (error) {
    HttpException(:final message) => message,
    FormatException(:final message) => message,
    _ => '更新失败，请检查网络后重试',
  };

  String _formatBytes(int value) {
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
