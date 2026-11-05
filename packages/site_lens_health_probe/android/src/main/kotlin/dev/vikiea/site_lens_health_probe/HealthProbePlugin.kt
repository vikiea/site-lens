package dev.vikiea.site_lens_health_probe

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Registered by Flutter in Activity and WorkManager engines alike. */
class HealthProbePlugin : FlutterPlugin {
    interface Runtime : MethodChannel.MethodCallHandler {
        fun close()
    }
    companion object {
        // Installed by Application before any foreground or headless engine.
        @Volatile var createRuntime: ((Context) -> Runtime)? = null
    }
    private var channel: MethodChannel? = null
    private var runtime: Runtime? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runtime = createRuntime?.invoke(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "site_lens/health_network").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val active = runtime
                if (active == null) result.error("health_unavailable", "后台路由尚未初始化", null)
                else active.onMethodCall(call, result)
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        runtime?.close()
        runtime = null
        channel = null
    }
}
