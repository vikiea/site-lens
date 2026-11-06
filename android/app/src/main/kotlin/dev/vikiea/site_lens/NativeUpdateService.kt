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
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request as HttpRequest
import okhttp3.Response
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max

/** Durable, single-transfer Android owner for the APK network stream. */
class NativeUpdateService : Service() {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "site-lens-update").apply { isDaemon = true }
    }
    /**
     * The APK download uses the same route as the browser and the media queue.
     * It is rebuilt per call because the tunnel can come up or go away between
     * transfers, and a bound client pins the network it was created for.
     */
    private fun httpClient(target: String): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(20, java.util.concurrent.TimeUnit.SECONDS)
            .callTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(false)
        val tunnel = SystemMediaNetwork.vpnNetwork(
            getSystemService(android.net.ConnectivityManager::class.java),
        )
        // Only a synthesized answer expects tunnel sockets; a real address must
        // leave through the underlay or the tunnel drops it.
        val tunnelSocketsNeeded = tunnel != null && runCatching {
            SystemMediaNetwork.tunnelResolvesToSynthesized(tunnel, java.net.URI(target))
        }.getOrDefault(false)
        if (tunnelSocketsNeeded) SystemMediaNetwork.bindToVpn(this, builder)
        if (tunnel != null) {
            // Resolve inside the tunnel, but never accept a synthesized address:
            // a host the tunnel routes DIRECT would point at an address nothing
            // answers. A real address is reachable either way.
            builder.dns(object : okhttp3.Dns {
                override fun lookup(hostname: String): List<java.net.InetAddress> {
                    val answer = tunnel.getAllByName(hostname).toList()
                    if (answer.isEmpty() || answer.any { !SystemMediaNetwork.fakeIp(it) }) {
                        return answer
                    }
                    return runCatching { okhttp3.Dns.SYSTEM.lookup(hostname) }
                        .getOrElse { answer }
                }
            })
        }
        return builder.build()
    }
    private val pauseRequested = AtomicBoolean(false)
    private val userPause = AtomicBoolean(true)
    private val deleteRequested = AtomicBoolean(false)
    private val jobGeneration = java.util.concurrent.atomic.AtomicLong(0L)
    private val activeCall = AtomicReference<Call?>(null)
    @Volatile private var current: UpdateRequest? = null
    @Volatile private var destroyed = false
    @Volatile private var foregroundReady = false

    override fun onCreate() {
        super.onCreate()
        synchronized(lock) { instance = this }
        try {
            ensureForeground(null)
            foregroundReady = true
        } catch (error: Exception) {
            readState(applicationContext)?.request?.let { request ->
                val message = error.message ?: "更新前台服务启动失败"
                writeState(PersistedState(STATE_FAILED, request, null, message))
                emit(
                    "nativeUpdateState",
                    snapshot(applicationContext, request, STATE_FAILED, false, error = message),
                )
            }
            destroyed = true
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!foregroundReady) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent?.action) {
            ACTION_START, ACTION_RESUME -> {
                val request = UpdateRequest.fromIntent(intent) ?: readState(applicationContext)?.request
                if (request != null) startTransfer(request)
            }
            ACTION_PAUSE -> pause(true)
            ACTION_DELETE -> {
                val request = UpdateRequest.fromIntent(intent) ?: readState(applicationContext)?.request
                if (request != null) delete(request)
                stopSelf(startId)
            }
            else -> {
                val state = readState(applicationContext)
                if (state?.state == STATE_RUNNING) state.request?.let(::startTransfer)
                else stopDetached()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        destroyed = true
        // Keep the durable state resumable if Android tears down the service
        // while the stream is active. The worker will observe the new
        // generation and must not publish a stale failure over that state.
        pauseRequested.set(true)
        jobGeneration.incrementAndGet()
        activeCall.getAndSet(null)?.cancel()
        worker.shutdownNow()
        synchronized(lock) { if (instance === this) instance = null }
        super.onDestroy()
    }

    private fun startTransfer(request: UpdateRequest) {
        runCatching { request.validate() }.onFailure { error ->
            publishFailure(request, error.message ?: "更新参数无效")
            return
        }
        synchronized(jobLock) {
            val existing = current
            if (existing != null) {
                if (existing == request) return
                publishFailure(request, "已有更新下载正在进行")
                return
            }
            current = request
            val generation = jobGeneration.incrementAndGet()
            pauseRequested.set(false)
            userPause.set(false)
            deleteRequested.set(false)
            updatePartialPause(request, false)
            writeState(PersistedState(STATE_RUNNING, request, null, null))
            worker.execute { download(request, generation) }
        }
    }

    private fun pause(byUser: Boolean) {
        pauseRequested.set(true)
        userPause.set(byUser)
        activeCall.get()?.cancel()
        val request = current ?: readState(applicationContext)?.request
        if (request == null) return
        updatePartialPause(request, byUser)
        writeState(PersistedState(STATE_PAUSED, request, null, null))
        publishSnapshot(snapshot(applicationContext, request, STATE_PAUSED, byUser))
        if (current == null) stopDetached()
    }

    private fun download(request: UpdateRequest, generation: Long) {
        try {
            val paths = paths(request)
            var received = if (paths.part.isFile) paths.part.length() else 0L
            var meta = readPartial(paths.meta)
            if (meta == null || meta.tagName != request.tagName || meta.sha256 != request.sha256) {
                paths.part.delete()
                paths.meta.delete()
                received = 0L
                meta = null
            }
            if (received > NativeUpdatePolicy.MAX_APK_BYTES) throw DownloadFailure("APK 大小超过限制")
            var total = max(meta?.total ?: 0L, request.apkSize.toLong())
            var etag = meta?.etag
            var lastModified = meta?.lastModified
            var attempt = 0
            var responses = 0
            var transferred = false
            while (!transferred) {
                received = if (paths.part.isFile) paths.part.length() else 0L
                meta = readPartial(paths.meta)
                etag = meta?.etag ?: etag
                lastModified = meta?.lastModified ?: lastModified
                if (generation != jobGeneration.get() || deleteRequested.get()) return
                if (pauseRequested.get()) return finishPaused(request, received, total, etag, lastModified)
                if (++responses > 16) {
                    finishPaused(request, received, total, etag, lastModified)
                    return
                }
                try {
                    val response = open(request, received, etag ?: lastModified)
                    response.use {
                        when (it.code) {
                            416 -> {
                                paths.part.delete()
                                paths.meta.delete()
                                received = 0L
                                total = request.apkSize.toLong()
                                etag = null
                                lastModified = null
                                return@use
                            }
                            200, 206 -> {
                                val range = NativeUpdatePolicy.parseContentRange(it.header("Content-Range"))
                                if (it.code == 206 && (range == null || range.start != received)) {
                                    paths.part.delete()
                                    paths.meta.delete()
                                    received = 0L
                                    total = request.apkSize.toLong()
                                    etag = null
                                    lastModified = null
                                    return@use
                                }
                                val contentRange = range
                                if (received > 0L && it.code == 206 && contentRange != null && total > 0L && contentRange.total != total) {
                                    paths.part.delete()
                                    paths.meta.delete()
                                    received = 0L
                                    total = contentRange.total
                                    etag = it.header("ETag")
                                    lastModified = it.header("Last-Modified")
                                    return@use
                                }
                                if (received > 0L && it.code == 200) {
                                    paths.part.delete()
                                    paths.meta.delete()
                                    received = 0L
                                }
                                total = when {
                                    range != null -> range.total
                                    it.body?.contentLength() != null && it.body!!.contentLength() >= 0L -> it.body!!.contentLength()
                                    else -> max(total, request.apkSize.toLong())
                                }
                                if (total > NativeUpdatePolicy.MAX_APK_BYTES) throw DownloadFailure("APK 大小超过限制")
                                etag = it.header("ETag") ?: etag
                                lastModified = it.header("Last-Modified") ?: lastModified
                                writePartial(paths.meta, request, received, total, etag, lastModified, false)
                                val body = it.body ?: throw IOException("更新响应没有内容")
                                FileOutputStream(paths.part, received > 0L).use { output ->
                                    body.byteStream().use { input ->
                                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                        var sinceFlush = 0L
                                        while (true) {
                                            if (pauseRequested.get()) break
                                            val count = input.read(buffer)
                                            if (count < 0) break
                                            received += count
                                            if (received > NativeUpdatePolicy.MAX_APK_BYTES || (total > 0L && received > total)) {
                                                throw DownloadFailure("APK 大小与发布信息不符")
                                            }
                                            output.write(buffer, 0, count)
                                            sinceFlush += count
                                            if (sinceFlush >= FLUSH_BYTES) {
                                                output.flush()
                                                output.fd.sync()
                                                writePartial(paths.meta, request, received, total, etag, lastModified, false)
                                                publishSnapshot(snapshot(applicationContext, request, STATE_RUNNING, false, received, total, etag, lastModified))
                                                sinceFlush = 0L
                                            }
                                        }
                                        output.flush()
                                        output.fd.sync()
                                    }
                                }
                                if (deleteRequested.get()) return
                                if (pauseRequested.get()) {
                                    finishPaused(request, received, total, etag, lastModified)
                                    return
                                }
                                writePartial(paths.meta, request, received, total, etag, lastModified, false)
                                if (total > 0L && received < total) throw IOException("下载连接中断")
                                transferred = true
                            }
                            404 -> throw DownloadFailure("更新包地址不可用，请稍后重试")
                            else -> {
                                if (it.code in 408..429 || it.code >= 500) throw IOException("更新服务返回 HTTP ${it.code}")
                                throw DownloadFailure("APK 下载返回 HTTP ${it.code}")
                            }
                        }
                    }
                    attempt = 0
                } catch (error: DownloadFailure) {
                    if (generation != jobGeneration.get() || deleteRequested.get()) return
                    paths.part.delete()
                    paths.meta.delete()
                    discardHandoff(request)
                    publishFailure(request, error.message ?: "更新下载失败")
                    return
                } catch (_: IOException) {
                    if (generation != jobGeneration.get() || deleteRequested.get()) return
                    if (pauseRequested.get()) return finishPaused(request, received, total, etag, lastModified)
                    if (attempt >= NativeUpdatePolicy.RETRY_DELAYS_MS.size) {
                        finishPaused(request, received, total, etag, lastModified)
                        return
                    }
                    sleepBounded(NativeUpdatePolicy.RETRY_DELAYS_MS[attempt])
                    attempt++
                }
            }
            if (!transferred) return
            if (!isCurrentJob(request, generation)) return
            val handoffFile = handoff(applicationContext, request)
            FileInputStream(paths.part).use { input ->
                FileOutputStream(handoffFile).use { output ->
                    input.copyTo(output)
                    output.flush()
                    output.fd.sync()
                }
            }
            if (!isCurrentJob(request, generation)) return
            val handoffSize = handoffFile.length()
            if (!sha256(handoffFile).equals(request.sha256, ignoreCase = true)) {
                discardHandoff(request)
                throw DownloadFailure("APK 校验失败，请重新下载")
            }
            writeReadyMarker(handoffFile, request, handoffSize)
            writeState(PersistedState(STATE_READY, request, handoffFile.absolutePath, null))
            publishSnapshot(snapshot(applicationContext, request, STATE_READY, false, handoffSize, handoffSize, etag, lastModified, handoffFile.absolutePath))
            stopDetached()
        } catch (error: DownloadFailure) {
            if (generation != jobGeneration.get() || deleteRequested.get()) return
            discardHandoff(request)
            publishFailure(request, error.message ?: "更新下载失败")
        } catch (error: Exception) {
            if (generation != jobGeneration.get() || deleteRequested.get()) return
            if (pauseRequested.get()) finishPaused(request, fileLength(request), request.apkSize.toLong(), null, null)
            else publishFailure(request, error.message ?: "更新下载失败")
        } finally {
            if (current === request && jobGeneration.get() == generation) current = null
            activeCall.set(null)
        }
    }

    private fun isCurrentJob(request: UpdateRequest, generation: Long): Boolean =
        current === request && generation == jobGeneration.get() && !deleteRequested.get()

    private fun discardHandoff(request: UpdateRequest) {
        val file = handoff(applicationContext, request)
        file.delete()
        File(file.absolutePath + ".json").delete()
    }

    private fun writeReadyMarker(file: File, request: UpdateRequest, size: Long) {
        val marker = JSONObject()
            .put("tagName", request.tagName)
            .put("sha256", request.sha256)
            .put("size", size)
        atomicWrite(File(file.absolutePath + ".json"), marker.toString())
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun open(request: UpdateRequest, offset: Long, ifRange: String?): Response {
        var url = NativeUpdatePolicy.initialUrl(request.apkUrl, request.tagName, request.apkName)
        for (hop in 0..NativeUpdatePolicy.MAX_REDIRECTS) {
            val builder = HttpRequest.Builder()
                .url(url)
                .header("User-Agent", "SiteLens/vikiea/site-lens")
                .header("Accept", "application/octet-stream")
            if (offset > 0L) {
                builder.header("Range", "bytes=$offset-")
                if (!ifRange.isNullOrBlank()) builder.header("If-Range", ifRange)
            }
            val call = httpClient(url.toString()).newCall(builder.get().build())
            activeCall.set(call)
            val response = try { call.execute() } finally { activeCall.compareAndSet(call, null) }
            if (response.code !in REDIRECTS) return response
            val location = response.header("Location") ?: run {
                response.close()
                throw DownloadFailure("更新地址重定向无效")
            }
            response.close()
            if (hop == NativeUpdatePolicy.MAX_REDIRECTS) throw DownloadFailure("更新地址重定向过多")
            url = NativeUpdatePolicy.redirectUrl(url.resolve(location)?.toString() ?: "")
        }
        throw DownloadFailure("更新地址重定向过多")
    }

    private fun finishPaused(request: UpdateRequest, received: Long, total: Long, etag: String?, lastModified: String?) {
        val actual = fileLength(request)
        val paths = paths(request)
        writePartial(paths.meta, request, actual, total, etag, lastModified, userPause.get())
        writeState(PersistedState(STATE_PAUSED, request, null, null))
        publishSnapshot(snapshot(applicationContext, request, STATE_PAUSED, userPause.get(), actual, total, etag, lastModified))
        stopDetached()
    }

    private fun publishFailure(request: UpdateRequest, message: String) {
        writeState(PersistedState(STATE_FAILED, request, null, message))
        publishSnapshot(snapshot(applicationContext, request, STATE_FAILED, false, error = message))
        stopDetached()
    }

    private fun publishSnapshot(value: Map<String, Any?>) {
        updateNotification(value)
        emit("nativeUpdateState", value)
    }

    private fun emit(method: String, value: Map<String, Any?>) {
        synchronized(lock) { eventSink }?.invoke(method, value)
    }

    private fun updateNotification(value: Map<String, Any?>) {
        val state = value["state"] as? String ?: STATE_RUNNING
        val received = (value["received"] as? Number)?.toInt() ?: 0
        val total = (value["total"] as? Number)?.toInt() ?: 0
        ensureForeground(value)
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification(value, state, received, total))
    }

    private fun ensureForeground(value: Map<String, Any?>?) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "软件更新", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = notification(value ?: emptyMap(), value?.get("state") as? String ?: STATE_RUNNING, (value?.get("received") as? Number)?.toInt() ?: 0, (value?.get("total") as? Number)?.toInt() ?: 0)
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(NOTIFICATION_ID, notification)
    }

    private fun notification(value: Map<String, Any?>, state: String, received: Int, total: Int): Notification {
        val open = PendingIntent.getActivity(
            this,
            24061,
            Intent(this, MainActivity::class.java).apply {
                action = ACTION_OPEN_UPDATE_ROUTE
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Site Lens 软件更新")
            .setContentText(
                when (state) {
                    STATE_PAUSED -> "下载已暂停，可继续"
                    STATE_TRANSFERRED -> "下载完成，正在等待应用校验"
                    STATE_FAILED -> value["error"] as? String ?: "下载失败，可重试"
                    else -> "正在下载更新"
                },
            )
            .setContentIntent(open)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
        if (total > 0) builder.setProgress(total, received.coerceAtMost(total), false)
        if (state == STATE_RUNNING) {
            builder.setOngoing(true).addAction(
                Notification.Action.Builder(
                    null,
                    "暂停",
                    servicePendingIntent(ACTION_PAUSE),
                ).build(),
            )
        } else if (state == STATE_PAUSED || state == STATE_FAILED) {
            builder.setOngoing(false).addAction(
                Notification.Action.Builder(
                    null,
                    "继续",
                    servicePendingIntent(ACTION_RESUME),
                ).build(),
            )
        } else {
            builder.setOngoing(false).setAutoCancel(true)
        }
        return builder.build()
    }

    private fun servicePendingIntent(action: String): PendingIntent = PendingIntent.getService(
        this,
        if (action == ACTION_PAUSE) 24062 else 24063,
        Intent(this, NativeUpdateService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun stopDetached(removeNotification: Boolean = false) {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(if (removeNotification) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
        }
        else @Suppress("DEPRECATION") stopForeground(false)
        stopSelf()
    }

    private fun delete(request: UpdateRequest) {
        synchronized(jobLock) {
            jobGeneration.incrementAndGet()
            deleteRequested.set(true)
            pauseRequested.set(true)
            activeCall.get()?.cancel()
            // The worker owns the partial and handoff files. Join it before
            // deleting anything so a late callback cannot recreate output.
            while (current != null) {
                Thread.sleep(20L)
            }
            val path = paths(request)
            path.part.delete()
            path.meta.delete()
            val target = handoff(applicationContext, request)
            target.delete()
            File(target.absolutePath + ".json").delete()
            val state = readState(applicationContext)
            if (state?.request?.tagName == request.tagName) stateFile(applicationContext).delete()
            publishSnapshot(mapOf("state" to STATE_IDLE))
            stopDetached(removeNotification = true)
        }
    }

    private fun fileLength(request: UpdateRequest): Long = paths(request).part.takeIf { it.isFile }?.length() ?: 0L

    private fun paths(request: UpdateRequest): Paths {
        val directory = File(filesDir, WORK_DIRECTORY).apply { mkdirs() }
        val part = File(directory, "site-lens-${request.tagName}.apk.part")
        return Paths(part, File(part.absolutePath + ".json"))
    }

    private fun handoff(context: Context, request: UpdateRequest): File =
        File(File(context.cacheDir, WORK_DIRECTORY).apply { mkdirs() }, request.apkName)

    private fun updatePartialPause(request: UpdateRequest, paused: Boolean) {
        val path = paths(request)
        val meta = readPartial(path.meta) ?: return
        writePartial(path.meta, request, path.part.length(), meta.total, meta.etag, meta.lastModified, paused)
    }

    private fun writePartial(file: File, request: UpdateRequest, received: Long, total: Long, etag: String?, lastModified: String?, paused: Boolean) {
        val json = JSONObject()
            .put("tagName", request.tagName)
            .put("sha256", request.sha256)
            .put("apkUrl", request.apkUrl)
            .put("received", received)
            .put("total", total)
            .put("updatedAt", Instant.now().toString())
            .putOpt("etag", etag)
            .putOpt("lastModified", lastModified)
            .put("pausedByUser", paused)
        atomicWrite(file, json.toString())
    }

    private fun readPartial(file: File): Partial? = runCatching {
        if (!file.isFile) return null
        val json = JSONObject(file.readText())
        Partial(
            json.getString("tagName"),
            json.getString("sha256"),
            json.optLong("total", 0L),
            json.optString("etag").takeIf { it.isNotBlank() },
            json.optString("lastModified").takeIf { it.isNotBlank() },
            json.optBoolean("pausedByUser", false),
        )
    }.getOrNull()

    private fun writeState(state: PersistedState) {
        val json = JSONObject().put("state", state.state)
        state.request?.toJson(json)
        json.putOpt("path", state.path).putOpt("error", state.error)
        atomicWrite(stateFile(applicationContext), json.toString())
    }

    private fun readState(context: Context): PersistedState? = runCatching {
        val file = stateFile(context)
        if (!file.isFile) return null
        val json = JSONObject(file.readText())
        val request = UpdateRequest.fromJson(json)
        PersistedState(json.optString("state", STATE_IDLE), request, json.optString("path").takeIf { it.isNotBlank() }, json.optString("error").takeIf { it.isNotBlank() })
    }.getOrNull()

    private fun snapshot(
        context: Context,
        request: UpdateRequest,
        state: String,
        pausedByUser: Boolean,
        received: Long = fileLength(request),
        total: Long = request.apkSize.toLong(),
        etag: String? = null,
        lastModified: String? = null,
        path: String? = null,
        error: String? = null,
    ): Map<String, Any?> = mapOf(
        "state" to state,
        "tagName" to request.tagName,
        "sha256" to request.sha256,
        "received" to received,
        "total" to total,
        "path" to path,
        "pausedByUser" to pausedByUser,
        "etag" to etag,
        "lastModified" to lastModified,
        "error" to error,
    )

    private fun sleepBounded(duration: Long) {
        var remaining = duration
        while (remaining > 0L && !pauseRequested.get()) {
            val slice = minOf(remaining, 100L)
            Thread.sleep(slice)
            remaining -= slice
        }
    }

    private fun atomicWrite(file: File, value: String) {
        file.parentFile?.mkdirs()
        val temporary = File(file.absolutePath + ".tmp")
        FileOutputStream(temporary).use { output ->
            output.write(value.toByteArray(Charsets.UTF_8))
            output.flush()
            output.fd.sync()
        }
        check(temporary.renameTo(file) || run { file.delete(); temporary.renameTo(file) }) { "无法保存更新状态" }
    }

    private data class Paths(val part: File, val meta: File)
    private data class Partial(val tagName: String, val sha256: String, val total: Long, val etag: String?, val lastModified: String?, val pausedByUser: Boolean)
    private data class PersistedState(val state: String, val request: UpdateRequest?, val path: String?, val error: String?)
    private class DownloadFailure(message: String) : Exception(message)

    data class UpdateRequest(
        val tagName: String,
        val sha256: String,
        val apkUrl: String,
        val apkName: String,
        val apkSize: Int,
    ) {
        fun validate() {
            NativeUpdatePolicy.initialUrl(apkUrl, tagName, apkName)
            require(sha256.matches(Regex("[0-9a-fA-F]{64}"))) { "更新校验值格式错误" }
            require(apkSize >= 0) { "更新大小无效" }
        }

        fun toJson(json: JSONObject) {
            json.put("tagName", tagName).put("sha256", sha256).put("apkUrl", apkUrl)
                .put("apkName", apkName).put("apkSize", apkSize)
        }

        fun toIntent(intent: Intent): Intent = intent.putExtra(EXTRA_TAG, tagName)
            .putExtra(EXTRA_SHA256, sha256).putExtra(EXTRA_URL, apkUrl)
            .putExtra(EXTRA_NAME, apkName).putExtra(EXTRA_SIZE, apkSize)

        companion object {
            fun fromIntent(intent: Intent): UpdateRequest? {
                val tag = intent.getStringExtra(EXTRA_TAG) ?: return null
                val sha = intent.getStringExtra(EXTRA_SHA256) ?: return null
                val url = intent.getStringExtra(EXTRA_URL) ?: return null
                val name = intent.getStringExtra(EXTRA_NAME) ?: return null
                return UpdateRequest(tag, sha, url, name, intent.getIntExtra(EXTRA_SIZE, 0))
            }

            fun fromJson(json: JSONObject): UpdateRequest? {
                val tag = json.optString("tagName").takeIf { it.isNotBlank() } ?: return null
                val sha = json.optString("sha256").takeIf { it.isNotBlank() } ?: return null
                val url = json.optString("apkUrl").takeIf { it.isNotBlank() } ?: return null
                val name = json.optString("apkName").takeIf { it.isNotBlank() } ?: "site-lens-$tag.apk"
                return UpdateRequest(tag, sha, url, name, json.optInt("apkSize", 0))
            }
        }
    }

    companion object {
        const val ACTION_START = "dev.vikiea.site_lens.UPDATE_START"
        const val ACTION_RESUME = "dev.vikiea.site_lens.UPDATE_RESUME"
        const val ACTION_PAUSE = "dev.vikiea.site_lens.UPDATE_PAUSE"
        const val ACTION_DELETE = "dev.vikiea.site_lens.UPDATE_DELETE"
        const val ACTION_OPEN_UPDATE_ROUTE = "dev.vikiea.site_lens.UPDATE_OPEN_ROUTE"
        const val WORK_DIRECTORY = "site-lens-updates"
        const val STATE_RUNNING = "downloading"
        const val STATE_PAUSED = "paused"
        const val STATE_TRANSFERRED = "transferred"
        const val STATE_READY = "ready"
        const val STATE_FAILED = "failed"
        const val STATE_IDLE = "idle"
        const val EXTRA_TAG = "tagName"
        const val EXTRA_SHA256 = "sha256"
        const val EXTRA_URL = "apkUrl"
        const val EXTRA_NAME = "apkName"
        const val EXTRA_SIZE = "apkSize"
        private const val CHANNEL = "site-lens-update"
        private const val NOTIFICATION_ID = 24061
        private const val FLUSH_BYTES = 1024L * 1024L
        private val REDIRECTS = setOf(301, 302, 303, 307, 308)
        private val lock = Any()
        private val jobLock = Any()
        private var instance: NativeUpdateService? = null
        private var eventSink: ((String, Map<String, Any?>) -> Unit)? = null

        fun setEventSink(sink: ((String, Map<String, Any?>) -> Unit)?) {
            synchronized(lock) { eventSink = sink }
        }

        fun start(context: Context, request: UpdateRequest): Map<String, Any?> {
            request.validate()
            val app = context.applicationContext
            synchronized(jobLock) {
                val active = synchronized(lock) { instance }?.current
                require(active == null || active == request) { "已有更新下载正在进行" }
            }
            val stateFile = stateFile(app)
            val existing = readStateStatic(app)
            if (existing?.request?.tagName == request.tagName &&
                existing.request.sha256 == request.sha256 &&
                (existing.state == STATE_TRANSFERRED || existing.state == STATE_READY)
            ) {
                val part = File(app.filesDir, "$WORK_DIRECTORY/site-lens-${request.tagName}.apk.part")
                if (part.isFile && part.length() > 0L) {
                    val handoff = File(File(app.cacheDir, WORK_DIRECTORY).apply { mkdirs() }, request.apkName)
                    if (!handoff.isFile || handoff.length() != part.length()) {
                        part.copyTo(handoff, overwrite = true)
                    }
                    return snapshotStatic(request, STATE_READY, part.length(), request.apkSize.toLong(), handoff.absolutePath)
                }
            }
            val state = JSONObject().put("state", STATE_RUNNING)
            request.toJson(state)
            atomicWriteStatic(stateFile, state.toString())
            val intent = request.toIntent(Intent(app, NativeUpdateService::class.java).setAction(ACTION_START))
            try {
            ContextCompat.startForegroundService(app, intent)
            } catch (error: Exception) {
                stateFile(app).delete()
                throw error
            }
            val part = File(app.filesDir, "$WORK_DIRECTORY/site-lens-${request.tagName}.apk.part")
            return snapshotStatic(request, STATE_RUNNING, if (part.isFile) part.length() else 0L, request.apkSize.toLong(), null)
        }

        fun pause(context: Context): Map<String, Any?> {
            val service = synchronized(lock) { instance }
            if (service != null) {
                service.pause(true)
                return query(context)
            }
            val state = readStateStatic(context.applicationContext) ?: return mapOf("state" to STATE_IDLE)
            val request = state.request ?: return mapOf("state" to STATE_IDLE)
            val intent = Intent(context.applicationContext, NativeUpdateService::class.java).setAction(ACTION_PAUSE)
            ContextCompat.startForegroundService(context.applicationContext, intent)
            return snapshotStatic(request, STATE_PAUSED, 0L, request.apkSize.toLong(), null, true)
        }

        fun delete(context: Context, request: UpdateRequest): Map<String, Any?> {
            val service = synchronized(lock) { instance }
            if (service != null) service.delete(request) else {
                File(context.filesDir, "$WORK_DIRECTORY/site-lens-${request.tagName}.apk.part").delete()
                File(context.filesDir, "$WORK_DIRECTORY/site-lens-${request.tagName}.apk.part.json").delete()
                val handoff = File(File(context.cacheDir, WORK_DIRECTORY).apply { mkdirs() }, request.apkName)
                handoff.delete()
                File(handoff.absolutePath + ".json").delete()
                stateFile(context.applicationContext).delete()
            }
            return mapOf("state" to STATE_IDLE)
        }

        fun deleteStale(context: Context, keepTag: String): Map<String, Any?> {
            require(NativeUpdatePolicy.isValidTagName(keepTag)) { "更新标签格式错误" }
            val app = context.applicationContext
            val activeTag = synchronized(lock) { instance }?.current?.tagName
            deleteStaleFiles(File(app.filesDir, WORK_DIRECTORY), keepTag, activeTag)
            deleteStaleFiles(File(app.cacheDir, WORK_DIRECTORY), keepTag, activeTag)
            val state = readStateStatic(app)
            val stateRequest = state?.request
            if (stateRequest != null && stateRequest.tagName != keepTag && stateRequest.tagName != activeTag) {
                stateFile(app).delete()
            }
            return mapOf("state" to (state?.state ?: STATE_IDLE))
        }

        fun query(context: Context): Map<String, Any?> {
            val state = readStateStatic(context.applicationContext) ?: return mapOf("state" to STATE_IDLE)
            val request = state.request ?: return mapOf("state" to STATE_IDLE)
            val part = File(context.filesDir, "$WORK_DIRECTORY/site-lens-${request.tagName}.apk.part")
            val meta = runCatching {
                JSONObject(File(part.absolutePath + ".json").readText())
            }.getOrNull()
        val persistedPath = state.path?.let { File(it).takeIf(File::isFile)?.absolutePath }
        val path = persistedPath ?: if ((state.state == STATE_TRANSFERRED || state.state == STATE_READY) && part.isFile) part.absolutePath else null
            return snapshotStatic(request, state.state, if (part.isFile) part.length() else 0L, meta?.optLong("total", request.apkSize.toLong()) ?: request.apkSize.toLong(), path, meta?.optBoolean("pausedByUser", false) ?: false, state.error)
                .toMutableMap().apply {
                    put("etag", meta?.optString("etag")?.takeIf { it.isNotBlank() })
                    put("lastModified", meta?.optString("lastModified")?.takeIf { it.isNotBlank() })
                }
        }

        private fun stateFile(context: Context): File = File(File(context.filesDir, WORK_DIRECTORY).apply { mkdirs() }, ".native-state.json")

        private fun readStateStatic(context: Context): PersistedState? = runCatching {
            val file = stateFile(context)
            if (!file.isFile) return null
            val json = JSONObject(file.readText())
            PersistedState(json.optString("state", STATE_IDLE), UpdateRequest.fromJson(json), json.optString("path").takeIf { it.isNotBlank() }, json.optString("error").takeIf { it.isNotBlank() })
        }.getOrNull()

        private fun snapshotStatic(request: UpdateRequest, state: String, received: Long, total: Long, path: String?, paused: Boolean = false, error: String? = null): Map<String, Any?> = mapOf(
            "state" to state, "tagName" to request.tagName, "sha256" to request.sha256,
            "received" to received, "total" to total, "path" to path,
            "pausedByUser" to paused, "error" to error,
        )

        private val staleFilePattern = Regex(
            "^site-lens-(v(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)(?:\\.(?:alpha|beta|rc)(?:0|[1-9]\\d*))?)\\.apk(?:\\.part(?:\\.json)?|\\.json)?$",
        )

        private fun deleteStaleFiles(directory: File, keepTag: String, activeTag: String?) {
            directory.listFiles()?.forEach { file ->
                val tag = staleFilePattern.matchEntire(file.name)?.groupValues?.get(1)
                if (tag != null && tag != keepTag && tag != activeTag) file.delete()
            }
        }

        private fun atomicWriteStatic(file: File, value: String) {
            file.parentFile?.mkdirs()
            val temporary = File(file.absolutePath + ".tmp")
            temporary.writeText(value)
            check(temporary.renameTo(file) || run { file.delete(); temporary.renameTo(file) })
        }
    }
}
