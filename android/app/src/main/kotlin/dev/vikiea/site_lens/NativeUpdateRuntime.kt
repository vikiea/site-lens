package dev.vikiea.site_lens

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** MethodChannel adapter; all durable work lives in [NativeUpdateService]. */
class NativeUpdateRuntime(context: Context) {
    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "site-lens-update-channel").apply { isDaemon = true }
    }
    @Volatile private var channel: MethodChannel? = null
    @Volatile private var disposed = false
    @Volatile private var pendingOpenRoute = false

    fun attach(channel: MethodChannel) {
        this.channel = channel
        NativeUpdateService.setEventSink { method, arguments ->
            main.post {
                if (!disposed) this.channel?.invokeMethod(method, arguments)
            }
        }
        if (pendingOpenRoute) {
            main.post { if (!disposed) this.channel?.invokeMethod("openUpdateRoute", null) }
        }
    }

    fun dispose() {
        disposed = true
        channel = null
        NativeUpdateService.setEventSink(null)
        executor.shutdownNow()
    }

    fun handleIntent(intent: Intent?) {
        if (intent?.action != NativeUpdateService.ACTION_OPEN_UPDATE_ROUTE) return
        pendingOpenRoute = true
        main.post { if (!disposed) channel?.invokeMethod("openUpdateRoute", null) }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (disposed) {
            result.error("update_backend_disposed", "更新桥接已释放", null)
            return true
        }
        val method = call.method
        if (method !in setOf("startDownload", "queryDownload", "pauseDownload", "deleteDownload", "deleteStaleDownloads")) return false
        executor.execute {
            val outcome = runCatching {
                when (method) {
                    "startDownload" -> NativeUpdateService.start(context, request(call))
                    "queryDownload" -> NativeUpdateService.query(context).toMutableMap().apply {
                        if (pendingOpenRoute) {
                            put("openUpdateRoute", true)
                            pendingOpenRoute = false
                        }
                    }
                    "pauseDownload" -> NativeUpdateService.pause(context)
                    "deleteDownload" -> NativeUpdateService.delete(context, deleteRequest(call))
                    "deleteStaleDownloads" -> NativeUpdateService.deleteStale(
                        context,
                        call.argument<String>("keepTag") ?: error("缺少保留更新标签"),
                    )
                    else -> error("不支持的更新操作")
                }
            }
            main.post {
                if (disposed) {
                    result.error("update_backend_disposed", "更新桥接已释放", null)
                    return@post
                }
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { error -> result.error("update_backend", error.message ?: "更新服务不可用", null) },
                )
            }
        }
        return true
    }

    private fun request(call: MethodCall): NativeUpdateService.UpdateRequest {
        val tag = call.argument<String>("tagName") ?: error("缺少更新标签")
        val sha = call.argument<String>("sha256") ?: error("缺少更新校验值")
        val url = call.argument<String>("apkUrl") ?: error("缺少更新地址")
        val name = call.argument<String>("apkName") ?: error("缺少更新文件名")
        val size = call.argument<Number>("apkSize")?.toInt() ?: 0
        return NativeUpdateService.UpdateRequest(tag, sha, url, name, size)
    }

    private fun deleteRequest(call: MethodCall): NativeUpdateService.UpdateRequest {
        val tag = call.argument<String>("tagName") ?: error("缺少更新标签")
        val sha = call.argument<String>("sha256") ?: "0".repeat(64)
        val name = call.argument<String>("apkName") ?: "site-lens-$tag.apk"
        val url = "https://github.com/vikiea/site-lens/releases/download/$tag/$name"
        return NativeUpdateService.UpdateRequest(tag, sha, url, name, 0).also { it.validate() }
    }
}
