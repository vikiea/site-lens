---
name: site-lens-ui
description: Apply the Site Lens Flutter UI system when creating or changing screens, themes, widgets, dialogs, navigation, browser chrome, or visual regression captures. Preserve the project's iOS 27 liquid-glass surface language while keeping Material as the behavior and accessibility substrate.
---

# Site Lens UI

Use this skill for UI work in this repository. Read [references/ui-system.md](references/ui-system.md) before changing a shared surface, theme token, page shell, dialog, sheet, navigation control, or screenshot.

## Core contract

- Treat liquid glass as the visual surface system and Material as Flutter's application, behavior, semantics, focus, and accessibility infrastructure. Do not replace `MaterialApp`, `ThemeData`, `Scaffold`, `Navigator`, or Material behavior wholesale.
- Use `SiteLensBackdrop`, `SiteLensGlassSurface`, `SiteLensPanel`, and `SiteLensGlassGroup` for app surfaces. Use `SiteLensSurfaceRole.platformView` only for controls over the native WebView.
- Keep the background static, low saturation, and theme tinted. Do not add page-local gradients, shadows, opaque cards, or a second spacing/radius system.
- Treat backdrop modes as semantic sources: `defaultGradient` paints the default gradient, `themeBuiltIn` paints the theme-derived gradient, `customImage` paints the uploaded image, and the legacy `transparent` wire id selects the `纯色背景` mode. That mode ignores any previously uploaded image, paints opaque black in dark appearance and the theme's neutral solid backdrop in light appearance, and gives premium glass a stable app-owned source.
- Shared menus and ordinary top-bar actions use the active glass render plan's `glassColor` for their base fill; `SiteLensColors.controlSurface(SiteLensBackdropScope.modeOf(context))` supplies interaction tint and control-state feedback instead of unrelated white or grey Material surfaces.
- Foldable panels keep the same no-shadow hierarchy while collapsed, pressed, focused, hovered, and expanded; interaction feedback comes from glass tint/overlay and shape, never elevation or a drop shadow.
- The bottom navigation is a floating, narrow glass chrome surface. It must use the liquid-glass path, keep one row of icon-plus-label destinations, and use a tinted selected capsule without a solid navigation slab.
- Prefer shared UI primitives and theme tokens over one-off `Container`, `BoxDecoration`, `Card`, `TextStyle`, `BorderRadius`, or hard-coded colors in screens.
- Keep ordinary rows on the shared `SiteLensMetrics.compactRowMinHeight` baseline. Use compact switch and overflow primitives so controls do not steal width from the primary label.
- Keep row copy to one title line plus one short description line. Use `SiteLensRowText` and the shared `SiteLensTypography` scale for short copy; when a description exceeds `SiteLensMetrics.rowDescriptionFoldThreshold`, use `SiteLensExpandableRow` or `SiteLensDisclosure` and place the complete description in the foldable detail. Do not solve long descriptions with truncation plus ellipsis.
- Switch rows use `SiteLensSwitchRow` or `SiteLensCompactSwitch`. Touching a switch row must keep the row surface quiet; the switch animation is the feedback. Do not restore grey pressed or focus slabs for touch interaction.
- Use low-contrast inset dividers between distinct rows in one panel. Keep a setting's label, selector, explanation and status together without decorative dividers between them.
- Group ordinary settings by category in one always-visible semantic panel. Category panels are separated by section labels; they do not fold. Do not add a route only to hold two or three simple controls.
- Keep complex workflows such as backups, gestures, media management, filtering, and scripts on direct second-level pages. Use inline disclosure only for secondary explanation or a long list row that benefits from one-open details.
- Use one accordion controller per detail list or secondary page so opening a detail closes the previous detail in that list. A settings category itself remains visible.
- Theme presets are a useful row disclosure: collapsed by default, with six circular candidates per row when opened. Do not turn the whole appearance category into a foldable panel.
- Treat rendering cost as a hard constraint: long lists must remain lazily built with one page scroll owner and a bounded glass viewport. Remove per-row glass surfaces only when the shared viewport preserves virtualization and stable layout.
- Secondary pages always show their title in the shared page shell. Keep content-height panels fixed for short groups; introduce an internal lazy viewport only for groups over ten rows or independently bounded long lists.
- Use `SiteLensMenuSelector` for compact single-choice menus; follow the sizing, interaction, and accessibility rules in [Compact choice menus](references/ui-system.md#compact-choice-menus).
- Foldable panels use the shared foldable-panel primitive/theme; do not introduce raw `ExpansionTile` defaults with elevation, pressed shadows, opaque backgrounds, or page-local shape overrides.
- Preserve existing business behavior, fail-closed navigation and script rules, WebView lifecycle, and data flows while changing presentation.
- Media Library and Media Tasks share the same folder/file browser interaction primitives for navigation, selection, move, rename, copy and delete. User-visible organization is persisted separately from native download paths so folder operations never invalidate resumable cache identities.
- Treat the canonical token snapshot in `references/ui-system.md` and the runtime values in `lib/ui/app_theme.dart` as one synchronization contract. When a shared metric, typography value, color role, opacity rule, surface role, or glass-quality rule changes intentionally, update both files and the focused UI tests in the same change.

## Implementation workflow

1. Inspect the existing surface role and the canonical token snapshot before adding a new one; compare against `lib/ui/app_theme.dart` when a value is involved.
2. Reuse or extend the shared primitive layer before composing a page-local widget.
3. Keep Material controls when they provide useful semantics and interaction; style them through the Site Lens theme or wrap them in a Site Lens surface.
4. Check light mode, dark mode, a non-default theme preset, narrow phone width, long Chinese text, empty state, and error state.
5. For long or dynamic lists, verify lazy construction, one scroll owner, bounded glass size, forward/reverse scrolling, and detail expansion before optimizing panel count. For short pages, verify that the panel stays content-sized.
6. Use `$site-lens-validation` to run the targeted UI tests and the smallest sufficient validation level before reporting completion. UI changes that affect WebView overlays, platform insets, gestures, or native callbacks require L2 or higher.

Do not introduce Cupertino as a replacement for the whole component system. Use it only when a platform-native interaction is explicitly required.
