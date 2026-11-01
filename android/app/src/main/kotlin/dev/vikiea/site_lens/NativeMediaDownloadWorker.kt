package dev.vikiea.site_lens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Environment
import android.os.SystemClock
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

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
        val initial = repository.read(taskId) ?: return Result.failure()
        configureMaxConcurrency(
            applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getInt(CONCURRENCY_KEY, DEFAULT_CONCURRENCY),
        )
        try {
            setForegroundAsync(
                foregroundInfo(initial, 0L, null, "等待下载"),
            ).get(15, TimeUnit.SECONDS)
        } catch (_: Exception) {
            return Result.retry()
        }
        val acquired = try {
            downloadSlots.tryAcquire(30, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!acquired) return Result.retry()
        try {
            return withFileLock(applicationContext, taskId, initial.seriesDirectory) {
                if (isObsolete()) return@withFileLock Result.failure()
                val record = repository.read(taskId) ?: return@withFileLock Result.failure()
                val partial = partialFile(applicationContext, record)
                val finalFile = finalFile(applicationContext, record)
                if (finalFile.isFile && finalFile.length() > 0L) {
                    return@withFileLock success(finalFile)
                }
                val transfer = ResumableMediaTransfer(
                    cancelled = { isObsolete() || SystemClock.elapsedRealtime() >= deadline },
                    connectForAttempt = { uri, attempt ->
                        val vpn = allowsProxyFakeIp(uri)
                        SystemMediaNetwork.openConnection(uri, allowProxyFakeIp = vpn, attempt = attempt)
                    },
                )
                ownedTransfer = transfer
                transfers[taskId] = transfer
                try {
                    partial.parentFile?.mkdirs()
                    var lastProgress = 0L
                    val initialUrl = validateUrl(record.url)
                    val sourceUrl = validateUrl(record.sourceUrl.ifBlank { record.url })
                    transfer.transfer(
                        initialUrl,
                        sourceUrl,
                        partial,
                        android.webkit.WebSettings.getDefaultUserAgent(applicationContext),
                        requestCookies = { uri ->
                            runCatching {
                                AndroidCookieReader.get(uri.toString())
                                    ?: AndroidCookieReader.get(sourceUrl.toString())
                            }.getOrNull()
                        },
                        onProgress = { bytes, total ->
                            val now = SystemClock.elapsedRealtime()
                            if (now - lastProgress >= 1000) {
                                lastProgress = now
                                setForegroundAsync(
                                    foregroundInfo(record, bytes, total, "下载中"),
                                )
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
                    if (runAttemptCount == 0) {
                        val refreshed = runCatching {
                            NativeMediaAuthRefreshService.refreshBlocking(
                                applicationContext,
                                record.taskId,
                                record.sourceUrl.ifBlank { record.url },
                                record.url,
                                record.resourceKey,
                            )
                        }.getOrDefault(mapOf("state" to "waiting_execution"))
                        when (refreshed["state"] as? String) {
                            "refreshed" -> return@withFileLock Result.retry()
                            "waiting_execution" -> return@withFileLock failure(
                                "waiting_execution",
                                refreshed["reason"]?.toString() ?: "等待系统允许后台授权刷新",
                            )
                        }
                    }
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
        } finally {
            downloadSlots.release()
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

    private fun foregroundInfo(
        record: NativeMediaTaskRepository.Record,
        bytes: Long,
        total: Long?,
        state: String,
    ): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "媒体下载", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            applicationContext,
            notificationId(record.taskId),
            Intent(applicationContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val content = if (total != null && total > 0L) {
            "$state · ${(bytes * 100 / total).coerceIn(0L, 100L)}%"
        } else {
            "$state · ${bytes / (1024 * 1024)} MB"
        }
        val builder = Notification.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(record.title)
            .setContentText(content)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (total != null && total > 0L && total <= Int.MAX_VALUE) {
            builder.setProgress(total.toInt(), bytes.coerceIn(0L, total).toInt(), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        val id = notificationId(record.taskId)
        val notification = builder.build()
        return if (android.os.Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(id, notification)
        }
    }

    private fun allowsProxyFakeIp(uri: URI): Boolean {
        val directRoute = runCatching { SystemMediaNetwork.hasDirectRoute(uri) }
            .getOrDefault(false)
        if (!directRoute) return false
        // The actual DIRECT candidate performs the DNS-range check inside
        // openConnection(); do not resolve the origin while a proxy candidate
        // may still be tried first.
        return directRoute
    }

    companion object {
        private val transfers = ConcurrentHashMap<String, ResumableMediaTransfer>()
        const val PREFERENCES = "site_lens_native_downloads"
        const val CONCURRENCY_KEY = "max_concurrency"
        private const val DEFAULT_CONCURRENCY = 2
        private const val CHANNEL = "site-lens-media-downloads"
        private val downloadSlots = DownloadSlotGate(DEFAULT_CONCURRENCY)
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

        fun <T> withFileLock(
            context: Context,
            taskId: String,
            directoryName: String? = null,
            action: () -> T,
        ): T {
            require(taskId.matches(Regex("[A-Za-z0-9._-]{1,128}")) && taskId !in listOf(".", ".."))
            val run = {
                synchronized(fileMonitors.getOrPut(taskId) { Any() }) {
                    val lock = File(root(context), "." + taskId + ".lock")
                    lock.parentFile?.mkdirs()
                    java.io.RandomAccessFile(lock, "rw").use { file ->
                        file.channel.lock().use { action() }
                    }
                }
            }
            return if (directoryName == null) run()
            else withDirectoryLocks(context, listOf(directoryName), run)
        }

        /** Serializes directory migration with every worker writing that directory. */
        fun <T> withDirectoryLocks(
            context: Context,
            names: Collection<String>,
            action: () -> T,
        ): T {
            val ordered = names.map(::validateDirectoryName).distinct().sorted()
            fun acquire(index: Int): T = if (index == ordered.size) {
                action()
            } else {
                withDirectoryLock(context, ordered[index]) { acquire(index + 1) }
            }
            return acquire(0)
        }

        private fun <T> withDirectoryLock(
            context: Context,
            name: String,
            action: () -> T,
        ): T {
            val root = root(context).canonicalFile
            val lock = File(root, ".directory-${directoryKey(name)}.lock")
            return synchronized(directoryMonitors.getOrPut(lock.path) { Any() }) {
                lock.parentFile?.mkdirs()
                java.io.RandomAccessFile(lock, "rw").use { file ->
                    file.channel.lock().use { action() }
                }
            }
        }

        private fun validateDirectoryName(name: String): String {
            require(name.isNotBlank() && name != "." && name != "..")
            require(!name.contains('/') && !name.contains('\\')) { "媒体目录无效" }
            return name
        }

        private fun directoryKey(name: String): String = MessageDigest
            .getInstance("SHA-256")
            .digest(name.toByteArray(Charsets.UTF_8))
            .take(12)
            .joinToString("") { "%02x".format(it) }

        private val directoryMonitors = ConcurrentHashMap<String, Any>()

        fun configureMaxConcurrency(value: Int) {
            downloadSlots.configure(value)
        }

        fun postProgressNotification(
            context: Context,
            taskId: String,
            title: String,
            bytes: Long,
            total: Long?,
        ) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "媒体下载", NotificationManager.IMPORTANCE_LOW),
            )
            val content = if (total != null && total > 0L) {
                "下载中 · ${(bytes * 100 / total).coerceIn(0L, 100L)}%"
            } else {
                "下载中 · ${bytes / (1024 * 1024)} MB"
            }
            val builder = Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(content)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
            if (total != null && total > 0L && total <= Int.MAX_VALUE) {
                builder.setProgress(total.toInt(), bytes.coerceIn(0L, total).toInt(), false)
            } else {
                builder.setProgress(0, 0, true)
            }
            manager.notify(notificationId(taskId), builder.build())
        }

        fun clearProgressNotification(context: Context, taskId: String) {
            context.getSystemService(NotificationManager::class.java)
                .cancel(notificationId(taskId))
        }

        private fun notificationId(taskId: String): Int =
            taskId.hashCode().and(Int.MAX_VALUE).coerceAtLeast(1)

        fun validateUrl(raw: String): URI {
            val uri = URI(raw.trim())
            SystemMediaNetwork.validateTarget(uri)
            return uri
        }

    }
}

private class DownloadSlotGate(initial: Int) {
    private val monitor = Object()
    private var limit = initial.coerceIn(1, 6)
    private var active = 0

    fun configure(value: Int) {
        synchronized(monitor) {
            limit = value.coerceIn(1, 6)
            monitor.notifyAll()
        }
    }

    fun tryAcquire(timeout: Long, unit: TimeUnit): Boolean {
        val deadline = SystemClock.elapsedRealtime() + unit.toMillis(timeout)
        synchronized(monitor) {
            while (active >= limit) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                if (remaining <= 0L) return false
                try {
                    monitor.wait(remaining)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
            active++
            return true
        }
    }

    fun release() {
        synchronized(monitor) {
            active = (active - 1).coerceAtLeast(0)
            monitor.notifyAll()
        }
    }
}
