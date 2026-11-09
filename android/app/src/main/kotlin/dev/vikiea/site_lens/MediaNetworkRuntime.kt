package dev.vikiea.site_lens

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.webkit.WebSettings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URI
import java.util.concurrent.Executors

internal fun mediaTransferCancelled(error: Throwable): Boolean =
    generateSequence(error) { it.cause }.any { it is java.io.InterruptedIOException }

/**
 * Resumable native media transfer and LAN relay adapter.
 *
 * Network policy lives exclusively in [SystemMediaNetwork]. This class keeps
 * task ownership, authorization headers, Range validation and progress.
 */
class MediaNetworkRuntime(
    appContext: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {
    private val context = appContext.applicationContext
    private val userAgent = WebSettings.getDefaultUserAgent(appContext)
    private val main = Handler(Looper.getMainLooper())
    private val transfers = MediaTransferQueue(transferExecutor)
    private val networkListener = SystemMediaNetwork.addNetworkChangeListener {
        transfers.cancelAll()
        main.post {
            runCatching {
                channel.invokeMethod(
                    "networkChanged",
                    mapOf("networkEpoch" to SystemMediaNetwork.networkEpoch()),
                )
            }
        }
    }

    init {
        SystemMediaNetwork.initialize(context)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancelTransfer" -> {
                call.argument<String>("jobId")?.let(transfers::cancel)
                result.success(null)
            }
            "transferFile" -> enqueueTransfer(call, result)
            "relayAddress" -> {
                val receiver = call.argument<String>("url")
                executor.execute {
                    val outcome = runCatching {
                        DlnaRelayAddress.resolve(URI(receiver ?: error("缺少接收设备地址")))
                    }
                    main.post {
                        outcome.fold(
                            onSuccess = { result.success(it) },
                            onFailure = {
                                result.error(
                                    "dlna_route",
                                    "无法读取本机投屏地址，请检查与接收设备的网络连接",
                                    DlnaRelayAddress.failureDetails(it),
                                )
                            },
                        )
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        networkListener()
        transfers.cancelAll()
    }

    private fun enqueueTransfer(call: MethodCall, result: MethodChannel.Result) {
        try {
            val job = call.argument<String>("jobId") ?: "invalid"
            require(job.matches(Regex("[A-Za-z0-9_-]{1,100}"))) { "下载任务无效" }
            val attempts = mutableListOf<Map<String, Any>>()
            val resourceKind = call.argument<String>("resourceKind")
                ?.takeIf { it in setOf("manifest", "key", "segment", "map", "file") }
                ?: "file"
            val transfer = ResumableMediaTransfer(
                connectForAttempt = { uri, attempt ->
                    SystemMediaNetwork.openMediaConnection(context, uri, attempt)
                },
                networkEpochForAttempt = { SystemMediaNetwork.networkEpoch() },
                onAttempt = { diagnostics ->
                    if (attempts.size < 5) {
                        attempts += diagnostics + mapOf("resourceKind" to resourceKind)
                    }
                    if ((diagnostics["elapsedMs"] as? Long ?: 0L) >= 2_000L ||
                        diagnostics["outcome"] != "completed"
                    ) {
                        Log.i(
                            "SiteLensMediaNetwork",
                            "epoch=${SystemMediaNetwork.networkEpoch()} " +
                                "resource=$resourceKind $diagnostics",
                        )
                    }
                },
            )
            transfers.submit(job, transfer::abort, { transferFile(call, transfer, job) }) { outcome ->
                main.post {
                    outcome.fold(
                        onSuccess = {
                            result.success(
                                mapOf(
                                    "attemptsUsed" to transfer.attemptsUsed,
                                    "finalUrl" to transfer.finalUrl?.toString(),
                                    "attempts" to attempts,
                                ),
                            )
                        },
                        onFailure = { failTransfer(result, it, attempts, resourceKind) },
                    )
                }
            }
        } catch (error: Exception) {
            failTransfer(result, error)
        }
    }

    private fun failTransfer(
        result: MethodChannel.Result,
        error: Throwable,
        attempts: List<Map<String, Any>> = emptyList(),
        resourceKind: String = "file",
    ) {
        val cancelled = mediaTransferCancelled(error)
        val code = when {
            error is MediaAuthorizationException -> "media_authorization"
            cancelled -> "media_cancelled"
            else -> "media_transfer"
        }
        val details = when (error) {
            is MediaTransferFailure -> error.diagnostics() + mapOf(
                "attempts" to attempts,
                "resourceKind" to resourceKind,
                "failureCategory" to if (cancelled) "cancelled" else error.reason,
            )
            is MediaAuthorizationException -> mapOf(
                "attemptsUsed" to error.attemptsUsed,
                "httpStatus" to error.statusCode,
            )
            else -> if (cancelled) {
                mapOf(
                    "attempts" to attempts,
                    "resourceKind" to resourceKind,
                    "failureCategory" to "cancelled",
                )
            } else {
                null
            }
        }
        result.error(
            code,
            when {
                error is MediaAuthorizationException -> "下载地址需要重新授权"
                cancelled -> "媒体下载已暂停，可重试"
                else -> "媒体连接失败，已保留缓存，可重试"
            },
            details,
        )
    }

    private fun transferFile(
        call: MethodCall,
        transfer: ResumableMediaTransfer,
        job: String,
    ) {
        val url = URI(call.argument<String>("url") ?: error("缺少媒体地址"))
        val document = URI(call.argument<String>("document") ?: error("缺少来源页面"))
        SystemMediaNetwork.validateTarget(url)
        SystemMediaNetwork.validateTarget(document)
        val output = File(call.argument<String>("path") ?: error("缺少缓存文件")).canonicalFile
        val roots = listOfNotNull(
            context.filesDir.canonicalFile,
            context.getExternalFilesDir(null)?.canonicalFile,
        )
        require(roots.any { output.path.startsWith(it.path + File.separator) }) {
            "媒体缓存路径越界"
        }
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
                ) {
                    name!! to text
                } else {
                    null
                }
            }
            .toMap()
            .toMutableMap()
            .also { it.putAll(contextHeaders?.headers.orEmpty()) }
        var lastProgressAt: Long? = null
        transfer.transfer(
            url,
            document,
            output,
            userAgent,
            maxBytes = maxBytes,
            maxAttempts = call.argument<Int>("maxAttempts") ?: 5,
            startAttempt = call.argument<Int>("startAttempt") ?: 0,
            requestHeaders = requestHeaders,
            requestCookies = { target -> AndroidCookieReader.get(target.toString()) },
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
