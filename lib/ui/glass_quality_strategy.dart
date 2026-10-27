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
    this.webViewVisible = false,
    this.hcppEffective = false,
    this.backgroundMode = BackgroundMode.defaultGradient,
    this.lightweightShaderSupported,
    this.adaptiveQualityOverride,
  });

  final SiteLensGlassQualityMode mode;
  final bool allSurfacesHighQuality;

  /// Whether an Android WebView remains mounted, including below a modal.
  /// Legacy composition retains the compatibility fence until the current
  /// engine positively confirms HCPP.
  final bool webViewVisible;

  /// Current engine HCPP predicate, retained for diagnostics and policy
  /// snapshots. Flutter-owned surfaces do not use it as a reason to drop their
  /// shader path; only the native WebView role is fenced while that view is
  /// mounted.
  final bool hcppEffective;

  /// Transparent dark mode deliberately leaves the app-owned backdrop empty.
  /// Glass shaders need a real backdrop to sample, so this mode uses the
  /// stable clipped fill path for every surface instead of sampling the host
  /// window.
  final BackgroundMode backgroundMode;

  /// Optional override for the package's lightweight shader capability.
  ///
  /// `null` means unknown: let [AdaptiveGlass] select its Skia/Impeller path
  /// and handle an asset or renderer failure internally. This must not be
  /// populated from `ui.ImageFilter.isShaderFilterSupported`, because that
  /// flag describes the full Impeller shader filter path while the lightweight
  /// shader is specifically the Android/Skia fallback.
  final bool? lightweightShaderSupported;
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
    // A live BackdropFilter over an Android hybrid-composed WebView forces the
    // rasterizer to sample a native video surface on every frame. That path is
    // the common trigger for playback-page raster crashes on affected WebView /
    // GPU combinations. Keep only the platform-view role on the clipped
    // translucent fill; Flutter-owned panels and chrome retain their shader
    // path. This changes only native-surface sampling; controls, tint, shape,
    // and interaction remain unchanged.
    final androidWebViewComposition = isAndroid && webViewVisible;
    final platformViewBackdrop =
        role == SiteLensSurfaceRole.platformView && !androidWebViewComposition;
    // liquid_glass_widgets has a lightweight shader path for Skia/Android even
    // when the full Impeller renderer is unavailable. Keep that path for
    // Flutter-owned surfaces; only the native WebView surface needs the
    // clipped fill because its pixels cannot be captured by the glass shader.
    final useCompatibilityFallback =
        backgroundMode == BackgroundMode.transparent ||
        (androidWebViewComposition &&
            role == SiteLensSurfaceRole.platformView) ||
        (lightweightShaderSupported == false && !platformViewBackdrop);

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
    final selectedQuality = switch (mode) {
      SiteLensGlassQualityMode.standard => GlassQuality.standard,
      SiteLensGlassQualityMode.automatic => adaptiveQuality,
      SiteLensGlassQualityMode.high => GlassQuality.premium,
    };
    final quality = switch (role) {
      SiteLensSurfaceRole.panel =>
        allSurfacesHighQuality ? selectedQuality : GlassQuality.standard,
      SiteLensSurfaceRole.platformView => GlassQuality.standard,
      SiteLensSurfaceRole.chrome => selectedQuality,
    };
    // Minimal is a renderer fallback, not a user-facing quality mode for these
    // surfaces. The Android WebView route uses the clipped fill selected in
    // resolve() instead of a live backdrop read for every role.
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
            // Native WebView overlays use the platform-view fallback, while
            // Flutter-owned surfaces retain the requested optical parameters.
            // On Skia, liquid_glass_widgets maps premium to its lightweight
            // shader path; it still preserves refraction/rim treatment.
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
