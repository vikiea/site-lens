package dev.vikiea.site_lens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature

class MainActivity : FlutterActivity() {
    private var hosts: NativeWebHostRegistry? = null
    private var pendingNotification: Pair<String, String>? = null
    private var notificationPermissionAsked = false

    private fun postNotification(title: String, body: String) {
        val manager = getSystemService(NotificationManager::class.java)
        val channelId = "site-lens-health"
        manager.createNotificationChannel(
            NotificationChannel(
                channelId,
                "站点存活检查",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        val notification = Notification.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setAutoCancel(true)
            .build()
        manager.notify(9000, notification)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 4711) return
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        val pending = pendingNotification
        pendingNotification = null
        // Deliver the notice the moment the user allows notifications.
        if (granted && pending != null) postNotification(pending.first, pending.second)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            val store = ProfileStore.getInstance()
            for (name in store.allProfileNames.filter { it.startsWith("site-lens-probe-") }) {
                try { store.deleteProfile(name) } catch (_: IllegalStateException) { /* Never delete an in-use profile. */ }
            }
        }
        hosts = NativeWebHostRegistry(this, flutterEngine)
        // Minimal device-conditions channel for the background survival check.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site_lens/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isCharging" -> {
                    val battery =
                        getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    result.success(battery.isCharging)
                }
                "notify" -> {
                    val title = call.argument<String>("title") ?: "择站 · Site Lens"
                    val body = call.argument<String>("body") ?: ""
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                    ) {
                        // Ask exactly once per process; the caller keeps the
                        // notice and it is delivered when permission is granted.
                        pendingNotification = title to body
                        if (!notificationPermissionAsked) {
                            notificationPermissionAsked = true
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                4711,
                            )
                        }
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    postNotification(title, body)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onPause() { hosts?.foreground(false); super.onPause() }
    override fun onResume() { super.onResume(); hosts?.foreground(true) }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        hosts?.dispose(); hosts = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
