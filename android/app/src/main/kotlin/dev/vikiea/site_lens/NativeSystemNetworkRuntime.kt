package dev.vikiea.site_lens

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InterruptedIOException
import java.net.URI
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import okhttp3.Call

/**
 * Dart-facing adapter for small, app-owned HTTP requests. Business policy stays
 * in Dart; socket ownership, proxy selection, DNS and TLS stay in
 * [SystemMediaNetwork].
 */
class NativeSystemNetworkRuntime(appContext: Context) : MethodChannel.MethodCallHandler {
    private val context = appContext
    private fun executor(name: String, core: Int, max: Int, queue: Int): ThreadPoolExecutor =
        ThreadPoolExecutor(
            core,
            max,
            30L,
            TimeUnit.SECONDS,
            ArrayBlockingQueue(queue),
            { runnable -> Thread(runnable, "site-lens-system-network-$name").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy(),
        )

    // Keep discovery probes from consuming the update and script lanes. The
    // probe lane still has a bounded queue for its eight-worker coordinator,
    // while update metadata always retains two native request slots.
    // Sized for the coordinator's 8 concurrent candidates. Each slot can block
    // for several seconds on a tunnel, so an undersized pool turned a slow link
    // into an immediate "busy" rejection.
    private val probeExecutor = executor("probe", core = 4, max = 8, queue = 16)
    private val updateExecutor = executor("update", core = 1, max = 2, queue = 4)
    private val generalExecutor = executor("general", core = 2, max = 2, queue = 8)
    private val main = Handler(Looper.getMainLooper())
    private val activeCalls = ConcurrentHashMap<String, Call>()
    private val cancelledRequests = ConcurrentHashMap.newKeySet<String>()
    private val pendingResults = ConcurrentHashMap<String, MethodChannel.Result>()
    private val networkListener = SystemMediaNetwork.addNetworkChangeListener {
        activeCalls.values.forEach(Call::cancel)
    }

    init {
        SystemMediaNetwork.initialize(appContext)
    }

    private fun executorFor(lane: String): ThreadPoolExecutor = when (lane.lowercase()) {
        "probe" -> probeExecutor
        "update" -> updateExecutor
        else -> generalExecutor
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancel") {
            val requestId = call.argument<String>("requestId")?.trim()
            if (requestId.isNullOrEmpty()) {
                result.error("native_network", "缺少请求 ID", null)
                return
            }
            val pending = pendingResults.remove(requestId)
            if (pending == null) {
                result.success(null)
                return
            }
            cancelledRequests += requestId
            activeCalls.remove(requestId)?.cancel()
            main.post {
                pending.error(
                    "native_network",
                    "系统网络请求已取消",
                    mapOf("category" to "cancelled"),
                )
            }
            result.success(null)
            return
        }
        if (call.method != "request") {
            result.notImplemented()
            return
        }
        val requestId = call.argument<String>("requestId")?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "sys_${UUID.randomUUID()}"
        pendingResults[requestId] = result
        val lane = call.argument<String>("lane")?.trim().orEmpty()
        try {
            executorFor(lane).execute {
                if (cancelledRequests.contains(requestId)) {
                    main.post {
                        cancelledRequests.remove(requestId)
                    }
                    return@execute
                }
                val outcome = runCatching { request(call, requestId) }
                main.post {
                    if (cancelledRequests.remove(requestId)) {
                        return@post
                    }
                    if (pendingResults.remove(requestId) == null) return@post
                    outcome.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { error ->
                            result.error(
                                "native_network",
                                "系统网络请求失败",
                                mapOf("category" to category(error)),
                            )
                        },
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            if (pendingResults.remove(requestId) != null) {
                result.error(
                    "native_network",
                    "系统网络请求繁忙，请稍后重试",
                    mapOf("category" to "busy"),
                )
            }
        }
    }

    fun dispose() {
        activeCalls.values.forEach(Call::cancel)
        activeCalls.clear()
        probeExecutor.shutdownNow()
        updateExecutor.shutdownNow()
        generalExecutor.shutdownNow()
        val pending = pendingResults.entries.toList()
        pendingResults.clear()
        cancelledRequests.clear()
        networkListener()
        main.post {
            pending.forEach { (_, result) ->
                result.error(
                    "native_network",
                    "系统网络执行器已关闭",
                    mapOf("category" to "cancelled"),
                )
            }
        }
    }

    private fun request(call: MethodCall, requestId: String): Map<String, Any?> {
        if (cancelledRequests.contains(requestId)) throw InterruptedIOException("请求已取消")
        val rawUrl = call.argument<String>("url")?.trim().orEmpty()
        val uri = URI(rawUrl)
        val method = call.argument<String>("method")?.uppercase() ?: "GET"
        val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any?, Any?>())
            .mapNotNull { (key, value) ->
                val name = key?.toString()?.trim()?.takeIf { it.isNotEmpty() }
                val text = value?.toString()
                if (name == null || text == null) null else name to text
            }
            .toMap()
        val body = call.argument<ByteArray>("body")
        val maxBytes = call.argument<Number>("maxBytes")?.toInt() ?: 2 * 1024 * 1024
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 15_000L
        val response = SystemMediaNetwork.requestBuffered(
            context = context,
            uri = uri,
            method = method,
            headers = headers,
            body = body,
            maxBytes = maxBytes,
            timeoutMs = timeoutMs,
            isCancelled = { cancelledRequests.contains(requestId) },
            registerCall = {
                activeCalls[requestId] = it
                if (cancelledRequests.contains(requestId)) it.cancel()
            },
            unregisterCall = { activeCalls.remove(requestId, it) },
        )
        return mapOf(
            "statusCode" to response.statusCode,
            "headers" to response.headers,
            "body" to response.body,
            "url" to response.finalUri.toString(),
            "networkEpoch" to response.networkEpoch,
        )
    }

    private fun category(error: Throwable): String {
        if (error is MediaRouteIOException) return error.category
        val names = generateSequence(error) { it.cause }
            .map { it::class.java.simpleName.lowercase() }
            .toList()
        return when {
            names.any { it.contains("unknownhost") } -> "dns"
            names.any { it.contains("timeout") } -> "timeout"
            names.any { it.contains("ssl") || it.contains("certificate") } -> "tls_handshake"
            names.any { it.contains("proxy") } -> "proxy_connect"
            error is InterruptedIOException -> "cancelled"
            error is IllegalArgumentException -> "route_policy"
            else -> "io"
        }
    }
}
