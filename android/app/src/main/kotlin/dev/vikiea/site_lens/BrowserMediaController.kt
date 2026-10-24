package dev.vikiea.site_lens

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
    val supported = NativeWebCapabilityEvaluator.evaluate(activity).mediaControlSupported
    private val token = UUID.randomUUID().toString()
    private val bridge = "lensMedia" + token.replace("-", "")
    private val documentToken = UUID.randomUUID().toString()
    private var ownerToken = UUID.randomUUID().toString()
    private var epoch = 0L
    private var sequence = 0L
    private val handler = Handler(Looper.getMainLooper())
    private data class Frame(
        val id: String,
        val document: String,
        val proxy: JavaScriptReplyProxy,
        val main: Boolean,
        val parent: String? = null,
        var playing: Boolean = false,
        var resumable: Boolean = false,
        var canSkip: Boolean = false,
        var activeOrder: Long = 0,
    )
    private val frames = linkedMapOf<String, Frame>()
    private val pendingFrames = linkedMapOf<String, Frame>()
    private val retired = linkedSetOf<String>()
    private val retiredDocuments = linkedSetOf<String>()
    private val resumeFrames = mutableSetOf<String>()
    private val reported = mutableSetOf<String>()
    private val pending = mutableMapOf<Long, Pair<String, String>>()
    private var mainFrame: String? = null
    private var activeDocument: String? = null
    private var navigationPending = false
    private var injection: ScriptHandler? = null
    private var current = false
    private var visible = false
    private var requestedForeground = true
    private var platformForeground = true
    private val foreground get() = requestedForeground && platformForeground
    private var background = false
    private var manualPause = false
    private var disposed = false
    private var title = "当前标签"
    private val allowed get() = browsing && current && ((foreground && visible) || background)
    private val playing get() = frames.values.any { it.playing }
    private val script = activity.assets.open("flutter_assets/web_assets/media_lifecycle.js").bufferedReader().use { it.readText() }

    init {
        mute(true)
        if (supported && browsing) {
            WebViewCompat.addWebMessageListener(view, bridge, setOf("*")) { sourceView, message, sourceOrigin, main, proxy ->
                if (!disposed && sourceView === view) {
                    try {
                        val text = message.data ?: ""
                        if (text.length > 4096) { diagnostic("oversize"); return@addWebMessageListener }
                        receive(JSONObject(text), main, proxy, sourceOrigin)
                    } catch (_: Exception) { /* Untrusted page telemetry. */ }
                }
            }
            refreshInjection()
        }
    }

    private fun receive(data: JSONObject, main: Boolean, proxy: JavaScriptReplyProxy, sourceOrigin: Uri) {
        if (data.optString("token") != documentToken) return
        val id = data.optString("frame")
        val document = data.optString("document")
        if (!id.matches(Regex("[a-zA-Z0-9_-]{1,96}")) || id in retired) return
        if (!document.matches(Regex("[a-zA-Z0-9_-]{1,96}")) || document in retiredDocuments) return
        if (data.optString("kind") == "hello") {
            val parent = if (main) null else data.optString("parentFrame").takeIf {
                it.matches(Regex("[a-zA-Z0-9_-]{1,96}"))
            }
            if (!main && parent == null) return
            var promoted = emptyList<Frame>()
            if (main && document != id) return
            if (!main && activeDocument != document) {
                val staged = pendingFrames[id]
                if (staged != null && (staged.proxy !== proxy || staged.document != document || staged.parent != parent)) return
                pendingFrames[id] = Frame(id, document, proxy, false, parent)
                while (pendingFrames.size > 128) pendingFrames.remove(pendingFrames.keys.first())
                return
            }
            if (main && activeDocument != document) {
                resetFrames()
                activeDocument = document
                promoted = promotePending(document)
            }
            val existing = frames[id]
            if (existing != null &&
                (existing.proxy !== proxy || existing.main != main || existing.document != document || existing.parent != parent)
            ) return
            if (existing == null && frames.size + pendingFrames.size >= 128) {
                diagnostic("frame_limit")
                return
            }
            val frame = existing ?: Frame(id, document, proxy, main, parent).also { frames[id] = it }
            if (main) {
                mainFrame = id
                navigationPending = false
            }
            send(frame, if (allowed && !manualPause) "unblock" else "pause")
            promoted.forEach { send(it, if (allowed && !manualPause) "unblock" else "pause") }
            if (main) enforce()
            return
        }
        if (navigationPending) return
        val frame = frames[id]?.takeIf {
            it.proxy === proxy && it.main == main && it.document == document
        } ?: return
        if (data.optLong("epoch", -1) != epoch) return
        if (data.optString("kind") == "gone" && main) {
            val child = data.optString("childFrame")
            val childParent = data.optString("childParentFrame").takeIf {
                it.matches(Regex("[a-zA-Z0-9_-]{1,96}"))
            } ?: id
            val childFrame = frames[child] ?: pendingFrames[child]
            val parentOwnedBySender = childParent == id || isDescendant(childParent, id)
            if (id == mainFrame && document == activeDocument &&
                child.matches(Regex("[a-zA-Z0-9_-]{1,96}")) && childFrame != null &&
                !childFrame.main && childFrame.document == document && childFrame.parent == childParent &&
                parentOwnedBySender
            ) {
                val removed = frames.values.filter { it.id == child || isDescendant(it.id, child) }.toList()
                removed.forEach { publishClear(it, "gone") }
                removed.forEach { frames.remove(it.id); resumeFrames.remove(it.id); retire(it.id) }
                frames.remove(child)
                pendingFrames.remove(child)
                resumeFrames.remove(child)
                retire(child)
                updateNotification()
                return
            }
            // A child retirement message must never fall through to the
            // main-document reset path when its ownership proof is invalid.
            return
        }
        when (data.optString("kind")) {
            "clear" -> {
                val page = observedPage(data.optString("pageUrl"), sourceOrigin) ?: return
                onCandidate?.invoke(mapOf(
                    "kind" to "clear",
                    "reason" to data.optString("reason", "route"),
                    "pageUrl" to page,
                    "previousPageUrl" to observedPage(data.optString("previousPageUrl"), sourceOrigin),
                    "frame" to id,
                    "document" to document,
                    "main" to main,
                    "snapshot" to if (data.has("snapshot")) data.optLong("snapshot") else null,
                ))
            }
            "gone" -> {
                if (main) resetFrames()
                else { publishClear(frame, "gone"); frames.remove(id); resumeFrames.remove(id); retire(id) }
                updateNotification()
            }
            "state" -> {
                if (data.opt("playing") !is Boolean) return
                val nextPlaying = data.getBoolean("playing")
                if (nextPlaying && !frame.playing) frame.activeOrder = ++sequence
                frame.playing = nextPlaying
                frame.resumable = data.optBoolean("resumable")
                frame.canSkip = data.optBoolean("canSkip")
                if (main) title = data.optString("title", "当前标签").take(512)
                if (nextPlaying && (!allowed || manualPause)) send(frame, "pause")
                val evidence = data.optJSONObject("evidence")
                if (evidence != null) {
                    observedPage(evidence.optString("pageUrl"), sourceOrigin)?.let { page ->
                        evidence.put("pageUrl", page)
                        evidence.put("frame", id)
                        evidence.put("document", document)
                        evidence.put("epoch", epoch)
                        onCandidate?.invoke(mapOf(
                            "kind" to "playbackEvidence",
                            "payload" to evidence.toString(),
                        ))
                    }
                }
                updateNotification()
            }
            "candidates" -> {
                val candidates = data.optJSONArray("candidates") ?: return
                for (index in 0 until candidates.length()) {
                    val candidate = candidates.optJSONObject(index) ?: continue
                    val page = observedPage(candidate.optString("pageUrl"), sourceOrigin) ?: continue
                    onCandidate?.invoke(mapOf(
                        "kind" to "candidate",
                        "url" to candidate.optString("url"),
                        "title" to candidate.optString("title"),
                        "mime" to candidate.optString("mime"),
                        "thumbnail" to candidate.optString("thumbnail"),
                        "pageUrl" to page,
                        "frame" to id,
                        "document" to document,
                        "main" to main,
                        "epoch" to data.optLong("epoch", -1),
                        "episodeNumber" to if (candidate.has("episodeNumber")) candidate.optInt("episodeNumber") else null,
                        "durationMs" to if (candidate.has("durationMs")) candidate.optLong("durationMs") else null,
                    ))
                }
            }
            "ack" -> {
                val command = data.optLong("command", -1)
                val expected = pending[command] ?: return
                if (expected.first != id) return
                pending.remove(command)
                if (!data.optBoolean("ok")) diagnostic("command_failed", expected.second)
            }
        }
    }

    private fun observedPage(raw: String, sourceOrigin: Uri): String? {
        if (raw.isBlank()) return sourceOrigin.toString()
        if (raw.length > 2048) return null
        val page = runCatching { Uri.parse(raw) }.getOrNull() ?: return null
        if (page.scheme !in setOf("http", "https") || page.host.isNullOrEmpty() || page.userInfo != null) return null
        fun port(uri: Uri) = if (uri.port >= 0) uri.port else if (uri.scheme == "https") 443 else 80
        return raw.takeIf {
            page.scheme == sourceOrigin.scheme && page.host.equals(sourceOrigin.host, ignoreCase = true) &&
                port(page) == port(sourceOrigin)
        }
    }

    private fun publishClear(frame: Frame, reason: String) {
        onCandidate?.invoke(mapOf("kind" to "clear", "reason" to reason,
            "frame" to frame.id, "document" to frame.document, "main" to frame.main))
    }

    private fun retire(id: String) {
        retired.add(id)
        if (retired.size > 512) retired.remove(retired.first())
    }
    private fun isDescendant(id: String, ancestor: String): Boolean {
        val seen = mutableSetOf<String>()
        var current = frames[id] ?: pendingFrames[id]
        while (current != null && seen.add(current.id)) {
            val parent = current.parent ?: return false
            if (parent == ancestor) return true
            current = frames[parent] ?: pendingFrames[parent]
        }
        return false
    }
    private fun resetFrames() {
        stopService()
        frames.values.forEach { publishClear(it, "document") }
        ownerToken = UUID.randomUUID().toString()
        activeDocument?.let {
            retiredDocuments.add(it)
            if (retiredDocuments.size > 512) retiredDocuments.remove(retiredDocuments.first())
        }
        activeDocument = null
        pendingFrames.entries.removeIf { it.value.document in retiredDocuments }
        frames.keys.forEach(::retire)
        frames.clear(); resumeFrames.clear(); mainFrame = null
        pending.clear(); handler.removeCallbacksAndMessages(null)
        reported.clear(); epoch++; manualPause = false; title = "当前标签"
    }

    private fun promotePending(document: String): List<Frame> {
        val promote = pendingFrames.values.filter { it.document == document }
        pendingFrames.entries.removeIf { it.value.document == document }
        promote.forEach { frames[it.id] = it }
        return promote
    }
    private fun refreshInjection() {
        if (!supported || !browsing || disposed) return
        runCatching { injection?.remove() }
        // New frames start blocked until their own native handshake receives the
        // current policy. Late iframes must not inherit stale injection policy.
        val config = JSONObject().put("bridge", bridge).put("token", documentToken).put("blocked", true)
        injection = runCatching {
            WebViewCompat.addDocumentStartJavaScript(view,
                script.replace("__SITE_LENS_MEDIA_CONFIG__", config.toString()), setOf("*"))
        }.onFailure { diagnostic("injection_failed") }.getOrNull()
    }
    fun activity(current: Boolean, visible: Boolean, foreground: Boolean, background: Boolean): Boolean {
        this.current = current; this.visible = visible; requestedForeground = foreground
        this.background = background && supported
        enforce()
        return supported && browsing
    }
    fun foregroundState(value: Boolean) { platformForeground = value; enforce() }
    fun pageStarted() {
        if (disposed) return
        // Document-start can precede this callback. Retiring here could retire
        // the new main frame as well; its hello proves document replacement.
        stopService()
        ownerToken = UUID.randomUUID().toString()
        navigationPending = true
        manualPause = false
        mute(true)
    }
    fun pageFinished() {
        if (disposed) return
        runCatching { view.evaluateJavascript("window.__siteLensMediaControl?.connect();", null) }
        enforce()
    }
    fun userGesture() { if (foreground && visible && current && !disposed) { manualPause = false; enforce() } }
    private fun action(name: String) {
        if (disposed || navigationPending) return
        if (name in setOf("resume", "next", "previous")) {
            if (!allowed) return
            manualPause = false
            mute(false)
            runCatching { view.onResume() }
            val targets = if (name == "resume") {
                frames.values.filter { it.id in resumeFrames }.ifEmpty {
                    listOfNotNull(frames.values.filter { it.resumable }.maxByOrNull { it.activeOrder })
                }
            } else listOfNotNull(frames.values.filter { it.canSkip }.maxByOrNull { it.activeOrder })
            if (targets.isEmpty()) diagnostic("no_target", name)
            targets.forEach { send(it, name, acknowledge = true) }
            resumeFrames.clear()
        } else if (name in setOf("pause", "stop")) {
            if (!manualPause) resumeFrames.addAll(frames.values.filter { it.playing }.map { it.id })
            manualPause = true
            mute(true)
            broadcast("pause", acknowledge = true)
            // Keep the JS bridge alive for notification resume in background.
            if (name == "stop") { resumeFrames.clear(); stopService(); return }
        }
        updateNotification()
    }
    private fun send(frame: Frame, action: String, acknowledge: Boolean = false) {
        if (disposed) return
        val command = ++sequence
        if (acknowledge) pending[command] = frame.id to action
        val payload = JSONObject().put("token", documentToken).put("frame", frame.id)
            .put("document", frame.document).put("epoch", epoch)
            .put("action", action).put("command", command)
        runCatching { frame.proxy.postMessage(payload.toString()) }.onFailure {
            pending.remove(command)
            diagnostic("frame_send_failed", action)
        }
        if (acknowledge && command in pending) handler.postDelayed({
            val missed = pending.remove(command)
            if (!disposed && missed != null) diagnostic("command_timeout", missed.second)
        }, 4000)
    }
    private fun broadcast(action: String, acknowledge: Boolean = false) {
        frames.values.toList().forEach { send(it, action, acknowledge) }
    }
    private fun mute(value: Boolean) {
        if (!disposed && WebViewFeature.isFeatureSupported(WebViewFeature.MUTE_AUDIO)) {
            runCatching { WebViewCompat.setAudioMuted(view, value) }.onFailure { diagnostic("mute_failed") }
        }
    }
    private fun enforce() {
        if (disposed) return
        if (navigationPending) { mute(true); return }
        val run = allowed && !manualPause
        mute(!run)
        broadcast(if (run) "unblock" else "pause")
        runCatching { if (run || (allowed && background)) view.onResume() else view.onPause() }
        if (!allowed) stopService()
        updateNotification()
    }
    private fun updateNotification() {
        if (disposed) return
        if (!allowed) { stopService(); return }
        if (navigationPending) return
        val expectedOwner = ownerToken
        val updated = runCatching {
            BrowserMediaService.update(activity, expectedOwner, title, playing && !manualPause, foreground,
                frames.values.any { it.canSkip }) { command ->
                if (!disposed && expectedOwner == ownerToken) action(command)
            }
        }.getOrDefault(false)
        if (!updated && playing) {
            diagnostic("service_start_rejected")
            // A foreground page must keep its own WebView audio when the
            // notification service cannot be updated. Only background or
            // hidden playback is paused by this failure path.
            if (!foreground || !visible || !current) {
                manualPause = true; mute(true); broadcast("pause")
            }
        }
    }
    private fun diagnostic(code: String, action: String = "policy") {
        if (!reported.add("$code:$action")) return
        // Only enumerated operation/state is persisted, never private data.
        android.util.Log.w(
            "SiteLensMedia",
            "code=$code action=$action frames=" + frames.size +
                " current=$current visible=$visible foreground=$foreground " +
                "background=$background manualPause=$manualPause epoch=$epoch",
        )
    }
    private fun stopService() { runCatching { BrowserMediaService.stop(activity, ownerToken) } }
    fun rendererGone() {
        if (disposed) return
        disposed = true; frames.clear(); pendingFrames.clear(); pending.clear(); resumeFrames.clear()
        handler.removeCallbacksAndMessages(null); injection = null
        stopService()
    }
    fun dispose() {
        if (disposed) return
        mute(true); broadcast("pause"); disposed = true
        frames.clear(); pendingFrames.clear(); pending.clear(); handler.removeCallbacksAndMessages(null)
        stopService()
        runCatching { injection?.remove() }; injection = null
        if (supported && browsing) runCatching { WebViewCompat.removeWebMessageListener(view, bridge) }
    }
}
