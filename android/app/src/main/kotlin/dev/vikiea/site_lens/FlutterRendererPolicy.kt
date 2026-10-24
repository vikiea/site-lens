package dev.vikiea.site_lens

import io.flutter.embedding.engine.FlutterShellArgs

/**
 * Keeps an explicit Skia compatibility build available for diagnosis without
 * inferring a global renderer downgrade from the device's API or GPU. WebView
 * overlays use the glass surface role designed for native pixels; Flutter
 * panels and chrome keep the renderer selected by the engine by default.
 */
object FlutterRendererPolicy {
    fun shouldDisableImpeller(forceSkia: Boolean = BuildConfig.SITE_LENS_FORCE_SKIA): Boolean =
        forceSkia

    fun shellArgs(
        base: Array<String>,
        forceSkia: Boolean = BuildConfig.SITE_LENS_FORCE_SKIA,
    ): FlutterShellArgs {
        val args = base.toMutableList()
        if (forceSkia) {
            args.removeAll { it == "--enable-impeller" || it.startsWith("--enable-impeller=") }
            args += "--enable-impeller=false"
        }
        return FlutterShellArgs(args)
    }
}
