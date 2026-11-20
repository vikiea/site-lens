package dev.vikiea.site_lens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.TimeUnit

/**
 * Bounded, invisible same-origin refresh session.
 *
 * The page is reloaded so it can re-issue its own main playlist request; that
 * request is the only thing this service adopts. It never injects user scripts,
 * opens an Activity, follows a cross-origin redirect, or returns cookie bytes.
 * The captured address is returned to the caller but is never logged: log lines
 * carry [MediaAuthRefreshPolicy.captureDigest] instead of the address.
 */
class NativeMediaAuthRefreshService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val requests = ArrayDeque<Request>()
    private var activeRequest: Request? = null
    private var webView: WebView? = null
    private var finished = false
    private var timeoutRunnable: Runnable? = null
    private var cookieSettleRunnable: Runnable? = null
    private var initialCookie = ""
    private var nextToken = 0L
    private var activeToken = 0L
    private val postedRequests = AtomicInteger(0)

    /** The page origin this service lifetime is bound to. One origin per run. */
    private var sessionCookieBaseline = ""
    private val sessionCaptures = mutableListOf<MediaAuthRefreshPolicy.CapturedPlaylist>()

    override fun onCreate() {
        super.onCreate()
        ensureForeground()
        synchronized(pendingLock) { instance = this }
        drainPending()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        activeToken = ++nextToken
        finished = true
        timeoutRunnable?.let(main::removeCallbacks)
        timeoutRunnable = null
        cookieSettleRunnable?.let(main::removeCallbacks)
        cookieSettleRunnable = null
        activeRequest?.let { request ->
            runCatching {
                request.callback(
                    result("waiting_execution", "授权刷新服务已停止"),
                )
            }
        }
        activeRequest = null
        requests.forEach { request ->
            runCatching {
                request.callback(
                    result("waiting_execution", "授权刷新服务已停止"),
                )
            }
        }
        requests.clear()
        cleanup()
        synchronized(pendingLock) {
            if (instance === this) instance = null
        }
        super.onDestroy()
    }

    private fun ensureForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "媒体授权刷新", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Site Lens")
            .setContentText("媒体授权刷新中")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, notification)
        }
    }

    private fun enqueue(request: Request) {
        requests.addLast(request)
        startNext()
    }

    private fun startNext() {
        if (activeRequest != null || requests.isEmpty()) return
        val request = requests.removeFirst()
        activeRequest = request
        try {
            refresh(request)
        } catch (error: Exception) {
            finish(
                activeToken,
                request.callback,
                result("failed", safeErrorText(error)),
            )
        }
    }

    private fun postRequest(request: Request) {
        postedRequests.incrementAndGet()
        main.post {
            postedRequests.decrementAndGet()
            if (instance === this) {
                enqueue(request)
            } else {
                runCatching {
                    request.callback(result("waiting_execution", "授权刷新服务已停止"))
                }
            }
        }
    }

    private fun refresh(request: Request) {
        val token = ++nextToken
        activeToken = token
        finished = false
        val page = parseHttp(request.pageUrl)
        val media = parseHttp(request.mediaUrl)
        require(page != null && media != null) { "媒体授权刷新地址无效" }
        val pageOrigin = origin(page)
        val refreshRequest = request
        require(refreshRequest.resourceKey.isEmpty() ||
            refreshRequest.resourceKey.matches(Regex("[0-9a-f]{64}"))) {
            "媒体资源身份无效"
        }
        sessionCaptures.clear()

        // A load of this page that already updated the cookie is only evidence
        // that the cookie is current; it says nothing about the media address,
        // so it can never stand in for a capture. Only a replay of this exact
        // task's own capture may answer without loading the page.
        val currentCookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
        when (val cached = recentRefresh(recentRefreshKey(refreshRequest), currentCookie)) {
            is RecentRefresh.Captured -> {
                main.post {
                    finish(token, refreshRequest.callback, capturedReplay(refreshRequest, cached))
                }
                return
            }
            is RecentRefresh.CookieOnly -> {
                // The task never saw an address, so a recent cookie change must
                // not turn its retry into `unchanged` without looking again.
                forgetRefresh(recentRefreshKey(refreshRequest))
            }
            null -> Unit
        }

        val view = WebView(applicationContext)
        webView = view
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        view.settings.mediaPlaybackRequiresUserGesture = true
        view.settings.setSupportMultipleWindows(false)
        view.settings.javaScriptCanOpenWindowsAutomatically = false
        view.webChromeClient = object : WebChromeClient() {
            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message?,
            ): Boolean = false
        }
        val requestsByIdentity = listOf(refreshRequest.identity())
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(
                view: WebView,
                url: String,
                favicon: android.graphics.Bitmap?,
            ) {
                val current = parseHttp(url)
                if (current == null || origin(current) != pageOrigin) {
                    finish(token, refreshRequest.callback, result("reauthorize", "授权页面来源已变化"))
                    view.stopLoading()
                }
            }

            /**
             * Runs on a WebView background thread: every state change is posted
             * to the main handler, which owns [sessionCaptures].
             */
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                val raw = request.url.toString()
                if (request.isForMainFrame) {
                    val next = parseHttp(raw)
                    if (next == null || origin(next) != pageOrigin) {
                        main.post {
                            finish(token, refreshRequest.callback, result("reauthorize", "页面尝试跨站跳转"))
                        }
                        return WebResourceResponse(
                            "text/plain",
                            "UTF-8",
                            ByteArrayInputStream(ByteArray(0)),
                        )
                    }
                    return super.shouldInterceptRequest(view, request)
                }
                val accept = runCatching { request.requestHeaders?.get("Accept") }.getOrNull()
                val isCandidate = MediaAuthRefreshPolicy.isMainPlaylist(raw, accept) &&
                    MediaAuthRefreshPolicy.isSameSessionOrigin(pageOrigin, raw)
                if (!isCandidate) return super.shouldInterceptRequest(view, request)
                val diagnostic = MediaAuthRefreshPolicy.hasUnknownQuery(raw)
                main.post {
                    adoptCapture(token, refreshRequest, pageOrigin, raw, accept, diagnostic)
                }
                return super.shouldInterceptRequest(view, request)
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val next = parseHttp(request.url.toString())
                if (next == null || origin(next) != pageOrigin) {
                    finish(token, refreshRequest.callback, result("reauthorize", "页面尝试跨站跳转"))
                    return true
                }
                return false
            }

            override fun onPageFinished(view: WebView, url: String) {
                val current = parseHttp(url)
                if (current == null || origin(current) != pageOrigin) {
                    finish(token, refreshRequest.callback, result("reauthorize", "授权页面来源已变化"))
                    return
                }
                val title = (view.title ?: "").lowercase()
                val challenge = title.contains("captcha") || title.contains("验证") ||
                    title.contains("登录") || title.contains("login") ||
                    title.contains("sign in")
                if (challenge) {
                    finish(token, refreshRequest.callback, result("reauthorize", "页面需要人工验证或登录"))
                    return
                }
                scheduleCookieSettlement(token, refreshRequest, pageOrigin, requestsByIdentity)
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    finish(token, refreshRequest.callback, result("failed", error.description?.toString()))
                }
            }
        }
        initialCookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
        sessionCookieBaseline = initialCookie
        view.loadUrl(request.pageUrl)
        timeoutRunnable = Runnable {
            if (token == activeToken && !finished) {
                finish(token, request.callback, result("waiting_execution", "授权刷新超时"))
            }
        }
        main.postDelayed(timeoutRunnable!!, TIMEOUT_MS)
    }

    /**
     * Records the page's own main playlist and answers immediately.
     *
     * Only the first qualifying request of a page load is adopted; a capture is
     * a completed refresh, so waiting for the rest of the page would only add
     * latency. Runs on the main thread.
     */
    private fun adoptCapture(
        token: Long,
        request: Request,
        pageOrigin: String,
        capturedUrl: String,
        acceptHeader: String?,
        diagnostic: Boolean,
    ) {
        if (token != activeToken || finished) return
        if (sessionCaptures.isNotEmpty()) return
        if (request.logicalIdentity.isBlank()) return
        val outcome = MediaAuthRefreshPolicy.classify(
            capturedUrl = capturedUrl,
            acceptHeader = acceptHeader,
            pageOrigin = pageOrigin,
            cookieChanged = false,
            pageSettled = false,
        )
        if (outcome !is MediaAuthRefreshPolicy.RefreshOutcome.Refreshed) return
        sessionCaptures.add(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = outcome.mediaUrl,
                pageUrl = request.pageUrl,
            ),
        )
        Log.i(
            TAG,
            "captured main playlist " + (MediaAuthRefreshPolicy.captureDigest(outcome.mediaUrl) ?: "digest-unavailable") +
                " signed=" + diagnostic,
        )
        val cookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
        val cookieChanged = cookie != sessionCookieBaseline
        if (cookieChanged || !captureReplayAllowed(request)) {
            rememberRefresh(recentRefreshKey(request), cookie, outcome.mediaUrl.takeIf { captureReplayAllowed(request) })
        }
        finish(
            token,
            request.callback,
            refreshedResult(
                request = request,
                pageOrigin = pageOrigin,
                mediaOrigin = pageOrigin,
                cookie = cookie,
                mediaUrl = outcome.mediaUrl,
                diagnostic = diagnostic.takeIf { it },
            ),
        )
    }

    private fun scheduleCookieSettlement(
        token: Long,
        request: Request,
        pageOrigin: String,
        requestsByIdentity: List<MediaAuthRefreshPolicy.RefreshRequestIdentity>,
    ) {
        cookieSettleRunnable?.let(main::removeCallbacks)
        val deadline = SystemClock.uptimeMillis() + COOKIE_SETTLE_TIMEOUT_MS

        fun settle() {
            if (token != activeToken || finished) return
            runCatching { CookieManager.getInstance().flush() }
            val cookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
            val cookieChanged = cookie != initialCookie
            if (cookieChanged) rememberRefresh(recentRefreshKey(request), cookie, null)
            // The page settled without asking for a playlist: hand the verdict
            // to the policy, which reports unchanged or page-required. A cookie
            // change alone is never a refreshed address.
            val outcome = MediaAuthRefreshPolicy.classify(
                capturedUrl = null,
                acceptHeader = null,
                pageOrigin = pageOrigin,
                cookieChanged = cookieChanged,
                pageSettled = true,
            )
            finish(token, request.callback, outcomeResult(request, pageOrigin, cookie, outcome))
        }

        fun poll() {
            if (token != activeToken || finished) return
            runCatching { CookieManager.getInstance().flush() }
            val cookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
            if (cookie != initialCookie || SystemClock.uptimeMillis() >= deadline) {
                settle()
                return
            }
            cookieSettleRunnable = Runnable { poll() }
            main.postDelayed(cookieSettleRunnable!!, COOKIE_SETTLE_INTERVAL_MS)
        }

        cookieSettleRunnable = Runnable { poll() }
        main.postDelayed(cookieSettleRunnable!!, COOKIE_SETTLE_INTERVAL_MS)
    }

    private fun finish(
        token: Long,
        callback: (Map<String, Any?>) -> Unit,
        value: Map<String, Any?>,
    ) {
        if (token != activeToken || finished) return
        finished = true
        timeoutRunnable?.let(main::removeCallbacks)
        timeoutRunnable = null
        cookieSettleRunnable?.let(main::removeCallbacks)
        cookieSettleRunnable = null
        runCatching { callback(value) }
        cleanup()
        activeRequest = null
        if (requests.isEmpty() && postedRequests.get() == 0) {
            stopSelf()
        } else {
            startNext()
        }
    }

    private fun cleanup() {
        webView?.let { view ->
            runCatching { view.stopLoading() }
            runCatching { view.webChromeClient = null }
            runCatching { view.webViewClient = WebViewClient() }
            runCatching { view.destroy() }
        }
        webView = null
    }

    private fun result(
        state: String,
        reason: String?,
        extra: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> = buildMap {
        put("state", state)
        if (reason != null) put("reason", reason)
        putAll(extra)
    }

    /**
     * The single refreshed answer. [mediaUrl] is the address the page itself
     * requested; it leaves through the platform channel and is never logged.
     */
    private fun refreshedResult(
        request: Request,
        pageOrigin: String,
        mediaOrigin: String,
        cookie: String,
        mediaUrl: String,
        diagnostic: Boolean? = null,
    ): Map<String, Any?> {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(cookie.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }
        return result(
            "refreshed",
            null,
            buildMap {
                put("taskId", request.taskId)
                put("logicalIdentity", request.logicalIdentity)
                put("pageOrigin", pageOrigin)
                put("mediaOrigin", mediaOrigin)
                put("resourceKey", request.resourceKey)
                put("cookieDigest", digest)
                put("mediaUrl", mediaUrl)
                if (diagnostic == true) put("diagnostic", DIAGNOSTIC_SIGNED_ADDRESS)
            },
        )
    }

    /** The answer for a page that settled without a usable capture. */
    private fun outcomeResult(
        request: Request,
        pageOrigin: String,
        cookie: String,
        outcome: MediaAuthRefreshPolicy.RefreshOutcome?,
    ): Map<String, Any?> {
        val mediaOrigin = recentMediaOrigin(request) ?: pageOrigin
        return when (outcome) {
            is MediaAuthRefreshPolicy.RefreshOutcome.Refreshed -> refreshedResult(
                request = request,
                pageOrigin = pageOrigin,
                mediaOrigin = mediaOrigin,
                cookie = cookie,
                mediaUrl = outcome.mediaUrl,
            )
            is MediaAuthRefreshPolicy.RefreshOutcome.Unchanged -> result(
                "unchanged",
                "授权状态已更新但没有捕获到主清单地址",
                baseExtra(request, pageOrigin),
            )
            is MediaAuthRefreshPolicy.RefreshOutcome.PageRequired -> result(
                "reauthorize",
                outcome.reason,
                baseExtra(request, pageOrigin),
            )
            null -> result(
                "reauthorize",
                MediaAuthRefreshPolicy.PAGE_REQUIRED_REASON,
                baseExtra(request, pageOrigin),
            )
        }
    }

    private fun baseExtra(
        request: Request,
        pageOrigin: String,
    ): Map<String, Any?> = mapOf(
        "taskId" to request.taskId,
        "logicalIdentity" to request.logicalIdentity,
        "pageOrigin" to pageOrigin,
        "mediaOrigin" to (recentMediaOrigin(request) ?: pageOrigin),
        "resourceKey" to request.resourceKey,
    )

    private fun recentMediaOrigin(request: Request): String? =
        parseHttp(request.mediaUrl)?.let(::origin)

    /**
     * A failure message that cannot carry an address.
     *
     * An exception thrown while parsing a media or page URL quotes that URL in
     * its message, so the text is not forwarded at all: only the exception type
     * and the log-safe hash of any URL-looking fragment survives.
     */
    private fun safeErrorText(error: Exception): String {
        val digest = error.message
            .orEmpty()
            .split(' ')
            .mapNotNull { part -> MediaAuthRefreshPolicy.captureDigest(part.trim()) }
            .firstOrNull()
        return buildString {
            append("媒体授权刷新失败")
            append(" (").append(error.javaClass.simpleName).append(')')
            if (digest != null) append(" at ").append(digest)
        }
    }

    data class Request(
        val taskId: String,
        val pageUrl: String,
        val mediaUrl: String,
        val resourceKey: String = "",
        val logicalIdentity: String = "",
        val callback: (Map<String, Any?>) -> Unit,
    ) {
        internal fun identity(): MediaAuthRefreshPolicy.RefreshRequestIdentity =
            MediaAuthRefreshPolicy.RefreshRequestIdentity(
                taskId = taskId,
                logicalIdentity = logicalIdentity,
                pageUrl = pageUrl,
                mediaUrl = mediaUrl,
            )
    }

    companion object {
        private const val TAG = "MediaAuthRefresh"
        private const val CHANNEL = "site-lens-media-auth"
        private const val ID = 24003
        private const val TIMEOUT_MS = 15_000L
        private const val BLOCKING_WAIT_MS = 8_000L
        private const val COOKIE_SETTLE_INTERVAL_MS = 250L
        private const val COOKIE_SETTLE_TIMEOUT_MS = 3_000L
        private const val RECENT_REFRESH_TTL_MS = 15_000L

        /** Diagnostic reported with an adopted address that carries a signature. */
        const val DIAGNOSTIC_SIGNED_ADDRESS = "media_url_has_unknown_query"

        /**
         * Prefix of the identity a batch page load is asked under.
         *
         * The load is shared by every task on the page, so it cannot name one:
         * the prefix keeps a probe out of the task cache, and the policy hands
         * the capture to its real owner by address.
         */
        internal const val PROBE_IDENTITY_PREFIX = "refresh:"

        internal fun probeIdentity(pageUrl: String): String = PROBE_IDENTITY_PREFIX + pageUrl.trim()

        private var instance: NativeMediaAuthRefreshService? = null
        private val pendingLock = Any()
        private val pending = ArrayDeque<Request>()
        /**
         * What a recent load by one task may replay.
         *
         * [Captured] carries the address that task's own load adopted, so a
         * repeat of the same task can be answered immediately. [CookieOnly]
         * records that the load changed cookies without producing an address;
         * it can never answer a retry, because a task that never saw an address
         * must not be told its authorization is unchanged.
         */
        private sealed class RecentRefresh {
            abstract val cookie: String
            abstract val expiresAt: Long

            data class Captured(
                override val cookie: String,
                override val expiresAt: Long,
                val mediaUrl: String,
            ) : RecentRefresh()

            data class CookieOnly(
                override val cookie: String,
                override val expiresAt: Long,
            ) : RecentRefresh()
        }

        /** Recent loads, keyed by the task that asked for them. */
        private val recentRefreshes = mutableMapOf<String, RecentRefresh>()
        private val refreshLock = Any()

        fun refresh(context: Context, request: Request) {
            val service = synchronized(pendingLock) {
                instance ?: run {
                    pending.addLast(request)
                    null
                }
            }
            if (service != null) {
                service.postRequest(request)
                return
            }
            try {
                ContextCompat.startForegroundService(
                    context.applicationContext,
                    Intent(context.applicationContext, NativeMediaAuthRefreshService::class.java),
                )
            } catch (error: Exception) {
                synchronized(pendingLock) { pending.remove(request) }
                request.callback(mapOf("state" to "waiting_execution", "reason" to (error.message ?: "系统暂不允许后台执行")))
            }
        }

        /**
         * Runs one refresh and returns as soon as the page hands over its main
         * playlist, or after [BLOCKING_WAIT_MS]. A capture is a completed
         * refresh, so the wait never extends to the end of the page load.
         */
        fun refreshBlocking(
            context: Context,
            taskId: String,
            pageUrl: String,
            mediaUrl: String,
            resourceKey: String = "",
            logicalIdentity: String = "",
        ): Map<String, Any?> {
            val latch = CountDownLatch(1)
            var value: Map<String, Any?> = mapOf("state" to "waiting_execution", "reason" to "授权刷新未执行")
            refresh(
                context,
                Request(taskId, pageUrl, mediaUrl, resourceKey, logicalIdentity) {
                    value = it
                    latch.countDown()
                },
            )
            latch.await(BLOCKING_WAIT_MS, TimeUnit.MILLISECONDS)
            return value
        }

        /**
         * Refreshes a group of requests that share one page origin with a
         * single page load, then reports one result per request.
         *
         * The group's first page URL is the navigation; every other URL in the
         * group rides on the captures from that load. A capture reaches only
         * the request whose logical identity matches. A request without a
         * capture settles on `unchanged` or `reauthorize` — never on another
         * task's address.
         */
        fun refreshBatch(
            context: Context,
            requests: List<Request>,
            callback: (List<Map<String, Any?>>) -> Unit,
        ) {
            if (requests.isEmpty()) {
                callback(emptyList())
                return
            }
            val groups = MediaAuthRefreshPolicy.groupByOrigin(requests.map { it.identity() })
            val results = java.util.Collections.synchronizedMap(LinkedHashMap<String, Map<String, Any?>>())
            val remaining = AtomicInteger(groups.size)
            if (groups.isEmpty()) {
                callback(requests.map { result("reauthorize", MediaAuthRefreshPolicy.PAGE_REQUIRED_REASON, mapOf("taskId" to it.taskId)) })
                return
            }

            fun collect() {
                if (remaining.decrementAndGet() > 0) return
                val ordered = requests.map { request ->
                    results[request.taskId]
                        ?: result(
                            "waiting_execution",
                            "授权刷新未执行",
                            mapOf("taskId" to request.taskId),
                        )
                }
                callback(ordered)
            }

            for (group in groups) {
                val pageUrl = MediaAuthRefreshPolicy.distinctPageUrls(group).firstOrNull()
                val members = requests.filter { request ->
                    group.any { identity -> identity.taskId == request.taskId }
                }
                if (pageUrl == null || members.isEmpty()) {
                    members.forEach { request ->
                        results[request.taskId] = result(
                            "reauthorize",
                            MediaAuthRefreshPolicy.PAGE_REQUIRED_REASON,
                            mapOf("taskId" to request.taskId),
                        )
                    }
                    collect()
                    continue
                }
                val lead = members.first()
                val pageRequests = group.map { identity ->
                    members.firstOrNull { it.taskId == identity.taskId } ?: lead
                }
                // One question per origin: did the page hand over a main
                // playlist? The load is shared by every task on the page, so it
                // is asked under the page's own probe identity and the capture
                // records the page it came from; finishBatch() then hands it to
                // the one member whose address it replaces.
                refresh(
                    context,
                    Request(
                        taskId = lead.taskId,
                        pageUrl = pageUrl,
                        mediaUrl = lead.mediaUrl,
                        resourceKey = lead.resourceKey,
                        logicalIdentity = probeIdentity(pageUrl),
                    ) { value ->
                        val captured = captureOf(value, pageUrl)
                        val cookieChanged = !pageRequires(value)
                        val outcomes = MediaAuthRefreshPolicy.finishBatch(
                            requests = pageRequests.map { it.identity() },
                            captured = listOfNotNull(captured),
                            cookieChanged = cookieChanged,
                        )
                        for (request in pageRequests) {
                            val outcome = outcomes[request.taskId]
                            results[request.taskId] = if (outcome == null) {
                                result(
                                    "reauthorize",
                                    MediaAuthRefreshPolicy.PAGE_REQUIRED_REASON,
                                    mapOf("taskId" to request.taskId),
                                )
                            } else {
                                batchResult(request, outcome)
                            }
                        }
                        collect()
                    },
                )
            }
        }

        /**
         * The capture a batch load produced, attributed to the page it came
         * from.
         *
         * The load is shared, so the capture cannot be attributed to the task
         * that happened to carry the load; [pageUrl] is the only fact the service
         * knows for certain, and the policy derives the owner from the address.
         */
        private fun captureOf(
            value: Map<String, Any?>,
            pageUrl: String,
        ): MediaAuthRefreshPolicy.CapturedPlaylist? {
            if (value["state"] != MediaAuthRefreshPolicy.STATE_REFRESHED) return null
            val url = value["mediaUrl"] as? String ?: return null
            if (url.isBlank()) return null
            return MediaAuthRefreshPolicy.CapturedPlaylist(url, pageUrl)
        }

        private fun batchResult(
            request: Request,
            outcome: MediaAuthRefreshPolicy.RequestOutcome,
        ): Map<String, Any?> = buildMap {
            put("taskId", request.taskId)
            put("state", outcome.state)
            put("logicalIdentity", request.logicalIdentity)
            put("resourceKey", request.resourceKey)
            outcome.reason?.let { put("reason", it) }
            outcome.mediaUrl?.let { put("mediaUrl", it) }
        }

        private fun pageRequires(value: Map<String, Any?>): Boolean =
            value["state"] == MediaAuthRefreshPolicy.STATE_REAUTHORIZE

        private fun result(
            state: String,
            reason: String?,
            extra: Map<String, Any?> = emptyMap(),
        ): Map<String, Any?> = buildMap {
            put("state", state)
            if (reason != null) put("reason", reason)
            putAll(extra)
        }

        private fun drainPending() {
            val queued = synchronized(pendingLock) {
                buildList {
                    while (pending.isNotEmpty()) add(pending.removeFirst())
                }
            }
            val service = synchronized(pendingLock) { instance } ?: return
            queued.forEach(service::postRequest)
        }

        /**
         * The cache key: one task, on one page.
         *
         * A refresh is only ever answerable for the task that asked for it, so
         * the key is the task's own identity together with its page. A batch
         * member inherits the load's key, which is why the batch marks its
         * synthesized probe identity as one that may carry a capture.
         */
        internal fun recentRefreshKey(request: Request): String =
            request.logicalIdentity.trim() + "|" + request.pageUrl.trim()

        private fun captureReplayAllowed(request: Request): Boolean =
            !request.logicalIdentity.startsWith(PROBE_IDENTITY_PREFIX)

        /**
         * A cached capture, replayed for the same task that adopted it.
         *
         * The address is this task's own adopted address, so the retry adopts
         * exactly what the earlier load produced; nothing new is learned and
         * nothing is re-authorized on another task's behalf.
         */
        private fun capturedReplay(
            request: Request,
            cached: RecentRefresh.Captured,
        ): Map<String, Any?> = result(
            MediaAuthRefreshPolicy.STATE_REFRESHED,
            null,
            buildMap {
                put("taskId", request.taskId)
                put("logicalIdentity", request.logicalIdentity)
                put("resourceKey", request.resourceKey)
                put("mediaUrl", cached.mediaUrl)
                put("replayedCapture", true)
            },
        )

        private fun recentRefresh(key: String, cookie: String): RecentRefresh? {
            val now = SystemClock.uptimeMillis()
            synchronized(refreshLock) {
                val cached = recentRefreshes[key]
                if (cached == null || cached.expiresAt <= now) {
                    recentRefreshes.remove(key)
                    return null
                }
                return cached.takeIf { it.cookie == cookie }
            }
        }

        private fun rememberRefresh(key: String, cookie: String, mediaUrl: String?) {
            synchronized(refreshLock) {
                val expiresAt = SystemClock.uptimeMillis() + RECENT_REFRESH_TTL_MS
                recentRefreshes[key] = if (mediaUrl.isNullOrBlank()) {
                    RecentRefresh.CookieOnly(cookie, expiresAt)
                } else {
                    RecentRefresh.Captured(cookie, expiresAt, mediaUrl)
                }
            }
        }

        private fun forgetRefresh(key: String) {
            synchronized(refreshLock) { recentRefreshes.remove(key) }
        }

        private fun parseHttp(raw: String): Uri? = runCatching {
            Uri.parse(raw).takeIf { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() && it.userInfo == null }
        }.getOrNull()

        private fun origin(uri: Uri): String {
            val scheme = uri.scheme!!.lowercase()
            val port = uri.port
            val defaultPort = if (scheme == "https") 443 else 80
            val suffix = if (port == -1 || port == defaultPort) "" else ":$port"
            return "$scheme://${uri.host!!.lowercase()}$suffix"
        }
    }
}
