import 'package:flutter/foundation.dart' show kIsWeb;
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
  if (role != SiteLensSurfaceRole.platformView) return base;
  return base.copyWith(
    backerColor: dark ? const Color(0x99000000) : const Color(0xA6FFFFFF),
  );
}

/// One material boundary for the whole app.
///
/// Quality is fixed at [GlassQuality.premium]: the material is a product
/// decision, not a device-dependent fallback. Reduce Motion still stops the
/// animations; high contrast never swaps the material out.
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
    return AdaptiveGlass(
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      settings: siteLensGlassSettings(context, role: role),
      quality: GlassQuality.premium,
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
