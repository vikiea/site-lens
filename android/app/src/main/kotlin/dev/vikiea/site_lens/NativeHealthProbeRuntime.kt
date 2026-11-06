package dev.vikiea.site_lens

import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.vikiea.site_lens_health_probe.HealthProbePlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Each engine owns its executor, cancellation and reply barrier. */
class NativeHealthProbeRuntime(private val context: Context) : HealthProbePlugin.Runtime {
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val closed = AtomicBoolean(false)
    private var active: HealthHttpProbe? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingReply: AtomicBoolean? = null

    override fun close() {
        closed.set(true)
        active?.close()
        active = null
        pendingReply?.set(true)
        pendingResult = null
        executor.shutdownNow()
        timer.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancel") {
            active?.close()
            if (pendingReply?.compareAndSet(false, true) == true) {
                pendingResult?.error("health_cancelled", "后台检查已取消", null)
            }
            result.success(null)
            return
        }
        if (call.method != "probe") { result.notImplemented(); return }
        if (active != null || closed.get()) {
            result.error("health_busy", "后台检查正在执行", null)
            return
        }
        val url = call.argument<String>("url")
        val attempt = call.argument<Int>("attempt") ?: 0
        val probe = HealthHttpProbe { uri, index, onRoute ->
            SystemMediaNetwork.openMediaConnection(
                context, uri, index, onRoute = onRoute,
            )
        }
        active = probe
        pendingResult = result
        val replied = AtomicBoolean(false)
        pendingReply = replied
        // Reply is bounded even if platform DNS is temporarily uninterruptible.
        val deadline = timer.schedule({
            probe.close()
            main.post {
                if (!closed.get() && replied.compareAndSet(false, true)) {
                    result.success(mapOf("status" to "unreachable", "routeKind" to "unknown",
                        "failureCategory" to "timeout", "elapsedMs" to 5000,
                        "networkEpoch" to SystemMediaNetwork.networkEpoch()))
                }
            }
        }, 5, TimeUnit.SECONDS)
        executor.execute {
            try {
                val payload = probe.probe(url, attempt, SystemMediaNetwork.networkEpoch()) +
                    ("networkEpoch" to SystemMediaNetwork.networkEpoch())
                main.post {
                    if (!closed.get() && replied.compareAndSet(false, true)) result.success(payload)
                }
            } finally {
                deadline.cancel(false)
                probe.close()
                main.post { if (active === probe) {
                    active = null; pendingResult = null; pendingReply = null
                } }
            }
        }
    }
}
