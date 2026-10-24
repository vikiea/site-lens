package dev.vikiea.site_lens

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.webkit.*
import android.widget.FrameLayout
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import androidx.webkit.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.ByteArrayInputStream
import java.util.UUID
import java.util.concurrent.Executors

private fun webUri(value: String): Uri {
    val uri = Uri.parse(value)
    require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrEmpty() && uri.userInfo == null) { "Only credential-free HTTP(S) URLs are accepted" }
    return uri
}
private fun origin(uri: Uri): String = "${uri.scheme}://${uri.host?.lowercase()}:${if (uri.port >= 0) uri.port else if (uri.scheme == "https") 443 else 80}"

/** A filter snapshot must never turn a real video/audio transport into 204. */
private fun isMediaRequest(request: WebResourceRequest): Boolean {
    val path = request.url.path?.lowercase() ?: ""
    if (Regex("\\.(?:m3u8?|mpd|mp4|m4v|webm|mov|mkv|ts|m4s|aac|mp3|m4a|ogg|wav)(?:$|/)").containsMatchIn(path)) {
        return true
    }
    return request.requestHeaders.any { (name, value) ->
        name.equals("Accept", ignoreCase = true) && value.split(',').any { item ->
            val type = item.trim().substringBefore(';').lowercase()
            type.startsWith("video/") || type.startsWith("audio/") ||
                type.contains("mpegurl") || type.contains("dash+xml")
        }
    }
}

/**
 * Canonical form of an HTTP(S) URL, used to compare the URL we leased scripts
 * for with the URL the WebView reports for the actual navigation.
 *
 * WebView canonicalizes whatever was handed to `loadUrl`, so `https://host`
 * becomes `https://host/`. Comparing raw strings therefore reports every
 * slash-less entry as an unverifiable navigation and silently revokes all
 * privileged scripts. Default ports, host case and fragments are normalized
 * for the same reason.
 */
private fun canonicalWebUrl(value: String?): String? {
    val text = value?.takeIf { it.isNotEmpty() } ?: return null
    val uri = try { Uri.parse(text) } catch (_: Exception) { return null }
    val scheme = uri.scheme?.lowercase() ?: return null
    if (scheme != "http" && scheme != "https") return null
    val host = uri.host?.lowercase() ?: return null
    val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
    val path = uri.path?.takeIf { it.isNotEmpty() } ?: "/"
    val query = uri.query?.let { "?$it" } ?: ""
    return "$scheme://$host:$port$path$query"
}

/** How many redirects an app-started entry may follow before it must be re-authorized. */
private const val MAX_ENTRY_REDIRECTS = 5

/** Keeps Android's left-edge back gesture from being consumed as pull-to-refresh. */
private class BrowserRefreshLayout(context: Context) : SwipeRefreshLayout(context) {
    private val backGestureEdge = 32f * resources.displayMetrics.density
    private var downX = Float.NaN

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> downX = event.x
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_UP -> downX = Float.NaN
        }
        if (!downX.isNaN() && downX <= backGestureEdge) return false
        return super.onInterceptTouchEvent(event)
    }
}

/** True when [expected] and [actual] address the same canonical document. */
private fun sameWebUrl(expected: String?, actual: String?): Boolean {
    val left = canonicalWebUrl(expected) ?: return false
    val right = canonicalWebUrl(actual) ?: return false
    return left == right
}

/** Scheme/host/default-port origin, used only for same-document lease continuity. */
private fun webOrigin(value: String?): String? {
    val text = value?.takeIf { it.isNotEmpty() } ?: return null
    val uri = try { Uri.parse(text) } catch (_: Exception) { return null }
    val scheme = uri.scheme?.lowercase() ?: return null
    if (scheme != "http" && scheme != "https") return null
    val host = uri.host?.lowercase() ?: return null
    val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
    return "$scheme://$host:$port"
}
// The URL rules are compared against, in the same shape Dart and the JS runtime use:
// no fragment, and an empty path becomes `/` so an all-URLs rule also covers a bare
// origin like https://host (WebView may report the address verbatim, and a rule that
// matches nothing here silently rejects every GM request coming from that page).
// Block comments are avoided on purpose: Kotlin nests them and the pattern contains
// a slash-star sequence.
private fun matchTarget(url: String): String {
    val hashless = url.substringBefore('#')
    return try {
        val uri = Uri.parse(hashless)
        if (uri.path.isNullOrEmpty() && !uri.scheme.isNullOrEmpty() && !uri.authority.isNullOrEmpty()) {
            uri.buildUpon().path("/").build().toString()
        } else hashless
    } catch (_: Exception) { hashless }
}

private fun matches(script: ScriptRegistration, url: String): Boolean = try {
    val rules = JSONObject(script.rulesJson)
    val target = matchTarget(url)
    fun accepts(array: JSONArray): Boolean = (0 until array.length()).any { Regex(array.getString(it)).matches(target) }
    accepts(rules.getJSONArray("matches")) && !accepts(rules.getJSONArray("excludes"))
} catch (_: Exception) { false }

class SiteLensWebView(context: Context) : WebView(context) {
    var onTap: (() -> Unit)? = null
    var unavailable = false
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (unavailable) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                downAt = event.eventTime
            }
            MotionEvent.ACTION_UP -> {
                val dx = event.x - downX
                val dy = event.y - downY
                if (event.eventTime - downAt <= 500 && dx * dx + dy * dy <= touchSlop * touchSlop) {
                    val handled = try {
                        super.dispatchTouchEvent(event)
                    } catch (_: Exception) {
                        false
                    }
                    // A tap can coincide with a WebView navigation or renderer
                    // teardown. Media telemetry is best effort and must never
                    // turn a page click into an app crash.
                    runCatching { onTap?.invoke() }
                    return handled
                }
            }
        }
        return try {
            super.dispatchTouchEvent(event)
        } catch (_: Exception) {
            false
        }
    }
}

class NativeWebHostRegistry(private val activity: Activity, engine: FlutterEngine) : WebHostApi {
    private val messenger = engine.dartExecutor.binaryMessenger
    private val events = WebHostEvents(engine.dartExecutor.binaryMessenger)
    private val hosts = mutableMapOf<Long, NativeWebHost>()
    private val retiringHosts = mutableSetOf<NativeWebHost>()
    private val browserUi = MethodChannel(messenger, "site_lens/browser_ui")
    private var fullscreenOwner: NativeWebHost? = null
    private var disposed = false
    private var nextNotificationId = 1000
    private val filterWorker = Executors.newSingleThreadExecutor()
    private val filterRules = NativeFilterRules(activity.filesDir)
    private val filterMain = Handler(Looper.getMainLooper())
    private val filterRequests = mutableMapOf<Long, Long>()
    private val inspector = activity.assets.open("flutter_assets/web_assets/page_inspector.js").bufferedReader().use { it.readText() }
    init {
        WebHostApi.setUp(engine.dartExecutor.binaryMessenger, this)
        browserUi.setMethodCallHandler { call, result ->
            if (call.method != "setFullscreen" && call.method != "exitFullscreen") {
                result.notImplemented()
            } else try {
                val hostId = call.argument<Number>("hostId")?.toLong()
                    ?: throw IllegalArgumentException("Missing browser host")
                if (call.method == "exitFullscreen") {
                    // Fullscreen cleanup is idempotent: the Flutter route can
                    // outlive the native host that owned the custom view.
                    hosts[hostId]?.forceClearFullscreen()
                } else {
                    val target = host(hostId)
                    require(target.purpose == HostPurpose.BROWSING) { "Only browsing hosts own system bars" }
                    val enabled = call.argument<Boolean>("enabled") == true
                    if (enabled) {
                        requestFullscreen(target, true)
                    } else {
                        // A stale host cannot restore system bars over the current owner.
                        requestFullscreen(target, false)
                    }
                }
                result.success(null)
            } catch (error: Exception) {
                result.error("browser_ui_unavailable", error.message, null)
            }
        }
        engine.platformViewsController.registry.registerViewFactory("site_lens/web_host", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            override fun create(context: android.content.Context, viewId: Int, args: Any?): PlatformView {
                val id = ((args as? Map<*, *>)?.get("hostId") as? Number)?.toLong() ?: -1
                val host = host(id)
                host.acquirePlatformView(viewId)
                return object : PlatformView {
                    override fun getView(): View = host.platformView
                    override fun dispose() { host.releasePlatformView(viewId) }
                }
            }
        })
    }
    private fun host(id: Long): NativeWebHost = hosts[id]?.takeIf { !disposed && it.available } ?: throw FlutterError("host_destroyed", "Web host no longer exists", null)
    private var isForeground = true
    override fun create(hostId: Long, purpose: HostPurpose, preferences: HostPreferences): HostCapabilities {
        check(!disposed && !activity.isFinishing && !activity.isDestroyed) { "Web host activity is unavailable" }
        // A Flutter integration test can time out after the platform create
        // reply was sent but before Dart records the session. On the next
        // test/engine generation the numeric host id is reused; dispose the
        // orphaned native host instead of making every later test fail with a
        // stale `Host already exists` error.
        hosts.remove(hostId)?.let {
            releaseFullscreen(it)
            retiringHosts.add(it)
            it.dispose(force = true)
        }
        val host = NativeWebHost(activity, hostId, purpose, events, preferences, onFullscreenChanged = { changed, active ->
            onHostFullscreenChanged(changed, active)
        }, onDisposed = { retired ->
            retiringHosts.remove(retired)
        }) { gone ->
            releaseFullscreen(gone)
            if (hosts[hostId] === gone) hosts.remove(hostId)
        }
        host.media.foregroundState(isForeground)
        hosts[hostId] = host
        return host.capabilities
    }
    override fun registerScripts(hostId: Long, scripts: List<ScriptRegistration>) {
        val host = host(hostId)
        require(host.purpose == HostPurpose.BROWSING || scripts.isEmpty()) { "Probe hosts cannot run user scripts" }
        host.registerScripts(scripts)
    }
    override fun applyFilter(hostId: Long, context: HostFilterContextDto, policy: FilterPolicyDto, snapshot: FilterSnapshotDto, callback: (Result<Unit>) -> Unit) {
        try {
            val target = host(hostId)
            require(context.hostId == hostId && context.snapshotId == snapshot.id) { "Filter snapshot identity mismatch" }
            require(context.generation >= target.generation) { "Filter generation is stale" }
            val request = (filterRequests[hostId] ?: 0L) + 1L
            filterRequests[hostId] = request
            filterWorker.execute {
                val prepared = runCatching { filterRules.load(snapshot) }
                filterMain.post {
                    callback(runCatching {
                        require(host(hostId) === target && filterRequests[hostId] == request) { "Filter host or request is stale" }
                        if (prepared.isFailure) {
                            target.restoreFilterInjection()
                            throw prepared.exceptionOrNull()!!
                        }
                        target.applyFilter(context, policy, snapshot, prepared.getOrThrow())
                    })
                }
            }
        } catch (error: Exception) { callback(Result.failure(error)) }
    }
    override fun setHostActivity(hostId: Long, isCurrent: Boolean, visible: Boolean, foreground: Boolean, allowBackgroundPlayback: Boolean): Boolean =
        host(hostId).media.activity(isCurrent, visible, foreground, allowBackgroundPlayback)
    fun foreground(value: Boolean) {
        if (disposed) return
        isForeground = value
        hosts.values.toList().filter { it.available }.forEach { it.media.foregroundState(value) }
    }
    override fun applyPreferences(hostId: Long, preferences: HostPreferences) { host(hostId).applyPreferences(preferences) }
    // `navigate`/`reload` are the navigations the app starts itself, so they are the
    // ones the entry-redirect switch applies to.
    override fun navigate(hostId: Long, url: String) { webUri(url); val host = host(hostId); host.prepareNavigation(url, host.preferences.followEntryRedirects) { host.webView.loadUrl(url) } }
    override fun reload(hostId: Long) { val host = host(hostId); host.prepareNavigation(host.webView.url ?: return, host.preferences.followEntryRedirects) { host.webView.reload() } }
    override fun goBack(hostId: Long): Boolean = host(hostId).goHistory(-1)
    override fun goForward(hostId: Long): Boolean = host(hostId).goHistory(1)
    override fun stop(hostId: Long) { val host = host(hostId); host.revoke(); host.webView.stopLoading() }
    override fun destroy(hostId: Long) {
        hosts.remove(hostId)?.let {
            releaseFullscreen(it)
            retiringHosts.add(it)
            it.dispose()
        }
    }

    private fun requestFullscreen(host: NativeWebHost, enabled: Boolean) {
        if (!enabled && fullscreenOwner !== host) return
        host.setManualFullscreen(enabled)
    }

    private fun onHostFullscreenChanged(host: NativeWebHost, active: Boolean) {
        if (active) {
            if (disposed || hosts[host.id] !== host || !host.available) return
            val previous = fullscreenOwner
            fullscreenOwner = host
            if (previous !== host) previous?.forceClearFullscreen()
            applyFullscreenWindow(true)
        } else if (fullscreenOwner === host) {
            fullscreenOwner = null
            applyFullscreenWindow(false)
        }
    }

    private fun releaseFullscreen(host: NativeWebHost) {
        if (fullscreenOwner !== host) return
        fullscreenOwner = null
        applyFullscreenWindow(false)
    }

    private fun applyFullscreenWindow(enabled: Boolean) {
        if (activity.isFinishing || activity.isDestroyed) return
        val window = activity.window
        // Keep the app's edge-to-edge policy; fullscreen changes visibility only.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (enabled) hide(WindowInsetsCompat.Type.systemBars())
            else show(WindowInsetsCompat.Type.systemBars())
        }
    }
    override fun notify(hostId: Long, title: String, body: String) {
        host(hostId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 5101)
            throw IllegalStateException("通知权限未授权，已请求；允许后重试")
        }
        val manager = activity.getSystemService(NotificationManager::class.java)
        val channelId = "site-lens-scripts"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(channelId, "用户脚本通知", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val intent = Intent(activity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(activity, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(activity, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title.take(120))
            .setContentText(body.take(1000))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        manager.notify(nextNotificationId++, notification)
    }
    override fun openExternal(hostId: Long, url: String) {
        host(hostId)
        val intent = Intent(Intent.ACTION_VIEW, webUri(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
    }
    override fun inspect(hostId: Long, selector: String, callback: (Result<PageSnapshot>) -> Unit) {
        try {
            val host = host(hostId); val generation = host.generation
            host.webView.evaluateJavascript(inspector.replace("__LENS_SELECTOR__", JSONObject.quote(selector))) { raw ->
                try {
                    check(!host.destroyed && host.generation == generation) { "Document invalidated" }
                    val text = JSONTokener(raw).nextValue() as? String ?: throw IllegalStateException("No inspector response")
                    val j = JSONObject(text)
                    val links = j.optJSONArray("links") ?: JSONArray()
                    callback(Result.success(PageSnapshot(url = host.webView.url ?: "", title = j.optString("title"), generation = generation,
                        ready = j.optBoolean("ready"), challenge = j.optBoolean("challenge"), interactionRequired = j.optBoolean("interactionRequired"),
                        links = (0 until links.length()).map { links.getString(it) }, text = j.optString("text"), error = host.pageError ?: j.optString("error"))))
                } catch (e: Exception) { callback(Result.failure(e)) }
            }
        } catch (e: Exception) { callback(Result.failure(e)) }
    }
    override fun invokeMenu(hostId: Long, scriptId: String, menuId: String, expectedGeneration: Long, expectedRevision: String, callback: (Result<Unit>) -> Unit) {
        try {
            val host = host(hostId)
            check(host.generation == expectedGeneration) { "Menu generation invalidated" }
            val binding = host.bindings.firstOrNull { it.script.id == scriptId && it.script.revision == expectedRevision && host.valid(it) } ?: throw IllegalStateException("Menu invalidated")
            val proxy = binding.proxy ?: throw IllegalStateException("Menu has no same-world route")
            proxy.executeJavaScript("if (__lensBridgeToken !== ${JSONObject.quote(binding.token)}) throw new Error('stale menu'); __lensInvokeMenu(${JSONObject.quote(menuId)});", object : WebViewOutcomeReceiver<String, JavaScriptExecutionException> {
                override fun onResult(result: String) { if (host.valid(binding)) callback(Result.success(Unit)) else callback(Result.failure(IllegalStateException("Document invalidated"))) }
                override fun onError(error: JavaScriptExecutionException) { callback(Result.failure(error)) }
            })
        } catch (e: Exception) { callback(Result.failure(e)) }
    }
    fun dispose() {
        if (disposed) return
        disposed = true
        filterWorker.shutdown()
        // Closing hosts have already left the public registry but can still
        // await a Flutter platform-view release when the engine goes away.
        val previous = (hosts.values + retiringHosts).distinct()
        hosts.clear()
        retiringHosts.clear()
        fullscreenOwner = null
        applyFullscreenWindow(false)
        WebHostApi.setUp(messenger, null)
        browserUi.setMethodCallHandler(null)
        previous.forEach { it.dispose(force = true) }
    }
}

private const val PRIVILEGED_SCRIPT_SLOTS = 32

class ScriptBinding(val script: ScriptRegistration, val generation: Long, val token: String, val world: JavaScriptExecutionWorld) {
    var proxy: JavaScriptReplyProxy? = null
}

/** In-memory request/page filtering state. It is replaced atomically before a
 * navigation and is intentionally independent of Dart, disk and network. */
private data class NativeFilterState(
    val enabled: Boolean = false,
    val pageFiltering: Boolean = false,
    val exceptions: Set<String> = emptySet(),
    val blockedDomains: Set<String> = emptySet(),
    val rules: List<NativeFilterRule> = emptyList(),
    val snapshotId: String = "",
)

internal data class NativeFilterInjectionSelection(
    val cosmetic: List<NativeFilterRule>,
    val scriptlets: List<NativeFilterRule>,
)

internal const val MAX_FILTER_INJECTION_BYTES = 4 * 1024 * 1024

/** Preserve all frame scopes. The runtime applies per-frame budgets after exceptions. */
internal fun selectFilterInjectionRules(rules: List<NativeFilterRule>): NativeFilterInjectionSelection =
    NativeFilterInjectionSelection(
        cosmetic = rules.filter { it.cosmetic && it.scriptlet == null },
        scriptlets = rules.filter { it.scriptlet != null },
    )

private const val FILTER_RUNTIME_ASSET = "flutter_assets/web_assets/filter_runtime.js"

@Suppress("SetJavaScriptEnabled")
class NativeWebHost(private val activity: Activity, val id: Long, val purpose: HostPurpose, private val events: WebHostEvents, initialPreferences: HostPreferences, private val onFullscreenChanged: (NativeWebHost, Boolean) -> Unit = { _, _ -> }, private val onDisposed: (NativeWebHost) -> Unit = {}, private val onRendererGone: (NativeWebHost) -> Unit = {}) {
    val webView = SiteLensWebView(activity)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val viewLifetime = WebViewLifetime(
        post = { task -> mainHandler.post { task() } },
        destroy = { finishDispose() },
    )
    private val popupProbes = mutableMapOf<WebView, () -> Unit>()
    val available get() = !viewLifetime.closing && !destroyed && !rendererGone && !activity.isFinishing && !activity.isDestroyed

    fun acquirePlatformView(viewId: Int) {
        viewLifetime.acquire(viewId)
        (platformView.parent as? ViewGroup)?.removeView(platformView)
    }

    fun releasePlatformView(viewId: Int) {
        if (viewLifetime.release(viewId)) {
            (platformView.parent as? ViewGroup)?.removeView(platformView)
        }
    }

    /// Policy owned by Dart; the host only enforces it. `applyPreferences` keeps a
    /// live host in step with a switch the user flipped mid-session.
    val media = BrowserMediaController(
        activity,
        webView,
        purpose == HostPurpose.BROWSING,
    ) { candidate ->
        if (candidate["kind"] == "clear") {
            event("mediaCandidatesClear", JSONObject(candidate).toString())
        } else if (candidate["kind"] == "playbackEvidence") {
            val payload = candidate["payload"] as? String
            if (!payload.isNullOrBlank()) event("mediaPlaybackEvidence", payload)
        } else {
            val url = candidate["url"] as? String
            if (url != null && url.isNotBlank()) event("mediaCandidate", JSONObject(candidate).toString())
        }
    }
    var preferences: HostPreferences = initialPreferences
        private set

    fun applyPreferences(next: HostPreferences) {
        preferences = next
        refreshLayout?.isEnabled = next.pullToRefresh
    }

    // Pull-to-refresh is a browsing affordance only; discovery/probe hosts must
    // not gain a user-visible refresh gesture or alter their lifecycle.
    private val refreshLayout: SwipeRefreshLayout? = if (purpose == HostPurpose.BROWSING) {
        BrowserRefreshLayout(activity).apply {
            // The pull gesture costs the page (and its user scripts) their own
            // pull-to-refresh, so it is a switch the user owns: off leaves the
            // gesture to the site.
            isEnabled = initialPreferences.pullToRefresh
            webView.layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            addView(webView)
            setOnRefreshListener {
                val current = webView.url
                if (current.isNullOrEmpty()) isRefreshing = false
                else prepareNavigation(current, preferences.followEntryRedirects) { webView.reload() }
            }
        }
    } else null
    val platformView: View = refreshLayout ?: webView
    private val webCapabilities = NativeWebCapabilityEvaluator.evaluate(activity)
    private val hasWorld = webCapabilities.hasWorld
    private val hasNavigation = webCapabilities.hasNavigation
    private val hasStart = webCapabilities.hasStart
    private val hasProfiles = webCapabilities.hasProfiles
    private val enhanced = webCapabilities.enhanced
    val capabilities: HostCapabilities
    @Volatile var generation = 0L
    @Volatile var destroyed = false
    @Volatile private var eventEpoch = 0L
    private val eventDispatcher = HostEventDispatcher(
        isMainThread = { Looper.myLooper() == Looper.getMainLooper() },
        post = { delivery -> mainHandler.post { delivery() } },
        isCurrent = { ticket, epoch -> !destroyed && generation == ticket && eventEpoch == epoch },
    )
    var pageError: String? = null
    var scripts = emptyList<ScriptRegistration>()
        private set
    val bindings = mutableListOf<ScriptBinding>()
    // Pre-register a bounded pool before any document runs. Even adding a
    // listener to a live document rebuilds all provider message endpoints.
    // Navigation, script churn and increasing script counts only reuse slots.
    private val privilegedWorlds = mutableListOf<JavaScriptExecutionWorld>()
    private val injections = mutableListOf<ScriptHandler>()
    private val filterInstallation = NativeFilterInstallation<NativeFilterState, ScriptHandler>(NativeFilterState()) { it.remove() }
    private val retiredInjections = mutableListOf<ScriptHandler>()
    private var bridgeCleanupScheduled = false
    private val bridgeCleanup = Runnable {
        bridgeCleanupScheduled = false
        flushRetiredBridges()
    }
    private val filterState: NativeFilterState get() = filterInstallation.state
    private var filterBlockedCount = 0
    private var filterAllowedCount = 0
    private var accepting = false
    private var expectedUrl: String? = null
    // Kept across same-document navigation so SPA/hash episode changes do not
    // need a full reload. Cleared on every real document lease/revoke.
    private var leasedOrigin: String? = null
    // True while the navigation the app itself started (entry, go-home, reload) is
    // still resolving its server redirects; cleared by the first commit or revoke.
    private var entryFollowing = false
    private var entryHops = 0
    // The exact Navigation this entry started. Only *its* redirects may be
    // followed: activeNavigation alone would also match a navigation the page
    // began while the entry window was still open (a reload leaves the previous
    // document alive, and a page-started navigation does not necessarily pass
    // through shouldOverrideUrlLoading, which is what re-prepares a strict lease).
    private var entryNavigation: Navigation? = null
    // The window may be claimed exactly once: by the first navigation start that
    // addresses the URL the app just authorized. Without that, a *page* navigation
    // to the same URL would re-point the window at itself and its own redirect
    // chain would then be followed. (Navigation.wasInitiatedByPage() cannot be used
    // for this: measured on Android WebView 157 it reports false both for the app's
    // own loadUrl and for a page-started navigation whose reported URL is the
    // redirect target.)
    private var entryArmed = false
    private var activeNavigation: Navigation? = null
    private var sslNavigation: Navigation? = null
    private val sslFailures = WebSslFailurePolicy()
    private var activePage: Page? = null
    // App-owned back/forward is armed only after the target's scripts have
    // been fetched and immediately before WebView starts the history load.
    // Page-started history remains fail-closed, while the toolbar can restore
    // a known history entry without producing a false warning.
    private var historyArmed = false
    // A predictive-back gesture can dispatch more than one callback before
    // WebView commits the history entry. Serialize the preparation so a second
    // callback cannot start a reload or consume the same entry twice.
    private var historyInFlight = false
    private var historyLoading = false
    private var historyTimeout: Runnable? = null
    private var customView: View? = null
    private var manualFullscreen = false
    private var customFullscreen = false
    val browserFullscreen: Boolean
        get() = manualFullscreen || customFullscreen
    private var customCallback: WebChromeClient.CustomViewCallback? = null
    @Volatile private var rendererGone = false
    private var originalOrientation: Int? = null
    private var navigationListener: NavigationListener? = null
    // WebView may update view.url through history.pushState before the matching
    // onPageFinished callback returns. Keep the URL reported at page start so
    // that callback can still be associated with the same document load.
    private var pageLoadGeneration = -1L
    private var pageStartedUrl: String? = null
    // Do not let callbacks from the previous document cancel the asynchronous
    // policy preparation for the next app-owned load on older providers.
    private var fallbackNavigationPreparing = false
    @Volatile private var lastKnownUrl: String? = null
    // A history traversal is app-owned only for the one target selected from
    // copyBackForwardList. Keep this marker until the navigation commits so
    // WebViewClient cannot turn goBack/goForward into a fresh loadUrl.
    private var historyTargetUrl: String? = null
    private val profileName = if (purpose == HostPurpose.BROWSING) null else "site-lens-probe-${UUID.randomUUID()}"

    internal fun applyFilter(context: HostFilterContextDto, policy: FilterPolicyDto, snapshot: FilterSnapshotDto, rules: List<NativeFilterRule>) {
        check(context.hostId == id) { "Filter host identity mismatch" }
        check(context.generation >= generation) { "Filter generation is stale" }
        val nextState = NativeFilterState(
            enabled = policy.enabled && snapshot.state != "missing" && snapshot.state != "failed" && snapshot.state != "corrupt",
            pageFiltering = policy.pageFiltering,
            exceptions = policy.domainExceptions.map { it.lowercase() }.toSet(),
            blockedDomains = policy.blockedDomains.map { it.lowercase() }.toSet(),
            rules = rules,
            snapshotId = snapshot.id,
        )
        installFilterState(nextState)
    }

    /**
     * Registers the new document-start hook before retiring the old one. The
     * WebView provider may reject a registration (for example while the
     * renderer is recovering); in that case the old state and hook remain
     * active and the caller receives the failure.
     */
    private fun installFilterState(nextState: NativeFilterState) {
        filterInstallation.replace(nextState, ::registerFilterInjection)
        filterBlockedCount = 0
        filterAllowedCount = 0
    }

    private fun registerFilterInjection(state: NativeFilterState): ScriptHandler? {
        if (!state.enabled || !state.pageFiltering || !hasStart || destroyed) return null
        val source = activity.assets.open(FILTER_RUNTIME_ASSET).bufferedReader().use { it.readText() }
        val selected = selectFilterInjectionRules(state.rules)
        val cosmeticJson = mutableListOf<String>()
        val scriptletJson = mutableListOf<String>()
        var encodedBytes = 0
        fun appendEncoded(target: MutableList<String>, value: String): Boolean {
            encodedBytes += value.toByteArray(Charsets.UTF_8).size + 1
            if (encodedBytes > MAX_FILTER_INJECTION_BYTES) return false
            target += value
            return true
        }
        for (rule in selected.cosmetic) {
            if (!isSafeCosmeticSelector(rule.pattern)) continue
            val value = JSONObject().put("selector", rule.pattern).put("domain", rule.domain ?: "*")
                .put("domains", JSONArray(rule.domains)).put("excludedDomains", JSONArray(rule.excludedDomains))
                .put("exception", rule.exception).toString()
            if (!appendEncoded(cosmeticJson, value)) {
                throw IllegalStateException("页面过滤规则超过 ${MAX_FILTER_INJECTION_BYTES / (1024 * 1024)} MiB document-start 预算")
            }
        }
        for (rule in selected.scriptlets) {
            val value = JSONObject().put("domain", rule.pattern).put("name", rule.scriptlet)
                .put("domains", JSONArray(rule.domains)).put("excludedDomains", JSONArray(rule.excludedDomains))
                .put("args", JSONArray(rule.scriptletArgs)).toString()
            if (!appendEncoded(scriptletJson, value)) {
                throw IllegalStateException("页面过滤规则超过 ${MAX_FILTER_INJECTION_BYTES / (1024 * 1024)} MiB document-start 预算")
            }
        }
        val config = JSONObject()
            .put("enabled", true)
            .put("selectors", JSONArray().apply { cosmeticJson.forEach { put(JSONObject(it)) } })
            .put("scriptlets", JSONArray().apply { scriptletJson.forEach { put(JSONObject(it)) } })
            .put("snapshotId", state.snapshotId)
        if (config.toString().toByteArray(Charsets.UTF_8).size > MAX_FILTER_INJECTION_BYTES) {
            throw IllegalStateException("页面过滤规则超过 ${MAX_FILTER_INJECTION_BYTES / (1024 * 1024)} MiB document-start 预算")
        }
        return if (hasWorld) {
            val world = WebViewCompat.getExecutionWorld(webView, JavaScriptExecutionWorld.PAGE_WORLD_NAME)
            WebViewCompat.addJavaScriptOnEvent(webView, source.replace("__SITE_LENS_FILTER_CONFIG__", config.toString()), WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), world)
        } else {
            WebViewCompat.addDocumentStartJavaScript(webView, source.replace("__SITE_LENS_FILTER_CONFIG__", config.toString()), setOf("*"))
        }
    }

    private fun refreshFilterInjection() {
        filterInstallation.replace(filterState, ::registerFilterInjection)
    }

    internal fun restoreFilterInjection() { refreshFilterInjection() }

    private fun isSafeCosmeticSelector(selector: String): Boolean {
        if (selector.isBlank() || selector.length > 256 || selector.any { it == '{' || it == '}' || it == ';' }) return false
        val lower = selector.lowercase()
        if (listOf(":has-text", ":contains", ":matches-css", ":xpath", ":style", ":remove-attr", ":remove-class").any(lower::contains)) return false
        return selector.matches(Regex("^[A-Za-z0-9_.*#\\-\\[\\]=\"': >+~(),]+$"))
    }

    private fun filterAllows(request: WebResourceRequest): Boolean {
        val url = request.url
        val state = filterState
        // The document navigation remains available even when a stale or
        // degraded snapshot is active. Filtering subresources keeps the
        // browser recoverable and matches the Dart engine's document policy.
        if (request.isForMainFrame || !state.enabled) return true
        val host = url.host?.lowercase() ?: return true
        if (state.exceptions.any { host == it || host.endsWith(".$it") }) return true
        if (state.blockedDomains.any { host == it || host.endsWith(".$it") }) return false
        // shouldInterceptRequest may run off the WebView thread. Use the
        // volatile callback snapshot instead of reading a WebView property
        // from the request worker.
        val document = lastKnownUrl?.let { runCatching { Uri.parse(it) }.getOrNull() }
        val resourceType = requestResourceType(request)
        val thirdParty = document?.host?.lowercase()?.let { documentHost ->
            host != documentHost && !host.endsWith(".$documentHost") && !documentHost.endsWith(".$host")
        }
        var blocked = false
        var exception = false
        for (rule in state.rules) {
            // Cosmetic selectors and audited scriptlets run in the document;
            // they are never request-blocking rules.
            if (rule.cosmetic) continue
            if (rule.resourceTypes.isNotEmpty() && !rule.resourceTypes.contains(resourceType)) continue
            if (rule.thirdParty != null && rule.thirdParty != thirdParty) continue
            if (rule.domains.isNotEmpty() || rule.excludedDomains.isNotEmpty()) {
                val documentHost = document?.host?.lowercase() ?: continue
                if (rule.excludedDomains.any { documentHost == it || documentHost.endsWith(".$it") }) continue
                if (rule.domains.isNotEmpty() && rule.domains.none { documentHost == it || documentHost.endsWith(".$it") }) continue
            }
            val pattern = rule.pattern.lowercase()
            val matched = if (rule.hostOnly || pattern.startsWith("||")) {
                val rawExpected = pattern.removePrefix("||")
                val delimiter = rawExpected.indexOfAny(charArrayOf('/', ':', '^'))
                val expected = if (delimiter >= 0) rawExpected.substring(0, delimiter) else rawExpected
                val hostMatched = host == expected || host.endsWith(".$expected")
                if (!hostMatched) false
                else if (delimiter < 0 || rawExpected.substring(delimiter) == "^") true
                else url.toString().lowercase().contains(rawExpected.substring(delimiter).replace("^", "").replace("*", ""))
            } else {
                url.toString().lowercase().contains(pattern.replace("*", ""))
            }
            if (!matched) continue
            if (rule.exception || !rule.block) exception = true else blocked = true
        }
        return !blocked || exception
    }

    private fun requestResourceType(request: WebResourceRequest): String {
        if (request.isForMainFrame) return "document"
        val accept = request.requestHeaders.entries
            .firstOrNull { it.key.equals("Accept", ignoreCase = true) }
            ?.value
            ?.lowercase()
            ?: ""
        val path = request.url.path?.lowercase() ?: ""
        return when {
            accept.contains("javascript") || path.endsWith(".js") -> "script"
            accept.contains("text/css") || path.endsWith(".css") -> "stylesheet"
            accept.contains("image/") || path.matches(Regex(".*\\.(png|jpe?g|gif|webp|svg|ico)$")) -> "image"
            accept.contains("font/") || path.matches(Regex(".*\\.(woff2?|ttf|otf|eot)$")) -> "font"
            accept.contains("audio/") || accept.contains("video/") || path.matches(Regex(".*\\.(mp4|m4a|webm|mp3|ts|m3u8)$")) -> "media"
            accept.contains("text/html") -> "subdocument"
            accept.contains("json") || accept.contains("xml") || request.method.equals("POST", ignoreCase = true) -> "xhr"
            else -> "other"
        }
    }

    private fun redactedFilterUrl(url: Uri): String {
        val query = url.queryParameterNames.joinToString("&") { "$it=…" }
        return url.buildUpon().clearQuery().apply {
            if (query.isNotEmpty()) encodedQuery(query)
        }.build().toString()
    }

    private fun recordFilterDecision(blocked: Boolean, requestGeneration: Long, requestEpoch: Long) {
        eventDispatcher.dispatch(requestGeneration, requestEpoch) {
            if (!filterState.enabled) return@dispatch
            if (blocked) filterBlockedCount++ else filterAllowedCount++
            val total = filterBlockedCount + filterAllowedCount
            if (total % 32 == 0) emitFilterStats()
        }
    }

    private fun emitFilterStats() {
        if (!filterState.enabled) return
        val total = filterBlockedCount + filterAllowedCount
        if (total == 0) return
        event(
            "filterStats",
            JSONObject()
                .put("blocked", filterBlockedCount)
                .put("allowed", filterAllowedCount)
                .put("snapshotId", filterState.snapshotId)
                .toString(),
        )
    }
    init {
        if (purpose != HostPurpose.BROWSING && !hasProfiles) {
            webView.destroy()
            throw FlutterError("private_profile_unavailable", "独立检测 Profile 不可用，禁止共享浏览 Cookie 进行检测", null)
        }
        // Profile must be selected before any navigation, cookie/store access.
        if (profileName != null) WebViewCompat.setProfile(webView, profileName)
        if (purpose == HostPurpose.BROWSING && enhanced) {
            repeat(PRIVILEGED_SCRIPT_SLOTS) { createPrivilegedWorld(it) }
        }
        val provider = WebViewCompat.getCurrentWebViewPackage(activity)
        capabilities = HostCapabilities(platform = "Android WebView ${provider?.versionName ?: "unknown"}", isolatedScripts = enhanced, documentStart = hasStart,
            privateProbes = hasProfiles, reason = "world=$hasWorld; navigation=$hasNavigation; profile=$hasProfiles; privilegedScriptSlots=$PRIVILEGED_SCRIPT_SLOTS. Missing capabilities fail closed; no iframe or generic JavaScript bridge.")
        webView.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true
            allowFileAccess = false; allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            // Popups are supported so the host can observe them, but the app turns every
            // one of them into its own tab; a real popup window is never created.
            setSupportMultipleWindows(true); javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
        }
        if (purpose == HostPurpose.BROWSING) {
            webView.onTap = {
                runCatching { media.userGesture() }
                runCatching { event("interaction", "tap") }
            }
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false)
        webView.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY))
        webView.layout(0, 0, 1080, 1920)
        if (hasNavigation) {
            navigationListener = object : NavigationListener {
                override fun onNavigationStarted(navigation: Navigation) {
                    if (!available) return
                    activeNavigation = navigation; activePage = null
                    sslNavigation = navigation
                    sslFailures.navigate(navigation.url)
                    // The navigation must address the canonical URL the registration was
                    // fetched for; WebView normalizes `https://host` to `https://host/`
                    // before reporting it, so a raw string compare would revoke every
                    // slash-less entry. Redirects are not a second navigation start.
                    val leased = sameWebUrl(expectedUrl, navigation.url)
                    // A same-document navigation keeps the same JS world, DOM and
                    // document token. Within the same origin it is therefore safe
                    // to keep the existing lease (SPA/hash episode changes); the
                    // bridge still checks @match and origin on every GM request.
                    val sameDocumentLease = navigation.isSameDocument &&
                        leasedOrigin != null && leasedOrigin == webOrigin(navigation.url)
                    // A server-side redirect is the same in-flight navigation,
                    // but the NavigationListener may report only the final URL.
                    // Keep the lease when the final document stays on the leased
                    // origin; cross-origin redirects still fail closed.
                    val sameOriginRedirect = !navigation.isSameDocument && !navigation.isHistory && !leased &&
                        expectedUrl != null && webOrigin(expectedUrl) == webOrigin(navigation.url)
                    // This start is the entry itself: remember which navigation it
                    // is, so only that one's redirect chain can be followed.
                    if (entryFollowing && entryArmed && leased) {
                        entryNavigation = navigation; entryArmed = false
                    }
                    val entryRedirectLease = entryFollowing &&
                        entryNavigation === navigation && !navigation.isHistory &&
                        entryHops < MAX_ENTRY_REDIRECTS
                    // The toolbar arms a single, known history target after its
                    // scripts have been prepared. Consume that lease exactly at
                    // the matching navigation start; arbitrary page history is
                    // still rejected below.
                    val appHistoryLease = historyArmed && historyLoading &&
                        (leased || (expectedUrl == null && navigation.isHistory))
                    if (appHistoryLease) historyArmed = false
                    // A redirect of the entry is followed in onNavigationRedirected,
                    // where the listener proves it belongs to the same in-flight
                    // navigation the app started. A *start* that does not match the
                    // leased URL is a navigation somebody else began, so it stays
                    // fail-closed even while the entry is still resolving: an
                    // isolated world can navigate the frame from document start,
                    // which is before the commit that closes the entry window.
                    if ((navigation.isSameDocument || navigation.isHistory || !leased) &&
                        !sameDocumentLease && !sameOriginRedirect && !appHistoryLease && !entryRedirectLease) {
                        revoke(); event("scriptsSuspended", "无法确认新文档或历史恢复，特权脚本关闭直至显式刷新")
                    }
                    expectedUrl = if (sameOriginRedirect) navigation.url else null
                    // A same-document SPA/hash change does not run onPageFinished
                    // again. Emitting the normal "started" event would leave the
                    // tab permanently marked unloaded; keep the document loaded
                    // and report a distinct URL change instead.
                    if (navigation.isSameDocument && appHistoryLease) {
                        // A traversal can restore an existing JS world instead
                        // of running our freshly installed document-start code.
                        // Its old native bindings were revoked before traversal:
                        // do not grant new authority to those surviving closures.
                        revoke()
                        event("scriptsSuspended", "历史页面沿用原文档，旧脚本权限已撤销；显式刷新后恢复")
                        event("loaded", url = navigation.url)
                    } else if (sameDocumentLease) event("sameDocument", url = navigation.url)
                    else event("started", url = navigation.url)
                }
                override fun onNavigationRedirected(navigation: Navigation) {
                    if (!available) return
                    // Preparation retires SSL ownership before the next start.
                    // activeNavigation can still refer to the previous load here.
                    if (activeNavigation != navigation || sslNavigation !== navigation) return
                    sslFailures.redirected(navigation.url)
                    val leased = leasedOrigin
                    val redirected = webOrigin(navigation.url)
                    // The app's own entry navigation may follow the server's redirect
                    // chain onto the landing host until the first commit (bounded).
                    if (entryFollowing && navigation == entryNavigation && entryHops < MAX_ENTRY_REDIRECTS && redirected != null) {
                        entryHops++
                        expectedUrl = navigation.url; leasedOrigin = redirected
                        event("redirected", url = navigation.url); return
                    }
                    // A redirect may change the origin without producing a new
                    // onNavigationStarted event. Cross-origin redirects must not
                    // inherit the old document's privileged scripts.
                    if (leased != null && redirected != null && leased != redirected) {
                        revoke(); event("scriptsSuspended", "无法确认新文档或历史恢复，特权脚本关闭直至显式刷新")
                    }
                    event("redirected", url = navigation.url)
                }
                override fun onNavigationCompleted(navigation: Navigation) {
                    if (!available) return
                    if (activeNavigation != navigation) return
                    val wasHistory = historyInFlight
                    clearHistoryNavigation()
                    if (navigation.didCommit()) {
                        // The entry has resolved into a document; from here on the
                        // ordinary lease rules decide again. entryArmed needs no
                        // clearing here: claiming the window also requires
                        // entryFollowing, which this clears (as revoke() does).
                        entryFollowing = false; entryHops = 0; entryNavigation = null
                        activePage = navigation.page; event("committed", url = navigation.url)
                    } else if (wasHistory) {
                        revoke()
                        event("scriptsSuspended", "历史导航未提交，特权脚本已关闭；可继续前进或后退")
                    }
                    if (navigation.didCommitErrorPage()) { revoke(); event("networkError", "WebView committed an error page") }
                }
                override fun onPageDeleted(page: Page) { if (available && page == activePage) { revoke(); event("invalidated") } }
            }
            WebViewCompat.addNavigationListener(webView, navigationListener!!)
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                val requestGeneration = generation
                val requestEpoch = eventEpoch
                if (!available) return null
                // Keep the top-level document available so a bad or stale
                // snapshot cannot strand the user on a blank page. Subresources
                // are synchronously rejected from the in-memory snapshot.
                if (!request.isForMainFrame && !filterAllows(request)) {
                    // Media transports remain available to the native media
                    // pipeline even when a broad filter rule matches them.
                    // Keep the decision visible in diagnostics as an allowed
                    // bypass rather than returning a synthetic 204 response.
                    if (isMediaRequest(request)) {
                        recordFilterDecision(false, requestGeneration, requestEpoch)
                        return super.shouldInterceptRequest(view, request)
                    }
                    recordFilterDecision(true, requestGeneration, requestEpoch)
                    event(
                        "filtered",
                        "请求已阻止",
                        redactedFilterUrl(request.url),
                        expectedGeneration = requestGeneration,
                        expectedEpoch = requestEpoch,
                    )
                    return WebResourceResponse(
                        "text/plain",
                        "utf-8",
                        204,
                        "No Content",
                        mapOf("Cache-Control" to "no-store"),
                        ByteArrayInputStream(ByteArray(0)),
                    )
                }
                if (!request.isForMainFrame) recordFilterDecision(false, requestGeneration, requestEpoch)
                return super.shouldInterceptRequest(view, request)
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (!available) return true
                if (!request.isForMainFrame) return false
                return try {
                    // A toolbar history action has already fetched and installed
                    // the target document's scripts. Let that exact traversal
                    // continue; calling prepareNavigation/loadUrl here creates
                    // a new navigation, refreshes the page, and can consume the
                    // same history entry repeatedly. A different URL falls
                    // through to the normal navigation policy and supersedes
                    // the old one-shot history lease.
                    if (historyLoading && sameHistoryTarget(request.url.toString())) return false
                    if (runCatching { webUri(request.url.toString()) }.isFailure) return true
                    // Redirects are the same in-flight navigation, not a new lease.
                    if (purpose != HostPurpose.BROWSING || !request.isRedirect) {
                        // A page-started navigation may itself return a cross-origin
                        // 301/302. Do not install document-start scripts before that
                        // chain resolves: WebView 154 can deliver the redirect
                        // callback after the landing document has already run its
                        // injection. App-started entry navigations still install and
                        // follow their own redirect chain through navigate()/reload().
                        prepareNavigation(
                            request.url.toString(),
                            installScripts = purpose != HostPurpose.BROWSING,
                        ) { webView.loadUrl(request.url.toString()) }
                        true
                    } else {
                        false
                    }
                } catch (_: Exception) {
                    // WebView callbacks can arrive after the renderer or its
                    // navigation lease has been invalidated. Fail closed and
                    // keep the host recoverable instead of propagating into
                    // Flutter's UI thread.
                    runCatching { revoke() }
                    true
                }
            }
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                if (!available) return
                if (!hasNavigation) {
                    if (fallbackNavigationPreparing) return
                    sslFailures.navigate(url)
                    // Older providers may report only the final redirect URL.
                    // Privileged scripts are already unavailable without the
                    // navigation listener; don't mislabel that ordinary load.
                    if (expectedUrl == null) {
                        revoke()
                        event("scriptsSuspended", "Navigation lifecycle unavailable; refresh to restore page-only scripts")
                    }
                    expectedUrl = null; leasedOrigin = null
                }
                lastKnownUrl = url ?: lastKnownUrl
                runCatching { media.pageStarted() }
                // revoke() above advances generation. The started/finished pair
                // must use that new generation even for an unleased page load.
                pageLoadGeneration = generation
                pageStartedUrl = url
                event("started", url = url)
            }
            override fun onPageFinished(view: WebView, url: String?) {
                if (!available) return
                // history.pushState can change view.url before this callback
                // returns. Match the callback to the most recent page start,
                // then publish the current URL so Dart sees the SPA episode.
                // Keep the side effects inside the guard: a late callback from
                // an older load must not stop a newer refresh indicator/media
                // lifecycle or mark the newer document as loaded.
                if (pageLoadGeneration == generation &&
                    (pageStartedUrl == url || sameWebUrl(pageStartedUrl, url))) {
                    // Older providers have no NavigationListener. They still
                    // complete HTTP and about:blank traversals here.
                    clearHistoryNavigation()
                    runCatching { media.pageFinished() }
                    emitFilterStats()
                    refreshLayout?.isRefreshing = false
                    event("loaded", url = view.url ?: url)
                }
            }
            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                if (!available) { handler.cancel(); return }
                handler.cancel()
                if (sslFailures.affectsDocument(error.url, sslNavigation?.url)) {
                    refreshLayout?.isRefreshing = false
                    revoke()
                    event("certificateError", "TLS/证书验证失败，不会忽略证书错误；若启用了代理/MITM，请检查代理证书", error.url)
                }
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!available) return
                // Main-frame errors have no Navigation object. A late error
                // from the previous load must not revoke the new document.
                if (request.isForMainFrame && sslFailures.affectsDocument(request.url.toString(), sslNavigation?.url)) {
                    refreshLayout?.isRefreshing = false
                    revoke()
                    event("networkError", error.description.toString(), request.url.toString())
                }
            }
            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse) {
                if (!available) return
                if (request.isForMainFrame && sslFailures.affectsDocument(request.url.toString(), sslNavigation?.url)) {
                    refreshLayout?.isRefreshing = false
                    revoke()
                    event("httpError", "HTTP " + errorResponse.statusCode, request.url.toString())
                }
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                if (rendererGone || destroyed) return true
                rendererGone = true
                webView.unavailable = true
                generation++
                runCatching { refreshLayout?.isRefreshing = false }
                runCatching { NativeCrashStore.append(
                    activity,
                    module = "android.webview.renderer",
                    message = "网页渲染进程已退出",
                    details = buildString {
                        append("didCrash=").append(detail.didCrash()).append('\n')
                        append("rendererPriorityAtExit=").append(detail.rendererPriorityAtExit()).append('\n')
                        append("url=").append(lastKnownUrl ?: "")
                    },
                    contextValue = "host=$id generation=$generation",
                ) }
                event("hostInvalidated", "Web content process terminated; reopen browsing to recover", lastKnownUrl)
                // Never call normal media/lease/provider cleanup on a dead view.
                disposeAfterRendererGone(view)
                runCatching { onRendererGone(this@NativeWebHost) }
                return true
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onReceivedTitle(view: WebView, title: String?) { event("title", title ?: "") }
            override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                if (!available) return false
                val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
                // The popup URL is only known once the transport WebView starts loading, so
                // hand WebView a throwaway that cannot reach the network. It reports the
                // target URL, is destroyed immediately, and Flutter opens a real tab.
                val probe = WebView(activity)
                probe.settings.javaScriptEnabled = false
                probe.settings.blockNetworkLoads = true
                probe.settings.loadsImagesAutomatically = false
                var probeUrl: String? = null
                var probeDestroyed = false
                var probeReported = false
                val expire = Runnable { popupProbes[probe]?.invoke() }
                fun disposeProbe() {
                    if (probeDestroyed) return
                    probeDestroyed = true
                    mainHandler.removeCallbacks(expire)
                    popupProbes.remove(probe)
                    runCatching { (probe.parent as? ViewGroup)?.removeView(probe) }
                    runCatching { probe.destroy() }
                }
                popupProbes[probe] = ::disposeProbe
                // The popup is never attached; View.post may wait for attach.
                mainHandler.postDelayed(expire, 10_000L)
                probe.webViewClient = object : WebViewClient() {
                    private fun report(url: String?) {
                        if (probeDestroyed || probeReported || !available) return
                        probeUrl = url ?: probeUrl
                        if (url.isNullOrEmpty() || runCatching { webUri(url) }.isFailure) return
                        probeReported = true
                        event("newWindow", url)
                        // Never destroy a WebView from inside its own callback.
                        runCatching { probe.stopLoading() }
                        mainHandler.post { disposeProbe() }
                    }
                    override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                        if (request.isForMainFrame) report(request.url.toString())
                        return true
                    }
                    override fun onPageStarted(v: WebView, url: String?, favicon: Bitmap?) { report(url) }
                    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                        if (probeDestroyed) return true
                        runCatching { NativeCrashStore.append(
                            activity,
                            module = "android.webview.popup_renderer",
                            message = "弹窗网页渲染进程已退出",
                            details = "didCrash=" + detail.didCrash() +
                                " rendererPriorityAtExit=" + detail.rendererPriorityAtExit() +
                                " url=" + (probeUrl ?: ""),
                            contextValue = "host=" + id + " generation=" + generation,
                        ) }
                        disposeProbe()
                        return true
                    }
                }
                transport.webView = probe
                try {
                    resultMsg.sendToTarget()
                } catch (_: Exception) {
                    disposeProbe()
                    return false
                }
                return true
            }
            override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                if (!available) { runCatching { callback.onCustomViewHidden() }; return }
                if (customView != null) { runCatching { callback.onCustomViewHidden() }; return }
                (view.parent as? ViewGroup)?.removeView(view)
                customView = view; customCallback = callback; originalOrientation = activity.requestedOrientation
                try {
                    (activity.window.decorView as ViewGroup).addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                    customFullscreen = true
                    onFullscreenChanged(this@NativeWebHost, true)
                    event("fullscreen", "entered")
                } catch (_: RuntimeException) {
                    customView = null; customCallback = null
                    originalOrientation = null
                    customFullscreen = false
                    onFullscreenChanged(this@NativeWebHost, browserFullscreen)
                    runCatching { callback.onCustomViewHidden() }
                }
            }
            override fun onHideCustomView() { hideFullscreen() }
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) { callback.invoke(origin, false, false) }
        }
    }
    private fun event(
        kind: String,
        detail: String = "",
        url: String? = null,
        expectedGeneration: Long = generation,
        expectedEpoch: Long = eventEpoch,
    ) {
        // UI lifecycle notifications must arrive before teardown. Worker
        // diagnostics wait for the UI thread and expire with their document.
        eventDispatcher.dispatch(expectedGeneration, expectedEpoch) {
            runCatching {
                // WebView request callbacks may run on worker threads. Keep all
                // event state and Pigeon dispatch on the Android UI thread.
                if (url != null && kind in setOf("started", "loaded", "committed", "redirected", "sameDocument")) lastKnownUrl = url
                if (kind in setOf("networkError", "certificateError", "httpError")) pageError = detail
                events.onEvent(
                    HostEvent(id, expectedGeneration, kind, url ?: lastKnownUrl ?: "", detail),
                ) { _ -> }
            }.onFailure { error ->
                NativeCrashStore.append(
                    activity,
                    module = "android.webview.event",
                    message = "网页事件上报失败",
                    details = error.stackTraceToString(),
                    contextValue = "kind=$kind host=$id generation=$generation",
                )
            }
        }
    }
    fun valid(binding: ScriptBinding): Boolean = available && accepting && binding.generation == generation && bindings.contains(binding)
    private fun sameHistoryTarget(url: String?): Boolean = url != null &&
        (historyTargetUrl == url || sameWebUrl(historyTargetUrl, url))

    private fun clearHistoryNavigation() {
        historyTimeout?.let { mainHandler.removeCallbacks(it) }
        historyTimeout = null
        historyArmed = false
        historyInFlight = false
        historyLoading = false
        historyTargetUrl = null
    }

    private fun armHistoryTimeout(ticket: Long) {
        val timeout = Runnable {
            if (!available || generation != ticket || !historyInFlight) return@Runnable
            // Cancel pending script preparation as well as the UI lock. A late
            // Dart reply may not start a stale traversal after this point.
            revoke()
            event("scriptsSuspended", "历史导航超时，特权脚本已关闭；可继续前进或后退")
        }
        historyTimeout = timeout
        mainHandler.postDelayed(timeout, 15_000L)
    }

    fun revoke() {
        if (!available) return
        accepting = false; generation++; expectedUrl = null; leasedOrigin = null; pageError = null
        fallbackNavigationPreparing = false
        entryFollowing = false; entryHops = 0; entryNavigation = null; entryArmed = false
        clearHistoryNavigation()
        // Remove document-start injections after provider callbacks return.
        // Listener registrations stay with their WebView: changing any listener
        // rebuilds provider channels, racing messages from still-live documents.
        // Clearing bindings revokes all authority immediately, independently of
        // physical injection removal or the lifetime of those inert listeners.
        retiredInjections.addAll(injections)
        injections.clear()
        bindings.clear()
        if (!bridgeCleanupScheduled && retiredInjections.isNotEmpty()) {
            bridgeCleanupScheduled = true
            mainHandler.post(bridgeCleanup)
        }
        event("invalidated")
    }

    fun registerScripts(next: List<ScriptRegistration>) {
        revoke()
        requireScriptCapacity(next)
        scripts = next
    }

    private fun requireScriptCapacity(next: List<ScriptRegistration>) {
        require(!enhanced || next.count { it.privileged } <= PRIVILEGED_SCRIPT_SLOTS) {
            "当前配置最多同时启用 $PRIVILEGED_SCRIPT_SLOTS 个特权脚本，请停用部分脚本后刷新"
        }
    }

    private fun flushRetiredBridges() {
        mainHandler.removeCallbacks(bridgeCleanup)
        bridgeCleanupScheduled = false
        val oldInjections = retiredInjections.toList()
        retiredInjections.clear()
        if (!available) return
        oldInjections.forEach { runCatching { it.remove() } }
    }
    fun prepareNavigation(
        url: String,
        followEntryRedirects: Boolean = false,
        installScripts: Boolean = true,
        load: () -> Unit,
    ) {
        if (!available) return
        // Dart preparation is asynchronous. Old completion/page-deletion
        // callbacks must not consume this navigation's entry/history lease.
        activeNavigation = null
        activePage = null
        sslNavigation = null
        sslFailures.navigate(url)
        revoke(); val ticket = generation
        fallbackNavigationPreparing = !hasNavigation
        // Only the navigations the app itself starts may follow the server's own
        // redirect chain (see [entryFollowing]); everything a page starts on its
        // own keeps the strict lease rules. Page-started navigations also defer
        // script installation until an app-owned reload because a cross-origin
        // redirect may commit before WebView reports the redirect callback.
        entryFollowing = followEntryRedirects; entryHops = 0; entryNavigation = null
        entryArmed = followEntryRedirects
        if (!installScripts) {
            // revoke() defers provider removals until the current callback
            // returns. Start the next document after that queue entry, or it
            // can run the previous document-start script before removal.
            events.prepareFilterForNavigation(id, ticket, url) { result ->
                if (!available || generation != ticket) return@prepareFilterForNavigation
                if (result.isFailure) {
                    refreshLayout?.isRefreshing = false
                    fallbackNavigationPreparing = false
                    event("networkError", result.exceptionOrNull()?.message ?: "Filter navigation rejected")
                    return@prepareFilterForNavigation
                }
                mainHandler.post {
                    if (!available || generation != ticket) return@post
                    flushRetiredBridges()
                    expectedUrl = url; leasedOrigin = webOrigin(url)
                    fallbackNavigationPreparing = false
                    load()
                }
            }
            return
        }
        events.getScriptsForNavigation(id, ticket, url) { result ->
            if (!available || generation != ticket) return@getScriptsForNavigation
            if (result.isFailure) { refreshLayout?.isRefreshing = false; fallbackNavigationPreparing = false; event("networkError", result.exceptionOrNull()?.message ?: "Navigation policy rejected"); return@getScriptsForNavigation }
            try {
                scripts = result.getOrThrow()
                install(url)
                fallbackNavigationPreparing = false
                load()
            } catch (error: Exception) {
                refreshLayout?.isRefreshing = false
                runCatching { revoke() }
                event("networkError", error.message ?: "Navigation setup failed", url)
            }
        }
    }
    /**
     * Starts an app-owned history traversal after preparing the same document
     * start scripts used by a direct navigation. Calling revoke() here would
     * clear expectedUrl before NavigationListener sees the history entry and
     * would turn every toolbar back gesture into a false scriptsSuspended error.
     */
    private fun prepareHistoryNavigation(url: String?, load: () -> Unit) {
        if (!available) return
        activeNavigation = null
        activePage = null
        sslNavigation = null
        sslFailures.navigate(url)
        revoke(); historyInFlight = true; val ticket = generation
        fallbackNavigationPreparing = !hasNavigation
        entryFollowing = false; entryHops = 0; entryNavigation = null
        historyTargetUrl = url
        armHistoryTimeout(ticket)
        val targetUrl = url?.takeIf { runCatching { webUri(it) }.isSuccess }
        expectedUrl = targetUrl
        leasedOrigin = webOrigin(targetUrl)
        if (targetUrl == null) {
            // A history stack can contain about:blank or another non-web
            // entry. There is no script lease to fetch for those documents,
            // but the app-owned traversal is still a valid back/forward action.
            historyArmed = true
            historyLoading = true
            fallbackNavigationPreparing = false
            load()
            return
        }
        events.getScriptsForNavigation(id, ticket, targetUrl) { result ->
            if (!available || generation != ticket) return@getScriptsForNavigation
            if (result.isFailure) {
                refreshLayout?.isRefreshing = false
                expectedUrl = null; leasedOrigin = null
                fallbackNavigationPreparing = false
                clearHistoryNavigation()
                event("networkError", result.exceptionOrNull()?.message ?: "Navigation policy rejected")
                return@getScriptsForNavigation
            }
            try {
                scripts = result.getOrThrow()
                historyArmed = true
                historyLoading = true
                install(targetUrl)
                fallbackNavigationPreparing = false
                load()
            } catch (error: Exception) {
                refreshLayout?.isRefreshing = false
                runCatching { revoke() }
                historyInFlight = false
                historyTargetUrl = null
                event("networkError", error.message ?: "History navigation setup failed", targetUrl)
            }
        }
    }

    /** App-owned back/forward with a pre-authorized history target. */
    fun goHistory(delta: Int): Boolean {
        if (!available) return false
        if (exitFullscreen()) return true
        if (historyInFlight) return true
        val list = webView.copyBackForwardList()
        val targetIndex = list.currentIndex + delta
        if (targetIndex !in 0 until list.size) return false
        val target = list.getItemAtIndex(targetIndex)?.url
        prepareHistoryNavigation(target) {
            if (!destroyed) {
                if (delta < 0) webView.goBack() else webView.goForward()
            }
        }
        return true
    }
    private fun install(url: String) {
        // Called after the navigation-policy reply, outside provider callbacks.
        // Finish the previous generation's removals before installing another.
        flushRetiredBridges()
        requireScriptCapacity(scripts)
        expectedUrl = url; leasedOrigin = webOrigin(url); accepting = true
        if (purpose != HostPurpose.BROWSING) return
        var privilegedSlot = 0
        for (script in scripts) {
            val source = resolvedSource(script)
            if (script.privileged) {
                if (!enhanced) continue
                val token = UUID.randomUUID().toString()
                val world = privilegedWorlds[privilegedSlot++]
                val binding = ScriptBinding(script, generation, token, world); bindings.add(binding)
                injections.add(WebViewCompat.addJavaScriptOnEvent(webView, "const __lensBridgeToken = ${JSONObject.quote(token)};\n$source", WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), world))
            } else if (hasWorld) {
                val world = WebViewCompat.getExecutionWorld(webView, JavaScriptExecutionWorld.PAGE_WORLD_NAME)
                injections.add(WebViewCompat.addJavaScriptOnEvent(webView, source, WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), world))
            } else if (hasStart) {
                injections.add(WebViewCompat.addDocumentStartJavaScript(webView, source, setOf("*")))
            }
        }
    }
    private fun createPrivilegedWorld(slot: Int) {
        check(slot == privilegedWorlds.size)
        val world = WebViewCompat.getExecutionWorld(webView, "site-lens.$id.slot.$slot")
        WebViewCompat.addWebMessageListener(webView, "lensBridge", setOf("*"), world) { view, message, sourceOrigin, isMainFrame, proxy ->
            try {
                check(view === webView && isMainFrame) { "Invalid frame" }
                // A slot can be assigned a different script on a later document.
                // Resolve its current lease, then authenticate the unpredictable
                // document token; old closures can never inherit the new lease.
                val binding = bindings.firstOrNull { it.world === world && valid(it) }
                    ?: throw IllegalStateException("Document invalidated")
                val script = binding.script
                val current = webView.url ?: throw IllegalStateException("No current document")
                check(origin(webUri(current)) == origin(sourceOrigin) && matches(script, current)) { "Source is not allowed" }
                val raw = message.data ?: throw IllegalStateException("Empty message")
                check(raw.length <= 128 * 1024) { "Message too large" }
                val payload = JSONObject(raw)
                check(payload.optString("token") == binding.token) { "Invalid native document capability" }
                binding.proxy = proxy
                events.onGmRequest(GmRequest(id, binding.generation, script.id, script.revision, current, raw)) { result ->
                    if (!valid(binding) || webView.url?.let { origin(webUri(it)) == origin(sourceOrigin) && matches(script, it) } != true) return@onGmRequest
                    proxy.postMessage(result.getOrElse { JSONObject().put("id", payload.optString("id")).put("ok", false).put("error", it.message ?: "Native error").toString() })
                }
            } catch (_: Exception) { /* Unauthenticated messages never reach Dart. */ }
        }
        privilegedWorlds.add(world)
    }
    private fun resolvedSource(script: ScriptRegistration): String {
        if (script.sourcePath.isBlank()) return script.source
        val root = activity.filesDir.canonicalFile
        val file = File(script.sourcePath).canonicalFile
        require(file.path == root.path || file.path.startsWith(root.path + File.separator)) { "Script source path is outside app storage" }
        require(file.isFile) { "Script source file is unavailable" }
        val raw = file.readText(Charsets.UTF_8)
        return script.source.replace(JSONObject.quote("__SITE_LENS_SOURCE__"), JSONObject.quote(raw))
    }
    fun exitFullscreen(): Boolean { if (customView == null) return false; hideFullscreen(); return true }
    fun setManualFullscreen(value: Boolean) {
        manualFullscreen = value
        onFullscreenChanged(this, browserFullscreen)
    }
    fun forceClearFullscreen() {
        manualFullscreen = false
        customFullscreen = false
        hideFullscreen()
        onFullscreenChanged(this, false)
    }
    private fun hideFullscreen() {
        val view = customView ?: return
        (view.parent as? ViewGroup)?.removeView(view); customView = null
        if (!rendererGone) runCatching { customCallback?.onCustomViewHidden() }
        customCallback = null
        originalOrientation?.let { runCatching { activity.requestedOrientation = it } }; originalOrientation = null
        customFullscreen = false
        onFullscreenChanged(this, browserFullscreen)
        event("fullscreen", "exited")
    }
    private fun clearPopupProbes() {
        mainHandler.removeCallbacksAndMessages(null)
        popupProbes.values.toList().forEach { it() }
        popupProbes.clear()
    }
    private fun disposeAfterRendererGone(deadView: WebView) {
        if (destroyed) return
        eventEpoch++
        viewLifetime.rendererGone()
        destroyed = true
        accepting = false
        webView.onTap = null
        expectedUrl = null; leasedOrigin = null
        entryFollowing = false; entryArmed = false; entryNavigation = null
        clearHistoryNavigation()
        activeNavigation = null; activePage = null; navigationListener = null
        injections.clear(); bindings.clear(); scripts = emptyList()
        retiredInjections.clear(); privilegedWorlds.clear()
        bridgeCleanupScheduled = false
        filterInstallation.forget()
        runCatching { forceClearFullscreen() }
        runCatching { (platformView.parent as? ViewGroup)?.removeView(platformView) }
        runCatching { (deadView.parent as? ViewGroup)?.removeView(deadView) }
        runCatching { deadView.destroy() }
        runCatching { media.rendererGone() }
        // Let all affected WebViews acknowledge their own renderer callback
        // before disposing any surviving sibling probes or isolated profile.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            clearPopupProbes()
            clearProbeProfile()
        }
        onDisposed(this)
    }
    private fun clearProbeProfile() {
        profileName?.let { name -> runCatching {
            ProfileStore.getInstance().deleteProfile(name)
        } }
    }
    fun dispose() {
        dispose(force = false)
    }

    fun dispose(force: Boolean) {
        if (destroyed) return
        if (rendererGone) { disposeAfterRendererGone(webView); return }
        if (!viewLifetime.closing) {
            // Invalidate the document while the host is still available; the
            // actual provider removal remains deferred until the view release.
            runCatching { revoke() }
            eventEpoch++
            mainHandler.removeCallbacks(bridgeCleanup)
            bridgeCleanupScheduled = false
            webView.unavailable = true
            webView.onTap = null
            runCatching { clearPopupProbes() }
            runCatching { media.dispose() }
            runCatching { webView.stopLoading() }
        }
        // Flutter may still own the AndroidView. Revoke authority immediately,
        // but keep the provider alive until its platform-view dispose callback.
        if (force) runCatching { (platformView.parent as? ViewGroup)?.removeView(platformView) }
        viewLifetime.close(force)
    }

    private fun finishDispose() {
        if (destroyed) return
        if (rendererGone) { disposeAfterRendererGone(webView); return }
        eventEpoch++
        destroyed = true
        clearPopupProbes()
        runCatching { media.dispose() }
        injections.clear(); bindings.clear(); scripts = emptyList()
        retiredInjections.clear(); privilegedWorlds.clear()
        filterInstallation.forget()
        runCatching { forceClearFullscreen() }
        navigationListener?.let { runCatching { WebViewCompat.removeNavigationListener(webView, it) } }; navigationListener = null
        runCatching { webView.stopLoading() }
        runCatching { (platformView.parent as? ViewGroup)?.removeView(platformView) }
        runCatching { webView.destroy() }
        if (profileName != null) {
            // ProfileStore owns profile data cleanup. Deleting the profile
            // directly avoids touching a loaded CookieManager/WebStorage after
            // the WebView has been destroyed; loaded profiles are deferred to
            // the next process sweep when the provider rejects deletion.
            mainHandler.post { clearProbeProfile() }
        }
        onDisposed(this)
    }
}
