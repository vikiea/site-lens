package dev.vikiea.site_lens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Keeps the Flutter-owned export alive while the Activity is backgrounded. */
class NativeMediaExportService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (activeJobs.isEmpty()) stopSelf(startId)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "媒体导出", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Site Lens")
            .setContentText("媒体导出进行中")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, notification)
        }
    }

    companion object {
        private const val CHANNEL = "site-lens-media-export"
        private const val ID = 24003
        private val activeJobs = ConcurrentHashMap<String, AtomicInteger>()

        fun begin(context: Context, taskId: String) {
            require(taskId.isNotBlank()) { "缺少导出任务 ID" }
            activeJobs.computeIfAbsent(taskId) { AtomicInteger() }.incrementAndGet()
            try {
                ContextCompat.startForegroundService(
                    context.applicationContext,
                    Intent(context.applicationContext, NativeMediaExportService::class.java),
                )
            } catch (error: Exception) {
                end(context, taskId)
                throw error
            }
        }

        fun end(context: Context, taskId: String) {
            activeJobs.computeIfPresent(taskId) { _, count ->
                if (count.decrementAndGet() <= 0) null else count
            }
            if (activeJobs.isEmpty()) {
                stop(context)
            }
        }

        fun stop(context: Context) {
            activeJobs.clear()
            context.applicationContext.stopService(
                Intent(context.applicationContext, NativeMediaExportService::class.java),
            )
        }
    }
}
