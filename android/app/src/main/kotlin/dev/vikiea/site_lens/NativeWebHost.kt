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
import android.os.Message
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.webkit.*
import android.widget.FrameLayout
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import androidx.webkit.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.ByteArrayInputStream
import java.util.UUID

private fun webUri(value: String): Uri {
    val uri = Uri.parse(value)
    require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrEmpty() && uri.userInfo == null) { "Only credential-free HTTP(S) URLs are accepted" }
    return uri
}
private fun origin(uri: Uri): String = "${uri.scheme}://${uri.host?.lowercase()}:${if (uri.port >= 0) uri.port else if (uri.scheme == "https") 443 else 80}"

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
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
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
    private val events = WebHostEvents(engine.dartExecutor.binaryMessenger)
    private val hosts = mutableMapOf<Long, NativeWebHost>()
    private var nextNotificationId = 1000
    private val inspector = activity.assets.open("flutter_assets/web_assets/page_inspector.js").bufferedReader().use { it.readText() }
    init {
        WebHostApi.setUp(engine.dartExecutor.binaryMessenger, this)
        engine.platformViewsController.registry.registerViewFactory("site_lens/web_host", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            override fun create(context: android.content.Context, viewId: Int, args: Any?): PlatformView {
                val id = ((args as? Map<*, *>)?.get("hostId") as? Number)?.toLong() ?: -1
                val host = host(id)
                (host.platformView.parent as? ViewGroup)?.removeView(host.platformView)
                return object : PlatformView {
                    override fun getView(): View = host.platformView
                    override fun dispose() { (host.platformView.parent as? ViewGroup)?.removeView(host.platformView) }
                }
            }
        })
    }
    private fun host(id: Long): NativeWebHost = hosts[id]?.takeIf { !it.destroyed } ?: throw FlutterError("host_destroyed", "Web host no longer exists", null)
    private var isForeground = true
    override fun create(hostId: Long, purpose: HostPurpose, preferences: HostPreferences): HostCapabilities {
        // A Flutter integration test can time out after the platform create
        // reply was sent but before Dart records the session. On the next
        // test/engine generation the numeric host id is reused; dispose the
        // orphaned native host instead of making every later test fail with a
        // stale `Host already exists` error.
        hosts.remove(hostId)?.dispose()
        val host = NativeWebHost(activity, hostId, purpose, events, preferences)
        host.media.foregroundState(isForeground)
        hosts[hostId] = host
        return host.capabilities
    }
    override fun registerScripts(hostId: Long, scripts: List<ScriptRegistration>) {
        val host = host(hostId)
        require(host.purpose == HostPurpose.BROWSING || scripts.isEmpty()) { "Probe hosts cannot run user scripts" }
        host.revoke(); host.scripts = scripts
    }
    override fun applyFilter(hostId: Long, context: HostFilterContextDto, policy: FilterPolicyDto, snapshot: FilterSnapshotDto) {
        val host = host(hostId)
        require(context.hostId == hostId) { "Filter host identity mismatch" }
        require(context.generation >= host.generation) { "Filter generation is stale" }
        host.applyFilter(context, policy, snapshot)
    }
    override fun setHostActivity(hostId: Long, isCurrent: Boolean, visible: Boolean, foreground: Boolean, allowBackgroundPlayback: Boolean): Boolean =
        host(hostId).media.activity(isCurrent, visible, foreground, allowBackgroundPlayback)
    fun foreground(value: Boolean) { isForeground = value; hosts.values.forEach { it.media.foregroundState(value) } }
    override fun applyPreferences(hostId: Long, preferences: HostPreferences) { host(hostId).applyPreferences(preferences) }
    // `navigate`/`reload` are the navigations the app starts itself, so they are the
    // ones the entry-redirect switch applies to.
    override fun navigate(hostId: Long, url: String) { webUri(url); val host = host(hostId); host.prepareNavigation(url, host.preferences.followEntryRedirects) { host.webView.loadUrl(url) } }
    override fun reload(hostId: Long) { val host = host(hostId); host.prepareNavigation(host.webView.url ?: return, host.preferences.followEntryRedirects) { host.webView.reload() } }
    override fun goBack(hostId: Long): Boolean = host(hostId).goHistory(-1)
    override fun goForward(hostId: Long): Boolean = host(hostId).goHistory(1)
    override fun stop(hostId: Long) { val host = host(hostId); host.revoke(); host.webView.stopLoading() }
    override fun destroy(hostId: Long) { hosts.remove(hostId)?.dispose() }
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
    fun dispose() { hosts.values.toList().forEach { it.dispose() }; hosts.clear() }
}

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

private data class NativeFilterRule(
    val pattern: String,
    val block: Boolean,
    val cosmetic: Boolean,
    val hostOnly: Boolean,
    val domain: String? = null,
    val domains: List<String> = emptyList(),
    val excludedDomains: List<String> = emptyList(),
    val exception: Boolean = false,
    val scriptlet: String? = null,
    val scriptletArgs: List<String> = emptyList(),
)

private const val FILTER_RUNTIME_ASSET = "flutter_assets/web_assets/filter_runtime.js"

@Suppress("SetJavaScriptEnabled")
class NativeWebHost(private val activity: Activity, val id: Long, val purpose: HostPurpose, private val events: WebHostEvents, initialPreferences: HostPreferences) {
    val webView = SiteLensWebView(activity)

    /// Policy owned by Dart; the host only enforces it. `applyPreferences` keeps a
    /// live host in step with a switch the user flipped mid-session.
    val media = BrowserMediaController(
        activity,
        webView,
        purpose == HostPurpose.BROWSING,
    ) { candidate ->
        val url = candidate["url"] as? String
        if (url != null && url.isNotBlank()) event("mediaCandidate", JSONObject(candidate).toString())
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
        SwipeRefreshLayout(activity).apply {
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
    private val hasWorld = WebViewFeature.isFeatureSupported(WebViewFeature.JS_INJECTION_IN_FRAME_AND_WORLD)
    private val hasNavigation = WebViewFeature.isFeatureSupported(WebViewFeature.NAVIGATION_LISTENER)
    private val hasStart = hasWorld || WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
    private val hasProfiles = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
    private val enhanced = hasWorld && hasNavigation
    val capabilities: HostCapabilities
    var generation = 0L
    var destroyed = false
    var pageError: String? = null
    var scripts = emptyList<ScriptRegistration>()
    val bindings = mutableListOf<ScriptBinding>()
    private val injections = mutableListOf<ScriptHandler>()
    private var filterInjection: ScriptHandler? = null
    @Volatile private var filterState = NativeFilterState()
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
    private var activePage: Page? = null
    // App-owned back/forward is armed only after the target's scripts have
    // been fetched and immediately before WebView starts the history load.
    // Page-started history remains fail-closed, while the toolbar can restore
    // a known history entry without producing a false warning.
    private var historyArmed = false
    private var customView: View? = null
    private var customCallback: WebChromeClient.CustomViewCallback? = null
    private var originalOrientation: Int? = null
    private var navigationListener: NavigationListener? = null
    // WebView may update view.url through history.pushState before the matching
    // onPageFinished callback returns. Keep the URL reported at page start so
    // that callback can still be associated with the same document load.
    private var pageLoadGeneration = -1L
    private var pageStartedUrl: String? = null
    private val profileName = if (purpose == HostPurpose.BROWSING) null else "site-lens-probe-${UUID.randomUUID()}"

    fun applyFilter(context: HostFilterContextDto, policy: FilterPolicyDto, snapshot: FilterSnapshotDto) {
        check(context.hostId == id) { "Filter host identity mismatch" }
        check(context.generation >= generation) { "Filter generation is stale" }
        val rules = runCatching {
            val array = JSONArray(snapshot.rules)
            (0 until array.length()).mapNotNull { index ->
                val value = array.optJSONObject(index) ?: return@mapNotNull null
                val pattern = value.optString("pattern").trim()
                if (pattern.isEmpty()) null else NativeFilterRule(
                    pattern = pattern,
                    block = value.optBoolean("block", true),
                    cosmetic = value.optBoolean("cosmetic", false),
                    hostOnly = value.optBoolean("hostOnly", false),
                    domain = value.optString("domain").takeIf { it.isNotEmpty() },
                    domains = value.optJSONArray("domains")?.let { domains ->
                        (0 until domains.length()).mapNotNull { domains.optString(it).takeIf(String::isNotBlank) }
                    } ?: emptyList(),
                    excludedDomains = value.optJSONArray("excludedDomains")?.let { domains ->
                        (0 until domains.length()).mapNotNull { domains.optString(it).takeIf(String::isNotBlank) }
                    } ?: emptyList(),
                    exception = value.optBoolean("exception", false),
                    scriptlet = value.optString("scriptlet").takeIf { it.isNotEmpty() },
                    scriptletArgs = value.optJSONArray("scriptletArgs")?.let { args ->
                        (0 until args.length()).mapNotNull { args.optString(it).takeIf { value -> value.isNotEmpty() } }
                    } ?: emptyList(),
                )
            }
        }.getOrDefault(emptyList())
        filterState = NativeFilterState(
            enabled = policy.enabled && snapshot.state != "missing" && snapshot.state != "failed" && snapshot.state != "corrupt",
            pageFiltering = policy.pageFiltering,
            exceptions = policy.domainExceptions.map { it.lowercase() }.toSet(),
            blockedDomains = policy.blockedDomains.map { it.lowercase() }.toSet(),
            rules = rules,
            snapshotId = snapshot.id,
        )
        refreshFilterInjection()
    }

    private fun refreshFilterInjection() {
        runCatching { filterInjection?.remove() }
        filterInjection = null
        val state = filterState
        if (!state.enabled || !state.pageFiltering || !hasStart || destroyed) return
        val source = runCatching { activity.assets.open(FILTER_RUNTIME_ASSET).bufferedReader().use { it.readText() } }.getOrNull() ?: return
        val cosmetic = state.rules.filter { it.block && !it.exception && it.cosmetic && it.scriptlet == null && isSafeCosmeticSelector(it.pattern) }.map { rule ->
            JSONObject().put("selector", rule.pattern).put("domain", rule.domain ?: "*")
                .put("domains", JSONArray(rule.domains)).put("excludedDomains", JSONArray(rule.excludedDomains))
        }.take(128)
        val scriptlets = state.rules.filter { it.scriptlet != null }.map { rule ->
            JSONObject().put("domain", rule.pattern).put("name", rule.scriptlet)
                .put("args", JSONArray(rule.scriptletArgs))
        }.take(32)
        val config = JSONObject()
            .put("enabled", true)
            .put("selectors", JSONArray(cosmetic))
            .put("scriptlets", JSONArray(scriptlets))
            .put("snapshotId", state.snapshotId)
        filterInjection = runCatching {
            if (hasWorld) {
                val world = WebViewCompat.getExecutionWorld(webView, JavaScriptExecutionWorld.PAGE_WORLD_NAME)
                WebViewCompat.addJavaScriptOnEvent(webView, source.replace("__SITE_LENS_FILTER_CONFIG__", config.toString()), WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), world)
            } else WebViewCompat.addDocumentStartJavaScript(webView, source.replace("__SITE_LENS_FILTER_CONFIG__", config.toString()), setOf("*"))
        }.getOrNull()
    }

    private fun isSafeCosmeticSelector(selector: String): Boolean {
        if (selector.isBlank() || selector.length > 256 || selector.any { it == '{' || it == '}' || it == ';' }) return false
        val lower = selector.lowercase()
        if (listOf(":has-text", ":contains", ":matches-css", ":xpath", ":style", ":remove-attr", ":remove-class").any(lower::contains)) return false
        return selector.matches(Regex("^[A-Za-z0-9_.*#\\-\\[\\]=\"': >+~(),]+$"))
    }

    private fun filterAllows(url: Uri): Boolean {
        val state = filterState
        if (!state.enabled) return true
        val host = url.host?.lowercase() ?: return true
        if (state.exceptions.any { host == it || host.endsWith(".$it") }) return true
        if (state.blockedDomains.any { host == it || host.endsWith(".$it") }) return false
        val text = url.toString().lowercase()
        for (rule in state.rules) {
            // Cosmetic selectors and audited scriptlets run in the document;
            // they are never request-blocking rules.
            if (rule.cosmetic) continue
            val pattern = rule.pattern.lowercase()
            val matched = if (rule.hostOnly || pattern.startsWith("||")) {
                val rawExpected = pattern.removePrefix("||")
                val delimiter = rawExpected.indexOfAny(charArrayOf('/', ':', '^'))
                val expected = if (delimiter >= 0) rawExpected.substring(0, delimiter) else rawExpected
                host == expected || host.endsWith(".$expected")
            } else {
                text.contains(pattern.replace("*", ""))
            }
            if (matched) return !rule.block
        }
        return true
    }
    init {
        if (purpose != HostPurpose.BROWSING && !hasProfiles) {
            webView.destroy()
            throw FlutterError("private_profile_unavailable", "独立检测 Profile 不可用，禁止共享浏览 Cookie 进行检测", null)
        }
        // Profile must be selected before any navigation, cookie/store access.
        if (profileName != null) WebViewCompat.setProfile(webView, profileName)
        val provider = WebViewCompat.getCurrentWebViewPackage(activity)
        capabilities = HostCapabilities(platform = "Android WebView ${provider?.versionName ?: "unknown"}", isolatedScripts = enhanced, documentStart = hasStart,
            privateProbes = hasProfiles, reason = "world=$hasWorld; navigation=$hasNavigation; profile=$hasProfiles. Missing capabilities fail closed; no iframe or generic JavaScript bridge.")
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
                    activeNavigation = navigation; activePage = null
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
                    // The toolbar arms a single, known history target after its
                    // scripts have been prepared. Consume that lease exactly at
                    // the matching navigation start; arbitrary page history is
                    // still rejected below.
                    val appHistoryLease = historyArmed &&
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
                        !sameDocumentLease && !sameOriginRedirect && !appHistoryLease) {
                        revoke(); event("scriptsSuspended", "无法确认新文档或历史恢复，特权脚本关闭直至显式刷新")
                    }
                    expectedUrl = if (sameOriginRedirect) navigation.url else null
                    // A same-document SPA/hash change does not run onPageFinished
                    // again. Emitting the normal "started" event would leave the
                    // tab permanently marked unloaded; keep the document loaded
                    // and report a distinct URL change instead.
                    if (sameDocumentLease) event("sameDocument", url = navigation.url)
                    else event("started", url = navigation.url)
                }
                override fun onNavigationRedirected(navigation: Navigation) {
                    if (activeNavigation != navigation) return
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
                    if (activeNavigation != navigation) return
                    if (navigation.didCommit()) {
                        // The entry has resolved into a document; from here on the
                        // ordinary lease rules decide again. entryArmed needs no
                        // clearing here: claiming the window also requires
                        // entryFollowing, which this clears (as revoke() does).
                        entryFollowing = false; entryHops = 0; entryNavigation = null
                        historyArmed = false
                        activePage = navigation.page; event("committed", url = navigation.url)
                    }
                    if (navigation.didCommitErrorPage()) { revoke(); event("networkError", "WebView committed an error page") }
                }
                override fun onPageDeleted(page: Page) { if (page == activePage) { revoke(); event("invalidated") } }
            }
            WebViewCompat.addNavigationListener(webView, navigationListener!!)
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                // Keep the top-level document available so a bad or stale
                // snapshot cannot strand the user on a blank page. Subresources
                // are synchronously rejected from the in-memory snapshot.
                if (!request.isForMainFrame && !filterAllows(request.url)) {
                    event("filtered", "请求已阻止", request.url.toString())
                    return WebResourceResponse(
                        "text/plain",
                        "utf-8",
                        204,
                        "No Content",
                        mapOf("Cache-Control" to "no-store"),
                        ByteArrayInputStream(ByteArray(0)),
                    )
                }
                return super.shouldInterceptRequest(view, request)
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (!request.isForMainFrame) return false
                return try {
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
                runCatching { media.pageStarted() }
                pageLoadGeneration = generation
                pageStartedUrl = url
                if (!hasNavigation) {
                    if (expectedUrl == null) { revoke(); event("scriptsSuspended", "Navigation lifecycle unavailable; refresh to restore page-only scripts") }
                    expectedUrl = null; leasedOrigin = null
                }
                event("started", url = url)
            }
            override fun onPageFinished(view: WebView, url: String?) {
                // history.pushState can change view.url before this callback
                // returns. Match the callback to the most recent page start,
                // then publish the current URL so Dart sees the SPA episode.
                // Keep the side effects inside the guard: a late callback from
                // an older load must not stop a newer refresh indicator/media
                // lifecycle or mark the newer document as loaded.
                if (pageLoadGeneration == generation && sameWebUrl(pageStartedUrl, url)) {
                    runCatching { media.pageFinished() }
                    refreshLayout?.isRefreshing = false
                    event("loaded", url = view.url ?: url)
                }
            }
            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) { refreshLayout?.isRefreshing = false; handler.cancel(); revoke(); event("certificateError", "TLS/证书验证失败，不会忽略证书错误；若启用了代理/MITM，请检查代理证书", error.url) }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) { if (request.isForMainFrame) { refreshLayout?.isRefreshing = false; revoke(); event("networkError", error.description.toString(), request.url.toString()) } }
            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse) { if (request.isForMainFrame) { refreshLayout?.isRefreshing = false; event("httpError", "HTTP ${errorResponse.statusCode}", request.url.toString()) } }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                refreshLayout?.isRefreshing = false
                // The renderer may reject WebViewCompat cleanup calls after it
                // has gone away. Never let recovery from a renderer death turn
                // into an application crash on the UI thread.
                runCatching { revoke() }
                event("hostInvalidated", "Web content process terminated; reopen browsing to recover")
                runCatching { dispose() }
                return true
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onReceivedTitle(view: WebView, title: String?) { event("title", title ?: "") }
            override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
                // The popup URL is only known once the transport WebView starts loading, so
                // hand WebView a throwaway that cannot reach the network. It reports the
                // target URL, is destroyed immediately, and Flutter opens a real tab.
                val probe = WebView(activity)
                probe.settings.javaScriptEnabled = false
                probe.settings.blockNetworkLoads = true
                probe.settings.loadsImagesAutomatically = false
                probe.webViewClient = object : WebViewClient() {
                    private fun report(url: String?) {
                        if (!url.isNullOrEmpty() && runCatching { webUri(url) }.isSuccess) event("newWindow", url)
                        // Never destroy a WebView from inside its own callback.
                        runCatching { probe.stopLoading() }
                        probe.post { runCatching { probe.destroy() } }
                    }
                    override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                        if (request.isForMainFrame) report(request.url.toString())
                        return true
                    }
                    override fun onPageStarted(v: WebView, url: String?, favicon: Bitmap?) { report(url) }
                }
                transport.webView = probe
                try {
                    resultMsg.sendToTarget()
                } catch (_: Exception) {
                    runCatching { probe.destroy() }
                    return false
                }
                return true
            }
            override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                if (customView != null) { runCatching { callback.onCustomViewHidden() }; return }
                (view.parent as? ViewGroup)?.removeView(view)
                customView = view; customCallback = callback; originalOrientation = activity.requestedOrientation
                try {
                    (activity.window.decorView as ViewGroup).addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                    event("fullscreen", "entered")
                } catch (_: RuntimeException) {
                    customView = null; customCallback = null
                    originalOrientation = null
                    runCatching { callback.onCustomViewHidden() }
                }
            }
            override fun onHideCustomView() { hideFullscreen() }
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) { callback.invoke(origin, false, false) }
        }
    }
    private fun event(kind: String, detail: String = "", url: String? = null) {
        // Pigeon can throw while Flutter is detaching the engine, and WebView
        // may call us during renderer teardown. Host events are diagnostic;
        // losing one is safer than crashing the process.
        runCatching {
            if (kind in setOf("networkError", "certificateError", "httpError")) pageError = detail
            if (!destroyed) {
                events.onEvent(HostEvent(id, generation, kind, url ?: webView.url ?: "", detail)) { _ -> }
            }
        }
    }
    fun valid(binding: ScriptBinding): Boolean = !destroyed && accepting && binding.generation == generation && bindings.contains(binding)
    fun revoke() {
        accepting = false; generation++; expectedUrl = null; leasedOrigin = null; pageError = null
        entryFollowing = false; entryHops = 0; entryNavigation = null; entryArmed = false
        historyArmed = false
        injections.forEach { runCatching { it.remove() } }; injections.clear()
        runCatching { filterInjection?.remove() }; filterInjection = null
        bindings.forEach { runCatching { WebViewCompat.removeWebMessageListener(webView, it.world, "lensBridge") } }; bindings.clear()
        event("invalidated")
    }
    fun prepareNavigation(
        url: String,
        followEntryRedirects: Boolean = false,
        installScripts: Boolean = true,
        load: () -> Unit,
    ) {
        revoke(); val ticket = generation
        // Only the navigations the app itself starts may follow the server's own
        // redirect chain (see [entryFollowing]); everything a page starts on its
        // own keeps the strict lease rules. Page-started navigations also defer
        // script installation until an app-owned reload because a cross-origin
        // redirect may commit before WebView reports the redirect callback.
        entryFollowing = followEntryRedirects; entryHops = 0; entryNavigation = null
        entryArmed = followEntryRedirects
        if (!installScripts) {
            expectedUrl = url; leasedOrigin = webOrigin(url)
            load()
            return
        }
        events.getScriptsForNavigation(id, ticket, url) { result ->
            if (destroyed || generation != ticket) return@getScriptsForNavigation
            if (result.isFailure) { refreshLayout?.isRefreshing = false; event("networkError", result.exceptionOrNull()?.message ?: "Navigation policy rejected"); return@getScriptsForNavigation }
            try {
                scripts = result.getOrThrow()
                install(url)
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
        revoke(); val ticket = generation
        entryFollowing = false; entryHops = 0; entryNavigation = null
        val targetUrl = url?.takeIf { runCatching { webUri(it) }.isSuccess }
        expectedUrl = targetUrl
        leasedOrigin = webOrigin(targetUrl)
        if (targetUrl == null) {
            // A history stack can contain about:blank or another non-web
            // entry. There is no script lease to fetch for those documents,
            // but the app-owned traversal is still a valid back/forward action.
            historyArmed = true
            load()
            return
        }
        events.getScriptsForNavigation(id, ticket, targetUrl) { result ->
            if (destroyed || generation != ticket) return@getScriptsForNavigation
            if (result.isFailure) {
                refreshLayout?.isRefreshing = false
                expectedUrl = null; leasedOrigin = null
                event("networkError", result.exceptionOrNull()?.message ?: "Navigation policy rejected")
                return@getScriptsForNavigation
            }
            try {
                scripts = result.getOrThrow()
                historyArmed = true
                install(targetUrl)
                load()
            } catch (error: Exception) {
                refreshLayout?.isRefreshing = false
                runCatching { revoke() }
                event("networkError", error.message ?: "History navigation setup failed", targetUrl)
            }
        }
    }

    /** App-owned back/forward with a pre-authorized history target. */
    fun goHistory(delta: Int): Boolean {
        if (exitFullscreen()) return true
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
        expectedUrl = url; leasedOrigin = webOrigin(url); accepting = true
        if (purpose != HostPurpose.BROWSING) return
        for (script in scripts) {
            val source = resolvedSource(script)
            if (script.privileged) {
                if (!enhanced) continue
                val token = UUID.randomUUID().toString()
                val world = WebViewCompat.getExecutionWorld(webView, "site-lens.$id.${script.id}.$generation.$token")
                val binding = ScriptBinding(script, generation, token, world); bindings.add(binding)
                WebViewCompat.addWebMessageListener(webView, "lensBridge", setOf("*"), world) { view, message, sourceOrigin, isMainFrame, proxy ->
                    try {
                        check(view === webView && isMainFrame && valid(binding)) { "Invalid frame or document" }
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
                injections.add(WebViewCompat.addJavaScriptOnEvent(webView, "const __lensBridgeToken = ${JSONObject.quote(token)};\n$source", WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), world))
            } else if (hasWorld) {
                val world = WebViewCompat.getExecutionWorld(webView, JavaScriptExecutionWorld.PAGE_WORLD_NAME)
                injections.add(WebViewCompat.addJavaScriptOnEvent(webView, source, WebViewCompat.INJECTION_EVENT_DOCUMENT_START, setOf("*"), world))
            } else if (hasStart) {
                injections.add(WebViewCompat.addDocumentStartJavaScript(webView, source, setOf("*")))
            }
        }
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
    private fun hideFullscreen() {
        val view = customView ?: return
        (view.parent as? ViewGroup)?.removeView(view); customView = null
        runCatching { customCallback?.onCustomViewHidden() }; customCallback = null
        originalOrientation?.let { runCatching { activity.requestedOrientation = it } }; originalOrientation = null
        event("fullscreen", "exited")
    }
    fun dispose() {
        if (destroyed) return
        runCatching { media.dispose() }
        runCatching { revoke() }
        runCatching { hideFullscreen() }
        destroyed = true
        navigationListener?.let { runCatching { WebViewCompat.removeNavigationListener(webView, it) } }; navigationListener = null
        runCatching { webView.stopLoading() }
        runCatching { (platformView.parent as? ViewGroup)?.removeView(platformView) }
        runCatching { webView.destroy() }
        if (profileName != null) {
            // ProfileStore deletion of a loaded profile may be rejected. Clear the
            // isolated cookie/storage; never touch the default browsing profile.
            try {
                val profile = ProfileStore.getInstance().getProfile(profileName)
                profile?.cookieManager?.removeAllCookies(null)
                profile?.webStorage?.deleteAllData()
                ProfileStore.getInstance().deleteProfile(profileName) } catch (_: IllegalStateException) { /* Removed on next process start; see sweep below. */ }
        }
    }
}
