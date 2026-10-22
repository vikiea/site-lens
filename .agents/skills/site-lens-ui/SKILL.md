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
- Foldable panels keep the same no-shadow hierarchy while collapsed, pressed, focused, hovered, and expanded; interaction feedback comes from glass tint/overlay and shape, never elevation or a drop shadow.
- The bottom navigation is a floating, narrow glass chrome surface. It must use the liquid-glass path, keep one row of icon-plus-label destinations, and use a tinted selected capsule without a solid navigation slab.
- Prefer shared UI primitives and theme tokens over one-off `Container`, `BoxDecoration`, `Card`, `TextStyle`, `BorderRadius`, or hard-coded colors in screens.
- Keep related settings in one semantic foldable panel when the group is finite; do not add a route only to hold two or three controls. Use at most the second route level for ordinary settings flows.
- Use one accordion controller per semantic panel so opening a detail closes the previous detail in that panel. Keep top-level settings panels independently collapsible.
- Treat rendering cost as a hard constraint: long lists must remain lazily built with one page scroll owner and a bounded glass viewport. Remove per-row glass surfaces only when the shared viewport preserves virtualization and stable layout.
- Use `SiteLensMenuSelector` for compact single-choice menus; follow the sizing, interaction, and accessibility rules in [Compact choice menus](references/ui-system.md#compact-choice-menus).
- Foldable panels use the shared foldable-panel primitive/theme; do not introduce raw `ExpansionTile` defaults with elevation, pressed shadows, opaque backgrounds, or page-local shape overrides.
- Preserve existing business behavior, fail-closed navigation and script rules, WebView lifecycle, and data flows while changing presentation.

## Implementation workflow

1. Inspect the existing surface role and theme token before adding a new one.
2. Reuse or extend the shared primitive layer before composing a page-local widget.
3. Keep Material controls when they provide useful semantics and interaction; style them through the Site Lens theme or wrap them in a Site Lens surface.
4. Check light mode, dark mode, a non-default theme preset, narrow phone width, long Chinese text, empty state, and error state.
5. For long or dynamic lists, verify lazy construction, one scroll owner, bounded glass size, forward/reverse scrolling, and detail expansion before optimizing panel count.
6. Use `$site-lens-validation` to run the targeted UI tests and the smallest sufficient validation level before reporting completion. UI changes that affect WebView overlays, platform insets, gestures, or native callbacks require L2 or higher.

Do not introduce Cupertino as a replacement for the whole component system. Use it only when a platform-native interaction is explicitly required.
