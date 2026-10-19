package dev.vikiea.site_lens

import android.content.Context
import android.os.Environment
import android.os.SystemClock
import androidx.work.Data
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/** Bounded native work slices. WorkManager reschedules interrupted work with
 * the same durable partial; no Flutter engine or Activity is needed. */
class NativeMediaDownloadWorker(appContext: Context, params: WorkerParameters) : Worker(appContext, params) {
    private val repository = NativeMediaTaskRepository(appContext)
    @Volatile private var ownedTransfer: ResumableMediaTransfer? = null

    override fun doWork(): Result {
        val taskId = inputData.getString("taskId") ?: return failure("invalid_task", "缺少任务 ID")
        val deadline = SystemClock.elapsedRealtime() + 6 * 60_000L
        fun isObsolete(): Boolean {
            val current = repository.read(taskId)
            return isStopped || current == null || current.workId != id.toString() || current.paused || current.cancelled
        }
        return withFileLock(applicationContext, taskId) {
            if (isObsolete()) return@withFileLock Result.failure()
            val record = repository.read(taskId) ?: return@withFileLock Result.failure()
            val partial = partialFile(applicationContext, record)
            val finalFile = finalFile(applicationContext, record)
            if (finalFile.isFile && finalFile.length() > 0L) {
                return@withFileLock success(finalFile)
            }
            val transfer = ResumableMediaTransfer(
                cancelled = { isObsolete() || SystemClock.elapsedRealtime() >= deadline },
            )
            ownedTransfer = transfer
            transfers[taskId] = transfer
            try {
                partial.parentFile?.mkdirs()
                var lastProgress = 0L
                transfer.transfer(
                    validateUrl(record.url),
                    validateUrl(record.sourceUrl.ifBlank { record.url }),
                    partial,
                    "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 "
                        + "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
                    onProgress = { bytes, total ->
                        val now = SystemClock.elapsedRealtime()
                        if (now - lastProgress >= 1000) {
                            lastProgress = now
                            setProgressAsync(Data.Builder().putLong("bytesDownloaded", bytes)
                                .putLong("totalBytes", total ?: -1L).build())
                        }
                    },
                )
                val published = transfer.publishIfActive(::isObsolete) {
                    check(partial.length() > 0L) { "媒体响应为空" }
                    check(partial.renameTo(finalFile)) { "无法提交媒体文件" }
                }
                if (published == null) return@withFileLock Result.failure()
                File(partial.path + ".resume").delete()
                File(partial.path + ".resume.tmp").delete()
                success(finalFile)
            } catch (error: MediaAuthorizationException) {
                failure("reauthorize", "下载地址需要重新授权")
            } catch (error: InterruptedIOException) {
                if (isObsolete()) Result.failure() else Result.retry()
            } catch (error: IOException) {
                if (isObsolete()) Result.failure()
                else if (runAttemptCount < 4) Result.retry()
                else failure("network", "网络连接中断，已保留已下载内容，可重试")
            } catch (error: Exception) {
                failure("download_failed", error.message ?: "媒体下载失败")
            } finally {
                transfers.remove(taskId, transfer)
                ownedTransfer = null
            }
        }
    }

    override fun onStopped() {
        ownedTransfer?.abort()
        super.onStopped()
    }

    private fun success(file: File): Result = Result.success(
        Data.Builder().putLong("bytesDownloaded", file.length()).putLong("totalBytes", file.length())
            .putString("localUri", android.net.Uri.fromFile(file).toString()).build(),
    )
    private fun failure(code: String, reason: String): Result =
        Result.failure(Data.Builder().putString("errorCode", code).putString("errorReason", reason).build())

    companion object {
        private val transfers = ConcurrentHashMap<String, ResumableMediaTransfer>()
        // In-process monitors prevent OverlappingFileLockException while the
        // OS lock additionally protects against a second app process.
        private val fileMonitors = ConcurrentHashMap<String, Any>()
        fun abort(taskId: String) { transfers[taskId]?.abort() }

        fun root(context: Context): File = File(
            context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: File(context.filesDir, "downloads"), "site-lens",
        )

        private fun directory(context: Context, record: NativeMediaTaskRepository.Record): File {
            require(record.taskId.matches(Regex("[A-Za-z0-9._-]{1,128}")))
            require(record.taskId != "." && record.taskId != "..")
            val root = root(context).canonicalFile
            val directory = File(root, record.seriesDirectory).canonicalFile
            require(directory.path.startsWith(root.path + File.separator)) { "媒体目录越界" }
            return directory
        }
        fun partialFile(context: Context, record: NativeMediaTaskRepository.Record) =
            File(directory(context, record), record.taskId + ".media.part")
        fun finalFile(context: Context, record: NativeMediaTaskRepository.Record) =
            File(directory(context, record), record.taskId + ".media")
        fun files(context: Context, record: NativeMediaTaskRepository.Record): List<File> = listOf(
            partialFile(context, record), finalFile(context, record),
            File(partialFile(context, record).path + ".resume"),
            File(partialFile(context, record).path + ".resume.tmp"),
            File(finalFile(context, record).path + ".legacy.tmp"),
            File(partialFile(context, record).path + ".legacy.tmp"),
        )

        fun <T> withFileLock(context: Context, taskId: String, action: () -> T): T {
            require(taskId.matches(Regex("[A-Za-z0-9._-]{1,128}")) && taskId !in listOf(".", ".."))
            return synchronized(fileMonitors.getOrPut(taskId) { Any() }) {
                val lock = File(root(context), "." + taskId + ".lock")
                lock.parentFile?.mkdirs()
                java.io.RandomAccessFile(lock, "rw").use { file -> file.channel.lock().use { action() } }
            }
        }

        fun validateUrl(raw: String): URI {
            val uri = URI(raw.trim())
            require(uri.scheme?.lowercase() in setOf("http", "https") &&
                !uri.host.isNullOrBlank() && uri.userInfo == null) { "媒体地址无效" }
            return uri
        }
    }
}
