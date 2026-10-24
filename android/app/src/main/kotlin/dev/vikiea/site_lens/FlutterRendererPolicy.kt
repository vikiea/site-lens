package dev.vikiea.site_lens

import android.os.Build
import io.flutter.embedding.engine.FlutterShellArgs

/**
 * Flutter 3.47's Android 16 Vulkan teardown can destroy an Adreno framebuffer
 * after the owning mutex has already been released. Keep the compatibility
 * decision in one place so the engine, diagnostics, and tests agree.
 */
object FlutterRendererPolicy {
    const val ANDROID_API_WITH_VULKAN_TEARDOWN_GUARD = 36

    fun shouldDisableImpeller(
        apiLevel: Int,
        socManufacturer: String = Build.SOC_MANUFACTURER,
        hardware: String = Build.HARDWARE,
    ): Boolean {
        if (apiLevel < ANDROID_API_WITH_VULKAN_TEARDOWN_GUARD) return false
        val soc = socManufacturer.trim().lowercase()
        val board = hardware.trim().lowercase()
        return soc == "qti" || soc == "qualcomm" || board == "qcom" || board.startsWith("qcom-")
    }

    fun shellArgs(
        base: Array<String>,
        apiLevel: Int,
        socManufacturer: String = Build.SOC_MANUFACTURER,
        hardware: String = Build.HARDWARE,
    ): FlutterShellArgs {
        val args = base.toMutableList()
        if (shouldDisableImpeller(apiLevel, socManufacturer, hardware)) {
            args.removeAll { it == "--enable-impeller" || it.startsWith("--enable-impeller=") }
            args += "--enable-impeller=false"
        }
        return FlutterShellArgs(args)
    }
}
