# Components, rows, lists, and menus

Read this when changing app chrome, bottom navigation, panels, rows, lists, choice menus, dialogs, feedback, or empty states.

## Component rules

- Bottom navigation: custom `SiteLensBottomNavigation` inside the liquid-glass `SiteLensNavigationSurface`; one row, always-visible labels, selected icon/label capsule, no nested solid slab.
- Browser toolbar: fixed equal-width row using `SiteLensSurfaceRole.platformView`; no wrapping or per-button surfaces.
- Panels: `SiteLensPanel` or `SiteLensGlassSurface`, with content padding from tokens. Segmented tracks inside a light glass panel use the recessed well tint so the track and selected pill remain distinct from a white panel surface.
- Composite information panels: related sections such as detection results, backup addresses, and history may share one `SiteLensPanel`; separate sections use `Divider(height: 1)` and foldable `ExpansionTile` rows inside that single glass boundary. Use `SiteLensMetrics.itemGap` only between separate semantic panels, never between sections that have been intentionally merged.
- Foldable panels use the shared foldable-panel primitive/theme and remain shadow-free in every interaction state. Expansion must not add Material elevation, a drop shadow, an opaque slab, or a pressed shadow; use the existing glass tint, overlay and shape tokens for feedback.
- Rows: use shared compact action/status row primitives when several pages need the same icon-title-description-trailing layout. Keep the primary label to one line where possible and move secondary actions into a compact overflow menu.
- Row copy: keep the title in one line and let the complete description remain in the row through horizontal dragging and accessibility semantics. Do not truncate descriptions or fold them automatically by character count.
- Row rhythm: entry rows and switch rows share the same minimum height. Use one low-contrast inset divider between adjacent semantic rows; do not divide a single setting into label, choice and status fragments.
- Long lists: preserve a single lazy `CustomScrollView` or `SliverList` owner. A shared glass viewport is preferred when it remains bounded and does not force the list into a `Column`; otherwise keep the list page-level and remove only the per-item glass boundaries. Never trade virtualization for a visually uniform panel.
- File-style media lists: use one bounded panel and internal dividers. Folder rows and media rows share selection and overflow behavior across Media Library and Media Tasks. Empty text describes the current scope only; a root that contains folders must not claim that the root has no files.
- Short secondary pages: keep one fixed panel when the content is ten rows or fewer. When a list exceeds ten rows, use one bounded lazy viewport and one glass boundary. Details may expand inline through one accordion controller, with the first row opened only when that page benefits from an immediate read.
- Disabled rows: mute the icon, title, subtitle, and secondary controls through the disabled content token while retaining readable status and accessible toggles.
- Feedback: use the shared notice/error surface for persistent page feedback; reserve snack bars for short-lived confirmation.
- Dialogs and sheets: keep Material semantics and actions, but use the themed opaque overlay or a liquid-glass wrapper. Do not restore default elevation or default opaque blue/grey surfaces.
- Glass menus overlap page panels and must opt out of the page's shared backdrop group with `GlassBackdropGroup(enabled: false)`; otherwise the shared capture can erase the glass underneath and produce black bands on Impeller.
- Solid-backdrop Flutter surfaces keep premium refraction, blur, frost, and rim lighting while sampling the app-owned backdrop.
- Empty states: use one icon, one title, optional explanation, and one action with shared spacing.

## Compact choice menus

Use `SiteLensMenuSelector<T>` with typed `SiteLensMenuOption<T>` values for an inline choice that opens a menu on one activation. Supply a concise accessible label and exactly one option matching the current value. A null callback or no enabled options disables the trigger; individual options can also be disabled.

- Size the trigger and menu to the longest option in the active typography, locale, direction, and text scale, plus control padding and icon space. Let the trigger shrink within its parent instead of filling the row. Ellipsize its visual value when constrained, preserve the full semantic value, and wrap menu labels within the available viewport. Keep a minimum 48 dp hit height and allow rows to grow with text scale.
- Align inline selectors to the trailing edge of their setting row. Use `bodySmall` typography and the active glass render plan's `glassColor` for the trigger and menu base fill; obtain interaction feedback from `SiteLensColors.controlSurface(SiteLensBackdropScope.modeOf(context))`. Keep adjoining edges with token radii, a subtle token border, zero elevation and no shadow. Press and hover use the token interaction tint without a grey Material slab. Show a primary-color outline only for keyboard or other traditional focus. Keep disabled colors.
- The trigger carries the current value and expanded semantics; list only alternative values in the menu. Measure every option, including the selected one, so changing selection keeps the width stable. Disable a selector without an enabled alternative.
- Preserve Material activation, arrow-key traversal, Escape/outside dismissal, and focus return. Cover one-tap opening, selection, stable width, keyboard focus, disabled states, narrow screens, large text, light/dark appearances, and a non-default preset in targeted widget tests.

## Lists

- Consecutive semantic rows inside a panel use `SiteLensMetrics.listGap` when they are separate surfaces or tiles. Do not rely on incidental `ListView` spacing or omit the gap on recommendation/result lists.
- A result row that contains a URL should use `SiteLensCopyableText` for the URL so long press copies the address without copying status labels or explanatory text.
- A list of related records uses one panel boundary and internal dividers only when its row count and viewport strategy remain efficient. Keep row actions compact and expandable details lazy; the panel count is secondary to scroll performance.
