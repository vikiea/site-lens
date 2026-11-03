package dev.vikiea.site_lens

import android.content.Context
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
                val proxy = if (call.method == "probeRoute") {
                    SystemMediaNetwork.probeConfiguration(uri, attempt = attempt)
                } else SystemMediaNetwork.configuration(uri, attempt = attempt)
                // This is only a route hint. The connecting transport still
                // validates DNS for the DIRECT entry actually being used.
                val routeInfo = runCatching {
                    SystemMediaNetwork.routeInfo(context, uri, attempt)
                }.getOrElse {
                    SystemMediaNetwork.RouteInfo(
                        SystemMediaNetwork.RouteKind.UNKNOWN,
                        SystemMediaNetwork.DnsOwner.UNKNOWN,
                        false,
                    )
                }
                val document = call.argument<String>("document")
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                    ?.also { SystemMediaNetwork.validateTarget(URI(it)) }
                mapOf(
                    "proxy" to proxy,
                    "routeAllowsFakeIp" to routeInfo.fakeIpAllowed,
                    "fakeIpAllowed" to routeInfo.fakeIpAllowed,
                    "routeKind" to routeInfo.kind.wireName,
                    "dnsOwner" to routeInfo.dnsOwner.wireName,
                    "networkEpoch" to networkEpoch,
                    "requestContextId" to MediaRequestContextRegistry
                        .latest(uri.toString(), document?.toString().orEmpty())?.id,
                    "userAgent" to userAgent,
                )
            }
            main.post { outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { result.error("media_route", "无法使用系统代理，请检查代理设置后重试", null) },
            ) }
        }
    }

    private fun enqueueTransfer(call: MethodCall, result: MethodChannel.Result) {
        try {
            val job = call.argument<String>("jobId") ?: "invalid"
            require(job.matches(Regex("[A-Za-z0-9_-]{1,100}"))) { "下载任务无效" }
            var selectedRoute = "unknown"
            val transfer = ResumableMediaTransfer(
                connectForAttempt = { uri, attempt ->
                    val routeAllowsFakeIp = isSystemDnsRouteAllowed(uri, attempt)
                    selectedRoute = "unknown"
                    SystemMediaNetwork.openConnection(uri, allowProxyFakeIp = routeAllowsFakeIp, attempt = attempt,
                        onSelectedRoute = { selectedRoute = it })
                },
                routeForConnection = { selectedRoute },
            )
            transfers.submit(job, transfer::abort, { transferFile(call, transfer, job) }) { outcome ->
                main.post { outcome.fold(
                    onSuccess = { result.success(null) },
                    onFailure = { failTransfer(result, it) },
                ) }
            }
        } catch (error: Exception) {
            failTransfer(result, error)
        }
    }

    private fun failTransfer(result: MethodChannel.Result, error: Throwable) {
        val code = if (error is MediaAuthorizationException) "media_authorization" else "media_transfer"
        val details = (error as? MediaTransferFailure)?.diagnostics()
        result.error(code, error.message ?: "媒体连接失败，已保留缓存，可重试", details)
    }

    /**
     * Returns a route capability without resolving the origin. The actual
     * DIRECT connection resolves through the active system DNS only after PAC
     * has selected DIRECT, then validates public or Fake-IP answers.
     */
    private fun isSystemDnsRouteAllowed(uri: URI, attempt: Int): Boolean =
        runCatching { SystemMediaNetwork.routeInfo(context, uri, attempt).fakeIpAllowed }
            .getOrDefault(false)

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
                requestHeaders = requestHeaders,
                requestCookies = { target ->
                    AndroidCookieReader.get(target.toString())
                        ?: AndroidCookieReader.get(document.toString())
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
