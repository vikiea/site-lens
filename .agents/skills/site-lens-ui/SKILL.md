---
name: site-lens-ui
description: Apply the Site Lens Flutter UI system when creating or changing screens, themes, widgets, dialogs, navigation, browser chrome, or visual regression captures. Preserve the project's iOS 27 liquid-glass surface language while keeping Material as the behavior and accessibility substrate.
---

# Site Lens UI

Use this skill for UI work in this repository. This file is the router: read the one reference that matches the area you are changing, and read the review checklist before reporting completion. Do not load every reference.

## Read on demand

| Changing | Read |
| --- | --- |
| Surface layering, surface roles, depth hierarchy, nested glass boundaries | [references/surfaces.md](references/surfaces.md) |
| Token values, typography, color roles, chrome and navigation metrics | [references/tokens.md](references/tokens.md) |
| App chrome, bottom navigation, panels, rows, lists, choice menus, dialogs, feedback, empty states | [references/components.md](references/components.md) |
| Settings structure, backdrop modes, opacity setting, diagnostics page, theme presets | [references/settings-and-themes.md](references/settings-and-themes.md) |
| Final self-review before reporting a UI change | [references/review-checklist.md](references/review-checklist.md) |

## Core contract

These rules are non-negotiable; the references carry the detail.

- Treat liquid glass as the visual surface system and Material as Flutter's application, behavior, semantics, focus, and accessibility infrastructure. Do not replace `MaterialApp`, `ThemeData`, `Scaffold`, `Navigator`, or Material behavior wholesale.
- Use the shared primitives and theme tokens before composing a page-local widget: `SiteLensBackdrop`, `SiteLensGlassSurface`, `SiteLensPanel`, `SiteLensGlassGroup`, the row/switch/menu primitives, and `SiteLensMetrics`/`SiteLensColors`/`SiteLensTypography`. No page-local gradients, shadows, opaque cards, or a second spacing/radius system; no raw `Colors.*` outside the documented full-screen playback exception.
- Assign exactly one surface role per semantic surface (`panel`, `chrome`, `platformView`), and use `platformView` only for controls over the native WebView. Do not nest full glass surfaces unless the nested control has its own deliberate role.
- Keep Material elevation at zero. Depth comes from glass, tint, contrast, and spacing; interaction feedback comes from glass tint/overlay and shape, never elevation or a drop shadow.
- Backdrop modes are semantic sources: `defaultGradient`, `themeBuiltIn`, `customImage`, and the legacy `transparent` wire id that selects `纯色背景`. Never paint one mode with another mode's source.
- Keep the one-row invariants: the bottom navigation is a narrow floating glass bar with icon-plus-label destinations, and the browser toolbar is a single equal-width row with no wrapping or per-button surfaces.
- Rows keep one title line and one complete, horizontally draggable description. Never truncate a description or fold it automatically by length; reserve disclosure for explicitly foldable details and long lists.
- Long lists stay lazy with one scroll owner and a bounded glass viewport. Never trade virtualization for visual uniformity.
- Preserve existing business behavior, fail-closed navigation and script rules, WebView lifecycle, and data flows while changing presentation. Media Library and Media Tasks share the same folder/file browser primitives, and user-visible organization stays independent of native download and resumable-cache identities.
- The canonical token snapshot in [references/tokens.md](references/tokens.md) and the runtime values in `lib/ui/app_theme.dart` are one synchronization contract: when a token changes intentionally, update the runtime constant, the snapshot, and the focused UI tests in the same change. `tool/check_ui_tokens.py` enforces the link between them.

## Implementation workflow

1. Name the surface role and the topic, then open the matching reference above before editing.
2. Reuse or extend the shared primitive and token layer; compare any involved value against `lib/ui/app_theme.dart`.
3. Keep Material controls where they provide useful semantics and interaction; style them through the Site Lens theme or wrap them in a Site Lens surface.
4. Implement the change so the existing layout contracts still hold: row fitting, list laziness, chrome one-row invariants, and panel viewport strategy.
5. Verify light mode, dark mode, a non-default theme preset, narrow phone width, long Chinese text, empty state, and error state. For dialogs, also use the documented opacity values.
6. Run [references/review-checklist.md](references/review-checklist.md), then use `$site-lens-validation` for targeted UI tests and the smallest sufficient level. UI changes that affect WebView overlays, platform insets, gestures, or native callbacks require L2 or higher.

Do not introduce Cupertino as a replacement for the whole component system. Use it only when a platform-native interaction is explicitly required.
