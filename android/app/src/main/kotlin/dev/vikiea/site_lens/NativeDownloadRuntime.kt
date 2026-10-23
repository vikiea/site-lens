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
import java.io.Closeable
import java.io.File
import java.nio.file.LinkOption
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Persistent native backend. Worker file writes are serialized by a lock. */
class NativeDownloadRuntime(context: Context) : MethodChannel.MethodCallHandler {
    private val context = context.applicationContext
    private val workManager = WorkManager.getInstance(this.context)
    private val legacyManager = this.context.getSystemService(DownloadManager::class.java)
    private val repository = NativeMediaTaskRepository(this.context)
    private val main = Handler(Looper.getMainLooper())
    private val runtimeId = UUID.randomUUID().toString()
    @Volatile private var disposed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("media_download", "媒体下载服务已关闭", null)
            return
        }
        executor.execute {
            val outcome = runCatching {
                when (call.method) {
                    "migrateLegacyDirectories" -> {
                        migrateLegacyDirectories()
                        null
                    }
                    "reserveMutation" -> reserveMutation(call)
                    "releaseMutation" -> {
                        releaseMutation(call.argument<String>("reservationId"))
                        null
                    }
                    else -> {
                        val taskId = validTaskId(call.argument<String>("taskId"))
                        when (call.method) {
                            "start" -> start(taskId, call)
                            "status" -> status(taskId)
                            "pause" -> { stop(taskId, false); null }
                            "resume" -> resume(taskId)
                            "cancel" -> { stop(taskId, true); null }
                            "delete" -> {
                                delete(taskId, call.argument<String>("reservationId"))
                                null
                            }
                            else -> error("不支持的下载操作")
                        }
                    }
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

    private data class LegacySnapshot(val completed: Boolean, val source: Uri?)

    private data class MutationReservation(
        val taskId: String,
        val legacy: LegacySnapshot?,
        val lease: Closeable,
        val ownerRuntimeId: String,
    )

    /**
     * Holds the native mutation fence across the Dart writer stop/flush
     * handshake. The caller supplies Dart-owned cache paths because those files
     * have no native repository row and must share the same fence.
     */
    private fun reserveMutation(call: MethodCall): String {
        val taskId = validTaskId(call.argument<String>("taskId"))
        val rawPaths = call.argument<List<*>>("paths") ?: emptyList<Any?>()
        require(rawPaths.size <= 256) { "媒体变更路径过多" }
        val paths = rawPaths.map {
            (it as? String)?.takeIf { value -> value.length <= 4096 }
                ?: error("媒体变更路径无效")
        }
        val record = repository.read(taskId)
        val legacy = record?.let(::readLegacy)
        var scope = if (record == null) {
            MediaFileLeaseRegistry.Scope.task(taskId)
        } else {
            mutationScope(record, legacy)
        }
        paths.forEach { scope += MediaFileLeaseRegistry.Scope.source(it) }
        val reservationId = UUID.randomUUID().toString()
        val lease = NativeMediaFileLeases.registry.acquireMutation(scope)
        mutationReservations[reservationId] = MutationReservation(
            taskId = taskId,
            legacy = legacy,
            lease = lease,
            ownerRuntimeId = runtimeId,
        )
        return reservationId
    }

    private fun releaseMutation(rawId: String?) {
        val id = rawId?.trim().orEmpty()
        if (id.isEmpty()) return
        val reservation = mutationReservations[id] ?: return
        if (reservation.ownerRuntimeId != runtimeId) return
        if (mutationReservations.remove(id, reservation)) reservation.lease.close()
    }

    private fun readLegacy(record: NativeMediaTaskRepository.Record): LegacySnapshot? {
        if (record.workId != null || record.downloadId < 0L) return null
        return legacyManager.query(DownloadManager.Query().setFilterById(record.downloadId)).use { row ->
            if (!row.moveToFirst()) null else LegacySnapshot(
                completed = row.getInt(row.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) == DownloadManager.STATUS_SUCCESSFUL,
                source = row.getString(row.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))?.let(Uri::parse),
            )
        }
    }

    private fun mutationScope(record: NativeMediaTaskRepository.Record, legacy: LegacySnapshot?): MediaFileLeaseRegistry.Scope {
        val files = NativeMediaDownloadWorker.files(context, record).fold(MediaFileLeaseRegistry.Scope.task(record.taskId)) { scope, file ->
            scope + MediaFileLeaseRegistry.Scope.file(file)
        }
        return legacy?.source?.let { files + MediaFileLeaseRegistry.Scope.source(it.toString()) } ?: files
    }

    private fun migrateLegacy(
        record: NativeMediaTaskRepository.Record,
        mutationHeld: Boolean = false,
        legacy: LegacySnapshot? = readLegacy(record),
    ): Map<String, Any?>? {
        if (!mutationHeld) return NativeMediaFileLeases.registry.mutate(mutationScope(record, legacy)) {
            migrateLegacy(record, mutationHeld = true, legacy = legacy)
        }
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

        if (legacy == null) {
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
        val completed = legacy.completed
        val target = if (completed) finalTarget else partialTarget
        val temporary = File(target.path + ".legacy.tmp")
        val source = legacy.source ?: throw IllegalStateException("旧下载文件地址不存在")
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

    private fun stop(taskId: String, cancelled: Boolean, mutationHeld: Boolean = false, legacy: LegacySnapshot? = null) {
        var record = repository.read(taskId) ?: return
        if (record.workId == null && record.downloadId >= 0L) {
            if (if (mutationHeld) migrateLegacy(record, true, legacy) != null else migrateLegacy(record) != null) return
            record = repository.read(taskId) ?: return
        }
        repository.save(record.copy(paused = !cancelled, cancelled = cancelled))
        NativeMediaDownloadWorker.abort(taskId)
        workManager.cancelUniqueWork(workName(taskId)).result.get(30, TimeUnit.SECONDS)
        NativeMediaDownloadWorker.withFileLock(context, taskId, record.seriesDirectory) { }
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

    private fun delete(taskId: String, reservationId: String? = null) {
        if (reservationId != null) {
            val reservation = mutationReservations[reservationId]
                ?: error("媒体变更许可不存在或已释放")
            require(reservation.taskId == taskId) { "媒体变更许可与任务不匹配" }
            deleteUnderLease(taskId, reservation.legacy)
            return
        }
        val initial = repository.read(taskId) ?: return
        val legacy = readLegacy(initial)
        val scope = mutationScope(initial, legacy)
        // Acquire before cancelling transport: a rejected deletion must not
        // pause a download, remove its metadata or disrupt the active reader.
        NativeMediaFileLeases.registry.mutate(scope) {
            deleteUnderLease(taskId, legacy)
        }
    }

    private fun deleteUnderLease(taskId: String, legacy: LegacySnapshot?) {
        stop(taskId, true, mutationHeld = true, legacy = legacy)
        val record = repository.read(taskId) ?: return
        NativeMediaDownloadWorker.withFileLock(context, taskId, record.seriesDirectory) {
            NativeMediaDownloadWorker.files(context, record).forEach { file ->
                if (file.exists()) check(file.delete()) { "无法删除下载文件" }
            }
            repository.remove(taskId)
        }
    }

    /**
     * Moves old batch directories in the Android-owned download root into the
     * clean series directory and merges duplicate children by replacing the
     * destination with the legacy source. WorkManager records that can still
     * write are left untouched and retried on a later cold restore.
     */
    private fun migrateLegacyDirectories() {
        val rawRoot = NativeMediaDownloadWorker.root(context)
        if (Files.isSymbolicLink(rawRoot.toPath()) ||
            !Files.isDirectory(rawRoot.toPath(), LinkOption.NOFOLLOW_LINKS)
        ) return
        val root = rawRoot.canonicalFile
        val records = repository.all()
        val activeDirectories = records
            .filter { isWorkActive(it) }
            .flatMap { listOf(it.seriesDirectory, cleanDirectory(it.seriesDirectory)) }
            .toSet()
        val migrations = linkedMapOf<String, String>().apply {
            putAll(repository.directoryMigrationJournal())
        }
        for (record in records) {
            val target = cleanDirectory(record.seriesDirectory)
            if (target != record.seriesDirectory) {
                migrations[record.seriesDirectory] = target
            }
        }
        root.listFiles()
            ?.filter {
                !Files.isSymbolicLink(it.toPath()) &&
                    Files.isDirectory(it.toPath(), LinkOption.NOFOLLOW_LINKS)
            }
            ?.sortedBy { it.name }
            ?.forEach { directory ->
                val target = cleanDirectory(directory.name)
                if (target != directory.name) migrations[directory.name] = target
            }

        for ((oldName, newName) in migrations.toSortedMap()) {
            if (oldName in activeDirectories || newName in activeDirectories || oldName == newName) continue
            if (!validDirectoryName(oldName) || !validDirectoryName(newName)) continue
            val sourceRaw = File(root, oldName)
            val targetRaw = File(root, newName)
            require(sourceRaw.parentFile?.canonicalFile == root) { "媒体目录越界" }
            require(targetRaw.parentFile?.canonicalFile == root) { "媒体目录越界" }
            if (Files.isSymbolicLink(sourceRaw.toPath()) || Files.isSymbolicLink(targetRaw.toPath())) {
                NativeCrashStore.append(
                    context,
                    module = "media.storage-migration",
                    message = "媒体目录包含符号链接，已跳过迁移",
                    details = "symbolic_link",
                    contextValue = "directory-migration",
                )
                continue
            }
            val sourceExists = Files.isDirectory(sourceRaw.toPath(), LinkOption.NOFOLLOW_LINKS)
            val targetExists = Files.isDirectory(targetRaw.toPath(), LinkOption.NOFOLLOW_LINKS)
            if (!sourceExists && !targetExists) continue
            repository.rememberDirectoryMigration(oldName, newName)
            try {
                val scope = MediaFileLeaseRegistry.Scope.file(sourceRaw) +
                    MediaFileLeaseRegistry.Scope.file(targetRaw)
                NativeMediaFileLeases.registry.mutate(scope) {
                    NativeMediaDownloadWorker.withDirectoryLocks(
                        context,
                        listOf(oldName, newName),
                    ) {
                        if (Files.isDirectory(sourceRaw.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                            mergeDirectory(sourceRaw, targetRaw)
                        }
                        check(Files.isDirectory(targetRaw.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                            "无法确认媒体目录迁移目标"
                        }
                        // If the source disappeared before this process
                        // started, the journal still lets us finish the
                        // durable record rewrite after a prior physical merge.
                        repository.rewriteSeriesDirectory(oldName, newName)
                        repository.completeDirectoryMigration(oldName)
                    }
                }
            } catch (error: Exception) {
                NativeCrashStore.append(
                    context,
                    module = "media.storage-migration",
                    message = "媒体目录迁移已暂缓",
                    details = error.javaClass.simpleName,
                    contextValue = "directory-migration",
                )
            }
        }
    }

    private fun isWorkActive(record: NativeMediaTaskRepository.Record): Boolean {
        if (record.downloadId >= 0L && record.workId == null) return true
        val workId = record.workId ?: return false
        val lookup = runCatching {
            workManager.getWorkInfoById(UUID.fromString(workId)).get(2, TimeUnit.SECONDS)
        }
        if (lookup.isFailure) return true
        val info = lookup.getOrNull() ?: return false
        return info.state == WorkInfo.State.RUNNING ||
            info.state == WorkInfo.State.ENQUEUED ||
            info.state == WorkInfo.State.BLOCKED
    }

    private fun cleanDirectory(value: String): String {
        val display = value.replace(Regex("[_ -]*批次[0-9]{16}$"), "")
        return safeDirectory(display)
    }

    private fun mergeDirectory(source: File, target: File) {
        check(!Files.isSymbolicLink(source.toPath())) { "媒体目录包含符号链接，无法自动合并" }
        if (!Files.isDirectory(source.toPath(), LinkOption.NOFOLLOW_LINKS)) return
        target.parentFile?.mkdirs()
        if (Files.isSymbolicLink(target.toPath())) {
            error("媒体目录目标包含符号链接，无法自动合并")
        }
        if (Files.exists(target.toPath(), LinkOption.NOFOLLOW_LINKS) &&
            !Files.isDirectory(target.toPath(), LinkOption.NOFOLLOW_LINKS)
        ) {
            check(target.delete()) { "无法替换媒体目录" }
        }
        check(target.mkdirs() || Files.isDirectory(target.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            "无法创建媒体目录"
        }
        val children = source.listFiles() ?: error("无法读取旧媒体目录")
        children.sortedBy { it.name }.forEach { child ->
            check(!Files.isSymbolicLink(child.toPath())) { "媒体目录包含符号链接，无法自动合并" }
            val destination = File(target, child.name)
            if (Files.isSymbolicLink(destination.toPath())) {
                error("媒体目标包含符号链接，无法自动合并")
            }
            if (Files.isDirectory(child.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                if (Files.exists(destination.toPath(), LinkOption.NOFOLLOW_LINKS) &&
                    !Files.isDirectory(destination.toPath(), LinkOption.NOFOLLOW_LINKS)
                ) {
                    check(destination.delete()) { "无法替换媒体文件" }
                }
                mergeDirectory(child, destination)
            } else {
                val temporary = File(destination.path + ".site-lens-migrate.part")
                if (temporary.exists()) check(temporary.delete())
                val expected = sha256(child)
                child.copyTo(temporary, overwrite = true)
                check(
                    temporary.length() == child.length() &&
                        sha256(temporary).contentEquals(expected),
                ) { "媒体目录迁移校验失败" }
                if (destination.exists()) check(destination.delete()) { "无法覆盖媒体文件" }
                check(temporary.renameTo(destination)) { "无法提交媒体目录迁移" }
                check(sha256(destination).contentEquals(expected)) { "媒体目录提交校验失败" }
                check(child.delete()) { "无法清理旧媒体文件" }
            }
        }
        if (Files.exists(source.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            check(source.delete()) { "无法清理旧媒体目录" }
        }
    }

    private fun validDirectoryName(value: String): Boolean =
        value.isNotBlank() && value != "." && value != ".." &&
            !value.contains('/') && !value.contains('\\') &&
            value.none { it.code < 0x20 }

    private fun sha256(file: File): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest()
    }

    private fun validTaskId(raw: String?): String = (raw?.trim() ?: error("缺少任务 ID")).also {
        require(it.matches(Regex("[A-Za-z0-9._-]{1,128}")) && it !in listOf(".", "..")) { "任务 ID 无效" }
    }

    private fun safeDirectory(raw: String?): String = raw?.trim().orEmpty()
        .replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
        .replace("..", "_").trim('.', ' ').take(80).ifBlank { "未命名媒体" }

    /**
     * Engine teardown must not leave a mutation fence or an active worker
     * behind. Mark the native task cancelled before releasing the fence; a
     * subsequent engine can then safely reconcile and retry it.
     */
    fun dispose() {
        disposed = true
        mutationReservations.entries
            .filter { it.value.ownerRuntimeId == runtimeId }
            .toList()
            .forEach { (id, reservation) ->
            runCatching {
                repository.read(reservation.taskId)?.let { record ->
                    repository.save(record.copy(paused = true, cancelled = true))
                }
                NativeMediaDownloadWorker.abort(reservation.taskId)
                workManager.cancelUniqueWork(workName(reservation.taskId)).result.get(30, TimeUnit.SECONDS)
            }
            mutationReservations.remove(id)?.lease?.close()
        }
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor { Thread(it, "site-lens-download-commands") }
        private val mutationReservations = ConcurrentHashMap<String, MutationReservation>()

        /** Validates a reservation for a path-only export cleanup. */
        internal fun ownsMutationReservation(rawId: String?, taskId: String): Boolean {
            val id = rawId?.trim().orEmpty()
            return id.isNotEmpty() && mutationReservations[id]?.taskId == taskId
        }

        fun workName(taskId: String) = "site-lens-media-" + taskId
    }
}
