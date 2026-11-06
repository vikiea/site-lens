package dev.vikiea.site_lens

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Dart-facing adapter for small, app-owned HTTP requests. Business policy stays
 * in Dart; socket ownership, proxy selection, DNS and TLS stay in
 * [SystemMediaNetwork].
 */
class NativeSystemNetworkRuntime(appContext: Context) : MethodChannel.MethodCallHandler {
    private val context = appContext
    private val executor: ExecutorService = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "request") {
            result.notImplemented()
            return
        }
        executor.execute {
            val outcome = runCatching { request(call) }
            main.post {
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
    }

    fun dispose() {
        executor.shutdownNow()
    }

    private fun request(call: MethodCall): Map<String, Any?> {
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
        val attempt = call.argument<Int>("attempt") ?: 0
        val response = SystemMediaNetwork.requestBuffered(
            context = context,
            uri = uri,
            method = method,
            headers = headers,
            body = body,
            maxBytes = maxBytes,
            attempt = attempt,
        )
        return mapOf(
            "statusCode" to response.statusCode,
            "headers" to response.headers,
            "body" to response.body,
            "url" to response.finalUri.toString(),
            "routeKind" to response.routeKind,
            "targetDnsMode" to response.targetDnsMode,
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
            error is IllegalArgumentException -> "route_policy"
            else -> "io"
        }
    }
}
