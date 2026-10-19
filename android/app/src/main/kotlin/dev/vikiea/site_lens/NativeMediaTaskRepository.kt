package dev.vikiea.site_lens

import android.content.Context

/** No Cookie, Authorization or other session headers are persisted here. */
class NativeMediaTaskRepository(context: Context) {
    private val prefs = context.getSharedPreferences("media_task_repository", Context.MODE_PRIVATE)

    data class Record(
        val taskId: String,
        val downloadId: Long = -1L,
        val candidateId: String = "",
        val generation: Long = 0L,
        val url: String = "",
        val sourceUrl: String = "",
        val title: String = "",
        val seriesDirectory: String = "未命名媒体",
        val paused: Boolean = false,
        val cancelled: Boolean = false,
        val workId: String? = null,
    )

    fun save(record: Record) {
        check(prefs.edit()
            .putLong("${record.taskId}.downloadId", record.downloadId)
            .putString("${record.taskId}.candidateId", record.candidateId)
            .putLong("${record.taskId}.generation", record.generation)
            .putString("${record.taskId}.url", record.url)
            .putString("${record.taskId}.sourceUrl", record.sourceUrl)
            .putString("${record.taskId}.title", record.title)
            .putString("${record.taskId}.seriesDirectory", record.seriesDirectory)
            .putBoolean("${record.taskId}.paused", record.paused)
            .putBoolean("${record.taskId}.cancelled", record.cancelled)
            .putString("${record.taskId}.workId", record.workId)
            .putBoolean("${record.taskId}.known", true)
            .commit()) { "无法保存下载状态" }
    }

    fun read(taskId: String): Record? {
        if (!prefs.getBoolean("$taskId.known", false)) return null
        return Record(
            taskId, prefs.getLong("$taskId.downloadId", -1L),
            prefs.getString("$taskId.candidateId", "") ?: "",
            prefs.getLong("$taskId.generation", 0L),
            prefs.getString("$taskId.url", "") ?: "",
            prefs.getString("$taskId.sourceUrl", "") ?: "",
            prefs.getString("$taskId.title", "") ?: "",
            prefs.getString("$taskId.seriesDirectory", "未命名媒体") ?: "未命名媒体",
            prefs.getBoolean("$taskId.paused", false),
            prefs.getBoolean("$taskId.cancelled", false),
            prefs.getString("$taskId.workId", null),
        )
    }

    fun remove(taskId: String) {
        val edit = prefs.edit()
        for (suffix in listOf("downloadId", "candidateId", "generation", "url", "sourceUrl",
            "title", "seriesDirectory", "paused", "cancelled", "workId", "known")) {
            edit.remove("$taskId.$suffix")
        }
        check(edit.commit()) { "无法删除下载状态" }
    }
}
