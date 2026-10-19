package dev.vikiea.site_lens

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Persistent native backend. Worker file writes are serialized by a lock. */
class NativeDownloadRuntime(context: Context) : MethodChannel.MethodCallHandler {
    private val context = context.applicationContext
    private val workManager = WorkManager.getInstance(this.context)
    private val legacyManager = this.context.getSystemService(DownloadManager::class.java)
    private val repository = NativeMediaTaskRepository(this.context)
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            val outcome = runCatching {
                val taskId = validTaskId(call.argument<String>("taskId"))
                when (call.method) {
                    "start" -> start(taskId, call)
                    "status" -> status(taskId)
                    "pause" -> { stop(taskId, false); null }
                    "resume" -> resume(taskId)
                    "cancel" -> { stop(taskId, true); null }
                    "delete" -> { delete(taskId); null }
                    else -> error("不支持的下载操作")
                }
            }
            main.post { outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { result.error("media_download", it.message ?: "下载失败", null) },
            ) }
        }
    }

    private fun start(taskId: String, call: MethodCall): Map<String, Any?> {
        val url = NativeMediaDownloadWorker.validateUrl(call.argument<String>("url") ?: error("缺少媒体地址"))
        var existing = repository.read(taskId)
        if (existing != null && existing.workId == null && existing.downloadId >= 0L) {
            val migrated = migrateLegacy(existing)
            if (migrated != null) return migrated
            existing = repository.read(taskId)
        }
        if (existing != null && !existing.paused && !existing.cancelled) {
            val state = status(taskId)["state"]
            if (state == "downloading" || state == "completed") return status(taskId)
        }
        if (existing != null) stop(taskId, false)
        val record = NativeMediaTaskRepository.Record(
            taskId = taskId,
            candidateId = call.argument<String>("candidateId") ?: "",
            generation = call.argument<Number>("generation")?.toLong() ?: 0L,
            url = url.toString(),
            sourceUrl = call.argument<String>("sourceUrl") ?: "",
            title = (call.argument<String>("title") ?: "Site Lens media").take(120),
            seriesDirectory = safeDirectory(call.argument<String>("storageDirectory")),
        )
        return enqueue(record)
    }

    private fun enqueue(record: NativeMediaTaskRepository.Record): Map<String, Any?> {
        val request = OneTimeWorkRequestBuilder<NativeMediaDownloadWorker>()
            .setInputData(Data.Builder().putString("taskId", record.taskId).build())
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
            .addTag("site-lens-media")
            .build()
        repository.save(record.copy(workId = request.id.toString(), downloadId = -1L,
            paused = false, cancelled = false))
        workManager.enqueueUniqueWork(workName(record.taskId), ExistingWorkPolicy.REPLACE, request)
            .result.get(30, TimeUnit.SECONDS)
        return status(record.taskId)
    }

    private fun status(taskId: String): Map<String, Any?> {
        val record = repository.read(taskId) ?: return mapOf("taskId" to taskId, "state" to "missing")
        if (record.workId == null && record.downloadId >= 0) {
            val migrated = try {
                migrateLegacy(record)
            } catch (_: Exception) {
                return legacyStatus(record)
            }
            if (migrated != null) return migrated
            val refreshed = repository.read(taskId)
            if (refreshed != null && refreshed.downloadId != record.downloadId) {
                return status(taskId)
            }
            return legacyStatus(record)
        }
        val partial = NativeMediaDownloadWorker.partialFile(context, record)
        val final = NativeMediaDownloadWorker.finalFile(context, record)
        val hasFinal = final.isFile && final.length() > 0L
        val hasPartial = partial.isFile && partial.length() > 0L
        val info = record.workId?.let {
            runCatching { workManager.getWorkInfoById(UUID.fromString(it)).get(15, TimeUnit.SECONDS) }.getOrNull()
        }
        val output = info?.outputData ?: Data.EMPTY
        val outputErrorCode = output.getString("errorCode")
        val state = when {
            record.cancelled -> "cancelled"
            record.paused -> "paused"
            hasFinal -> "completed"
            info == null && hasPartial -> "paused"
            info == null -> "failed"
            info.state == WorkInfo.State.SUCCEEDED -> "failed"
            info.state == WorkInfo.State.FAILED && outputErrorCode == "reauthorize" -> "reauthorize"
            info.state == WorkInfo.State.FAILED -> "failed"
            info.state == WorkInfo.State.CANCELLED -> "paused"
            else -> "downloading"
        }
        val bytes = if (state == "completed") final.length() else partial.length()
        val total = info?.progress?.getLong("totalBytes", -1L)?.takeIf { it >= bytes }
        return buildMap {
            put("taskId", taskId)
            put("state", state)
            put("bytesDownloaded", bytes)
            if (state == "completed") {
                put("totalBytes", bytes)
                put("localUri", Uri.fromFile(final).toString())
            } else if (total != null) put("totalBytes", total)
            if (info == null && !hasFinal && !hasPartial) {
                put("errorCode", "cache_missing")
                put("errorReason", "后台下载任务丢失，请重试")
            } else if (info?.state == WorkInfo.State.SUCCEEDED && !hasFinal) {
                put("errorCode", "cache_missing")
                put("errorReason", "后台下载文件缺失，请重试")
            } else {
                output.getString("errorCode")?.let { put("errorCode", it) }
                output.getString("errorReason")?.let { put("errorReason", it) }
            }
        }
    }

    private fun migrateLegacy(record: NativeMediaTaskRepository.Record): Map<String, Any?>? {
        val legacyId = record.downloadId
        if (legacyId < 0L) return null
        val finalTarget = NativeMediaDownloadWorker.finalFile(context, record)
        val partialTarget = NativeMediaDownloadWorker.partialFile(context, record)

        fun completedResult(target: File): Map<String, Any?> = mapOf(
            "taskId" to record.taskId,
            "state" to "completed",
            "bytesDownloaded" to target.length(),
            "totalBytes" to target.length(),
            "localUri" to Uri.fromFile(target).toString(),
        )

        var localUri: Uri? = null
        var completed = false
        legacyManager.query(DownloadManager.Query().setFilterById(legacyId)).use { row ->
            if (!row.moveToFirst()) {
                val stagedFinal = File(finalTarget.path + ".legacy.tmp")
                if (stagedFinal.isFile && stagedFinal.length() > 0L) {
                    commitLegacyCopy(stagedFinal, finalTarget)
                    repository.save(record.copy(downloadId = -1L, workId = null, paused = false, cancelled = false))
                    return completedResult(finalTarget)
                }
                val stagedPartial = File(partialTarget.path + ".legacy.tmp")
                if (stagedPartial.isFile && stagedPartial.length() > 0L) {
                    commitLegacyCopy(stagedPartial, partialTarget)
                    repository.save(record.copy(downloadId = -1L, workId = null, paused = true, cancelled = false))
                    return null
                }
                repository.save(record.copy(downloadId = -1L))
                return null
            }
            completed = row.getInt(row.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) ==
                DownloadManager.STATUS_SUCCESSFUL
            localUri = row.getString(row.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))?.let(Uri::parse)
        }
        val target = if (completed) finalTarget else partialTarget
        val temporary = File(target.path + ".legacy.tmp")
        val source = localUri ?: throw IllegalStateException("旧下载文件地址不存在")
        val input = if (source.scheme == "file") {
            File(source.path ?: error("旧下载文件地址无效")).inputStream()
        } else {
            context.contentResolver.openInputStream(source) ?: error("无法读取旧下载文件")
        }
        input.use { stream ->
            target.parentFile?.mkdirs()
            temporary.delete()
            temporary.outputStream().use { stream.copyTo(it) }
        }
        check(temporary.isFile && temporary.length() > 0L) { "旧下载文件为空" }
        // DownloadManager.remove also removes its destination. Keep the copy
        // outside that destination until ownership has been detached.
        check(legacyManager.remove(legacyId) > 0) { "无法解除旧下载任务" }
        commitLegacyCopy(temporary, target)
        repository.save(record.copy(
            downloadId = -1L,
            workId = null,
            paused = !completed,
            cancelled = false,
        ))
        if (completed && target.isFile && target.length() > 0L) {
            return completedResult(target)
        }
        return null
    }

    /** Commit a staged legacy copy and retain the stage as a recovery point on failure. */
    private fun commitLegacyCopy(staged: File, target: File) {
        target.parentFile?.mkdirs()
        if (!staged.renameTo(target)) {
            staged.copyTo(target, overwrite = true)
        }
        check(target.isFile && target.length() > 0L) { "无法迁移旧下载文件" }
        // A successful target commit makes the duplicate stage disposable. Do
        // not turn a cleanup-only failure into a lost migration.
        if (staged.exists()) runCatching { staged.delete() }
    }

    private fun legacyStatus(record: NativeMediaTaskRepository.Record): Map<String, Any?> {
        val legacy = context.getSystemService(DownloadManager::class.java)
        legacy.query(DownloadManager.Query().setFilterById(record.downloadId)).use { row ->
            if (!row.moveToFirst()) return mapOf("state" to "missing")
            val state = when (row.getInt(row.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                DownloadManager.STATUS_SUCCESSFUL -> "completed"
                DownloadManager.STATUS_FAILED -> "failed"
                DownloadManager.STATUS_PAUSED -> "paused"
                else -> "downloading"
            }
            return mapOf(
                "state" to state,
                "bytesDownloaded" to row.getLong(row.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                "totalBytes" to row.getLong(row.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)).takeIf { it >= 0L },
                "localUri" to row.getString(row.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)),
            )
        }
    }

    private fun stop(taskId: String, cancelled: Boolean) {
        var record = repository.read(taskId) ?: return
        if (record.workId == null && record.downloadId >= 0L) {
            if (migrateLegacy(record) != null) return
            record = repository.read(taskId) ?: return
        }
        repository.save(record.copy(paused = !cancelled, cancelled = cancelled))
        NativeMediaDownloadWorker.abort(taskId)
        workManager.cancelUniqueWork(workName(taskId)).result.get(30, TimeUnit.SECONDS)
        NativeMediaDownloadWorker.withFileLock(context, taskId) { }
    }

    private fun resume(taskId: String): Map<String, Any?> {
        repository.read(taskId) ?: error("媒体任务不存在")
        stop(taskId, false)
        val record = repository.read(taskId) ?: error("媒体任务不存在")
        val completed = NativeMediaDownloadWorker.finalFile(context, record)
        if (completed.isFile && completed.length() > 0L) {
            repository.save(record.copy(paused = false, cancelled = false))
            return status(taskId)
        }
        return enqueue(record.copy(paused = false, cancelled = false))
    }

    private fun delete(taskId: String) {
        repository.read(taskId) ?: return
        stop(taskId, true)
        val record = repository.read(taskId) ?: return
        NativeMediaDownloadWorker.withFileLock(context, taskId) {
            NativeMediaDownloadWorker.files(context, record).forEach { file ->
                if (file.exists()) check(file.delete()) { "无法删除下载文件" }
            }
            repository.remove(taskId)
        }
    }

    private fun validTaskId(raw: String?): String = (raw?.trim() ?: error("缺少任务 ID")).also {
        require(it.matches(Regex("[A-Za-z0-9._-]{1,128}")) && it !in listOf(".", "..")) { "任务 ID 无效" }
    }

    private fun safeDirectory(raw: String?): String = raw?.trim().orEmpty()
        .replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
        .replace("..", "_").trim('.', ' ').take(80).ifBlank { "未命名媒体" }

    private companion object {
        private val executor = Executors.newSingleThreadExecutor { Thread(it, "site-lens-download-commands") }
        fun workName(taskId: String) = "site-lens-media-" + taskId
    }
}
