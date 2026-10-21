# Site Lens UI system

## Material and liquid glass

The project has two complementary layers:

- Material supplies the application shell, navigation, semantics, focus, gestures, accessibility, dialogs, sheets, snack bars, lists, inputs, and control behavior.
- `liquid_glass_widgets` supplies the iOS 27-inspired surface: refraction, frost, tint, rim treatment, and the backdrop group.

A transparent `Material` inside `SiteLensGlassSurface` is intentional. It gives `ListTile`, `SwitchListTile`, and `InkWell` a valid ink and interaction context without painting a second surface.

## Surface roles

- `panel`: content panels, cards, ordinary sheets, and dialogs backed by the app gradient.
- `chrome`: top app chrome and the bottom navigation over the app gradient.
- `platformView`: browser toolbar, handle, and notices over the native WebView. This role uses a polarity-matched backer because the WebView content is not part of the captured app backdrop.

Use one glass boundary per semantic surface. Do not put a full `AdaptiveGlass` inside another glass boundary unless the nested surface is a deliberate control with a separate role.

## Hierarchy

1. Static gradient canvas.
2. Chrome: transparent or liquid-glass app bars and the narrow floating glass bottom navigation.
3. Content group: one `SiteLensGlassGroup` per screen.
4. Semantic panels: one panel per task or information group.
5. Controls: primary filled, secondary outlined, tertiary text, and status badges.

Material elevation stays at zero. Depth comes from glass, tint, contrast, and spacing.

## Tokens

Use `SiteLensMetrics`, `SiteLensColors`, `Theme.of(context).colorScheme`, and `Theme.of(context).textTheme` as the source of truth. Existing theme preset IDs and their persistence format are compatibility boundaries.

- Page padding: `SiteLensMetrics.pagePadding`.
- Panel radius and padding: `SiteLensMetrics.panelRadius` and `SiteLensMetrics.panelPadding`.
- Input/control radius: `SiteLensMetrics.inputRadius`.
- Bottom navigation: `SiteLensMetrics.navBarHeight`, `navRadius`, `navHorizontalInset`, and `navCapsuleInset`. Keep the rendered capsule radius at or below half its post-inset height; an oversized superellipse radius produces a visibly jagged anti-aliased edge.
- Browser toolbar: `toolbarHeight`, `toolbarIconSize`, `toolbarInset`, and `toolbarRadius`.

Use `SiteLensColors.of(context)` for backdrop, panel, navigation, divider, section-label, success, warning, and danger roles. The glass fill token must remain visually separated from the static backdrop in both appearances; current defaults are neutral light gray `#E7EAEE` in light mode and neutral charcoal `#25272B` in dark mode. Do not use a raw `Colors.*` value in a screen unless it is a platform or asset color with an explicit reason.

## Component rules

- Bottom navigation: custom `SiteLensBottomNavigation` inside the liquid-glass `SiteLensNavigationSurface`; one row, always-visible labels, selected icon/label capsule, no nested solid slab.
- Browser toolbar: fixed equal-width row using `SiteLensSurfaceRole.platformView`; no wrapping or per-button surfaces.
- Panels: `SiteLensPanel` or `SiteLensGlassSurface`, with content padding from tokens. Segmented tracks inside a light glass panel use the recessed well tint so the track and selected pill remain distinct from a white panel surface.
- Composite information panels: related sections such as detection results, backup addresses, and history may share one `SiteLensPanel`; separate sections use `Divider(height: 1)` and foldable `ExpansionTile` rows inside that single glass boundary. Use `SiteLensMetrics.itemGap` only between separate semantic panels, never between sections that have been intentionally merged.
- Foldable panels use the shared theme/primitive and remain shadow-free in every interaction state. Expansion must not add Material elevation, a drop shadow, an opaque slab, or a pressed shadow; use the existing glass tint, overlay and shape tokens for feedback.
- Rows: use shared action/status row primitives when several pages need the same icon-title-description-trailing layout.
- Feedback: use the shared notice/error surface for persistent page feedback; reserve snack bars for short-lived confirmation.
- Dialogs and sheets: keep Material semantics and actions, but use the themed opaque overlay or a liquid-glass wrapper. Do not restore default elevation or default opaque blue/grey surfaces.
- Empty states: use one icon, one title, optional explanation, and one action with shared spacing.

## Review checklist

- Does the surface use the correct role?
- Is there an unnecessary solid slab or nested glass boundary?
- Are all colors and dimensions sourced from the theme system?
- Does the primary action stand out without a shadow?
- Does the layout remain one row where the product contract requires it?
- Are long Chinese labels readable and safely truncated?
- Are focus, semantics, hit targets, and dismiss actions preserved?
- Does the same screen read correctly in light mode, dark mode, and a non-default seed preset?
- Do foldable panels remain shadow-free and visually stable before, during, and after expansion in light mode, dark mode, and a non-default seed preset?

## Compact choice menus

Use `SiteLensMenuSelector<T>` with typed `SiteLensMenuOption<T>` values for an inline choice that opens a menu on one activation. Supply a concise accessible label and exactly one option matching the current value. A null callback or no enabled options disables the trigger; individual options can also be disabled.

- Size the trigger and menu to the longest option in the active typography, locale, direction, and text scale, plus control padding and icon space. Let the trigger shrink within its parent instead of filling the row. Ellipsize its visual value when constrained, preserve the full semantic value, and wrap menu labels within the available viewport. Keep a minimum 48 dp hit height and allow rows to grow with text scale.
- Align inline selectors to the trailing edge of their setting row. Use `bodySmall` typography, a shared neutral glass-surface fill close to the surrounding background for both trigger and menu, adjoining edges with token radii, no decorative border, and zero elevation. Press and hover keep the same fill without splash or grey state transitions. Show a primary-color outline only for keyboard or other traditional focus; touch focus keeps the borderless appearance. Keep disabled colors.
- The trigger carries the current value and expanded semantics; list only alternative values in the menu. Measure every option, including the selected one, so changing selection keeps the width stable. Disable a selector without an enabled alternative.
- Preserve Material activation, arrow-key traversal, Escape/outside dismissal, and focus return. Cover one-tap opening, selection, stable width, keyboard focus, disabled states, narrow screens, large text, light/dark appearances, and a non-default preset in targeted widget tests.

## Lists

- Consecutive semantic rows inside a panel use `SiteLensMetrics.listGap` when they are separate surfaces or tiles. Do not rely on incidental `ListView` spacing or omit the gap on recommendation/result lists.
- A result row that contains a URL should use `SiteLensCopyableText` for the URL so long press copies the address without copying status labels or explanatory text.

## Glass surface opacity

- Label the setting `不透明度`; show only the numeric value, without explanatory notes. The value is absolute body alpha for Flutter liquid-glass surfaces: 100 is fully opaque and 0 is transparent fill. The default is `55`, and the slider exposes a clickable default marker that restores `55`. Do not multiply by the library preset alpha. Keep frost at the material baseline for values at or above the default 55; keep the selected body alpha linear so the slider remains predictable, and use the neutral fill tokens to preserve contrast at low values while blur, refraction and rim treatment remain active. Chrome surfaces must retain a visible AdaptiveGlass material floor at 0 so navigation controls remain legible. Content panels retain the exact selected alpha; their neutral fill tokens provide contrast even near the low end. The backdrop itself stays opaque and controls over a native WebView retain their polarity-matched contrast backer.

- Show `高质量覆盖全部面板` in `自动` and `高质量` modes. When enabled, Flutter content panels, dialogs, sheets, and glass cards follow the selected quality: adaptive standard/premium in automatic mode, premium in high mode. Standard mode keeps standard quality and retains the saved coverage preference. Keep the route-wide Android WebView composition fence when the current engine does not confirm HCPP. With effective HCPP, restore Flutter-owned standard/premium surfaces; direct native WebView overlays keep the platform-view backer/fill because HCPP does not expose native pixels to Flutter shaders.

## Settings diagnostics and theme presets

- Keep simple setting labels and subtitles concise; do not expose implementation notes, raw platform names, internal reasons, or duplicated detail blocks in the user-facing settings page. Use one concise action row for device diagnostics. Its dedicated read-only detail page may show support/configuration/effective/observed facts, source, timestamps and platform policy in shared foldable surfaces; never trigger active probes merely to populate that page.
- Theme preset swatches must be perceptually distinct at a glance in both light and dark modes. Choose seeds with separated hue/value families instead of relying on names that differ while colors remain near each other.

- Global backdrop gradients are opaque static colors, never glass or affected by opacity settings. Validate modal dialogs at opacity 1, 45 and 100 in both appearances. Keep stored preset IDs stable when revising colors; verify generated primary colors as well as raw seed swatches.
