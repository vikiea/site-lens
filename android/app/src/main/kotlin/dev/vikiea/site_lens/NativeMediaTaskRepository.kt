package dev.vikiea.site_lens

import android.content.Context

/** Durable native task index. DownloadManager owns the bytes; this repository
 * owns the task-to-download identity so a restarted Flutter engine can
 * reconcile without creating a second download. */
class NativeMediaTaskRepository(context: Context) {
    private val prefs = context.getSharedPreferences("media_task_repository", Context.MODE_PRIVATE)

    data class Record(
        val taskId: String,
        val downloadId: Long,
        val candidateId: String,
        val generation: Long,
        val url: String = "",
        val sourceUrl: String = "",
        val title: String = "",
        val paused: Boolean = false,
    )

    fun save(record: Record) {
        prefs.edit()
            .putLong("${record.taskId}.downloadId", record.downloadId)
            .putString("${record.taskId}.candidateId", record.candidateId)
            .putLong("${record.taskId}.generation", record.generation)
            .putString("${record.taskId}.url", record.url)
            .putString("${record.taskId}.sourceUrl", record.sourceUrl)
            .putString("${record.taskId}.title", record.title)
            .putBoolean("${record.taskId}.paused", record.paused)
            .putBoolean("${record.taskId}.known", true)
            .apply()
    }

    fun read(taskId: String): Record? {
        val id = prefs.getLong("$taskId.downloadId", -1L)
        if (!prefs.getBoolean("$taskId.known", false)) return null
        return Record(
            taskId,
            id,
            prefs.getString("$taskId.candidateId", "") ?: "",
            prefs.getLong("$taskId.generation", 0L),
            prefs.getString("$taskId.url", "") ?: "",
            prefs.getString("$taskId.sourceUrl", "") ?: "",
            prefs.getString("$taskId.title", "") ?: "",
            prefs.getBoolean("$taskId.paused", false),
        )
    }

    fun remove(taskId: String) {
        prefs.edit()
            .remove("$taskId.downloadId")
            .remove("$taskId.candidateId")
            .remove("$taskId.generation")
            .remove("$taskId.url")
            .remove("$taskId.sourceUrl")
            .remove("$taskId.title")
            .remove("$taskId.paused")
            .remove("$taskId.known")
            .apply()
    }
}
