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
    final records = _resolvedRecords(context, app);
    final groups = _capabilityGroups(records);
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
          key: const ValueKey('device-diagnostics-scroll'),
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            SiteLensMetrics.pagePadding,
            12,
            SiteLensMetrics.pagePadding,
            24,
          ),
          children: [
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    child: _EnvironmentSummary(snapshot: snapshot),
                  ),
                  const SiteLensPanelDivider(),
                  for (var index = 0; index < groups.length; index++) ...[
                    SiteLensActionRow(
                      icon: Icons.fact_check_outlined,
                      title: groups[index].$1,
                      subtitle: '${groups[index].$2.length} 项能力与策略',
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => _CapabilityGroupScreen(
                            title: groups[index].$1,
                            app: app,
                          ),
                        ),
                      ),
                    ),
                    if (index < groups.length - 1) const SiteLensPanelDivider(),
                  ],
                  const SiteLensPanelDivider(),
                  if (app.deviceDiagnostics.platform == 'android')
                    SiteLensActionRow(
                      icon: Icons.video_settings_outlined,
                      title: '编解码器清单',
                      subtitle: '进入后读取，缓存五分钟',
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => CodecInventoryScreen(app: app),
                        ),
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
                      child: Text('不适用：当前 iOS 版本不提供此编解码器清单。'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EnvironmentSummary extends StatelessWidget {
  const _EnvironmentSummary({required this.snapshot});

  final DeviceDiagnosticsSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot == null) {
      return const Text('正在读取设备信息…');
    }
    final rows = [
      ('系统', '${snapshot!.platform} ${snapshot!.osVersion}'),
      if (snapshot!.apiLevel != null) ('API', '${snapshot!.apiLevel}'),
      ('应用', snapshot!.appVersion),
      ('Flutter', snapshot!.flutterVersion ?? '未知'),
      if (snapshot!.webViewProvider != null)
        ('WebView', snapshot!.webViewProvider!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('当前环境', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(
              bottom: SiteLensMetrics.diagnosticRowGap,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: SiteLensMetrics.diagnosticLabelWidth,
                  child: Text(
                    row.$1,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(child: Text(row.$2)),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Text(
          '诊断仅读取现有状态，不申请权限、不创建 WebView、不播放媒体、不写入文件，也不发起网络探测。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

List<CapabilityRecord> _resolvedRecords(
  BuildContext context,
  AppController app,
) {
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

class _CapabilityGroupScreen extends StatefulWidget {
  const _CapabilityGroupScreen({required this.title, required this.app});
  final String title;
  final AppController app;

  @override
  State<_CapabilityGroupScreen> createState() => _CapabilityGroupScreenState();
}

class _CapabilityGroupScreenState extends State<_CapabilityGroupScreen> {
  final _accordion = SiteLensAccordionController();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      final groups = _capabilityGroups(_resolvedRecords(context, widget.app));
      final records = groups
          .where((group) => group.$1 == widget.title)
          .expand((group) => group.$2)
          .toList();
      final selectedId = _accordion.openId;
      if (selectedId != null &&
          !records.any((record) => record.id == selectedId)) {
        records.add(
          CapabilityRecord(
            id: selectedId.toString(),
            state: CapabilityState.unknown,
            reason: '当前快照中无此能力记录',
            source: 'DeviceDiagnosticsSnapshot',
            capturedAtMs:
                widget.app.deviceDiagnostics.snapshot?.capturedAtMs ?? 0,
          ),
        );
      }
      Widget rowAt(int index) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CapabilityRow(
            app: widget.app,
            record: records[index],
            accordion: _accordion,
            initiallyExpanded: index == 0,
          ),
          if (index < records.length - 1) const SiteLensPanelDivider(),
        ],
      );
      final content = records.length > 10
          ? SiteLensListPanel(
              scrollKey: PageStorageKey('capabilities-${widget.title}'),
              slivers: [
                SliverList.builder(
                  itemCount: records.length,
                  itemBuilder: (context, index) => rowAt(index),
                ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.all(SiteLensMetrics.pagePadding),
              child: SiteLensPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var i = 0; i < records.length; i++) rowAt(i)],
                ),
              ),
            );
      return SiteLensPageScaffold(
        title: widget.title,
        body: SiteLensGlassGroup(child: content),
      );
    },
  );
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.record,
    required this.app,
    required this.accordion,
    required this.initiallyExpanded,
  });

  final AppController app;
  final SiteLensAccordionController accordion;
  final bool initiallyExpanded;

  final CapabilityRecord record;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, record.state);
    return SiteLensAccordion(
      key: ValueKey('capability-${record.id}'),
      id: record.id,
      controller: accordion,
      leading: Icon(_statusIcon(record.state), color: color, size: 18),
      title: Text(_label(record.id)),
      subtitle: Text(
        _statusLabel(record.state),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      initiallyExpanded: initiallyExpanded,
      details: (context) {
        final current = _resolvedRecords(
          context,
          app,
        ).where((row) => row.id == record.id).firstOrNull;
        return _capabilityDetails(
          context,
          current ??
              CapabilityRecord(
                id: record.id,
                state: CapabilityState.unknown,
                reason: '当前快照中无此能力记录',
                source: 'DeviceDiagnosticsSnapshot',
                capturedAtMs: app.deviceDiagnostics.snapshot?.capturedAtMs ?? 0,
              ),
        );
      },
    );
  }

  Widget _capabilityDetails(BuildContext context, CapabilityRecord record) {
    final lines = [
      '平台支持：${_statusLabel(record.state)}',
      '应用配置：${_flag(record.configured)}',
      '当前有效：${_flag(record.effective)}',
      '实际观测：${record.observed ?? "无观测记录"}',
      '查询时间：${_time(record.capturedAtMs)}',
      '观测时间：${record.observedAtMs == null ? "无" : _time(record.observedAtMs!)}',
      '来源：${record.source}',
      ..._details(record.detailsJson),
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            MediaQuery.sizeOf(context).height *
            SiteLensMetrics.diagnosticDetailMaxHeightFraction,
      ),
      child: SingleChildScrollView(
        key: ValueKey('capability-detail-${record.id}'),
        physics: const ClampingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _label(record.id),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(record.reason),
            const SizedBox(height: 8),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(line),
              ),
          ],
        ),
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
    'muteAudio' => '原生网页静音',
    'webMessageListener' => '网页消息监听',
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
    'webview.mediaControl' => '网页媒体识别与后台控制',
    'webview.privateProbes' => '独立检测 Profile',
    'webview.provider' => 'WebView provider',
    'permissions.runtime' => '运行时权限',
    'storage.saf.persistedGrants' => 'SAF 持久化授权',
    'background.powerAndIdle' => '省电与后台状态',
    'background.workManager' => 'WorkManager 状态',
    'network.activeTransport' => '当前网络连接',
    'network.privateDns' => 'Private DNS 配置',
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

List<(String, List<CapabilityRecord>)> _capabilityGroups(
  List<CapabilityRecord> records,
) {
  String category(String id) {
    if (id.startsWith('platform.') || id.startsWith('glass.')) return '渲染与外观';
    if (id.startsWith('webview.')) return '网页能力';
    if (id.startsWith('media.') || id.startsWith('native.')) return '媒体能力';
    if (id.startsWith('storage.') || id.startsWith('permissions.')) {
      return '存储与权限';
    }
    if (id.startsWith('background.') ||
        id.startsWith('notifications.') ||
        id.startsWith('settings.')) {
      return '后台与系统策略';
    }
    if (id.startsWith('network.')) return '网络与投屏';
    return '其他能力';
  }

  final grouped = <String, List<CapabilityRecord>>{};
  for (final record in records) {
    (grouped[category(record.id)] ??= []).add(record);
  }
  return [for (final entry in grouped.entries) (entry.key, entry.value)];
}

/// The full codec inventory has exactly one scroll viewport, owned by this page.
class CodecInventoryScreen extends StatefulWidget {
  const CodecInventoryScreen({super.key, required this.app});
  final AppController app;
  @override
  State<CodecInventoryScreen> createState() => _CodecInventoryScreenState();
}

class _CodecInventoryScreenState extends State<CodecInventoryScreen> {
  Future<List<CodecDescriptor>>? _future;
  final _scroll = ScrollController();
  final _accordion = SiteLensAccordionController();

  @override
  void initState() {
    super.initState();
    _future = widget.app.deviceDiagnostics.readCodecInventory();
    _future!.ignore();
  }

  void _read() => setState(() {
    _future = widget.app.deviceDiagnostics.readCodecInventory();
    // FutureBuilder subscribes on the next frame; an immediate host failure
    // must already have an error listener while that frame is pending.
    _future!.ignore();
  });

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SiteLensPageScaffold(
    title: '编解码器清单',
    body: SiteLensGlassGroup(
      child: FutureBuilder<List<CodecDescriptor>>(
        future: _future,
        initialData: widget.app.deviceDiagnostics.cachedCodecInventory,
        builder: (context, snapshot) {
          final codecs = snapshot.data ?? const <CodecDescriptor>[];
          return SiteLensListPanel(
            controller: _scroll,
            scrollKey: const PageStorageKey('device-codec-list'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('只读取系统描述，不实例化编解码器。'),
                      if (snapshot.hasError)
                        TextButton.icon(
                          onPressed: _read,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                    ],
                  ),
                ),
              ),
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData)
                const SliverToBoxAdapter(child: LinearProgressIndicator())
              else if (snapshot.hasError)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('读取失败，请重试'),
                  ),
                )
              else if (_future != null && codecs.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('系统没有返回编解码器描述'),
                  ),
                ),
              if (codecs.isNotEmpty)
                SliverList.builder(
                  itemCount: codecs.length,
                  itemBuilder: (context, index) {
                    final codec = codecs[index];
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SiteLensAccordion(
                          key: ValueKey('codec-$index'),
                          id: index,
                          controller: _accordion,
                          title: Text(
                            codec.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${codec.mimeType ?? "MIME 未知"} · ${codec.encoder ? "编码器" : "解码器"} · '
                            '${codec.hardwareAccelerated == null
                                ? "硬件属性未知"
                                : codec.hardwareAccelerated!
                                ? "硬件"
                                : "非硬件"}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          details: (_) => _CodecDetails(codec: codec),
                        ),
                        if (index < codecs.length - 1)
                          const SiteLensPanelDivider(),
                      ],
                    );
                  },
                ),
              if (snapshot.connectionState == ConnectionState.done &&
                  !snapshot.hasError)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                    child: Text(
                      '清单结束，共 ${codecs.length} 项',
                      key: const ValueKey('codec-list-end'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _CodecDetails extends StatelessWidget {
  const _CodecDetails({required this.codec});

  final CodecDescriptor codec;

  @override
  Widget build(BuildContext context) {
    final lines = [
      'MIME：${codec.mimeType ?? "未知"}',
      '类型：${codec.encoder ? "编码器" : "解码器"}',
      '硬件加速：${codec.hardwareAccelerated == null
          ? "未知"
          : codec.hardwareAccelerated!
          ? "是"
          : "否"}',
      '厂商实现：${codec.vendor ?? "未知"}',
      '纯软件：${codec.softwareOnly == null
          ? "未知"
          : codec.softwareOnly!
          ? "是"
          : "否"}',
      'Profile/Level：${codec.profileLevelsJson ?? "未知"}',
      if (codec.error != null) '错误：${codec.error}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(padding: const EdgeInsets.only(bottom: 5), child: Text(line)),
      ],
    );
  }
}
