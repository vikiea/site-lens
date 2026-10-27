import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../background/background_snapshot.dart';
import '../settings/app_settings.dart';
import 'app_theme.dart';
import 'glass_quality_strategy.dart';

export 'glass_quality_strategy.dart'
    show
        SiteLensGlassPolicyScope,
        SiteLensGlassQualityStrategy,
        SiteLensGlassRenderPlan,
        SiteLensGlassQualityLabel,
        SiteLensSurfaceRole;

Widget _siteLensBackdropGradient(
  BuildContext context, {
  required bool useThemeSource,
}) {
  final colors = SiteLensColors.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final themeAccent = colors.backdropTint.withValues(alpha: 1);
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          useThemeSource
              ? Color.lerp(colors.backdropTop, themeAccent, dark ? 0.34 : 0.24)!
              : colors.backdropTop,
          useThemeSource
              ? Color.lerp(
                  colors.backdropBottom,
                  themeAccent,
                  dark ? 0.24 : 0.16,
                )!
              : colors.backdropBottom,
        ],
      ),
    ),
  );
}

/// The app-wide backdrop: one static, low-saturation gradient (tinted by the
/// selected theme) that every glass surface refracts.
///
/// It is painted once behind the whole app so screens stay transparent and the
/// material has something real to sample. Nothing animates, so there is no
/// continuous repaint behind the glass.
class SiteLensBackdrop extends StatelessWidget {
  const SiteLensBackdrop({
    super.key,
    required this.child,
    this.background = const BackgroundSnapshot(),
  });
  final Widget child;
  final BackgroundSnapshot background;

  @override
  Widget build(BuildContext context) {
    if (background.mode == BackgroundMode.transparent) {
      return Stack(fit: StackFit.expand, children: [child]);
    }
    final colors = SiteLensColors.of(context);
    final imagePath = background.imagePath;
    final transparent = background.mode == BackgroundMode.transparent;
    final useImage =
        imagePath != null &&
        (background.mode == BackgroundMode.customImage || transparent);
    final useThemeSource =
        background.mode == BackgroundMode.themeBuiltIn ||
        (transparent && !useImage);
    final image = !useImage
        ? null
        : Image.file(
            File(imagePath),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, _, _) => _siteLensBackdropGradient(
              context,
              // A broken custom image in transparent mode follows the same
              // fallback order as a missing asset: theme background first.
              useThemeSource: transparent,
            ),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image != null) Positioned.fill(child: image),
        if (image == null)
          _siteLensBackdropGradient(context, useThemeSource: useThemeSource),
        if (!transparent && image != null)
          Positioned.fill(
            child: ColoredBox(
              color: colors.backdropTint.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 0.18
                    : 0.10,
              ),
            ),
          ),
        if (!transparent && image == null)
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

enum SiteLensGlassEdge { left, right }

/// One material boundary for the whole app.
class SiteLensGlassSurface extends StatelessWidget {
  const SiteLensGlassSurface({
    super.key,
    required this.child,
    this.role = SiteLensSurfaceRole.panel,
    this.radius = SiteLensMetrics.panelRadius,
    this.attachedEdge,
    this.padding,
    this.scrollingContent = false,
    this.scrollContent = true,
  });

  final Widget child;
  final SiteLensSurfaceRole role;
  final double radius;
  final SiteLensGlassEdge? attachedEdge;
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
    final policy = SiteLensGlassPolicyScope.of(context);
    final plan = policy.resolve(context, role: role);
    final edge = attachedEdge;
    final LiquidShape shape = edge == null
        ? LiquidRoundedSuperellipse(borderRadius: radius)
        : LiquidVerticalRoundedRectangle(
            topRadius: edge == SiteLensGlassEdge.left ? radius : 0,
            bottomRadius: edge == SiteLensGlassEdge.right ? radius : 0,
          );
    Widget surface(Widget body) {
      if (edge != null) body = RotatedBox(quarterTurns: 3, child: body);

      // The alpha15 high-quality path used one AdaptiveGlass boundary with the
      // real content as its child. Keep that exact composition when Impeller
      // is available: it preserves the package's full refraction, specular rim
      // and edge geometry. The stable sibling path below is retained for Skia,
      // compatibility fills and adaptive transitions where the child must not
      // be remounted while the shader tier changes.
      final useFullPremiumShader =
          !kIsWeb &&
          policy.mode == SiteLensGlassQualityMode.high &&
          plan.quality == GlassQuality.premium &&
          !plan.useCompatibilityFallback &&
          ui.ImageFilter.isShaderFilterSupported;
      if (useFullPremiumShader) {
        final result = AdaptiveGlass(
          shape: shape,
          settings: plan.settings,
          quality: plan.quality,
          platformViewBackdrop: plan.platformViewBackdrop,
          allowElevation: false,
          child: body,
        );
        return edge == null
            ? result
            : RotatedBox(quarterTurns: 1, child: result);
      }

      late final Widget decoration;
      if (plan.useCompatibilityFallback) {
        final backer = plan.settings.effectiveBackerColor;
        decoration = ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backer != null) ColoredBox(color: backer),
              ColoredBox(color: plan.glassColor),
            ],
          ),
        );
      } else {
        decoration = AdaptiveGlass(
          shape: shape,
          settings: plan.settings,
          quality: plan.quality,
          platformViewBackdrop: plan.platformViewBackdrop,
          // Chrome and panels both provide the backdrop for their children: glass
          // inside a bar is a nested surface and would only double the blur.
          allowElevation: false,
          child: const SizedBox.expand(),
        );
      }
      // Shader loading and quality changes can replace the dependency's entire
      // child tree. Keep real content in a stable sibling slot so it always
      // paints, retaining state/focus even on the first premium frame.
      final stableBody = InheritedLiquidGlass(
        settings: plan.settings,
        quality: plan.quality,
        // Keep this inherited node even in fallback mode. Replacing the
        // wrapper would remount all content when backend support changes.
        // The decoration sibling supplies blur whenever shaders are enabled.
        isBlurProvidedByAncestor: !plan.useCompatibilityFallback,
        child: body,
      );
      // Clip only the content sibling. AdaptiveGlass/fallback decoration owns
      // its own shape clip, so the same edge is not anti-aliased twice.
      final result = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: ExcludeSemantics(child: IgnorePointer(child: decoration)),
          ),
          ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: stableBody,
          ),
        ],
      );
      return edge == null ? result : RotatedBox(quarterTurns: 1, child: result);
    }

    // Material quality must not add a second scrolling owner. Ordinary pages
    // split long settings into smaller panels; only an explicit viewport opts in.
    if (!scrollingContent) return surface(content);
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
