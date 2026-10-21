package dev.vikiea.site_lens

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebSettings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress
import java.net.URI
import java.util.concurrent.Executors
import java.io.File

class MediaNetworkRuntime(appContext: Context) : MethodChannel.MethodCallHandler {
    private val context = appContext
    private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
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
        if (call.method != "route") { result.notImplemented(); return }
        executor.execute {
            val outcome = runCatching {
                val uri = URI(call.argument<String>("url") ?: error("缺少媒体地址"))
                val attempt = call.argument<Int>("attempt") ?: 0
                val proxy = SystemMediaNetwork.configuration(uri, attempt = attempt)
                val vpn = allowsProxyFakeIp(uri)
                val cookie = runCatching {
                    CookieManager.getInstance().getCookie(uri.toString())
                }.getOrNull()
                mapOf(
                    "proxy" to proxy,
                    "vpn" to vpn,
                    "userAgent" to userAgent,
                    "cookie" to cookie,
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
            val transfer = ResumableMediaTransfer(
                connectForAttempt = { uri, attempt ->
                    val vpn = allowsProxyFakeIp(uri)
                    SystemMediaNetwork.openConnection(uri, allowProxyFakeIp = vpn, attempt = attempt)
                },
            )
            transfers.submit(job, transfer::abort, { transferFile(call, transfer) }) { outcome ->
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
        result.error(code, error.message ?: "媒体连接失败，已保留缓存，可重试", null)
    }

    /**
     * TUN/VPN implementations do not all expose TRANSPORT_VPN on Android.
     * Fake-IP DNS is still a positive signal that the direct socket is meant
     * to be intercepted by the system network path, so allow it through the
     * media route policy in that case.
     */
    private fun allowsProxyFakeIp(uri: URI): Boolean {
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        val directRoute = runCatching { SystemMediaNetwork.hasDirectRoute(uri) }
            .getOrDefault(false)
        val fakeIp = runCatching {
            InetAddress.getAllByName(uri.host).any(SystemMediaNetwork::fakeIp)
        }.getOrDefault(false)
        return SystemMediaNetwork.fakeIpRouteAllowed(
            vpnTransport = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true,
            explicitlyNotVpn = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN),
            directRoute = directRoute,
            dnsContainsFakeIp = fakeIp,
        )
    }

    private fun transferFile(call: MethodCall, transfer: ResumableMediaTransfer) {
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
            transfer.transfer(url, document, output, userAgent, maxBytes = maxBytes,
                requestCookies = { target -> CookieManager.getInstance().getCookie(target.toString()) },
            )
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor()
        private val transferExecutor = Executors.newFixedThreadPool(2)
    }
}
