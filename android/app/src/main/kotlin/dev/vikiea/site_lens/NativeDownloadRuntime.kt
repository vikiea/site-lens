package dev.vikiea.site_lens

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Uses Android's OS-managed DownloadManager so a queued media task survives
 * process death and network changes without sharing the update cache. */
class NativeDownloadRuntime(private val context: Context) : MethodChannel.MethodCallHandler {
    private val manager = context.getSystemService(DownloadManager::class.java)
    private val prefs = context.getSharedPreferences("media_downloads", Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> result.success(start(call))
                "status" -> result.success(status(call.argument<String>("taskId") ?: error("缺少任务 ID")))
                "cancel" -> { cancel(call.argument<String>("taskId") ?: error("缺少任务 ID")); result.success(null) }
                "delete" -> { delete(call.argument<String>("taskId") ?: error("缺少任务 ID")); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("media_download", error.message ?: "下载失败", null)
        }
    }

    private fun start(call: MethodCall): Map<String, Any?> {
        val taskId = call.argument<String>("taskId")?.trim() ?: error("缺少任务 ID")
        require(taskId.matches(Regex("[A-Za-z0-9._-]{1,128}"))) { "任务 ID 无效" }
        val uri = Uri.parse(call.argument<String>("url")?.trim() ?: error("缺少媒体地址"))
        require(uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) { "媒体地址无效" }
        val request = DownloadManager.Request(uri)
            .setTitle((call.argument<String>("title") ?: "Site Lens media").take(120))
            .setDescription("Site Lens 媒体下载")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, "site-lens/$taskId.media")
        val existing = prefs.getLong(taskId, -1L)
        if (existing != -1L) {
            val current = query(existing)
            if (current["state"] != "failed" && current["state"] != "cancelled") return current
        }
        val id = manager.enqueue(request)
        prefs.edit().putLong(taskId, id).apply()
        return query(id)
    }

    private fun status(taskId: String): Map<String, Any?> {
        val id = prefs.getLong(taskId, -1L)
        return if (id == -1L) mapOf("taskId" to taskId, "state" to "missing") else query(id) + mapOf("taskId" to taskId)
    }

    private fun query(id: Long): Map<String, Any?> {
        val cursor = manager.query(DownloadManager.Query().setFilterById(id))
        cursor.use {
            if (!it.moveToFirst()) return mapOf("downloadId" to id, "state" to "missing")
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val state = when (status) {
                DownloadManager.STATUS_PENDING, DownloadManager.STATUS_RUNNING -> "downloading"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_SUCCESSFUL -> "completed"
                else -> "failed"
            }
            return mapOf(
                "downloadId" to id,
                "state" to state,
                "bytesDownloaded" to it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                "totalBytes" to it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                "localUri" to it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)),
            )
        }
    }

    private fun cancel(taskId: String) {
        val id = prefs.getLong(taskId, -1L)
        if (id != -1L) manager.remove(id)
        prefs.edit().remove(taskId).apply()
    }

    private fun delete(taskId: String) {
        // Removal also deletes the OS-managed app-private destination.
        cancel(taskId)
    }
}
