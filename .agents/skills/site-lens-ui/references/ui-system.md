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
- Bottom navigation: `SiteLensMetrics.navBarHeight`, `navRadius`, `navHorizontalInset`, and `navCapsuleInset`.
- Browser toolbar: `toolbarHeight`, `toolbarIconSize`, `toolbarInset`, and `toolbarRadius`.

Use `SiteLensColors.of(context)` for backdrop, panel, navigation, divider, section-label, success, warning, and danger roles. Do not use a raw `Colors.*` value in a screen unless it is a platform or asset color with an explicit reason.

## Component rules

- Bottom navigation: custom `SiteLensBottomNavigation` inside the liquid-glass `SiteLensNavigationSurface`; one row, always-visible labels, selected icon/label capsule, no nested solid slab.
- Browser toolbar: fixed equal-width row using `SiteLensSurfaceRole.platformView`; no wrapping or per-button surfaces.
- Panels: `SiteLensPanel` or `SiteLensGlassSurface`, with content padding from tokens.
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
