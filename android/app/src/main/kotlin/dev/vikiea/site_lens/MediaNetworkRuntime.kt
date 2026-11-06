package dev.vikiea.site_lens

import android.content.Context
import android.util.Log
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.webkit.WebSettings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.util.concurrent.Executors
import java.io.File

class MediaNetworkRuntime(
    appContext: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {
    private val context = appContext
    private val userAgent = WebSettings.getDefaultUserAgent(appContext)
    private val main = Handler(Looper.getMainLooper())
    private val transfers = MediaTransferQueue(transferExecutor)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancelTransfer") {
            val job = call.argument<String>("jobId")
            if (job != null) transfers.cancel(job)
            result.success(null)
            return
        }
        if (call.method == "activeRoute") {
            // Proxy/VPN snapshot without DNS so a broken resolver cannot make
            // a WebView error diagnostic fail on its own.
            executor.execute {
                val outcome = runCatching {
                    val url = (call.argument<String>("url") ?: "")
                        .trim()
                        .takeIf { it.isNotEmpty() }
                        ?.let { runCatching { URI(it) }.getOrNull() }
                    val info = SystemMediaNetwork.activeRouteInfo(context, url)
                    mapOf(
                        "routeKind" to info.kind.wireName,
                        "dnsOwner" to info.dnsOwner.wireName,
                        "proxyConfigured" to info.proxyConfigured,
                        "directAllowed" to info.directAllowed,
                        "targetDnsMode" to info.targetDnsMode,
                        "vpnTransport" to info.vpnTransport,
                    )
                }
                main.post { outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("media_route", "无法读取当前代理设置", null) },
                ) }
            }
            return
        }
        if (call.method == "transferFile") {
            enqueueTransfer(call, result)
            return
        }
        if (call.method == "relayAddress") {
            val receiver = call.argument<String>("url")
            executor.execute {
                val outcome = runCatching {
                    DlnaRelayAddress.resolve(URI(receiver ?: error("缺少接收设备地址")))
                }
                main.post { outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("dlna_route", "无法读取本机投屏地址，请检查与接收设备的网络连接", DlnaRelayAddress.failureDetails(it)) },
                ) }
            }
            return
        }
        if (call.method != "route" && call.method != "probeRoute") { result.notImplemented(); return }
        executor.execute {
            val outcome = runCatching {
                val uri = URI(call.argument<String>("url") ?: error("缺少媒体地址"))
                val attempt = call.argument<Int>("attempt") ?: 0
                val networkEpoch = call.argument<Int>("networkEpoch") ?: 0
                val plan = SystemMediaNetwork.routePlan(context, uri, attempt)
                val routeInfo = plan.info
                val strategy = routeInfo.kind
                val proxy = SystemMediaNetwork.configuration(plan)
                val document = call.argument<String>("document")
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                    ?.also { SystemMediaNetwork.validateTarget(URI(it)) }
                mapOf(
                    "proxy" to proxy,
                    "routeAllowsFakeIp" to (
                        strategy == SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP ||
                            strategy == SystemMediaNetwork.RouteKind.ROUTER_FAKE_IP
                    ),
                    "fakeIpAllowed" to (
                        strategy == SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP ||
                            strategy == SystemMediaNetwork.RouteKind.ROUTER_FAKE_IP
                    ),
                    "routeKind" to strategy.wireName,
                    "dnsOwner" to routeInfo.dnsOwner.wireName,
                    "proxyConfigured" to routeInfo.proxyConfigured,
                    "preferVpnTun" to routeInfo.preferVpnTun,
                    "directAllowed" to routeInfo.directAllowed,
                    "dnsClass" to routeInfo.dnsClass,
                    "targetDnsMode" to routeInfo.targetDnsMode,
                    "vpnTransport" to routeInfo.vpnTransport,
                    "networkEpoch" to networkEpoch,
                    "requestContextId" to MediaRequestContextRegistry
                        .latest(uri.toString(), document.orEmpty())?.id,
                    "userAgent" to userAgent,
                )
            }
            main.post { outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = {
                    result.error(
                        "media_route",
                        "无法使用系统代理，请检查代理设置后重试",
                        mapOf("category" to routeFailureCategory(it)),
                    )
                },
            ) }
        }
    }

    private fun routeFailureCategory(error: Throwable): String {
        val names = generateSequence(error) { it.cause }
            .map { it::class.java.simpleName.lowercase() }
            .toList()
        return when {
            names.any { it.contains("unknownhost") } -> "dns"
            names.any { it.contains("sockettimeout") || it.contains("timeout") } -> "timeout"
            names.any { it.contains("sslpeer") || it.contains("certificate") } -> "certificate"
            names.any { it.contains("ssl") || it.contains("tls") } -> "tls_handshake"
            names.any { it.contains("protocol") || it.contains("proxy") } -> "proxy_connect"
            error is IllegalArgumentException -> "route_policy"
            else -> "route"
        }
    }

    private fun enqueueTransfer(call: MethodCall, result: MethodChannel.Result) {
        try {
            val job = call.argument<String>("jobId") ?: "invalid"
            require(job.matches(Regex("[A-Za-z0-9_-]{1,100}"))) { "下载任务无效" }
            var selectedRoute = "unknown"
            var targetDnsMode = "unknown"
            val attempts = mutableListOf<Map<String, Any>>()
            val resourceKind = call.argument<String>("resourceKind")
                ?.takeIf { it in setOf("manifest", "key", "segment", "map", "file") } ?: "file"
            val networkEpoch = call.argument<Int>("networkEpoch") ?: 0
            val transfer = ResumableMediaTransfer(
                connectForAttempt = { uri, attempt ->
                    selectedRoute = "unknown"
                    targetDnsMode = "unknown"
                    SystemMediaNetwork.openMediaConnection(context, uri, attempt) { info ->
                        selectedRoute = info.kind.wireName
                        targetDnsMode = info.targetDnsMode
                    }
                },
                routeForConnection = { selectedRoute },
                dnsModeForConnection = { targetDnsMode },
                networkEpochForAttempt = { SystemMediaNetwork.networkEpoch() },
                routeBeforeConnect = { selectedRoute },
                context = context,
                onAttempt = { diagnostics ->
                    if (attempts.size < 5) attempts += diagnostics + mapOf("resourceKind" to resourceKind)
                    if ((diagnostics["elapsedMs"] as? Long ?: 0L) >= 2_000L ||
                        diagnostics["outcome"] != "completed") {
                        Log.i("SiteLensMediaNetwork", "epoch=$networkEpoch resource=$resourceKind $diagnostics")
                    }
                },
            )
            transfers.submit(job, transfer::abort, { transferFile(call, transfer, job) }) { outcome ->
                main.post { outcome.fold(
                    onSuccess = { result.success(mapOf("attemptsUsed" to transfer.attemptsUsed, "finalUrl" to transfer.finalUrl?.toString(), "attempts" to attempts)) },
                    onFailure = { failTransfer(result, it, attempts, resourceKind) },
                ) }
            }
        } catch (error: Exception) {
            failTransfer(result, error)
        }
    }

    private fun failTransfer(result: MethodChannel.Result, error: Throwable, attempts: List<Map<String, Any>> = emptyList(), resourceKind: String = "file") {
        val code = if (error is MediaAuthorizationException) "media_authorization" else "media_transfer"
        val details = when (error) {
            is MediaTransferFailure -> error.diagnostics() + mapOf("attempts" to attempts, "resourceKind" to resourceKind)
            is MediaAuthorizationException -> mapOf(
                "attemptsUsed" to error.attemptsUsed, "httpStatus" to error.statusCode,
            )
            else -> null
        }
        result.error(code, if (error is MediaAuthorizationException) "下载地址需要重新授权"
            else "媒体连接失败，已保留缓存，可重试", details)
    }

    private fun transferFile(call: MethodCall, transfer: ResumableMediaTransfer, job: String) {
            val url = URI(call.argument<String>("url") ?: error("缺少媒体地址"))
            val document = URI(call.argument<String>("document") ?: error("缺少来源页面"))
            SystemMediaNetwork.validateTarget(url)
            SystemMediaNetwork.validateTarget(document)
            val output = File(call.argument<String>("path") ?: error("缺少缓存文件")).canonicalFile
            val roots = listOfNotNull(context.filesDir.canonicalFile, context.getExternalFilesDir(null)?.canonicalFile)
            require(roots.any { output.path.startsWith(it.path + File.separator) }) { "媒体缓存路径越界" }
            require(output.name.endsWith(".part")) { "媒体缓存目标无效" }
            val maxBytes = call.argument<Number>("maxBytes")?.toLong() ?: 0L
            require(maxBytes in 1..(2L * 1024 * 1024 * 1024)) { "媒体大小上限无效" }
            val contextId = call.argument<String>("requestContextId")
            val contextHeaders = MediaRequestContextRegistry.get(contextId)
                ?: MediaRequestContextRegistry.latest(
                    call.argument<String>("url").orEmpty(),
                    call.argument<String>("document").orEmpty(),
                )
            val requestHeaders = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any?, Any?>())
                .mapNotNull { (key, value) ->
                    val name = key?.toString()?.trim()?.lowercase()
                    val text = value?.toString()?.trim()
                    if (name in setOf("x-cdn-auth", "x-cdn-app") &&
                        !text.isNullOrEmpty() && text.length <= 512
                    ) name!! to text else null
                }
                .toMap()
                .toMutableMap()
                .also { it.putAll(contextHeaders?.headers.orEmpty()) }
            var lastProgressAt: Long? = null
            transfer.transfer(url, document, output, userAgent, maxBytes = maxBytes,
                maxAttempts = call.argument<Int>("maxAttempts") ?: 5,
                startAttempt = call.argument<Int>("startAttempt") ?: 0,
                requestHeaders = requestHeaders,
                requestCookies = { target ->
                    AndroidCookieReader.get(target.toString())
                },
                onProgress = { bytes, _ ->
                    val now = SystemClock.elapsedRealtime()
                    if (lastProgressAt == null || now - lastProgressAt!! >= 250L) {
                        lastProgressAt = now
                        main.post {
                            channel.invokeMethod(
                                "transferProgress",
                                mapOf("jobId" to job, "bytesDownloaded" to bytes),
                            )
                        }
                    }
                },
            )
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor()
        private val transferExecutor = Executors.newFixedThreadPool(2)
    }
}
