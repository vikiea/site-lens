import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../data/database.dart';

/// A persisted warm-up result used only as the next launch's starting hint.
///
/// This is deliberately separate from [AppSettings]: it describes the current
/// renderer, not a user preference.
class SiteLensGlassQualityCache {
  const SiteLensGlassQualityCache({
    required this.quality,
    required this.fingerprint,
    this.p75Ms,
    this.p95Ms,
  });

  final GlassQuality quality;
  final double? p75Ms;
  final double? p95Ms;
  final String fingerprint;

  Map<String, Object?> toJson() => {
    'version': 1,
    'quality': quality.name,
    'p75Ms': p75Ms,
    'p95Ms': p95Ms,
    'fingerprint': fingerprint,
  };

  String encode() => jsonEncode(toJson());

  factory SiteLensGlassQualityCache.decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      throw const FormatException('不支持的玻璃质量缓存版本');
    }
    final qualityName = json['quality'];
    final quality = GlassQuality.values
        .where((value) => value.name == qualityName)
        .firstOrNull;
    final fingerprint = json['fingerprint'];
    if (quality == null || fingerprint is! String || fingerprint.isEmpty) {
      throw const FormatException('玻璃质量缓存无效');
    }
    double? finiteNumber(Object? value) =>
        value is num && value.isFinite ? value.toDouble() : null;

    return SiteLensGlassQualityCache(
      quality: quality,
      p75Ms: finiteNumber(json['p75Ms']),
      p95Ms: finiteNumber(json['p95Ms']),
      fingerprint: fingerprint,
    );
  }

  bool matches(String currentFingerprint) => fingerprint == currentFingerprint;

  SiteLensGlassQualityCache copyWith({
    GlassQuality? quality,
    double? p75Ms,
    double? p95Ms,
    String? fingerprint,
  }) => SiteLensGlassQualityCache(
    quality: quality ?? this.quality,
    p75Ms: p75Ms ?? this.p75Ms,
    p95Ms: p95Ms ?? this.p95Ms,
    fingerprint: fingerprint ?? this.fingerprint,
  );
}

class SiteLensGlassQualityCacheRepository {
  const SiteLensGlassQualityCacheRepository(this.db);

  static const key = 'glass_quality_cache_v1';
  final AppDatabase db;

  Future<SiteLensGlassQualityCache?> read() async {
    final raw = await db.setting(key);
    if (raw == null) return null;
    try {
      return SiteLensGlassQualityCache.decode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> write(SiteLensGlassQualityCache cache) =>
      db.setSetting(key, cache.encode());

  Future<void> clear() =>
      db.customStatement('DELETE FROM settings WHERE key=?', [key]);
}

abstract final class SiteLensGlassFingerprint {
  static const strategyVersion = 'site-lens-glass-v1';

  static String current({required String appVersion}) {
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    final shaderSupport = ui.ImageFilter.isShaderFilterSupported;
    final renderer = shaderSupport ? 'shader' : 'fallback';
    final runtime = Platform.version.replaceAll('|', '/');
    const engine = String.fromEnvironment(
      'FLUTTER_ENGINE_VERSION',
      defaultValue: 'unknown',
    );
    return '$strategyVersion|app=$appVersion|platform=$platform'
        '|runtime=$runtime|engine=$engine|renderer=$renderer'
        '|shader=$shaderSupport';
  }
}
