import 'dart:convert';

import 'package:flutter/material.dart';

import '../web_host/web_host.g.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';

class DeviceDiagnosticsScreen extends StatefulWidget {
  const DeviceDiagnosticsScreen({super.key, required this.app});

  final AppController app;

  @override
  State<DeviceDiagnosticsScreen> createState() =>
      _DeviceDiagnosticsScreenState();
}

class _DeviceDiagnosticsScreenState extends State<DeviceDiagnosticsScreen>
    with WidgetsBindingObserver {
  bool _refreshing = false;
  bool _showCodecs = false;
  Future<List<CodecDescriptor>>? _codecs;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await app.deviceDiagnostics.refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _loadCodecs() {
    setState(() {
      _showCodecs = !_showCodecs;
      if (_showCodecs) _codecs = app.deviceDiagnostics.readCodecInventory();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final snapshot = app.deviceDiagnostics.snapshot;
    final records = _resolvedRecords(context);
    return SiteLensPageScaffold(
      title: '设备能力与平台策略',
      actions: [
        SiteLensRefreshButton(
          tooltip: '刷新',
          refreshing: _refreshing,
          onPressed: _refreshing ? null : _refresh,
        ),
      ],
      body: SiteLensGlassGroup(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            SiteLensPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前环境', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    _environmentSummary(snapshot),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '诊断仅读取现有状态，不申请权限、不创建 WebView、不播放媒体、不写入文件，也不发起网络探测。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < records.length; i++) ...[
                    _CapabilityRow(record: records[i]),
                    if (i != records.length - 1)
                      const Divider(height: 1, indent: 18, endIndent: 18),
                  ],
                  if (records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(SiteLensMetrics.panelPadding),
                      child: Text('等待原生能力查询结果'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
            if (app.deviceDiagnostics.platform == 'android')
              SiteLensPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '编解码器清单',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '按需读取系统已注册的 codec 描述，不实例化 codec。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _loadCodecs,
                      icon: Icon(
                        _showCodecs ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: Text(_showCodecs ? '收起清单' : '读取清单'),
                    ),
                    if (_showCodecs) _CodecList(future: _codecs!),
                  ],
                ),
              )
            else
              SiteLensPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '编解码器清单',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '不适用：当前 iOS 版本不提供此编解码器清单。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<CapabilityRecord> _resolvedRecords(BuildContext context) {
    final strategy = SiteLensGlassPolicyScope.of(context);
    final plans = {
      for (final role in SiteLensSurfaceRole.values)
        role.name: strategy.resolve(context, role: role),
    };
    return [
      for (final row in app.deviceDiagnosticRecords)
        if (row.id != 'glass.policy') row,
      CapabilityRecord(
        id: 'glass.policy',
        state: CapabilityState.supported,
        configured: true,
        effective: !plans['panel']!.useCompatibilityFallback,
        reason: '按当前实际角色策略解析；平台视图控件保留背板，网页像素采样受限',
        source: 'SiteLensGlassQualityStrategy.resolve',
        capturedAtMs: DateTime.now().millisecondsSinceEpoch,
        detailsJson: jsonEncode({
          'requested': app.settings.glassQualityMode.name,
          'allSurfacesHighQuality': app.settings.highQualityAllSurfaces,
          'adaptiveQuality': app.effectiveGlassQuality.name,
          for (final entry in plans.entries)
            entry.key: {
              'resolvedQuality': entry.value.quality.name,
              'compatibilityFallback': entry.value.useCompatibilityFallback,
              'nativePixelBackdrop': entry.value.platformViewBackdrop,
            },
        }),
      ),
    ];
  }

  String _environmentSummary(DeviceDiagnosticsSnapshot? snapshot) {
    if (snapshot == null) return '正在读取设备信息…';
    final api = snapshot.apiLevel == null ? '' : ' · API ${snapshot.apiLevel}';
    final provider = snapshot.webViewProvider == null
        ? ''
        : '\nWebView：${snapshot.webViewProvider}';
    return '${snapshot.platform} ${snapshot.osVersion}$api\n'
        '应用：${snapshot.appVersion}\nFlutter：${snapshot.flutterVersion ?? "未知"}$provider';
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.record});

  final CapabilityRecord record;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, record.state);
    final detailLines = [
      '应用配置：${_flag(record.configured)}',
      '当前有效：${_flag(record.effective)}',
      '实际观测：${record.observed ?? "无观测记录"}',
      '查询时间：${_time(record.capturedAtMs)}',
      '观测时间：${record.observedAtMs == null ? "无" : _time(record.observedAtMs!)}',
      '来源：${record.source}',
      ..._details(record.detailsJson),
    ];
    return SiteLensFoldable(
      child: ExpansionTile(
        leading: Icon(_statusIcon(record.state), color: color),
        title: Text(_label(record.id)),
        subtitle: Text('${_statusLabel(record.state)} · ${record.reason}'),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in detailLines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  String _flag(bool? value) => value == null
      ? '未知'
      : value
      ? '是'
      : '否';

  List<String> _details(String? value) {
    if (value == null) return const [];
    try {
      return _detailLines(jsonDecode(value));
    } catch (_) {
      return const ['详情无法解析'];
    }
  }

  List<String> _detailLines(Object? value, [String prefix = '']) {
    if (value is Map) {
      return [
        for (final entry in value.entries)
          ..._detailLines(
            entry.value,
            '$prefix${_detailLabel(entry.key.toString())}：',
          ),
      ];
    }
    if (value is List) {
      if (value.isEmpty) return ['$prefix无记录'];
      return [
        for (var i = 0; i < value.length; i++)
          ..._detailLines(value[i], '$prefix${i + 1}. '),
      ];
    }
    final display = value == null
        ? '未知'
        : value is bool
        ? _flag(value)
        : value.toString();
    return ['$prefix$display'];
  }

  String _detailLabel(String key) => switch (key) {
    'healthCheckEnabled' => '存活检查',
    'allowBackgroundPlayback' => '后台播放',
    'hcppEffective' => 'HCPP',
    'shaderSupported' => 'Shader 支持',
    'requested' => '请求质量',
    'adaptiveQuality' => '自适应质量',
    'resolvedQuality' => '最终质量',
    'compatibilityFallback' => '兼容填充',
    'allSurfacesHighQuality' => '全部面板高质量',
    'webViewMounted' => 'WebView 已挂载',
    'validated' => '系统网络已验证',
    'metered' => '计费网络',
    'transports' => '传输类型',
    'canInstallPackages' => '安装授权',
    'permissions' => 'Manifest 权限',
    'permission' => '权限',
    'granted' => '已授权',
    'applicable' => '当前系统适用',
    'playback' => '播放链路',
    'metadataRetriever' => 'Inspector 元数据',
    'frameExtractor' => 'Inspector 取帧',
    'mediaExtractorCompat' => 'Inspector 样本提取',
    'transformer' => 'Transformer',
    'powerSave' => '省电模式',
    'deviceIdle' => '设备空闲',
    'backgroundRestricted' => '后台受限',
    'ignoringBatteryOptimizations' => '电池优化豁免',
    'standbyBucket' => '待机分桶',
    'world' => '隔离世界',
    'navigation' => '导航监听',
    'documentStart' => '文档开始注入',
    'multiProfile' => '独立 Profile',
    'uri' => '授权地址',
    'read' => '读取授权',
    'write' => '写入授权',
    'matchedGrant' => '匹配持久化授权',
    'persistedAtMs' => '授权时间戳',
    'sessionId' || 'identity' => '会话身份',
    'trackType' => '轨道类型',
    'mime' => '媒体格式',
    'vulkan' => 'Vulkan 声明',
    'glesVersion' => 'GLES 版本',
    'feature' => '特性',
    'version' => '版本',
    'id' => '标识',
    'importance' => '通知重要性',
    'multicastLockHeld' => '多播锁已持有',
    'panel' => '内容面板',
    'chrome' => '导航控件',
    'platformView' => 'WebView 覆盖控件',
    'nativePixelBackdrop' => '原生背景路径',
    _ => key,
  };

  String _label(String id) => switch (id) {
    'platform.hcpp.engine' => 'HCPP 当前引擎能力',
    'platform.renderer' => '渲染后端判断',
    'platform.hcpp.manifest' => 'HCPP 应用配置',
    'glass.policy' => '液态玻璃平台策略',
    'webview.nativePixelSampling' => '网页原生像素采样',
    'webview.isolatedScripts' => '网页隔离脚本',
    'webview.documentStart' => '文档开始注入',
    'webview.privateProbes' => '独立检测 Profile',
    'webview.provider' => 'WebView provider',
    'permissions.runtime' => '运行时权限',
    'storage.saf.persistedGrants' => 'SAF 持久化授权',
    'background.powerAndIdle' => '省电与后台状态',
    'background.workManager' => 'WorkManager 状态',
    'network.activeTransport' => '当前网络连接',
    'notifications.runtime' => '通知权限与渠道',
    'settings.backgroundPolicy' => '应用后台策略',
    'storage.exportDirectory' => '导出目录策略',
    'media.playback.session' => '原生播放观测',
    'network.cast.session' => '投屏观测',
    'platform.graphicsDeclarations' => 'GPU 声明能力',
    'platform.android.api' => 'Android API',
    'media.pipeline' => '媒体处理链路',
    'media.codecInventory' => '编解码器枚举能力',
    'permissions.installPackages' => '应用安装授权',
    'network.dlna.multicast' => 'DLNA 与多播策略',
    'background.refresh' => '后台刷新状态',
    'network.localAuthorization' => '本地网络授权',
    'native.media' => '原生媒体播放路径',
    'native.download' => '原生下载路径',
    'native.export' => '原生导出路径',
    _ when id.startsWith('media.decoder.') => '会话解码器观测',
    _ when id.startsWith('media.playback.') => '会话播放观测',
    _ => id,
  };

  String _statusLabel(CapabilityState state) => switch (state) {
    CapabilityState.supported => '支持',
    CapabilityState.unsupported => '不支持',
    CapabilityState.unknown => '未知',
    CapabilityState.notApplicable => '不适用',
    CapabilityState.error => '查询失败',
  };

  IconData _statusIcon(CapabilityState state) => switch (state) {
    CapabilityState.supported => Icons.check_circle_outline,
    CapabilityState.unsupported => Icons.cancel_outlined,
    CapabilityState.unknown => Icons.help_outline,
    CapabilityState.notApplicable => Icons.remove_circle_outline,
    CapabilityState.error => Icons.error_outline,
  };

  Color _statusColor(BuildContext context, CapabilityState state) {
    final colors = SiteLensColors.of(context);
    return switch (state) {
      CapabilityState.supported => colors.ok,
      CapabilityState.unsupported => colors.danger,
      CapabilityState.unknown ||
      CapabilityState.notApplicable => colors.warning,
      CapabilityState.error => colors.danger,
    };
  }

  String _time(int millis) =>
      DateTime.fromMillisecondsSinceEpoch(millis)
          .toLocal()
          .toString()
          .split('.')
          .first;
}

class _CodecList extends StatelessWidget {
  const _CodecList({required this.future});

  final Future<List<CodecDescriptor>> future;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<CodecDescriptor>>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.all(8),
          child: LinearProgressIndicator(),
        );
      }
      if (snapshot.hasError) return const Text('读取 codec 清单失败，请收起后再次读取。');
      final codecs = snapshot.data ?? const <CodecDescriptor>[];
      if (codecs.isEmpty) return const Text('系统没有返回 codec 描述。');
      return Column(
        children: [
          for (final codec in codecs)
            ListTile(
              dense: true,
              title: Text(codec.name),
              subtitle: Text(
                '${codec.mimeType ?? "MIME 未知"} · ${codec.encoder ? "编码器" : "解码器"}\n'
                '${codec.hardwareAccelerated == null
                    ? "硬件属性未知"
                    : codec.hardwareAccelerated!
                    ? "硬件"
                    : "非硬件"}'
                '${codec.vendor == null ? "" : " · 厂商实现：${codec.vendor}"}\n'
                '纯软件：${codec.softwareOnly == null
                    ? "未知"
                    : codec.softwareOnly!
                    ? "是"
                    : "否"}\n'
                'Profile/Level：${codec.profileLevelsJson ?? "未知"}'
                '${codec.error == null ? "" : "\n${codec.error}"}',
              ),
              isThreeLine: true,
            ),
        ],
      );
    },
  );
}
