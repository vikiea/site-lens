# UI review checklist

Read this when a UI change is ready to report, before running validation.

## Checklist

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

## Rendering-cost verification

For long or dynamic lists, verify lazy construction, one scroll owner, bounded glass size, forward/reverse scrolling, and detail expansion before optimizing panel count. For short pages, verify that the panel stays content-sized.

## Appearance and content coverage

Check light mode, dark mode, a non-default theme preset, narrow phone width, long Chinese text, empty state, and error state. For dialogs, validate opacity 1, 45 and 100 in both appearances.

## Validation

Use `$site-lens-validation` to run the targeted UI tests and the smallest sufficient validation level before reporting completion. UI changes that affect WebView overlays, platform insets, gestures, or native callbacks require L2 or higher.
