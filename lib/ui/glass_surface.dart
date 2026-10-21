import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
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
    this.scrollingContent = false,
    this.scrollContent = true,
  });

  final Widget child;
  final SiteLensSurfaceRole role;
  final double radius;
  final EdgeInsetsGeometry? padding;

  /// Bounds the material to the viewport and scrolls long content inside it.
  /// The selected glass quality stays unchanged.
  final bool scrollingContent;

  /// False when a bounded child already owns its scrollable viewport.
  final bool scrollContent;

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
    Widget surface(Widget body) {
      if (plan.useCompatibilityFallback) {
        final backer = plan.settings.effectiveBackerColor;
        return ClipPath(
          clipper: ShapeBorderClipper(
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              if (backer != null)
                Positioned.fill(child: ColoredBox(color: backer)),
              ColoredBox(color: plan.glassColor, child: body),
            ],
          ),
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
        child: body,
      );
    }

    if (!scrollingContent &&
        (role != SiteLensSurfaceRole.panel ||
            plan.quality != GlassQuality.premium)) {
      return surface(content);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final viewport =
            (media.size.height -
                    media.padding.vertical -
                    media.viewInsets.vertical)
                .clamp(0.0, double.infinity);
        final maxHeight =
            (constraints.hasBoundedHeight
                    ? constraints.maxHeight.clamp(0.0, viewport * 0.7)
                    : viewport * 0.7)
                .toDouble();
        if (maxHeight == 0) return const SizedBox.shrink();
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : null;
        return Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: SizedBox(
            width: width,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: surface(
                scrollContent
                    ? SingleChildScrollView(primary: false, child: content)
                    : content,
              ),
            ),
          ),
        );
      },
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
    this.scrollingContent = false,
    this.scrollContent = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool scrollingContent;
  final bool scrollContent;

  @override
  Widget build(BuildContext context) => SiteLensGlassSurface(
    radius: radius,
    padding: padding,
    scrollingContent: scrollingContent,
    scrollContent: scrollContent,
    child: child,
  );
}

/// Groups the glass of one screen so sibling surfaces share a single backdrop
/// read instead of one full-screen capture each.
class SiteLensGlassGroup extends StatelessWidget {
  const SiteLensGlassGroup({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassBackdropGroup(
    enabled:
        !kIsWeb &&
        !(defaultTargetPlatform == TargetPlatform.android &&
            SiteLensGlassPolicyScope.of(context).webViewVisible &&
            !SiteLensGlassPolicyScope.of(context).hcppEffective),
    joinEnclosing: true,
    child: child,
  );
}
