import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_theme.dart';
import 'glass_quality_strategy.dart';

export 'glass_quality_strategy.dart'
    show
        SiteLensGlassPolicyScope,
        SiteLensGlassQualityStrategy,
        SiteLensGlassRenderPlan,
        SiteLensGlassQualityLabel,
        SiteLensSurfaceRole;

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

/// Resolves the current material settings through the shared strategy.
LiquidGlassSettings siteLensGlassSettings(
  BuildContext context, {
  SiteLensSurfaceRole role = SiteLensSurfaceRole.panel,
}) =>
    SiteLensGlassPolicyScope.of(context).resolve(context, role: role).settings;

/// One material boundary for the whole app.
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
    final plan = SiteLensGlassPolicyScope.of(context)
        .resolve(context, role: role);
    if (plan.useCompatibilityFallback) {
      return ClipPath(
        clipper: ShapeBorderClipper(
          shape: LiquidRoundedSuperellipse(borderRadius: radius),
        ),
        child: ColoredBox(color: plan.glassColor, child: content),
      );
    }
    return AdaptiveGlass(
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      settings: plan.settings,
      quality: plan.quality,
      platformViewBackdrop: plan.platformViewBackdrop,
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
