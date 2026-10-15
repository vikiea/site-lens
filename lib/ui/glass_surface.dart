import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_theme.dart';

/// The app-wide backdrop: one static, low-saturation gradient (tinted by the
/// selected theme) that every glass surface refracts.
///
/// It is painted once behind the whole app so screens stay transparent and the
/// material has something real to sample. Nothing animates, so there is no
/// continuous repaint behind the glass.
class SiteLensBackdrop extends StatelessWidget {
  const SiteLensBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = SiteLensColors.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.backdropTop, colors.backdropBottom],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.75, -0.95),
              radius: 1.5,
              colors: [
                colors.backdropTint,
                colors.backdropTint.withValues(alpha: 0),
              ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// What a glass surface is for. The role picks the rendering path, not a
/// different look: the app is always iOS 27 liquid glass.
enum SiteLensSurfaceRole {
  /// Navigation chrome: app bar, bottom navigation, the browser toolbar.
  chrome,

  /// Content: panels, cards, sheets, dialogs.
  panel,

  /// Directly over a native WebView. The premium shader samples a captured
  /// texture that excludes the platform view, so this role takes the live
  /// backdrop-filter path instead of drawing an inert slab over the page.
  platformView,
}

/// The iOS 27 material for the current brightness.
///
/// [role] only changes what the surface has to survive, never the material:
/// a surface floating over the live web page cannot assume anything about the
/// page behind it, so it carries its own polarity-matched dimming pad (Apple's
/// guidance for controls over rich content). Without it a dark theme over a
/// light page would paint light glass behind white glyphs.
LiquidGlassSettings siteLensGlassSettings(
  BuildContext context, {
  SiteLensSurfaceRole role = SiteLensSurfaceRole.panel,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final base = dark
      ? LiquidGlassSettings.ios27Dark
      : LiquidGlassSettings.ios27Light;
  // The user preference controls the fill of every Flutter glass surface.
  // Keep blur, refraction, frost and rim treatment at full strength. Controls
  // over a native WebView retain their polarity-matched backer for contrast.
  final requestedGlassFillAlpha =
      Theme.of(context).extension<SiteLensGlassTheme>()?.backgroundAlpha ??
      0.45;
  // Android's lightweight renderer needs a translucent ceiling to keep the
  // backdrop and adjacent panels visually connected. A stored value of 100
  // otherwise becomes a flat white slab on high-density vendor devices.
  final glassFillAlpha = defaultTargetPlatform == TargetPlatform.android
      ? requestedGlassFillAlpha <= 0.45
            ? requestedGlassFillAlpha
            : 0.45 + (requestedGlassFillAlpha - 0.45) * 0.49
      : requestedGlassFillAlpha;
  // The fill and edge belong to the same global neutral surface token. Theme
  // color remains reserved for the backdrop, selected state and status UI.
  final colors = SiteLensColors.of(context);
  final globalSurfaceBase = colors.glassSurface;
  final glassFill = globalSurfaceBase.withValues(alpha: glassFillAlpha);
  // Keep the material baseline unchanged from the default value upward.
  // Only low fill alpha needs a limited frost reduction; otherwise the
  // preference would also change the glass character at ordinary values.
  const defaultFillAlpha = 0.45;
  final lowAlphaProgress = (glassFillAlpha / defaultFillAlpha).clamp(0.0, 1.0);
  final frostFactor = glassFillAlpha >= defaultFillAlpha
      ? 1.0
      : 0.15 + 0.85 * Curves.easeOut.transform(lowAlphaProgress);
  final isAndroid = defaultTargetPlatform == TargetPlatform.android;
  final adjusted = role == SiteLensSurfaceRole.platformView
      ? base
      : base.copyWith(
          visibility: 1,
          bodyMode: GlassBodyMode.clear,
          glassColor: glassFill,
          // Standard translates the iOS frost cloud into its compatible blur
          // path while keeping the child composited. Keep the optical depth
          // subtle on Android so the structural rim never becomes a second
          // bright panel, while the frost/tint still reads as glass.
          blur: base.blur,
          frost: base.frost,
          frostOpacity: base.frostOpacity * frostFactor,
          thickness: isAndroid ? 12 : base.thickness,
          refractiveIndex: isAndroid ? 1.08 : base.refractiveIndex,
          lightIntensity: isAndroid ? 0 : base.lightIntensity,
          rimLight: isAndroid ? 0 : base.rimLight,
          rimShade: isAndroid ? 0 : base.rimShade,
          edgeAbsorption: isAndroid ? 0 : base.edgeAbsorption,
          shadow: isAndroid ? const <BoxShadow>[] : base.shadow,
        );
  if (role != SiteLensSurfaceRole.platformView) return adjusted;
  return adjusted.copyWith(
    backerColor: dark ? const Color(0x99000000) : const Color(0xA6FFFFFF),
  );
}

/// One material boundary for the whole app.
///
/// Uses the premium material where the renderer is stable and the child-safe
/// frosted compatibility path on Android. Both paths share the same theme
/// tokens and Material semantics.
class SiteLensGlassSurface extends StatelessWidget {
  const SiteLensGlassSurface({
    super.key,
    required this.child,
    this.role = SiteLensSurfaceRole.panel,
    this.radius = SiteLensMetrics.panelRadius,
    this.padding,
  });

  final Widget child;
  final SiteLensSurfaceRole role;
  final double radius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    // A transparent Material gives ListTile/SwitchListTile/InkWell the ink and
    // splash context they assert on, without painting a second surface.
    final content = Material(
      type: MaterialType.transparency,
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    final settings = siteLensGlassSettings(context, role: role);
    return AdaptiveGlass(
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      settings: settings,
      // Android devices can report Impeller support while the premium
      // own-layer path still drops child content on some vendor renderers.
      // Standard keeps the child composited and retains the frost/blur glass
      // material; Android settings above reduce its independent rim. iOS and
      // desktop retain the full premium path.
      quality: defaultTargetPlatform == TargetPlatform.android
          ? GlassQuality.standard
          : GlassQuality.premium,
      platformViewBackdrop: role == SiteLensSurfaceRole.platformView,
      // Chrome and panels both provide the backdrop for their children: glass
      // inside a bar is a nested surface and would only double the blur.
      allowElevation: false,
      child: content,
    );
  }
}

/// The floating bottom navigation uses the same iOS 27 liquid-glass
/// material as the rest of the app. The selected destination supplies the
/// only local tint; the navigation surface itself must remain transparent
/// enough to refract the shared app backdrop.
class SiteLensNavigationSurface extends StatelessWidget {
  const SiteLensNavigationSurface({
    super.key,
    required this.child,
    this.radius = SiteLensMetrics.navRadius,
  });

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SiteLensGlassSurface(
      role: SiteLensSurfaceRole.chrome,
      radius: radius,
      child: child,
    ),
  );
}

/// A content panel: the single surface used where Material's `Card` used to be.
class SiteLensPanel extends StatelessWidget {
  const SiteLensPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(SiteLensMetrics.panelPadding),
    this.radius = SiteLensMetrics.panelRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) =>
      SiteLensGlassSurface(radius: radius, padding: padding, child: child);
}

/// Groups the glass of one screen so sibling surfaces share a single backdrop
/// read instead of one full-screen capture each.
class SiteLensGlassGroup extends StatelessWidget {
  const SiteLensGlassGroup({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      GlassBackdropGroup(enabled: !kIsWeb, joinEnclosing: true, child: child);
}
