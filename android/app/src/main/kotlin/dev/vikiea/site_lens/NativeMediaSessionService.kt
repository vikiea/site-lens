package dev.vikiea.site_lens

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.content.pm.ServiceInfo
import android.view.Surface
import androidx.core.content.ContextCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Process-owned native media session for downloaded or locally cached media.
 *
 * The Flutter Activity owns only a temporary video surface. The player,
 * MediaSession and foreground-service lifecycle stay here when the Activity
 * or Flutter engine is detached, so Android transport controls continue to
 * operate on the same media session.
 */
class NativeMediaSessionService : MediaSessionService() {
    private lateinit var player: ExoPlayer
    private lateinit var mediaSession: MediaSession
    private var sessionId: String? = null
    private var candidateId: String? = null
    private var title: String = "Site Lens"
    private var taskId: String? = null
    private var mediaUri: String? = null
    private var mediaMime: String = ""
    private var mediaIsHls: Boolean = false
    private var speed = 1f
    private var state = "stopped"
    private var lastError: String? = null
    private var userPaused = false
    private var stopping = false
    private var engineReleased = false
    private var fileLease: Closeable? = null
    private var restorable: RestorableState? = null
    private val positionHandler = Handler(Looper.getMainLooper())
    private val mediaSessionCallback = object : MediaSession.Callback {
        override fun onConnect(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            if (!isAllowedController(controllerInfo)) return MediaSession.ConnectionResult.reject()
            val playerCommands = if (isAppController(controllerInfo)) {
                MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS
            } else {
                MediaSession.ConnectionResult.DEFAULT_UNTRUSTED_PLAYER_COMMANDS
                    .buildUpon()
                    .removeAll(
                        Player.COMMAND_SET_MEDIA_ITEM,
                        Player.COMMAND_CHANGE_MEDIA_ITEMS,
                        Player.COMMAND_SET_MEDIA_ITEMS_METADATA,
                        Player.COMMAND_SET_PLAYLIST_METADATA,
                        Player.COMMAND_SET_VIDEO_SURFACE,
                        Player.COMMAND_RELEASE,
                    )
                    .build()
            }
            return MediaSession.ConnectionResult.accept(
                if (isAppController(controllerInfo)) {
                    MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS
                } else {
                    MediaSession.ConnectionResult.DEFAULT_UNTRUSTED_SESSION_COMMANDS
                },
                playerCommands,
            )
        }

        override fun onPlayerCommandRequest(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            playerCommand: Int,
        ): Int {
            if (!isAllowedController(controllerInfo)) return Player.COMMAND_INVALID
            if (playerCommand == Player.COMMAND_STOP) {
                stopAndRelease()
                return Player.COMMAND_INVALID
            }
            if (!isAppController(controllerInfo) &&
                !NativeMediaSessionPolicy.isExternalPlayerCommandAllowed(playerCommand)
            ) {
                return Player.COMMAND_INVALID
            }
            return playerCommand
        }
    }
    private val positionPersistence = object : Runnable {
        override fun run() {
            if (sessionId == null) return
            persistCurrentState()
            positionHandler.postDelayed(this, POSITION_PERSISTENCE_MS)
        }
    }
    private val statePrefs by lazy {
        getSharedPreferences("native_media_session_state", Context.MODE_PRIVATE)
    }

    override fun onCreate() {
        super.onCreate()
        ensureForeground()
        stopping = false
        engineReleased = false
        synchronized(pendingLock) { instance = this }
        player = ExoPlayer.Builder(
            this,
            DefaultRenderersFactory(this).setEnableDecoderFallback(true),
        ).build()
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        player.setHandleAudioBecomingNoisy(true)
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) = syncState()
            override fun onIsPlayingChanged(isPlaying: Boolean) = syncState()
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (NativeMediaSessionPolicy.isExplicitPlayWhenReadyChange(reason)) {
                    userPaused = !playWhenReady
                }
                syncState()
            }
            override fun onPlayerError(error: PlaybackException) {
                state = "failed"
                lastError = "${error.errorCodeName}:${error.message ?: "播放失败"}"
                NativeCrashStore.append(
                    this@NativeMediaSessionService,
                    module = "media.session",
                    message = "后台媒体播放失败",
                    details = error.stackTraceToString(),
                    contextValue = "session=${sessionId ?: "unknown"}",
                )
                publish()
            }
        })
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        mediaSession = MediaSession.Builder(this, player)
            .setId("site-lens-native")
            .setSessionActivity(open)
            .setCallback(mediaSessionCallback)
            .setPeriodicPositionUpdateEnabled(true)
            .build()
        restorable = readRestorable()
        if (restorable != null) state = "restorable"
        setShowNotificationForIdlePlayer(SHOW_NOTIFICATION_FOR_IDLE_PLAYER_AFTER_STOP_OR_ERROR)
        drainPending()
    }

    /** Android 14 requires a foreground service to promote itself promptly.
     * MediaSessionService will subsequently update the media notification, but
     * this small placeholder closes the startForeground timing window while
     * the player and session are being constructed.
     */
    private fun ensureForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Site Lens 媒体播放", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Site Lens")
            .setContentText("媒体播放准备中")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(ID, notification)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession = mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (sessionId == null) {
            // Starting the service to inspect a restorable snapshot must not
            // erase that snapshot when Android removes the launcher task.
            super.onTaskRemoved(rootIntent)
            return
        }
        when (NativeMediaSessionPolicy.taskRemovalAction(userPaused, state)) {
            NativeMediaSessionPolicy.TaskRemovalAction.KEEP_RUNNING ->
                super.onTaskRemoved(rootIntent)
            NativeMediaSessionPolicy.TaskRemovalAction.PRESERVE_RESTORABLE ->
                stopAndPreserveRestorable()
            NativeMediaSessionPolicy.TaskRemovalAction.RELEASE -> stopAndRelease()
        }
    }

    override fun onDestroy() {
        stopPositionPersistence()
        persistCurrentState()
        cancelPending()
        releaseMediaEngine()
        fileLease?.close()
        fileLease = null
        synchronized(pendingLock) {
            if (instance === this) instance = null
        }
        super.onDestroy()
    }

    private fun syncState() {
        if (state == "failed" || state == "stopped") return
        state = when {
            userPaused -> "paused"
            player.playbackState == Player.STATE_ENDED -> "completed"
            player.playbackState == Player.STATE_BUFFERING -> "buffering"
            player.isPlaying -> "playing"
            player.playWhenReady && player.playbackState == Player.STATE_READY -> "paused"
            player.playbackState == Player.STATE_READY -> "paused"
            else -> "preparing"
        }
        publish()
    }

    private fun publish() {
        persistCurrentState()
        val value = snapshot()
        observers.forEach { observer -> runCatching { observer(value) } }
    }

    private fun snapshot(): Map<String, Any?> = mapOf(
        "sessionId" to sessionId,
        "candidateId" to (candidateId ?: restorable?.candidateId),
        "taskId" to (taskId ?: restorable?.taskId),
        "state" to if (sessionId == null && restorable != null) "restorable" else state,
        "positionMs" to if (sessionId != null) player.currentPosition.coerceAtLeast(0L)
        else restorable?.positionMs ?: 0L,
        "durationMs" to if (sessionId != null) player.duration.coerceAtLeast(0L)
        else restorable?.durationMs ?: 0L,
        "videoWidth" to player.videoSize.width,
        "videoHeight" to player.videoSize.height,
        "speed" to if (sessionId != null) speed else restorable?.speed ?: 1f,
        "userPaused" to if (sessionId != null) userPaused else restorable?.userPaused ?: true,
        "errorCode" to lastError,
        "backend" to "media_session",
        "restorable" to (sessionId == null && restorable != null),
    )

    private fun persistCurrentState() {
        val active = sessionId ?: return
        val edit = statePrefs.edit()
            .putString("sessionId", active)
            .putString("taskId", taskId)
            .putString("candidateId", candidateId)
            .putString("uri", mediaUri)
            .putString("mime", mediaMime)
            .putBoolean("hls", mediaIsHls)
            .putString("title", title)
            .putLong("positionMs", player.currentPosition.coerceAtLeast(0L))
            .putLong("durationMs", player.duration.coerceAtLeast(0L))
            .putFloat("speed", speed)
            .putBoolean("userPaused", userPaused)
            .putString("state", state)
            .putBoolean("known", true)
        check(edit.commit()) { "无法保存原生媒体恢复状态" }
    }

    private fun readRestorable(): RestorableState? {
        if (!statePrefs.getBoolean("known", false)) return null
        val uri = statePrefs.getString("uri", null)?.takeIf { it.isNotBlank() } ?: return null
        return RestorableState(
            taskId = statePrefs.getString("taskId", null),
            candidateId = statePrefs.getString("candidateId", null),
            uri = uri,
            mime = statePrefs.getString("mime", "") ?: "",
            hls = statePrefs.getBoolean("hls", false),
            title = statePrefs.getString("title", "Site Lens") ?: "Site Lens",
            positionMs = statePrefs.getLong("positionMs", 0L).coerceAtLeast(0L),
            durationMs = statePrefs.getLong("durationMs", 0L).coerceAtLeast(0L),
            speed = statePrefs.getFloat("speed", 1f).coerceIn(0.25f, 8f),
            userPaused = statePrefs.getBoolean("userPaused", true),
            state = statePrefs.getString("state", "paused") ?: "paused",
        )
    }

    private fun clearRestorable() {
        restorable = null
        check(statePrefs.edit().clear().commit()) { "无法清理原生媒体恢复状态" }
    }

    private fun open(request: OpenRequest): Map<String, Any?> {
        val uri = Uri.parse(request.uri)
        require(uri.scheme == "file" || uri.scheme == "content") { "本地媒体地址无效" }
        val leaseScope = MediaFileLeaseRegistry.Scope.task(request.taskId) +
            if (uri.scheme == "file" && request.hls) {
                MediaFileLeaseRegistry.Scope.file(File(uri.path!!).parentFile!!)
            } else {
                MediaFileLeaseRegistry.Scope.source(request.uri)
            }
        val nextLease = NativeMediaFileLeases.registry.acquireRead(leaseScope)
        var installedLease = false
        try {
            stopPlayerOnly()
            fileLease?.close()
            fileLease = nextLease
            installedLease = true
            sessionId = request.sessionId.ifBlank { "native_${UUID.randomUUID()}" }
            candidateId = request.candidateId
            taskId = request.taskId
            mediaUri = request.uri
            mediaMime = request.mime
            mediaIsHls = request.hls
            title = request.title.ifBlank { "Site Lens" }.take(512)
            speed = 1f
            lastError = null
            userPaused = false
            clearRestorable()
            val item = MediaItem.Builder()
                .setUri(uri)
                .setMediaMetadata(MediaMetadata.Builder().setTitle(title).build())
                .apply { if (request.mime.isNotBlank()) setMimeType(request.mime) }
                .build()
            val hls = request.mime.contains("mpegurl", ignoreCase = true) ||
                uri.path?.lowercase()?.let { it.endsWith(".m3u8") || it.endsWith(".m3u") } == true
            if (hls) {
                val dataSource = GrowingFileDataSource.Factory()
                player.setMediaSource(
                    HlsMediaSource.Factory(dataSource).createMediaSource(item),
                )
            } else {
                player.setMediaItem(item)
            }
            state = if (request.autoPlay) "preparing" else "paused"
            userPaused = !request.autoPlay
            player.playWhenReady = request.autoPlay
            player.prepare()
            startPositionPersistence()
            publish()
            return snapshot()
        } catch (error: Exception) {
            if (!installedLease) runCatching { nextLease.close() }
            runCatching { stopAndRelease() }
            throw error
        }
    }

    private fun command(method: String, args: Map<String, Any?>): Map<String, Any?> {
        val requested = args["sessionId"] as? String
        require(sessionId != null && (requested.isNullOrBlank() || requested == sessionId)) {
            "播放会话已结束或已切换"
        }
        when (method) {
            "play" -> {
                userPaused = false
                if (player.playbackState == Player.STATE_ENDED) player.seekToDefaultPosition()
                player.play()
            }
            "pause" -> {
                userPaused = true
                player.pause()
                state = "paused"
            }
            "seek" -> {
                val position = (args["positionMs"] as? Number)?.toLong() ?: -1L
                require(position >= 0) { "播放位置无效" }
                player.seekTo(position)
            }
            "speed" -> {
                val value = (args["speed"] as? Number)?.toFloat() ?: 0f
                require(value > 0f && value <= 8f) { "播放倍速无效" }
                player.setPlaybackSpeed(value)
                speed = value
            }
            "stop", "close" -> return stopAndRelease()
            "state" -> Unit
            else -> error("不支持的后台媒体命令")
        }
        syncState()
        return snapshot()
    }

    private fun stopPlayerOnly() {
        player.stop()
        player.clearMediaItems()
        userPaused = false
        state = "stopped"
        lastError = null
    }

    private fun stopAndRelease(): Map<String, Any?> {
        stopping = true
        stopPositionPersistence()
        stopPlayerOnly()
        sessionId = null
        candidateId = null
        taskId = null
        mediaUri = null
        mediaMime = ""
        mediaIsHls = false
        clearRestorable()
        publish()
        val stopped = snapshot()
        releaseMediaEngine()
        fileLease?.close()
        fileLease = null
        stopSelf()
        return stopped
    }

    private fun stopAndPreserveRestorable() {
        stopping = true
        stopPositionPersistence()
        persistCurrentState()
        restorable = readRestorable()
        state = "stopped"
        player.stop()
        player.clearMediaItems()
        sessionId = null
        candidateId = null
        taskId = null
        mediaUri = null
        mediaMime = ""
        mediaIsHls = false
        lastError = null
        userPaused = restorable?.userPaused ?: true
        state = if (restorable != null) "restorable" else "stopped"
        publish()
        releaseMediaEngine()
        fileLease?.close()
        fileLease = null
        stopSelf()
    }

    private fun releaseMediaEngine() {
        if (engineReleased) return
        engineReleased = true
        if (::mediaSession.isInitialized) mediaSession.release()
        if (::player.isInitialized) player.release()
    }

    private fun attachSurface(surface: Surface?) {
        player.setVideoSurface(surface)
    }

    private fun isAppController(controllerInfo: MediaSession.ControllerInfo): Boolean =
        NativeMediaSessionPolicy.isAppController(controllerInfo.packageName, packageName)

    private fun isAllowedController(controllerInfo: MediaSession.ControllerInfo): Boolean =
        NativeMediaSessionPolicy.isAllowedController(
            controllerInfo.packageName,
            packageName,
            controllerInfo.isTrusted,
        )

    private fun startPositionPersistence() {
        positionHandler.removeCallbacks(positionPersistence)
        positionHandler.postDelayed(positionPersistence, POSITION_PERSISTENCE_MS)
    }

    private fun stopPositionPersistence() {
        positionHandler.removeCallbacks(positionPersistence)
    }

    data class OpenRequest(
        val sessionId: String,
        val taskId: String,
        val candidateId: String?,
        val uri: String,
        val mime: String,
        val title: String,
        val hls: Boolean,
        val autoPlay: Boolean = true,
        val surface: Surface?,
        val callback: (Result<Map<String, Any?>>) -> Unit,
    )

    private data class RestorableState(
        val taskId: String?,
        val candidateId: String?,
        val uri: String,
        val mime: String,
        val hls: Boolean,
        val title: String,
        val positionMs: Long,
        val durationMs: Long,
        val speed: Float,
        val userPaused: Boolean,
        val state: String,
    )

    companion object {
        private const val CHANNEL = "site-lens-native-media"
        private const val ID = 24002
        private const val POSITION_PERSISTENCE_MS = 2_000L
        private var instance: NativeMediaSessionService? = null
        private val observers = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
        private data class PendingAction(
            val generation: Long,
            val action: (NativeMediaSessionService) -> Unit,
            val cancel: () -> Unit,
        )

        private val pendingLock = Any()
        private val pending = ArrayDeque<PendingAction>()
        private var pendingGeneration = 0L

        fun registerObserver(observer: (Map<String, Any?>) -> Unit) {
            observers.add(observer)
            instance?.let { service -> observer(service.snapshot()) }
        }

        fun unregisterObserver(observer: (Map<String, Any?>) -> Unit) {
            observers.remove(observer)
        }

        fun owns(session: String?): Boolean = session != null && instance?.sessionId == session

        fun hasActiveSession(): Boolean = instance?.sessionId != null

        fun hasRestorableState(context: Context): Boolean =
            context.getSharedPreferences("native_media_session_state", Context.MODE_PRIVATE)
                .getBoolean("known", false)

        fun state(context: Context, callback: (Result<Map<String, Any?>>) -> Unit) {
            dispatch(
                context,
                action = { service -> callback(runCatching { service.snapshot() }) },
                cancel = { callback(Result.failure(IllegalStateException("媒体服务已停止"))) },
            )
        }

        fun open(context: Context, request: OpenRequest) {
            dispatch(
                context,
                action = { service ->
                    callbackResult(request.callback) {
                        val snapshot = service.open(request)
                        request.surface?.let(service::attachSurface)
                        snapshot
                    }
                },
                cancel = {
                    request.callback(
                        Result.failure(IllegalStateException("媒体服务已停止")),
                    )
                },
            )
        }

        fun command(
            context: Context,
            method: String,
            args: Map<String, Any?>,
            callback: (Result<Map<String, Any?>>) -> Unit,
        ) {
            dispatch(
                context,
                action = { service -> callbackResult(callback) { service.command(method, args) } },
                cancel = { callback(Result.failure(IllegalStateException("媒体服务已停止"))) },
            )
        }

        fun attachSurface(context: Context, surface: Surface?) {
            dispatch(context, action = { service -> service.attachSurface(surface) })
        }

        fun detachSurface(context: Context) {
            if (instance != null) instance?.attachSurface(null)
        }

        fun stop(context: Context) {
            cancelPending()
            instance?.stopAndRelease()
                ?: context.stopService(Intent(context.applicationContext, NativeMediaSessionService::class.java))
        }

        fun abandonRestorable(context: Context) {
            cancelPending()
            instance?.let { service ->
                service.clearRestorable()
                service.stopSelf()
            } ?: run {
                context.getSharedPreferences(
                    "native_media_session_state",
                    Context.MODE_PRIVATE,
                ).edit().clear().commit()
                context.stopService(
                    Intent(context.applicationContext, NativeMediaSessionService::class.java),
                )
            }
        }

        fun cancelPendingActions() = cancelPending()

        private fun callbackResult(
            callback: (Result<Map<String, Any?>>) -> Unit,
            block: () -> Map<String, Any?>,
        ) {
            callback(runCatching(block))
        }

        private fun dispatch(
            context: Context,
            action: (NativeMediaSessionService) -> Unit,
            cancel: () -> Unit = {},
        ) {
            var service: NativeMediaSessionService? = null
            var shouldStart = false
            synchronized(pendingLock) {
                service = instance
                if (service == null) {
                    pending.addLast(PendingAction(pendingGeneration, action, cancel))
                    shouldStart = true
                }
            }
            service?.let {
                if (it.stopping) cancel() else action(it)
                return
            }
            if (!shouldStart) return
            try {
                ContextCompat.startForegroundService(
                    context.applicationContext,
                    Intent(context.applicationContext, NativeMediaSessionService::class.java),
                )
            } catch (error: Exception) {
                cancelPending()
                throw error
            }
        }

        private fun drainPending() {
            val service = synchronized(pendingLock) { instance } ?: return
            while (true) {
                val action = synchronized(pendingLock) {
                    if (pending.isEmpty()) null else pending.removeFirst()
                } ?: break
                val active = synchronized(pendingLock) {
                    instance === service && action.generation == pendingGeneration
                }
                if (active) action.action(service) else action.cancel()
            }
        }

        private fun cancelPending() {
            val cancelled = synchronized(pendingLock) {
                pendingGeneration++
                buildList {
                    while (pending.isNotEmpty()) add(pending.removeFirst())
                }
            }
            cancelled.forEach { action -> runCatching { action.cancel() } }
        }
    }
}
