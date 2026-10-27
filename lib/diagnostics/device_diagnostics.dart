import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../web_host/web_host.g.dart';

typedef HcppReader = Future<bool> Function();

/// In-memory diagnostic state. Querying this service never requests access or
/// creates a browser/player; actual observations must be supplied by producers.
class DeviceDiagnosticsService extends ChangeNotifier {
  DeviceDiagnosticsService({
    DeviceDiagnosticsApi? api,
    HcppReader? hcppReader,
    String? platform,
    DateTime Function()? now,
  }) : _api = api ?? DeviceDiagnosticsApi(),
       _hcppReader = hcppReader ?? HybridAndroidViewController.checkIfSupported,
       platform = platform ?? Platform.operatingSystem,
       _now = now ?? DateTime.now;

  final DeviceDiagnosticsApi _api;
  final HcppReader _hcppReader;
  final String platform;
  final DateTime Function() _now;
  bool _disposed = false;
  bool? hcppSupported;
  String? hcppError;
  int? hcppCapturedAtMs;
  DeviceDiagnosticsSnapshot? snapshot;
  Future<void>? _hcppPending;
  Future<DeviceDiagnosticsSnapshot>? _snapshotPending;
  Future<List<CodecDescriptor>>? _codecPending;
  List<CodecDescriptor>? _codecs;
  DateTime? _codecsCapturedAt;
  static const codecCacheLifetime = Duration(minutes: 5);

  List<CodecDescriptor>? get cachedCodecInventory {
    final captured = _codecsCapturedAt;
    if (captured == null) return null;
    final age = _now().difference(captured);
    return !age.isNegative && age < codecCacheLifetime ? _codecs : null;
  }

  final _observations = <String, CapabilityRecord>{};

  bool get effectiveHcpp => platform == 'android' && hcppSupported == true;

  Future<void> refreshHcpp() =>
      _hcppPending ??= _refreshHcpp().whenComplete(() {
        _hcppPending = null;
      });

  Future<void> _refreshHcpp() async {
    if (platform != 'android') return;
    bool? supported;
    String? error;
    try {
      supported = await _hcppReader().timeout(const Duration(seconds: 5));
    } catch (_) {
      error = '当前引擎未能返回 HCPP 能力，采用兼容策略';
    }
    if (_disposed) return;
    hcppSupported = supported;
    hcppError = error;
    hcppCapturedAtMs = _now().millisecondsSinceEpoch;
    notifyListeners();
  }

  Future<DeviceDiagnosticsSnapshot> refresh() =>
      _snapshotPending ??= _readSnapshot().whenComplete(() {
        _snapshotPending = null;
      });

  Future<DeviceDiagnosticsSnapshot> _readSnapshot() async {
    await refreshHcpp();
    DeviceDiagnosticsSnapshot result;
    try {
      result = await _api.readSnapshot().timeout(const Duration(seconds: 8));
    } catch (_) {
      final captured = _now().millisecondsSinceEpoch;
      result = DeviceDiagnosticsSnapshot(
        platform: platform,
        osVersion: '未知',
        appVersion: '未知',
        capturedAtMs: captured,
        capabilities: [
          CapabilityRecord(
            id: 'diagnostics.native',
            state: CapabilityState.error,
            reason: '原生只读查询未完成，请刷新重试',
            source: 'DeviceDiagnosticsApi.readSnapshot',
            capturedAtMs: captured,
          ),
        ],
      );
    }
    result.flutterVersion = FlutterVersion.version;
    if (!_disposed) {
      snapshot = result;
      notifyListeners();
    }
    return result;
  }

  /// Page entry starts the read; repeated entries share one five-minute cache.
  /// Failures are never cached and concurrent readers share the pending query.
  Future<List<CodecDescriptor>> readCodecInventory() {
    final cached = cachedCodecInventory;
    if (cached != null) return Future.value(cached);
    return _codecPending ??= _readCodecs().whenComplete(
      () => _codecPending = null,
    );
  }

  Future<List<CodecDescriptor>> _readCodecs() async {
    final rows = List<CodecDescriptor>.unmodifiable(
      await _api.readCodecInventory().timeout(const Duration(seconds: 15)),
    );
    if (!_disposed) {
      _codecs = rows;
      _codecsCapturedAt = _now();
    }
    return rows;
  }

  /// Called only by existing playback/cast event streams, never by refresh.
  void recordObservation({
    required String id,
    required String observed,
    required String source,
    required String identity,
    bool failed = false,
  }) {
    if (_disposed) return;
    final prior = _observations[id];
    final details = jsonEncode({'identity': identity});
    if (prior?.observed == observed && prior?.detailsJson == details) return;
    final now = _now().millisecondsSinceEpoch;
    _observations[id] = CapabilityRecord(
      id: id,
      state: failed ? CapabilityState.error : CapabilityState.supported,
      observed: observed,
      reason: '正常使用时收到的会话事件；不代表所有格式或设备均已验证',
      source: source,
      capturedAtMs: now,
      observedAtMs: now,
      detailsJson: details,
    );
    notifyListeners();
  }

  void clearObservation(String id) {
    if (_disposed || _observations.remove(id) == null) return;
    notifyListeners();
  }

  /// Merges declared support, current engine policy and historical facts. The
  /// snapshot timestamp never replaces a producer's actual observation time.
  List<CapabilityRecord> records({
    required String glassMode,
    required String adaptiveQuality,
    required bool allSurfacesHighQuality,
    required bool webViewMounted,
    required bool backgroundHealthCheck,
    required bool allowBackgroundPlayback,
    required String? exportDirectory,
  }) {
    final now = _now().millisecondsSinceEpoch;
    final native = snapshot;
    final rows = <CapabilityRecord>[
      ...?native?.capabilities.where(
        (row) => !{
          'platform.hcpp.engine',
          'platform.renderer',
          'glass.policy',
          'webview.nativePixelSampling',
          'settings.backgroundPolicy',
          'storage.exportDirectory',
        }.contains(row.id),
      ),
    ];
    final isAndroid = platform == 'android';
    final hcppNotApplicable = !isAndroid || (native?.apiLevel ?? 34) < 34;
    rows.add(
      CapabilityRecord(
        id: 'platform.hcpp.engine',
        state: hcppNotApplicable
            ? CapabilityState.notApplicable
            : hcppError != null
            ? CapabilityState.error
            : hcppSupported == null
            ? CapabilityState.unknown
            : hcppSupported!
            ? CapabilityState.supported
            : CapabilityState.unsupported,
        effective: hcppNotApplicable ? null : hcppSupported,
        reason: hcppNotApplicable
            ? 'HCPP 需要 Android API 34+'
            : hcppError ??
                  (effectiveHcpp
                      ? '当前引擎确认 HCPP 路径可用；平台视图仍由引擎管理'
                      : 'Flutter 自动选择兼容平台视图策略'),
        source: 'HybridAndroidViewController.checkIfSupported',
        capturedAtMs: hcppCapturedAtMs ?? now,
      ),
    );
    rows.add(
      CapabilityRecord(
        id: 'platform.renderer',
        state: effectiveHcpp
            ? CapabilityState.supported
            : CapabilityState.unknown,
        observed: effectiveHcpp ? 'Impeller Vulkan' : null,
        reason: effectiveHcpp
            ? 'HCPP 当前引擎检查确认 Vulkan 前提；不等于某个视图已渲染'
            : '没有权威接口确认当前渲染后端；不从 shader 或硬件声明推断',
        source: 'Flutter HCPP engine predicate',
        capturedAtMs: hcppCapturedAtMs ?? now,
      ),
    );
    rows.add(
      CapabilityRecord(
        id: 'glass.policy',
        state: CapabilityState.supported,
        configured: true,
        effective: !(isAndroid && webViewMounted && !effectiveHcpp),
        observed: isAndroid && webViewMounted && !effectiveHcpp
            ? '兼容填充'
            : 'Flutter 玻璃按角色和质量策略解析',
        reason: '原生 WebView 覆盖控件保留专用背板；网页像素采样受限',
        source: 'SiteLensGlassQualityStrategy',
        capturedAtMs: now,
        detailsJson: jsonEncode({
          'requested': glassMode,
          'adaptiveQuality': adaptiveQuality,
          'allSurfacesHighQuality': allSurfacesHighQuality,
          'webViewMounted': webViewMounted,
          'hcppEffective': effectiveHcpp,
          'shaderSupported': ui.ImageFilter.isShaderFilterSupported,
        }),
      ),
    );
    rows.add(
      CapabilityRecord(
        id: 'webview.nativePixelSampling',
        state: CapabilityState.unsupported,
        effective: false,
        reason: '原生网页和视频像素不属于 Flutter shader 可采样的背景；HCPP 不提供像素桥接',
        source: 'Site Lens platformView policy',
        capturedAtMs: now,
      ),
    );
    rows.add(
      CapabilityRecord(
        id: 'settings.backgroundPolicy',
        state: CapabilityState.supported,
        configured: backgroundHealthCheck,
        reason: '设置意图与系统调度状态分别展示',
        source: 'AppSettings',
        capturedAtMs: now,
        detailsJson: jsonEncode({
          'healthCheckEnabled': backgroundHealthCheck,
          'allowBackgroundPlayback': allowBackgroundPlayback,
        }),
      ),
    );
    rows.add(
      CapabilityRecord(
        id: 'storage.exportDirectory',
        state: platform == 'ios'
            ? CapabilityState.notApplicable
            : CapabilityState.unknown,
        configured: exportDirectory != null,
        reason: exportDirectory == null
            ? '尚未配置导出目录'
            : '已配置目录；仅匹配持久化授权，不访问 provider 或测试写入',
        source: 'AppSettings.mp4ExportDirectory',
        capturedAtMs: now,
        detailsJson: _exportGrantDetails(exportDirectory, rows),
      ),
    );
    rows.addAll(_observations.values);
    for (final id in ['media.playback.session', 'network.cast.session']) {
      if (!_observations.containsKey(id)) {
        rows.add(
          CapabilityRecord(
            id: id,
            state: CapabilityState.unknown,
            reason: '当前进程尚未收到对应会话事件；不会为诊断启动探测',
            source: 'DeviceDiagnosticsService observations',
            capturedAtMs: now,
          ),
        );
      }
    }
    return rows;
  }

  String? _exportGrantDetails(String? directory, List<CapabilityRecord> rows) {
    if (directory == null) return null;
    final uri = Uri.tryParse(directory);
    if (uri?.scheme != 'content') {
      return jsonEncode({'matchedGrant': null});
    }
    final ledger = rows
        .where((row) => row.id == 'storage.saf.persistedGrants')
        .firstOrNull;
    if (ledger?.detailsJson == null || ledger?.state == CapabilityState.error) {
      return jsonEncode({'matchedGrant': null});
    }
    try {
      final grants = jsonDecode(ledger!.detailsJson!) as List;
      final match = grants
          .whereType<Map>()
          .where((grant) => grant['uri'] == directory)
          .firstOrNull;
      return jsonEncode({
        'matchedGrant': match != null,
        'read': match?['read'],
        'write': match?['write'],
      });
    } catch (_) {
      return jsonEncode({'matchedGrant': null});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
