import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/app_settings.dart';
export '../settings/app_settings.dart' show ThemePresetId, ThemeModePreference;

/// Shared geometry. Every screen takes its spacing, radii and control sizes
/// from here so the whole app reads as one material instead of five.
/// Route transitions use the app backdrop as their underlay instead of the
/// platform default black frame, which is visible through transparent glass.
class SiteLensFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const SiteLensFadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ColoredBox(
        color: SiteLensColors.of(context).backdropTop,
        child: child,
      ),
    );
  }
}

/// Android edge overscroll can temporarily invalidate the backdrop layer used
/// by the glass surfaces, especially when a scroll reaches either extent.
/// Keep the product pages on bounded clamping physics and suppress the Android
/// glow/stretch decoration globally so every scrollable page behaves the same.
class SiteLensScrollBehavior extends MaterialScrollBehavior {
  const SiteLensScrollBehavior();

  bool _usesAndroidEdgeEffects(BuildContext context) {
    final platform = getPlatform(context);
    return platform == TargetPlatform.android ||
        platform == TargetPlatform.fuchsia;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (_usesAndroidEdgeEffects(context)) {
      return const ClampingScrollPhysics();
    }
    return super.getScrollPhysics(context);
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (_usesAndroidEdgeEffects(context)) return child;
    return super.buildOverscrollIndicator(context, child, details);
  }
}

abstract final class SiteLensMetrics {
  static const pagePadding = 16.0;
  static const itemGap = 10.0;
  static const listGap = 14.0;
  static const formGap = 12.0;
  static const sectionGap = 24.0;
  static const panelRadius = 22.0;
  static const panelPadding = 18.0;
  static const inputRadius = 14.0;
  static const compactRowHorizontalPadding = 12.0;
  static const compactRowVerticalPadding = 3.0;
  static const compactRowMinHeight = 52.0;
  static const compactIconSize = 18.0;
  static const compactIconButtonSize = 36.0;
  static const compactDividerIndent = 12.0;
  static const accordionContentIndent = 42.0;
  static const settingsDividerIndent = 18.0;
  static const settingsSectionLabelHorizontalPadding = 6.0;
  static const settingsSectionLabelBottom = 8.0;

  /// Fixed bottom navigation: one compact labelled row, never wraps. The
  /// outer surface is narrower than the screen so it reads as a floating iOS
  /// chrome element instead of a full-width app bar.
  static const navBarHeight = 72.0;
  static const navIconSize = 20.0;
  static const navLabelSize = 12.0;
  // The rendered capsule is 60dp tall after the outer inset; keep the
  // superellipse radius within half its height so the clipped edge stays
  // smooth on Impeller and Skia.
  static const navRadius = 30.0;
  static const navHorizontalInset = 28.0;
  static const navCapsuleInset = 6.0;

  /// Compact segmented controls use the same short-pill proportions as the
  /// bottom navigation indicator.
  static const segmentedHeight = 40.0;
  static const segmentedInset = 2.0;

  /// Browser toolbar: one row of seven equal controls.
  static const toolbarHeight = 48.0;
  static const toolbarIconSize = 18.0;
  static const toolbarInset = 12.0;
  static const toolbarRadius = 26.0;
}

extension ThemePresetIdLabel on ThemePresetId {
  String get label => switch (this) {
    ThemePresetId.oceanBlue => '星海蓝',
    ThemePresetId.mistPine => '雾松绿',
    ThemePresetId.irisViolet => '鸢尾紫',
    ThemePresetId.roseGray => '玫瑰灰',
    ThemePresetId.sandstoneCopper => '砂岩铜',
    ThemePresetId.graphiteBlue => '石墨蓝灰',
    ThemePresetId.auroraCyan => '极光青',
    ThemePresetId.sunsetCoral => '落日珊瑚',
    ThemePresetId.lavenderInk => '皇家紫',
    ThemePresetId.mintGlass => '青柠橄榄',
    ThemePresetId.amberGlow => '琥珀金',
    ThemePresetId.midnightIndigo => '深海墨蓝',
  };

  Color get seed => switch (this) {
    ThemePresetId.oceanBlue => const Color(0xff4c63d9),
    ThemePresetId.mistPine => const Color(0xff2f766b),
    ThemePresetId.irisViolet => const Color(0xff9254ba),
    ThemePresetId.roseGray => const Color(0xffa45570),
    ThemePresetId.sandstoneCopper => const Color(0xff986449),
    ThemePresetId.graphiteBlue => const Color(0xff5a6776),
    ThemePresetId.auroraCyan => const Color(0xff159aab),
    ThemePresetId.sunsetCoral => const Color(0xffd8665c),
    ThemePresetId.lavenderInk => const Color(0xff4a148c),
    ThemePresetId.mintGlass => const Color(0xff8aa22b),
    ThemePresetId.amberGlow => const Color(0xffc58428),
    ThemePresetId.midnightIndigo => const Color(0xff174a63),
  };
}

ThemeMode toThemeMode(ThemeModePreference value) => switch (value) {
  ThemeModePreference.system => ThemeMode.system,
  ThemeModePreference.light => ThemeMode.light,
  ThemeModePreference.dark => ThemeMode.dark,
};

/// System bars follow the same polarity as the Site Lens surface behind them.
/// Android reads [statusBarIconBrightness] and [systemNavigationBarIconBrightness];
/// iOS reads [statusBarBrightness]. Keep all three in sync so transparent
/// edge-to-edge surfaces never leave white icons over the light backdrop.
SystemUiOverlayStyle siteLensSystemUiOverlayStyle(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );
}

/// Colour roles the Material scheme does not carry: the static backdrop the
/// glass refracts, status colours, and the dividers used between rows of one
/// panel. Hard-coded whites/blacks used to live in individual widgets; they
/// belong here so every theme preset keeps the same contrast.
@immutable
class SiteLensColors extends ThemeExtension<SiteLensColors> {
  const SiteLensColors({
    required this.backdropTop,
    required this.backdropBottom,
    required this.backdropTint,
    required this.glassSurface,
    required this.panelTint,
    required this.surfaceOpaque,
    required this.wellTint,
    required this.panelBorder,
    required this.divider,
    required this.sectionLabel,
    required this.disabledContent,
    required this.ok,
    required this.warning,
    required this.danger,
  });

  final Color backdropTop;
  final Color backdropBottom;
  final Color backdropTint;

  /// Neutral base color shared by every glass surface. Theme colors tint the
  /// backdrop and selected controls rather than changing the material itself.
  final Color glassSurface;

  /// Translucent fill for controls that sit *on* glass (chips, segmented
  /// tracks, selected rows).
  final Color panelTint;

  /// Near-opaque surface for Material overlays that are not backed by glass —
  /// menus, dialogs, sheets, snack bars. They must stay readable over any
  /// page, so they cannot use [panelTint].
  final Color surfaceOpaque;

  /// Fill for input wells and other recessed areas inside a glass panel.
  final Color wellTint;

  final Color panelBorder;
  final Color divider;
  final Color sectionLabel;
  final Color disabledContent;
  final Color ok;
  final Color warning;
  final Color danger;

  /// Resolves the roles for one preset and brightness.
  factory SiteLensColors.resolve(ThemePresetId preset, Brightness brightness) {
    final seed = preset.seed;
    if (brightness == Brightness.dark) {
      return SiteLensColors(
        backdropTop: const Color(0xff0e131c),
        backdropBottom: const Color(0xff1a2230),
        backdropTint: seed.withValues(alpha: 0.22),
        glassSurface: const Color(0xff25272b),
        panelTint: const Color(0x14FFFFFF),
        surfaceOpaque: const Color(0xf21a2230),
        wellTint: const Color(0x24FFFFFF),
        panelBorder: const Color(0x3218202c),
        divider: const Color(0x1FFFFFFF),
        sectionLabel: const Color(0xffb9c6d8),
        disabledContent: const Color(0xff778293),
        ok: const Color(0xff57d68f),
        warning: const Color(0xffe8b155),
        danger: const Color(0xffff8f86),
      );
    }
    return SiteLensColors(
      backdropTop: const Color(0xfff5f7fb),
      backdropBottom: const Color(0xffe7edf6),
      backdropTint: seed.withValues(alpha: 0.12),
      glassSurface: const Color(0xffe7eaee),
      panelTint: const Color(0x4df0f4fa),
      surfaceOpaque: const Color(0xf2fbfcfe),
      wellTint: const Color(0x12000000),
      panelBorder: const Color(0x45f0f4fa),
      divider: const Color(0x1F000000),
      sectionLabel: const Color(0xff4a5568),
      disabledContent: const Color(0xff8b93a1),
      ok: const Color(0xff1c8a56),
      warning: const Color(0xff9a6400),
      danger: const Color(0xffb3261e),
    );
  }

  static SiteLensColors of(BuildContext context) =>
      Theme.of(context).extension<SiteLensColors>() ??
      SiteLensColors.resolve(ThemePresetId.sunsetCoral, Brightness.light);

  @override
  SiteLensColors copyWith({
    Color? backdropTop,
    Color? backdropBottom,
    Color? backdropTint,
    Color? glassSurface,
    Color? panelTint,
    Color? surfaceOpaque,
    Color? wellTint,
    Color? panelBorder,
    Color? divider,
    Color? sectionLabel,
    Color? disabledContent,
    Color? ok,
    Color? warning,
    Color? danger,
  }) => SiteLensColors(
    backdropTop: backdropTop ?? this.backdropTop,
    backdropBottom: backdropBottom ?? this.backdropBottom,
    backdropTint: backdropTint ?? this.backdropTint,
    glassSurface: glassSurface ?? this.glassSurface,
    panelTint: panelTint ?? this.panelTint,
    surfaceOpaque: surfaceOpaque ?? this.surfaceOpaque,
    wellTint: wellTint ?? this.wellTint,
    panelBorder: panelBorder ?? this.panelBorder,
    divider: divider ?? this.divider,
    sectionLabel: sectionLabel ?? this.sectionLabel,
    disabledContent: disabledContent ?? this.disabledContent,
    ok: ok ?? this.ok,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
  );

  @override
  SiteLensColors lerp(ThemeExtension<SiteLensColors>? other, double t) {
    if (other is! SiteLensColors) return this;
    return SiteLensColors(
      backdropTop: Color.lerp(backdropTop, other.backdropTop, t)!,
      backdropBottom: Color.lerp(backdropBottom, other.backdropBottom, t)!,
      backdropTint: Color.lerp(backdropTint, other.backdropTint, t)!,
      glassSurface: Color.lerp(glassSurface, other.glassSurface, t)!,
      panelTint: Color.lerp(panelTint, other.panelTint, t)!,
      surfaceOpaque: Color.lerp(surfaceOpaque, other.surfaceOpaque, t)!,
      wellTint: Color.lerp(wellTint, other.wellTint, t)!,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      sectionLabel: Color.lerp(sectionLabel, other.sectionLabel, t)!,
      disabledContent: Color.lerp(disabledContent, other.disabledContent, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

TextTheme _textTheme(ColorScheme scheme) {
  final on = scheme.onSurface;
  final muted = scheme.onSurfaceVariant;
  return TextTheme(
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: on,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: on,
    ),
    titleSmall: TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      color: on,
    ),
    bodyLarge: TextStyle(fontSize: 15.5, height: 1.35, color: on),
    bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: on),
    bodySmall: TextStyle(fontSize: 12.5, height: 1.4, color: muted),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(fontSize: 12, color: muted),
    labelSmall: TextStyle(fontSize: 11, color: muted, letterSpacing: 0.2),
  );
}

@immutable
class SiteLensGlassTheme extends ThemeExtension<SiteLensGlassTheme> {
  const SiteLensGlassTheme({required this.backgroundAlpha});

  /// Absolute fill alpha for Flutter liquid-glass surfaces. Blur, refraction,
  /// frost and rim treatment stay at their normal strength.
  final double backgroundAlpha;

  @override
  SiteLensGlassTheme copyWith({double? backgroundAlpha}) => SiteLensGlassTheme(
    backgroundAlpha: backgroundAlpha ?? this.backgroundAlpha,
  );

  @override
  SiteLensGlassTheme lerp(ThemeExtension<SiteLensGlassTheme>? other, double t) {
    if (other is! SiteLensGlassTheme) return this;
    return SiteLensGlassTheme(
      backgroundAlpha: lerpDouble(backgroundAlpha, other.backgroundAlpha, t),
    );
  }

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

ThemeData buildSiteLensTheme(
  ThemePresetId preset,
  Brightness brightness, {
  int glassOpacity = AppPolicy.defaultGlassOpacity,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: preset.seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final colors = SiteLensColors.resolve(preset, brightness);
  final text = _textTheme(scheme);
  final radius = BorderRadius.circular(SiteLensMetrics.panelRadius);
  // Buttons never carry their own elevation: the material is the depth cue.
  const flat = WidgetStatePropertyAll(0.0);
  const flatColor = WidgetStatePropertyAll(Colors.transparent);

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    textTheme: text,
    // The backdrop is painted once behind the whole app, so screens are
    // transparent and the glass has something to refract.
    scaffoldBackgroundColor: Colors.transparent,
    splashFactory: InkSparkle.splashFactory,
    extensions: [
      colors,
      SiteLensGlassTheme(backgroundAlpha: glassOpacity.clamp(0, 100) / 100),
    ],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SiteLensFadePageTransitionsBuilder(),
        TargetPlatform.iOS: SiteLensFadePageTransitionsBuilder(),
        TargetPlatform.linux: SiteLensFadePageTransitionsBuilder(),
        TargetPlatform.macOS: SiteLensFadePageTransitionsBuilder(),
        TargetPlatform.windows: SiteLensFadePageTransitionsBuilder(),
        TargetPlatform.fuchsia: SiteLensFadePageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 20,
      titleTextStyle: text.titleLarge,
      toolbarTextStyle: text.bodyMedium,
      actionsIconTheme: IconThemeData(color: scheme.onSurface, size: 22),
      systemOverlayStyle: siteLensSystemUiOverlayStyle(brightness),
    ),
    bottomAppBarTheme: const BottomAppBarThemeData(elevation: 0),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceOpaque,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: colors.panelBorder),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: SiteLensMetrics.navBarHeight,
      elevation: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      indicatorShape: const StadiumBorder(),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelPadding: const EdgeInsets.only(top: 2),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelSmall?.copyWith(
          fontSize: SiteLensMetrics.navLabelSize,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: SiteLensMetrics.navIconSize,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.wellTint,
      hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      helperStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
        borderSide: BorderSide(color: colors.panelBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
        borderSide: BorderSide(color: colors.panelBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        elevation: flat,
        shadowColor: flatColor,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              SiteLensMetrics.inputRadius + 2,
            ),
          ),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        elevation: flat,
        shadowColor: flatColor,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              SiteLensMetrics.inputRadius + 2,
            ),
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        elevation: flat,
        shadowColor: flatColor,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              SiteLensMetrics.inputRadius + 2,
            ),
          ),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        elevation: flat,
        shadowColor: flatColor,
        foregroundColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
      ),
    ),
    // Kept even though the app has no FAB today: the rule is that no control
    // carries its own elevation, so a future one inherits it instead of
    // reintroducing a shadow.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: colors.surfaceOpaque,
      foregroundColor: scheme.onSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.panelRadius),
        side: BorderSide(color: colors.panelBorder),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        elevation: flat,
        shadowColor: flatColor,
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary.withValues(alpha: 0.20)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: colors.panelBorder)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
          ),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: 0.85)
            : colors.divider,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: scheme.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: text.titleSmall,
      subtitleTextStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      minVerticalPadding: 12,
      shape: RoundedRectangleBorder(borderRadius: radius),
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primary.withValues(alpha: 0.12),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      textColor: scheme.onSurface,
      collapsedTextColor: scheme.onSurface,
      iconColor: scheme.onSurfaceVariant,
      collapsedIconColor: scheme.onSurfaceVariant,
      tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      shape: RoundedRectangleBorder(borderRadius: radius),
      collapsedShape: RoundedRectangleBorder(borderRadius: radius),
    ),
    dividerTheme: DividerThemeData(
      color: colors.divider,
      thickness: 1,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: colors.surfaceOpaque,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.panelRadius + 4),
        side: BorderSide(color: colors.panelBorder),
      ),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      elevation: 0,
      modalElevation: 0,
      backgroundColor: colors.surfaceOpaque,
      modalBackgroundColor: colors.surfaceOpaque,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: colors.divider,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 0,
      color: colors.surfaceOpaque,
      surfaceTintColor: Colors.transparent,
      textStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius + 2),
        side: BorderSide(color: colors.panelBorder),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: colors.surfaceOpaque,
      contentTextStyle: text.bodyMedium,
      insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius + 2),
        side: BorderSide(color: colors.panelBorder),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      textStyle: TextStyle(fontSize: 12.5, color: scheme.onInverseSurface),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.panelTint,
      side: BorderSide(color: colors.panelBorder),
      shape: const StadiumBorder(),
      labelStyle: text.labelMedium,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: colors.divider,
      circularTrackColor: colors.divider,
    ),
  );
}
