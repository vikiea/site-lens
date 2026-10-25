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
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Bounded, invisible same-origin refresh session used only to renew cookies
 * for an already identified media task. It never injects user scripts, opens
 * an Activity, follows a cross-origin redirect, or returns cookie bytes.
 */
class NativeMediaAuthRefreshService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var finished = false

    override fun onCreate() {
        super.onCreate()
        ensureForeground()
        instance = this
        drainPending()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        cleanup()
        if (instance === this) instance = null
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

    private fun refresh(request: Request) {
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
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val next = request.url
                if (origin(next) != pageOrigin) {
                    finish(refreshRequest.callback, result("reauthorize", "页面尝试跨站跳转"))
                    return true
                }
                return false
            }

            override fun onPageFinished(view: WebView, url: String) {
                val current = parseHttp(url)
                if (current == null || origin(current) != pageOrigin) {
                    finish(refreshRequest.callback, result("reauthorize", "授权页面来源已变化"))
                    return
                }
                val title = (view.title ?: "").lowercase()
                val challenge = title.contains("captcha") || title.contains("验证") ||
                    title.contains("登录") || title.contains("login") ||
                    title.contains("sign in")
                if (challenge) {
                    finish(refreshRequest.callback, result("reauthorize", "页面需要人工验证或登录"))
                    return
                }
                val cookie = CookieManager.getInstance().getCookie(refreshRequest.pageUrl).orEmpty()
                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(cookie.toByteArray(Charsets.UTF_8))
                    .joinToString("") { byte -> "%02x".format(byte) }
                finish(
                    refreshRequest.callback,
                    result(
                        "refreshed",
                        null,
                        mapOf(
                            "taskId" to refreshRequest.taskId,
                            "pageOrigin" to pageOrigin,
                            "mediaOrigin" to allowedMediaOrigin,
                            "resourceKey" to refreshRequest.resourceKey,
                            "cookieDigest" to digest,
                        ),
                    ),
                )
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    finish(refreshRequest.callback, result("failed", error.description?.toString()))
                }
            }
        }
        view.loadUrl(request.pageUrl)
        main.postDelayed({
            if (!finished) finish(request.callback, result("waiting_execution", "授权刷新超时"))
        }, TIMEOUT_MS)
    }

    private fun finish(callback: (Map<String, Any?>) -> Unit, value: Map<String, Any?>) {
        if (finished) return
        finished = true
        main.removeCallbacksAndMessages(null)
        runCatching { callback(value) }
        cleanup()
        stopSelf()
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
        private var instance: NativeMediaAuthRefreshService? = null
        private val pending = ArrayDeque<() -> Unit>()

        fun refresh(context: Context, request: Request) {
            val service = instance
            if (service != null) {
                service.main.post { runCatching { service.refresh(request) }.onFailure {
                    request.callback(mapOf("state" to "failed", "reason" to (it.message ?: "授权刷新失败")))
                } }
                return
            }
            pending.addLast { instance?.main?.post {
                runCatching { instance?.refresh(request) }.onFailure {
                    request.callback(mapOf("state" to "failed", "reason" to (it.message ?: "授权刷新失败")))
                }
            } }
            try {
                ContextCompat.startForegroundService(
                    context.applicationContext,
                    Intent(context.applicationContext, NativeMediaAuthRefreshService::class.java),
                )
            } catch (error: Exception) {
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
            while (pending.isNotEmpty()) pending.removeFirst().invoke()
        }

        private fun parseHttp(raw: String): Uri? = runCatching {
            Uri.parse(raw).takeIf { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() && it.userInfo == null }
        }.getOrNull()

        private fun origin(uri: Uri): String =
            "${uri.scheme}://${uri.host!!.lowercase()}${if (uri.port != -1) ":${uri.port}" else ""}"
    }
}
