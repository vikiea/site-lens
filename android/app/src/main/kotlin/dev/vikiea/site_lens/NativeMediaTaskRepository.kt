package dev.vikiea.site_lens

import android.content.Context
import org.json.JSONObject

/** No Cookie, Authorization or other session headers are persisted here. */
class NativeMediaTaskRepository(context: Context) {
    private companion object {
        const val DIRECTORY_MIGRATION_JOURNAL = "directoryMigrationJournalV1"
    }

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
        val resourceKey: String = "",
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
            .putString("${record.taskId}.resourceKey", record.resourceKey)
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
            prefs.getString("$taskId.resourceKey", "") ?: "",
        )
    }

    fun all(): List<Record> = prefs.all.keys
        .asSequence()
        .filter { it.endsWith(".known") && prefs.getBoolean(it, false) }
        .map { it.removeSuffix(".known") }
        .distinct()
        .mapNotNull(::read)
        .toList()

    /** Persists old -> clean directory mappings before physical migration. */
    fun directoryMigrationJournal(): Map<String, String> {
        val raw = prefs.getString(DIRECTORY_MIGRATION_JOURNAL, null) ?: return emptyMap()
        return runCatching {
            val json = JSONObject(raw)
            json.keys().asSequence().associateWith { key -> json.getString(key) }
        }.getOrDefault(emptyMap())
    }

    fun rememberDirectoryMigration(oldName: String, newName: String) {
        val next = directoryMigrationJournal().toMutableMap()
        next[oldName] = newName
        val json = JSONObject()
        next.toSortedMap().forEach { (old, clean) -> json.put(old, clean) }
        check(prefs.edit().putString(DIRECTORY_MIGRATION_JOURNAL, json.toString()).commit()) {
            "无法保存媒体目录迁移记录"
        }
    }

    fun completeDirectoryMigration(oldName: String) {
        val next = directoryMigrationJournal().toMutableMap()
        next.remove(oldName)
        val edit = prefs.edit()
        if (next.isEmpty()) edit.remove(DIRECTORY_MIGRATION_JOURNAL)
        else {
            val json = JSONObject()
            next.toSortedMap().forEach { (old, clean) -> json.put(old, clean) }
            edit.putString(DIRECTORY_MIGRATION_JOURNAL, json.toString())
        }
        check(edit.commit()) { "无法清理媒体目录迁移记录" }
    }

    /** Updates every task in one SharedPreferences commit after a merge. */
    fun rewriteSeriesDirectory(oldName: String, newName: String) {
        val edit = prefs.edit()
        all().filter { it.seriesDirectory == oldName }.forEach { record ->
            edit.putString("${record.taskId}.seriesDirectory", newName)
        }
        check(edit.commit()) { "无法更新媒体目录引用" }
    }

    fun remove(taskId: String) {
        val edit = prefs.edit()
        for (suffix in listOf("downloadId", "candidateId", "generation", "url", "sourceUrl",
            "title", "seriesDirectory", "paused", "cancelled", "workId", "resourceKey", "known")) {
            edit.remove("$taskId.$suffix")
        }
        check(edit.commit()) { "无法删除下载状态" }
    }
}
