import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../settings/app_settings.dart';
import 'app_theme.dart';

/// What a glass surface is for. The role picks the rendering path, not a
/// different look: the app is always iOS 27 liquid glass.
extension SiteLensGlassQualityLabel on GlassQuality {
  String get label => switch (this) {
    GlassQuality.standard => '标准',
    GlassQuality.premium => '高质量',
    GlassQuality.minimal => '兼容',
  };
}

enum SiteLensSurfaceRole {
  /// Navigation chrome: app bar, bottom navigation, the browser toolbar.
  chrome,

  /// Content: panels, cards, sheets, dialogs.
  panel,

  /// Directly over a native WebView.
  platformView,
}

/// The complete rendering decision for one Site Lens surface.
@immutable
class SiteLensGlassRenderPlan {
  const SiteLensGlassRenderPlan({
    required this.quality,
    required this.settings,
    required this.glassColor,
    required this.platformViewBackdrop,
    required this.useCompatibilityFallback,
  });

  final GlassQuality quality;
  final LiquidGlassSettings settings;
  final Color glassColor;
  final bool platformViewBackdrop;
  final bool useCompatibilityFallback;
}

/// Resolves surface rendering policy without making the surface widget aware of
/// platform or renderer details.
@immutable
class SiteLensGlassQualityStrategy {
  const SiteLensGlassQualityStrategy({
    this.mode = SiteLensGlassQualityMode.automatic,
    this.allSurfacesHighQuality = false,
    this.shaderSupported,
    this.adaptiveQualityOverride,
  });

  final SiteLensGlassQualityMode mode;
  final bool allSurfacesHighQuality;
  final bool? shaderSupported;
  final GlassQuality? adaptiveQualityOverride;

  SiteLensGlassRenderPlan resolve(
    BuildContext context, {
    required SiteLensSurfaceRole role,
  }) {
    final platform = defaultTargetPlatform;
    final isAndroid = platform == TargetPlatform.android;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark
        ? LiquidGlassSettings.ios27Dark
        : LiquidGlassSettings.ios27Light;
    final glassColor = _glassColor(context, role: role);
    final adaptiveQuality =
        adaptiveQualityOverride ??
        GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
        GlassQuality.standard;
    final requestedQuality = _requestedQuality(
      role,
      adaptiveQuality: adaptiveQuality,
    );
    final platformViewBackdrop = role == SiteLensSurfaceRole.platformView;
    final shaderSupported =
        this.shaderSupported ?? ui.ImageFilter.isShaderFilterSupported;
    // Keep premium Flutter surfaces on AdaptiveGlass even when the premium
    // shader is unavailable. The library can select its calibrated lightweight
    // path; replacing them with a plain colored box makes high quality
    // indistinguishable from a tint change. PlatformView overlays remain on
    // their live backdrop path because premium capture cannot sample WebView.
    final useCompatibilityFallback =
        !shaderSupported &&
        role == SiteLensSurfaceRole.panel &&
        requestedQuality != GlassQuality.premium;

    return SiteLensGlassRenderPlan(
      quality: requestedQuality,
      settings: _settings(
        base,
        context,
        role: role,
        isAndroid: isAndroid,
        dark: dark,
        quality: requestedQuality,
        glassColor: glassColor,
      ),
      glassColor: glassColor,
      platformViewBackdrop: platformViewBackdrop,
      useCompatibilityFallback: useCompatibilityFallback,
    );
  }

  GlassQuality _requestedQuality(
    SiteLensSurfaceRole role, {
    required GlassQuality adaptiveQuality,
  }) {
    final quality = switch (role) {
      SiteLensSurfaceRole.panel =>
        mode == SiteLensGlassQualityMode.high && allSurfacesHighQuality
            ? GlassQuality.premium
            : GlassQuality.standard,
      SiteLensSurfaceRole.platformView => GlassQuality.standard,
      SiteLensSurfaceRole.chrome => switch (mode) {
        SiteLensGlassQualityMode.standard => GlassQuality.standard,
        SiteLensGlassQualityMode.automatic => adaptiveQuality,
        SiteLensGlassQualityMode.high => GlassQuality.premium,
      },
    };
    // Minimal is a renderer fallback, not a user-facing quality mode for these
    // surfaces. PlatformView overlays remain standard so their live backdrop
    // path can sample the native WebView safely.
    return quality == GlassQuality.minimal ? GlassQuality.standard : quality;
  }

  Color _glassColor(BuildContext context, {required SiteLensSurfaceRole role}) {
    final requestedAlpha =
        Theme.of(context).extension<SiteLensGlassTheme>()?.backgroundAlpha ??
        AppPolicy.defaultGlassOpacity / 100;
    // The Android-specific optical parameters below keep the material's
    // refraction stable. The user-controlled fill alpha must still remain
    // linear; compressing 45..100 into 45..72 made the slider misleading.
    // Chrome remains a visible glass control at the panel setting's zero
    // endpoint. The floor preserves the navigation surface and its contrast;
    // content panels continue to honor the exact requested alpha. Their neutral
    // theme tokens provide the contrast needed to make low values readable.
    final fillAlpha = role == SiteLensSurfaceRole.chrome
        ? requestedAlpha.clamp(0.16, 1.0)
        : requestedAlpha;
    return SiteLensColors.of(context).glassSurface.withValues(alpha: fillAlpha);
  }

  LiquidGlassSettings _settings(
    LiquidGlassSettings base,
    BuildContext context, {
    required SiteLensSurfaceRole role,
    required bool isAndroid,
    required bool dark,
    required GlassQuality quality,
    required Color glassColor,
  }) {
    final requestedAlpha =
        Theme.of(context).extension<SiteLensGlassTheme>()?.backgroundAlpha ??
        AppPolicy.defaultGlassOpacity / 100;
    final fillAlpha = glassColor.a;
    const defaultFillAlpha = AppPolicy.defaultGlassOpacity / 100;
    final lowAlphaProgress = (fillAlpha / defaultFillAlpha).clamp(0.0, 1.0);
    final frostFactor = fillAlpha >= defaultFillAlpha
        ? 1.0
        : 0.15 + 0.85 * Curves.easeOut.transform(lowAlphaProgress);
    final premiumSurface =
        isAndroid &&
        role != SiteLensSurfaceRole.platformView &&
        quality == GlassQuality.premium;

    final adjusted = role == SiteLensSurfaceRole.platformView
        ? base
        : base.copyWith(
            visibility: 1,
            bodyMode: GlassBodyMode.clear,
            glassColor: glassColor,
            blur: base.blur,
            frost: base.frost,
            frostOpacity: base.frostOpacity * frostFactor,
            thickness: isAndroid && !premiumSurface ? 12 : base.thickness,
            refractiveIndex: isAndroid && !premiumSurface
                ? 1.08
                : base.refractiveIndex,
            lightIntensity: isAndroid && !premiumSurface
                ? 0
                : base.lightIntensity,
            rimLight: isAndroid && !premiumSurface ? 0 : base.rimLight,
            rimShade: isAndroid && !premiumSurface ? 0 : base.rimShade,
            edgeAbsorption: isAndroid && !premiumSurface
                ? 0
                : base.edgeAbsorption,
            shadow: isAndroid && !premiumSurface
                ? const <BoxShadow>[]
                : base.shadow,
          );
    if (role != SiteLensSurfaceRole.platformView) return adjusted;
    return adjusted.copyWith(
      backerColor: dark ? const Color(0x99000000) : const Color(0xA6FFFFFF),
      glassColor: glassColor.withValues(alpha: requestedAlpha),
    );
  }
}

/// Provides the glass strategy to all descendants while keeping the surface
/// widget independently testable.
class SiteLensGlassPolicyScope extends InheritedWidget {
  const SiteLensGlassPolicyScope({
    required this.strategy,
    required super.child,
    super.key,
  });

  final SiteLensGlassQualityStrategy strategy;

  static SiteLensGlassQualityStrategy of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SiteLensGlassPolicyScope>()
          ?.strategy ??
      const SiteLensGlassQualityStrategy();

  @override
  bool updateShouldNotify(SiteLensGlassPolicyScope oldWidget) =>
      strategy != oldWidget.strategy;
}
