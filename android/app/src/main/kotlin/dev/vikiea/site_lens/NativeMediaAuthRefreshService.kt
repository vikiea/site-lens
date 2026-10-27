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
 * Bounded, invisible same-origin refresh session used only to renew cookies
 * for an already identified media task. It never injects user scripts, opens
 * an Activity, follows a cross-origin redirect, or returns cookie bytes.
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
                result("failed", error.message ?: "授权刷新失败"),
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
        val allowedMediaOrigin = origin(media)
        val refreshRequest = request
        require(refreshRequest.resourceKey.isEmpty() ||
            refreshRequest.resourceKey.matches(Regex("[0-9a-f]{64}"))) {
            "媒体资源身份无效"
        }
        val currentCookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
        val cachedRefresh = recentRefresh(pageOrigin, currentCookie)
        if (cachedRefresh) {
            finish(token,
                refreshRequest.callback,
                refreshedResult(refreshRequest, pageOrigin, allowedMediaOrigin, currentCookie),
            )
            return
        }
        // This service only refreshes same-origin cookies. It cannot discover
        // or replace a signed media URL, so retrying a URL with query
        // credentials would repeat the expired authorization unchanged.
        if (requiresUrlReauthorization(media)) {
            finish(token,
                refreshRequest.callback,
                result("reauthorize", "媒体地址需要播放页重新授权"),
            )
            return
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

            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                if (request.isForMainFrame) {
                    val next = parseHttp(request.url.toString())
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
                scheduleCookieSettlement(
                    token,
                    refreshRequest,
                    pageOrigin,
                    allowedMediaOrigin,
                )
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
        view.loadUrl(request.pageUrl)
        timeoutRunnable = Runnable {
            if (token == activeToken && !finished) {
                finish(token, request.callback, result("waiting_execution", "授权刷新超时"))
            }
        }
        main.postDelayed(timeoutRunnable!!, TIMEOUT_MS)
    }

    private fun scheduleCookieSettlement(
        token: Long,
        request: Request,
        pageOrigin: String,
        mediaOrigin: String,
    ) {
        cookieSettleRunnable?.let(main::removeCallbacks)
        val deadline = SystemClock.uptimeMillis() + COOKIE_SETTLE_TIMEOUT_MS

        fun poll() {
            if (token != activeToken || finished) return
            runCatching { CookieManager.getInstance().flush() }
            val cookie = CookieManager.getInstance().getCookie(request.pageUrl).orEmpty()
            if (cookie != initialCookie) {
                rememberRefresh(pageOrigin, cookie)
                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(cookie.toByteArray(Charsets.UTF_8))
                    .joinToString("") { byte -> "%02x".format(byte) }
                finish(token, request.callback, refreshedResult(request, pageOrigin, mediaOrigin, cookie, digest))
                return
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                finish(token,
                    request.callback,
                    result("reauthorize", "授权状态未更新，请返回播放页重新授权"),
                )
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

    private fun refreshedResult(
        request: Request,
        pageOrigin: String,
        mediaOrigin: String,
        cookie: String,
        digestOverride: String? = null,
    ): Map<String, Any?> {
        val digest = digestOverride ?: MessageDigest.getInstance("SHA-256")
            .digest(cookie.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }
        return result(
            "refreshed",
            null,
            mapOf(
                "taskId" to request.taskId,
                "pageOrigin" to pageOrigin,
                "mediaOrigin" to mediaOrigin,
                "resourceKey" to request.resourceKey,
                "cookieDigest" to digest,
            ),
        )
    }

    private fun requiresUrlReauthorization(uri: Uri): Boolean =
        uri.queryParameterNames.any { it.lowercase() !in NON_AUTH_MEDIA_QUERY_KEYS }

    data class Request(
        val taskId: String,
        val pageUrl: String,
        val mediaUrl: String,
        val resourceKey: String = "",
        val callback: (Map<String, Any?>) -> Unit,
    )

    companion object {
        private const val CHANNEL = "site-lens-media-auth"
        private const val ID = 24003
        private const val TIMEOUT_MS = 15_000L
        private const val COOKIE_SETTLE_INTERVAL_MS = 250L
        private const val COOKIE_SETTLE_TIMEOUT_MS = 3_000L
        private const val RECENT_REFRESH_TTL_MS = 15_000L
        private val NON_AUTH_MEDIA_QUERY_KEYS = setOf(
            "quality",
            "audio",
            "format",
            "type",
            "profile",
            "resolution",
            "codec",
            "lang",
            "language",
            "track",
            "channel",
            "bitrate",
            "width",
            "height",
            "fps",
            "variant",
            "version",
            "v",
            "source",
            "episode",
            "season",
            "start",
            "offset",
            "range",
            "download",
            "filename",
            "container",
        )
        private var instance: NativeMediaAuthRefreshService? = null
        private val pendingLock = Any()
        private val pending = ArrayDeque<Request>()
        private data class RecentRefresh(val cookie: String, val expiresAt: Long)
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

        fun refreshBlocking(
            context: Context,
            taskId: String,
            pageUrl: String,
            mediaUrl: String,
            resourceKey: String = "",
        ): Map<String, Any?> {
            val latch = CountDownLatch(1)
            var value: Map<String, Any?> = mapOf("state" to "waiting_execution", "reason" to "授权刷新未执行")
            refresh(context, Request(taskId, pageUrl, mediaUrl, resourceKey) {
                value = it
                latch.countDown()
            })
            latch.await(TIMEOUT_MS + 2_000L, TimeUnit.MILLISECONDS)
            return value
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

        private fun recentRefresh(origin: String, cookie: String): Boolean {
            val now = SystemClock.uptimeMillis()
            synchronized(refreshLock) {
                val cached = recentRefreshes[origin]
                if (cached == null || cached.expiresAt <= now) {
                    recentRefreshes.remove(origin)
                    return false
                }
                return cached.cookie == cookie
            }
        }

        private fun rememberRefresh(origin: String, cookie: String) {
            synchronized(refreshLock) {
                recentRefreshes[origin] = RecentRefresh(
                    cookie,
                    SystemClock.uptimeMillis() + RECENT_REFRESH_TTL_MS,
                )
            }
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
