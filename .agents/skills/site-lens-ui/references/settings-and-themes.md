# Settings, backdrops, and themes

Read this when changing settings structure, the backdrop source model, the glass opacity setting, the diagnostics page, or theme presets.

## Settings structure

- Group ordinary settings by category in one always-visible semantic panel, with the category label outside the panel. Category panels are separated by section labels; they do not fold. Use internal dividers only between distinct rows. Do not add a route only to hold two or three simple controls.
- Keep complex workflows such as backups, gestures, media management, filtering, and scripts on direct second-level pages. Use inline disclosure only for secondary explanation or a long list row that benefits from one-open details.
- Use one accordion controller per detail list or secondary page so opening a detail closes the previous detail in that list. A settings category itself remains visible.
- Secondary pages always show their title in the shared page shell; follow [components.md](components.md) for the panel and viewport strategy.
- About and update are separate direct entries; do not add a combined intermediate page.
- Simple setting labels and subtitles stay concise; do not expose implementation notes, raw platform names, internal reasons, or duplicated detail blocks in the user-facing settings page.

## Backdrop source semantics

- `defaultGradient` uses the current low-saturation default gradient.
- `themeBuiltIn` derives a visibly different gradient from the selected theme seed.
- `customImage` uses the validated uploaded image with `cover` and the light/dark protection tint.
- `transparent` is the legacy wire id for the `纯色背景` mode. It does not reuse the uploaded image, the theme gradient, or the default gradient; dark appearance paints an opaque black backdrop and light appearance uses the neutral solid backdrop.
- `SiteLensBackdropScope` is the source of truth for backdrop painting. Shared menus and top-bar actions keep the panel glass color stable across all four modes while the backdrop remains available to the glass renderer.
- Global backdrop gradients are opaque static colors, never glass and never affected by the opacity setting. Keep stored preset IDs stable when revising colors; verify generated primary colors as well as raw seed swatches.

## Glass surface opacity

- Label the setting `不透明度`; show only the numeric value, without explanatory notes. The value is absolute body alpha for Flutter liquid-glass surfaces: 100 is fully opaque and 0 is transparent fill. The default is `55`, and the slider exposes a clickable default marker that restores `55`. Do not multiply by the library preset alpha.
- Keep frost at the material baseline for values at or above the default 55; keep the selected body alpha linear so the slider remains predictable, and use the neutral fill tokens to preserve contrast at low values while blur, refraction and rim treatment remain active.
- Chrome surfaces must retain a visible AdaptiveGlass material floor at 0 so navigation controls remain legible. Content panels retain the exact selected alpha; their neutral fill tokens provide contrast even near the low end. The backdrop itself stays opaque and controls over a native WebView retain their polarity-matched contrast backer.
- Show `高质量覆盖全部面板` in `自动` and `高质量` modes. When enabled, Flutter content panels, dialogs, sheets, and glass cards follow the selected quality: adaptive standard/premium in automatic mode, premium in high mode. Standard mode keeps standard quality and retains the saved coverage preference.
- Keep the route-wide Android WebView composition fence when the current engine does not confirm HCPP. With effective HCPP, restore Flutter-owned standard/premium surfaces; direct native WebView overlays keep the platform-view backer/fill because HCPP does not expose native pixels to Flutter shaders.
- Renderer evidence has two layers: `quality`, `fallback`, HCPP state, and the renderer policy describe the selected app policy; they do not prove the Flutter engine backend or alpha15 pixel equivalence. Claim actual refraction, rim treatment, edge consistency, no startup flash, or visual equivalence only from a current screenshot/compositor capture on the target device. Keep `siteLensForceSkia=true` as an explicit compatibility build option rather than turning WebView capability limits into a global design rule.
- Validate modal dialogs at opacity 1, 45 and 100 in both appearances.

## Diagnostics and theme presets

- Keep the device diagnostics entry to one concise action row. Its dedicated read-only detail page may show support/configuration/effective/observed facts, source, timestamps and platform policy in shared foldable surfaces; never trigger active probes merely to populate that page.
- Theme presets are a useful row disclosure: collapsed by default, with six circular candidates per row when opened. Do not turn the whole appearance category into a foldable panel.
- Theme preset swatches must be perceptually distinct at a glance in both light and dark modes. Choose seeds with separated hue/value families instead of relying on names that differ while colors remain near each other.
