package dev.vikiea.site_lens

import android.app.Activity
import android.webkit.WebView
import androidx.webkit.*
import org.json.JSONObject
import java.util.UUID

/** Media telemetry has no navigation, network, storage, or userscript authority. */
class BrowserMediaController(
    private val activity: Activity,
    private val view: WebView,
    private val browsing: Boolean,
    private val onCandidate: ((Map<String, Any?>) -> Unit)? = null,
) {
    val supported = WebViewFeature.isFeatureSupported(WebViewFeature.MUTE_AUDIO) &&
        WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) &&
        WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
    private val token = UUID.randomUUID().toString()
    private val bridge = "lensMedia" + token.replace("-", "")
    private var injection: ScriptHandler? = null
    private var current = false
    private var visible = false
    private var requestedForeground = true
    private var platformForeground = true
    private val foreground get() = requestedForeground && platformForeground
    private var background = false
    private var playing = false
    private var manualPause = false
    private var disposed = false
    private var title = "当前标签"
    private val allowed get() = browsing && current && ((foreground && visible) || background)
    private val script = activity.assets.open("flutter_assets/web_assets/media_lifecycle.js").bufferedReader().use { it.readText() }

    init {
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MUTE_AUDIO)) {
            runCatching { WebViewCompat.setAudioMuted(view, true) }
        }
        if (supported && browsing) {
            WebViewCompat.addWebMessageListener(view, bridge, setOf("*")) { _, message, _, main, _ ->
                if (!disposed && main) {
                    try {
                        val text = message.data ?: ""
                        if (text.length > 4096) return@addWebMessageListener
                        val data = JSONObject(text)
                        if (data.opt("playing") is Boolean) {
                            playing = data.getBoolean("playing")
                            title = data.optString("title", "当前标签").take(512)
                            updateNotification()
                        }
                        val candidates = data.optJSONArray("candidates")
                        if (candidates != null) {
                            for (index in 0 until candidates.length()) {
                                val candidate = candidates.optJSONObject(index) ?: continue
                                onCandidate?.invoke(mapOf(
                                    "url" to candidate.optString("url"),
                                    "title" to candidate.optString("title"),
                                    "mime" to candidate.optString("mime"),
                                    "durationMs" to if (candidate.has("durationMs")) candidate.optLong("durationMs") else null,
                                ))
                            }
                        }
                    } catch (_: Exception) { /* Untrusted page telemetry. */ }
                }
            }
            refreshInjection()
        }
    }
    private fun refreshInjection() {
        if (!supported || !browsing || disposed) return
        runCatching { injection?.remove() }
        val config = JSONObject().put("bridge", bridge).put("token", token).put("blocked", !allowed || manualPause)
        injection = runCatching {
            WebViewCompat.addDocumentStartJavaScript(view,
                script.replace("__SITE_LENS_MEDIA_CONFIG__", config.toString()), setOf("*"))
        }.getOrNull()
    }
    fun activity(current: Boolean, visible: Boolean, foreground: Boolean, background: Boolean): Boolean {
        val changed = this.current != current || this.visible != visible || this.requestedForeground != foreground || this.background != background
        this.current = current; this.visible = visible; this.requestedForeground = foreground
        this.background = background && supported
        if (changed) refreshInjection()
        enforce()
        return supported && browsing
    }
    fun foregroundState(value: Boolean) { platformForeground = value; enforce() }
    fun pageStarted() { playing = false; manualPause = false; BrowserMediaService.stop(activity, token); refreshInjection() }
    fun pageFinished() { enforce() }
    fun userGesture() { if (foreground && visible && current) { manualPause = false; enforce() } }
    private fun action(name: String) {
        if (disposed) return
        if (name == "resume" && allowed) { manualPause = false; mute(false); view.onResume(); evaluate("resume") }
        else {
            manualPause = true; playing = false; mute(true); evaluate("pause"); view.onPause()
            if (name == "stop") BrowserMediaService.stop(activity, token)
        }
        refreshInjection()
        updateNotification()
    }
    private fun evaluate(action: String) {
        if (supported && browsing && !disposed) {
            runCatching { view.evaluateJavascript("window.__siteLensMediaControl?.apply('$action');", null) }
        }
    }
    private fun mute(value: Boolean) {
        if (!disposed && WebViewFeature.isFeatureSupported(WebViewFeature.MUTE_AUDIO)) {
            runCatching { WebViewCompat.setAudioMuted(view, value) }
        }
    }
    private fun enforce() {
        if (disposed) return
        val run = allowed && !manualPause
        mute(!run)
        evaluate(if (run) "unblock" else "pause")
        runCatching { if (run) view.onResume() else view.onPause() }
        if (!allowed) { playing = false; BrowserMediaService.stop(activity, token) }
        updateNotification()
    }
    private fun updateNotification() {
        if (disposed) return
        if (!allowed || !background) { BrowserMediaService.stop(activity, token); return }
        if (!BrowserMediaService.update(activity, token, title, playing && !manualPause, foreground, ::action)) {
            // Android refused a background service start: stop media, never leave hidden audio running.
            manualPause = true; playing = false; mute(true); evaluate("pause"); view.onPause()
        }
    }
    fun dispose() {
        if (disposed) return
        mute(true); evaluate("pause"); disposed = true
        BrowserMediaService.stop(activity, token)
        runCatching { injection?.remove() }; injection = null
        if (supported && browsing) runCatching { WebViewCompat.removeWebMessageListener(view, bridge) }
    }
}
