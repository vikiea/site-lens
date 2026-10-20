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
import java.net.URI
import java.util.concurrent.Executors

class MediaNetworkRuntime(context: Context) : MethodChannel.MethodCallHandler {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val userAgent = WebSettings.getDefaultUserAgent(context)
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "route") { result.notImplemented(); return }
        executor.execute {
            val outcome = runCatching {
                val uri = URI(call.argument<String>("url") ?: error("缺少媒体地址"))
                val proxy = SystemMediaNetwork.configuration(uri)
                val vpn = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
                    ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
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

    companion object { private val executor = Executors.newSingleThreadExecutor() }
}
