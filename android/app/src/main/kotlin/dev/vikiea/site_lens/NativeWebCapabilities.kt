package dev.vikiea.site_lens

import android.content.Context
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

data class NativeWebCapabilityFacts(
    val provider: String?,
    val hasWorld: Boolean,
    val hasNavigation: Boolean,
    val hasStart: Boolean,
    val hasProfiles: Boolean,
    val enhanced: Boolean,
)

/** One evaluator shared by live hosts and passive diagnostics. */
object NativeWebCapabilityEvaluator {
    fun evaluate(context: Context): NativeWebCapabilityFacts {
        val hasWorld = WebViewFeature.isFeatureSupported(
            WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD,
        )
        val hasNavigation = WebViewFeature.isFeatureSupported(
            WebViewFeature.NAVIGATION_LISTENER,
        )
        val hasStart = hasWorld || WebViewFeature.isFeatureSupported(
            WebViewFeature.DOCUMENT_START_SCRIPT,
        )
        val hasProfiles = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
        val provider = runCatching {
            WebViewCompat.getCurrentWebViewPackage(context)?.let { packageInfo ->
                "${packageInfo.packageName} ${packageInfo.versionName ?: "unknown"}"
            }
        }.getOrNull()
        return NativeWebCapabilityFacts(
            provider = provider,
            hasWorld = hasWorld,
            hasNavigation = hasNavigation,
            hasStart = hasStart,
            hasProfiles = hasProfiles,
            enhanced = hasWorld && hasNavigation,
        )
    }
}
