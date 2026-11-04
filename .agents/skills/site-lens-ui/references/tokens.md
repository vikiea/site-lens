# Tokens and the canonical snapshot

Read this when changing a token value, typography role, color role, chrome or navigation metric, or the runtime theme, or when you need the current design values.

Use `SiteLensMetrics`, `SiteLensColors`, `Theme.of(context).colorScheme`, and `Theme.of(context).textTheme` as the source of truth. Existing theme preset IDs and their persistence format are compatibility boundaries.

`lib/ui/app_theme.dart` is the runtime source and this table is the agent-facing synchronization contract. If a value changes intentionally, update the runtime constant, this table, and the focused UI tests together. `tool/check_ui_tokens.py` fails when the critical values diverge from the runtime, and it fails when a value is restated outside this document. These values describe the current alpha6/`0.5.0` design; do not revive values from earlier alpha versions.

## Canonical token snapshot

| Token group | Current values |
| --- | --- |
| Page and panel | `pagePadding=16`, `itemGap=10`, `listGap=14`, `formGap=12`, `sectionGap=24`, `panelRadius=22`, `panelPadding=18`, `inputRadius=14` |
| Menus | `menuRadius=16`, `menuItemMinHeight=48`, `menuHorizontalPadding=12`, `menuItemGap=10`, `menuIconSize=18`; glass operation menus use one shadow-free menu surface and wrap labels within the viewport |
| Compact rows | `compactRowHorizontalPadding=12`, `compactRowVerticalPadding=0`, `compactRowMinHeight=64`, `compactIconSize=18`, `compactIconButtonSize=36`, `compactSwitchScale=0.84` |
| Row interaction | `rowInteractionOverlay=transparent`; ordinary row press/hover/focus feedback stays visually quiet, while selected state uses `selectedTileColor` |
| Row fitting | `rowTextMaxCharacters=20`, `rowTextMinScale=0.88`; titles use `SiteLensRowText`, descriptions use a complete horizontally scrollable row viewport |
| Details and diagnostics | `compactDividerIndent=12`, `accordionContentIndent=42`, `settingsDividerIndent=18`, `diagnosticLabelWidth=64`, `detailLabelWidth=64`, `detailColumnGap=10`, `detailContentIndent=26`, `diagnosticRowGap=4`, `diagnosticDetailMaxHeightFraction=0.42` |
| Settings and media | `settingsSectionLabelHorizontalPadding=6`, `settingsSectionLabelBottom=8`, `mediaThumbnailSize=68x48` (the image keeps its source aspect ratio inside the slot) |
| Navigation | `navBarHeight=72`, `navIconSize=20`, `navLabelSize=12`, `navRadius=30`, `navHorizontalInset=28`, `navCapsuleInset=6` |
| Segmented controls | `segmentedHeight=40`, `segmentedInset=2` |
| Browser chrome | `toolbarHeight=48`, `toolbarIconSize=18`, `toolbarInset=12`, `toolbarRadius=26` |
| Browser dock | `browserDockWidth=toolbarHeight/3=16`, `browserDockIconSize=16`; the six-dot mark stays inside the 16 dp strip, outer edge straight and inward edge rounded |
| Top-bar actions | `topBarActionGroupRadius=28`, `topBarActionGroupRightInset=8`, `topBarActionGroupVerticalInset=5`, `topBarActionMinSize=44`; the app bar is transparent, all actions share one continuous chrome glass surface, and the group has no local fill or theme tint |
| Glass controls | `controlFillAlpha=0.62`, `themeBuiltInControlFillAlpha=0.56`, `customImageControlFillAlpha=0.70`, `transparentControlFillAlpha=0.78`, `controlThemeTintAlpha=0.16`, `themeBuiltInControlTintAlpha=0.24`, `customImageControlTintAlpha=0.18`, `transparentControlTintAlpha=0.14`, `controlInteractionAlpha=0.14`, `menuBackdropProtectionAlpha=0.78` |
| Opacity layout | default `55`, value format `n / 100`, `opacityLabelGap=6`, `opacitySliderGap=8`; the slider is trailing-aligned |
| Typography | page `20/w600`, section `16/w600`, row `15/w500`, body `14/w400`, description `12.5/w400`, caption `12/w400`, line height `1.35` |

Theme preset IDs are compatibility data: `oceanBlue`, `mistPine`, `irisViolet`, `roseGray`, `sandstoneCopper`, `graphiteBlue`, `auroraCyan`, `sunsetCoral`, `lavenderInk`, `mintGlass`, `amberGlow`, and `midnightIndigo`. Their seed map remains in `ThemePresetId.seed`; changing a seed is a visual migration and must preserve the stored IDs.

## Token usage

- Page and panel: `SiteLensMetrics.pagePadding`, `SiteLensMetrics.panelRadius`, `SiteLensMetrics.panelPadding`, and `SiteLensMetrics.inputRadius`. Use `SiteLensMetrics.itemGap` only between separate semantic panels.
- Operation menus: `menuRadius`, `menuItemMinHeight`, `menuHorizontalPadding`, `menuItemGap`, and `menuIconSize`; use `SiteLensGlassMenuButton` for compact action menus and keep labels readable when the viewport is narrow.
- Compact rows: `compactRowHorizontalPadding`, `compactRowVerticalPadding`, `compactRowMinHeight`, `compactIconSize`, and `compactIconButtonSize` set the shared baseline for ordinary rows.
- Compact controls: `compactSwitchScale`, `SiteLensCompactSwitch`, `SiteLensSwitchRow`, and `SiteLensCompactIconButton`; keep the row as the accessible activation target while reserving width for the label. Switch touch feedback stays transparent so only the thumb/track animation communicates the change.
- Row typography: `SiteLensTypography.pageTitle`, `sectionTitle`, `rowTitle`, `body`, `description`, and `caption` define the global hierarchy. Use `SiteLensRowText` for titles and `SiteLensScrollableRowText` for complete descriptions; use `SiteLensExpandableRow` or `SiteLensDisclosure` only when the product explicitly requires a foldable detail.
- Settings groups: `settingsDividerIndent`, `settingsSectionLabelHorizontalPadding`, and `settingsSectionLabelBottom`; use these for the category label and internal row dividers.
- Diagnostic summaries: `diagnosticLabelWidth` and `diagnosticRowGap`; use these to keep environment facts aligned across platforms and text lengths.
- Diagnostic detail: keep short capability pages content-sized, but bound unusually long expanded detail text to `diagnosticDetailMaxHeightFraction` so the fixed panel cannot overflow a small viewport.
- Theme swatches: use `themeSwatchColumns` (six), `themeSwatchSize`, and `themeSwatchGap` for the alpha6 circular palette rhythm. The palette disclosure starts collapsed and opens inside the appearance panel.
- Foldable details: `compactDividerIndent` and `accordionContentIndent`; use the shared accordion controller for one-open detail behavior.
- Detail facts: `detailLabelWidth`, `detailColumnGap`, and `detailContentIndent` keep expanded rule-source and capability facts aligned instead of using nested ad hoc indents.
- Bottom navigation: `SiteLensMetrics.navBarHeight`, `navRadius`, `navHorizontalInset`, and `navCapsuleInset`. Keep the rendered capsule radius at or below half its post-inset height; an oversized superellipse radius produces a visibly jagged anti-aliased edge.
- Browser toolbar: `toolbarHeight`, `toolbarIconSize`, `toolbarInset`, and `toolbarRadius`.
- Global browser dock: `browserDockWidth` is one third of `toolbarHeight`, with `browserDockIconSize` for the six-dot drag mark. The collapsed strip is flush with the selected screen edge; its outer edge is straight and inward edge rounded. Keep a `toolbarHeight`-wide gesture target. Dragging snaps to the left or right edge and saves the vertical position. Tapping opens the current-tab row; tapping its title returns to that tab.
- In-page browser handle: tapping the translucent arrow handle opens one primary toolbar row by default. The `expandAllBrowserControls` preference opts into opening the secondary action row at the same time; dragging keeps the handle position independent from the toolbar's expanded state.
- Opacity setting: show the selected value as `n / 100`, and align the slider to the trailing edge after a fixed label-to-control gap.
- Long media paths: keep the compact row title and subtitle to one line each. Tapping opens a detail area with the complete selectable path or explanation; do not put an ellipsized path in the only readable location, and do not let the collapsed row height change.

## Color roles

Use `SiteLensColors.of(context)` for backdrop, panel, navigation, divider, section-label, success, warning, danger and small-control roles. The glass fill token must remain visually separated from the static backdrop in both appearances; current defaults are neutral light gray `#E7EAEE` in light mode and neutral charcoal `#25272B` in dark mode. Shared menus and top-bar action groups use the active glass render plan's `glassColor` for their base fill, so they match glass panels regardless of backdrop mode or glass quality; use `SiteLensColors.controlSurface(...).interaction` or the theme accent only for pressed, hover and focus feedback. Do not use a raw `Colors.*` value in a screen unless it is a platform or asset color with an explicit reason.

Full-screen video playback and its native-style transport controls are an explicit exception to the app-surface color rule: black video backdrops, white playback glyphs, and transparent control overlays may use raw colors so controls remain legible over arbitrary video frames. Keep those colors inside the playback surface; app panels, settings, notices, dialogs, and browser chrome still use `SiteLensColors` and theme text roles.
