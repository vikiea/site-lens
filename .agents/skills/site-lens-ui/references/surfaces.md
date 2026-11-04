# Surfaces, roles, and hierarchy

Read this when changing the glass surface system, adding a panel, sheet, dialog, or chrome surface, or judging where visual depth comes from.

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

Material elevation stays at zero. Depth comes from glass, tint, contrast, and spacing. Keep the app backdrop static, low saturation, and theme tinted.
