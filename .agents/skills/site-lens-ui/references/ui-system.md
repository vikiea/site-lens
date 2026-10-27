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

### Canonical token snapshot

`lib/ui/app_theme.dart` is the runtime source and this table is the agent-facing synchronization contract. If a value changes intentionally, update the runtime constant, this table, and the focused UI tests together. These values describe the current alpha6/`0.5.0` design; do not revive values from earlier alpha versions.

| Token group | Current values |
| --- | --- |
| Page and panel | `pagePadding=16`, `itemGap=10`, `listGap=14`, `formGap=12`, `sectionGap=24`, `panelRadius=22`, `panelPadding=18`, `inputRadius=14` |
| Compact rows | `compactRowHorizontalPadding=12`, `compactRowVerticalPadding=0`, `compactRowMinHeight=64`, `compactIconSize=18`, `compactIconButtonSize=36`, `compactSwitchScale=0.84` |
| Row interaction | `rowInteractionOverlay=transparent`; ordinary row press/hover/focus feedback stays visually quiet, while selected state uses `selectedTileColor` |
| Row fitting | `rowTextMaxCharacters=20`, `rowTextMinScale=0.88`, `rowDescriptionFoldThreshold=20`; short copy uses `SiteLensRowText`, long descriptions use `SiteLensExpandableRow`/`SiteLensDisclosure` |
| Details and diagnostics | `compactDividerIndent=12`, `accordionContentIndent=42`, `settingsDividerIndent=18`, `diagnosticLabelWidth=64`, `detailLabelWidth=64`, `detailColumnGap=10`, `detailContentIndent=26`, `diagnosticRowGap=4`, `diagnosticDetailMaxHeightFraction=0.42` |
| Settings and media | `settingsSectionLabelHorizontalPadding=6`, `settingsSectionLabelBottom=8`, `mediaThumbnailSize=68x48` (the image keeps its source aspect ratio inside the slot) |
| Navigation | `navBarHeight=72`, `navIconSize=20`, `navLabelSize=12`, `navRadius=30`, `navHorizontalInset=28`, `navCapsuleInset=6` |
| Segmented controls | `segmentedHeight=40`, `segmentedInset=2` |
| Browser chrome | `toolbarHeight=48`, `toolbarIconSize=18`, `toolbarInset=12`, `toolbarRadius=26` |
| Browser dock | `browserDockWidth=toolbarHeight/3=16`, `browserDockIconSize=16`; the six-dot mark stays inside the 16 dp strip, outer edge straight and inward edge rounded |
| Top-bar actions | `topBarActionGroupRadius=28`, `topBarActionGroupRightInset=8`, `topBarActionGroupVerticalInset=5`, `topBarActionInset=1`, `topBarActionMinSize=44` |
| Glass controls | `controlFillAlpha=0.62`, `themeBuiltInControlFillAlpha=0.56`, `customImageControlFillAlpha=0.70`, `transparentControlFillAlpha=0.78`, `controlThemeTintAlpha=0.16`, `themeBuiltInControlTintAlpha=0.24`, `customImageControlTintAlpha=0.18`, `transparentControlTintAlpha=0.14`, `controlInteractionAlpha=0.14` |
| Opacity layout | default `55`, value format `n / 100`, `opacityLabelGap=6`, `opacitySliderGap=8`; the slider is trailing-aligned |
| Typography | page `20/w600`, section `16/w600`, row `15/w500`, body `14/w400`, description `12.5/w400`, caption `12/w400`, line height `1.35` |

Theme preset IDs are compatibility data: `oceanBlue`, `mistPine`, `irisViolet`, `roseGray`, `sandstoneCopper`, `graphiteBlue`, `auroraCyan`, `sunsetCoral`, `lavenderInk`, `mintGlass`, `amberGlow`, and `midnightIndigo`. Their seed map remains in `ThemePresetId.seed`; changing a seed is a visual migration and must preserve the stored IDs.

- Page padding: `SiteLensMetrics.pagePadding`.
- Panel radius and padding: `SiteLensMetrics.panelRadius` and `SiteLensMetrics.panelPadding`.
- Input/control radius: `SiteLensMetrics.inputRadius`.
- Compact rows: `compactRowHorizontalPadding`, `compactRowVerticalPadding`, `compactRowMinHeight`, `compactIconSize`, and `compactIconButtonSize`.
- Compact controls: `compactSwitchScale`, `SiteLensCompactSwitch`, `SiteLensSwitchRow`, and `SiteLensCompactIconButton`; keep the row as the accessible activation target while reserving width for the label. Switch touch feedback stays transparent so only the thumb/track animation communicates the change.
- Row typography: `SiteLensTypography.pageTitle`, `sectionTitle`, `rowTitle`, `body`, `description`, and `caption` define the global hierarchy. `SiteLensMetrics.rowTextMaxCharacters` is `20`, `rowTextMinScale` is `0.88`, and `rowDescriptionFoldThreshold` is `20`; use `SiteLensRowText` for short title/description widgets, then use `SiteLensExpandableRow` or `SiteLensDisclosure` for longer descriptions so the full copy lives in a foldable detail.
- Settings groups: `settingsDividerIndent`, `settingsSectionLabelHorizontalPadding`, and `settingsSectionLabelBottom`; use these for the category label and internal row dividers.
- Diagnostic summaries: `diagnosticLabelWidth` and `diagnosticRowGap`; use these to keep environment facts aligned across platforms and text lengths.
- Diagnostic detail: keep short capability pages content-sized, but bound unusually long expanded detail text to `diagnosticDetailMaxHeightFraction` so the fixed panel cannot overflow a small viewport.
- Theme swatches: use `themeSwatchColumns` (`6`), `themeSwatchSize`, and `themeSwatchGap` for the alpha6 circular palette rhythm. The palette disclosure starts collapsed and opens inside the appearance panel.
- Foldable details: `compactDividerIndent` and `accordionContentIndent`; use the shared accordion controller for one-open detail behavior.
- Detail facts: `detailLabelWidth`, `detailColumnGap`, and `detailContentIndent` keep expanded rule-source and capability facts aligned instead of using nested ad hoc indents.
- Bottom navigation: `SiteLensMetrics.navBarHeight`, `navRadius`, `navHorizontalInset`, and `navCapsuleInset`. Keep the rendered capsule radius at or below half its post-inset height; an oversized superellipse radius produces a visibly jagged anti-aliased edge.
- Browser toolbar: `toolbarHeight`, `toolbarIconSize`, `toolbarInset`, and `toolbarRadius`.
- Global browser dock: `browserDockWidth` is one third of `toolbarHeight`, with `browserDockIconSize` for the six-dot drag mark. The collapsed strip is flush with the selected screen edge; its outer edge is straight and inward edge rounded. Keep a `toolbarHeight`-wide gesture target. Dragging snaps to the left or right edge and saves the vertical position. Tapping opens the current-tab row; tapping its title returns to that tab.
- In-page browser handle: tapping the translucent arrow handle opens one primary toolbar row by default. The `expandAllBrowserControls` preference opts into opening the secondary action row at the same time; dragging keeps the handle position independent from the toolbar's expanded state.
- Opacity setting: show the selected value as `n / 100`, and align the slider to the trailing edge after a fixed label-to-control gap.
- Long media paths: keep the compact row title and subtitle to one line each. Tapping opens a detail area with the complete selectable path or explanation; do not put an ellipsized path in the only readable location, and do not let the collapsed row height change.

Use `SiteLensColors.of(context)` for backdrop, panel, navigation, divider, section-label, success, warning, danger and small-control roles. The glass fill token must remain visually separated from the static backdrop in both appearances; current defaults are neutral light gray `#E7EAEE` in light mode and neutral charcoal `#25272B` in dark mode. Use `SiteLensColors.controlSurface(SiteLensBackdropScope.modeOf(context))` for shared menus and top-bar actions so their fill and interaction tint follow the active backdrop source. Do not use a raw `Colors.*` value in a screen unless it is a platform or asset color with an explicit reason.

### Backdrop source semantics

- `defaultGradient` uses the current low-saturation default gradient.
- `themeBuiltIn` derives a visibly different gradient from the selected theme seed.
- `customImage` uses the validated uploaded image with `cover` and the light/dark protection tint.
- `transparent` does not reuse the uploaded image, the theme gradient, or the default gradient. In dark appearance it leaves the app-owned backdrop unpainted; in light appearance it uses the neutral solid backdrop.
- `SiteLensBackdropScope` is the source of truth for shared controls. Menus and top-bar actions can adjust local glass opacity and tint for readability while keeping one surface language across all four modes.

Full-screen video playback and its native-style transport controls are an explicit exception to the app-surface color rule: black video backdrops, white playback glyphs, and transparent control overlays may use raw colors so controls remain legible over arbitrary video frames. Keep those colors inside the playback surface; app panels, settings, notices, dialogs, and browser chrome still use `SiteLensColors` and theme text roles.

## Component rules

- Bottom navigation: custom `SiteLensBottomNavigation` inside the liquid-glass `SiteLensNavigationSurface`; one row, always-visible labels, selected icon/label capsule, no nested solid slab.
- Browser toolbar: fixed equal-width row using `SiteLensSurfaceRole.platformView`; no wrapping or per-button surfaces.
- Panels: `SiteLensPanel` or `SiteLensGlassSurface`, with content padding from tokens. Segmented tracks inside a light glass panel use the recessed well tint so the track and selected pill remain distinct from a white panel surface.
- Composite information panels: related sections such as detection results, backup addresses, and history may share one `SiteLensPanel`; separate sections use `Divider(height: 1)` and foldable `ExpansionTile` rows inside that single glass boundary. Use `SiteLensMetrics.itemGap` only between separate semantic panels, never between sections that have been intentionally merged.
- Settings: ordinary controls use one always-visible glass panel per category, with the category label outside the panel. Keep related controls together and use internal dividers only between distinct rows. Place complex workflows behind direct second-level rows. About and update are separate direct entries; do not add a combined intermediate page.
- Foldable panels use the shared theme/primitive and remain shadow-free in every interaction state. Expansion must not add Material elevation, a drop shadow, an opaque slab, or a pressed shadow; use the existing glass tint, overlay and shape tokens for feedback.
- Rows: use shared compact action/status row primitives when several pages need the same icon-title-description-trailing layout. Keep the primary label to one line where possible and move secondary actions into a compact overflow menu.
- Row copy: keep the title and short summary within the compact row. A description over `rowDescriptionFoldThreshold` belongs in a foldable detail and must remain fully readable there; do not use truncation plus ellipsis as the only presentation.
- Row rhythm: entry rows and switch rows share the same minimum height. Use one low-contrast inset divider between adjacent semantic rows; do not divide a single setting into label, choice and status fragments.
- Long lists: preserve a single lazy `CustomScrollView` or `SliverList` owner. A shared glass viewport is preferred when it remains bounded and does not force the list into a `Column`; otherwise keep the list page-level and remove only the per-item glass boundaries. Never trade virtualization for a visually uniform panel.
- File-style media lists: use one bounded panel and internal dividers. Folder rows and media rows share selection and overflow behavior across Media Library and Media Tasks. Empty text describes the current scope only; a root that contains folders must not claim that the root has no files.
- Short secondary pages: keep one fixed panel when the content is ten rows or fewer. When a list exceeds ten rows, use one bounded lazy viewport and one glass boundary. Details may expand inline through one accordion controller, with the first row opened only when that page benefits from an immediate read.
- Disabled rows: mute the icon, title, subtitle, and secondary controls through the disabled content token while retaining readable status and accessible toggles.
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
- Are ordinary settings categories always visible, with folding reserved for useful row details and long-list disclosure?
- Does every long list stay lazy with one scroll owner and a bounded glass render area?

## Compact choice menus

Use `SiteLensMenuSelector<T>` with typed `SiteLensMenuOption<T>` values for an inline choice that opens a menu on one activation. Supply a concise accessible label and exactly one option matching the current value. A null callback or no enabled options disables the trigger; individual options can also be disabled.

- Size the trigger and menu to the longest option in the active typography, locale, direction, and text scale, plus control padding and icon space. Let the trigger shrink within its parent instead of filling the row. Ellipsize its visual value when constrained, preserve the full semantic value, and wrap menu labels within the available viewport. Keep a minimum 48 dp hit height and allow rows to grow with text scale.
- Align inline selectors to the trailing edge of their setting row. Use `bodySmall` typography and the shared background-aware control surface from `SiteLensColors.controlSurface(SiteLensBackdropScope.modeOf(context))` for both trigger and menu. Keep adjoining edges with token radii, a subtle token border, zero elevation and no shadow. Press and hover use the token interaction tint without a grey Material slab. Show a primary-color outline only for keyboard or other traditional focus. Keep disabled colors.
- The trigger carries the current value and expanded semantics; list only alternative values in the menu. Measure every option, including the selected one, so changing selection keeps the width stable. Disable a selector without an enabled alternative.
- Preserve Material activation, arrow-key traversal, Escape/outside dismissal, and focus return. Cover one-tap opening, selection, stable width, keyboard focus, disabled states, narrow screens, large text, light/dark appearances, and a non-default preset in targeted widget tests.

## Lists

- Consecutive semantic rows inside a panel use `SiteLensMetrics.listGap` when they are separate surfaces or tiles. Do not rely on incidental `ListView` spacing or omit the gap on recommendation/result lists.
- A result row that contains a URL should use `SiteLensCopyableText` for the URL so long press copies the address without copying status labels or explanatory text.
- A list of related records uses one panel boundary and internal dividers only when its row count and viewport strategy remain efficient. Keep row actions compact and expandable details lazy; the panel count is secondary to scroll performance.

## Glass surface opacity

- Label the setting `不透明度`; show only the numeric value, without explanatory notes. The value is absolute body alpha for Flutter liquid-glass surfaces: 100 is fully opaque and 0 is transparent fill. The default is `55`, and the slider exposes a clickable default marker that restores `55`. Do not multiply by the library preset alpha. Keep frost at the material baseline for values at or above the default 55; keep the selected body alpha linear so the slider remains predictable, and use the neutral fill tokens to preserve contrast at low values while blur, refraction and rim treatment remain active. Chrome surfaces must retain a visible AdaptiveGlass material floor at 0 so navigation controls remain legible. Content panels retain the exact selected alpha; their neutral fill tokens provide contrast even near the low end. The backdrop itself stays opaque and controls over a native WebView retain their polarity-matched contrast backer.

- Show `高质量覆盖全部面板` in `自动` and `高质量` modes. When enabled, Flutter content panels, dialogs, sheets, and glass cards follow the selected quality: adaptive standard/premium in automatic mode, premium in high mode. Standard mode keeps standard quality and retains the saved coverage preference. Keep the route-wide Android WebView composition fence when the current engine does not confirm HCPP. With effective HCPP, restore Flutter-owned standard/premium surfaces; direct native WebView overlays keep the platform-view backer/fill because HCPP does not expose native pixels to Flutter shaders.
- Renderer evidence has two layers: `quality`, `fallback`, HCPP state, and the renderer policy describe the selected app policy; they do not prove the Flutter engine backend or alpha15 pixel equivalence. Claim actual refraction, rim treatment, edge consistency, no startup flash, or visual equivalence only from a current screenshot/compositor capture on the target device. Keep `siteLensForceSkia=true` as an explicit compatibility build option rather than turning WebView capability limits into a global design rule.

## Settings diagnostics and theme presets

- Keep simple setting labels and subtitles concise; do not expose implementation notes, raw platform names, internal reasons, or duplicated detail blocks in the user-facing settings page. Use one concise action row for device diagnostics. Its dedicated read-only detail page may show support/configuration/effective/observed facts, source, timestamps and platform policy in shared foldable surfaces; never trigger active probes merely to populate that page.
- Theme preset swatches must be perceptually distinct at a glance in both light and dark modes. Choose seeds with separated hue/value families instead of relying on names that differ while colors remain near each other.

- Global backdrop gradients are opaque static colors, never glass or affected by opacity settings. Transparent mode ignores an uploaded image; in dark mode it paints no app-owned backdrop, while light mode uses the theme's neutral solid backdrop. Validate modal dialogs at opacity 1, 45 and 100 in both appearances. Keep stored preset IDs stable when revising colors; verify generated primary colors as well as raw seed swatches.
