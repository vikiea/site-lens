package dev.vikiea.site_lens

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
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
import androidx.media3.session.DefaultMediaNotificationProvider
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
    private var mediaOpenedAtElapsedMs = 0L
    private var speed = 1f
    private var state = "stopped"
    private var lastError: String? = null
    private var sourceRetryCount = 0
    private var userPaused = false
    private var backgroundPolicyPaused = false
    private var applicationForeground = true
    private var allowNativeBackgroundPlayback = false
    private var lifecyclePolicyOwner = ""
    private var lifecyclePolicySequence = 0L
    private var stopping = false
    private var releaseWasExplicitStop = false
    private var engineReleased = false
    private var playerReleased = false
    private var mediaSessionReleased = false
    private var fileLease: Closeable? = null
    private var restorable: RestorableState? = null
    private var playerGeneration = 0L
    private var lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.READY
    private var playerListener: Player.Listener? = null
    private var ownerGeneration: Long? = null
    private var attachedSurface: Surface? = null
    private var attachedSurfaceBindingId: String? = null
    private val positionHandler = Handler(Looper.getMainLooper())
    private val operationHandler = Handler(Looper.getMainLooper())
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
            val decision = NativeMediaSessionPolicy.playerCommandDecision(
                controllerAllowed = isAllowedController(controllerInfo),
                appController = isAppController(controllerInfo),
                command = playerCommand,
            )
            return when (decision) {
                NativeMediaSessionPolicy.PlayerCommandDecision.REJECT -> Player.COMMAND_INVALID
                NativeMediaSessionPolicy.PlayerCommandDecision.ALLOW,
                NativeMediaSessionPolicy.PlayerCommandDecision.ALLOW_AND_RELEASE -> playerCommand
            }
        }

        override fun onPlayerInteractionFinished(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            playerCommands: Player.Commands,
        ) {
            if (isAllowedController(controllerInfo) &&
                playerCommands.contains(Player.COMMAND_STOP) &&
                NativeMediaSessionPolicy.shouldReleaseAfterPlayerCommand(Player.COMMAND_STOP)
            ) {
                stopAndRelease()
            }
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
        allowNativeBackgroundPlayback = statePrefs.getBoolean(
            PREF_ALLOW_NATIVE_BACKGROUND_PLAYBACK,
            false,
        )
        applicationForeground = statePrefs.getBoolean(
            PREF_APPLICATION_FOREGROUND,
            true,
        )
        lifecyclePolicyOwner = statePrefs.getString(PREF_POLICY_OWNER, "") ?: ""
        lifecyclePolicySequence = statePrefs.getLong(PREF_POLICY_SEQUENCE, 0L)
        // Media3 publishes the controllable notification after the player and
        // session are built. Android's foreground-service deadline starts at
        // startForegroundService(), so publish a concrete placeholder first;
        // Media3 then replaces it on the same notification/session ID.
        startForegroundImmediately()
        val notificationProvider = DefaultMediaNotificationProvider.Builder(applicationContext)
            .setNotificationId(ID)
            .setChannelId(CHANNEL)
            .setChannelName(R.string.site_lens_media_channel_name)
            .build()
            .apply { setSmallIcon(android.R.drawable.ic_media_play) }
        setMediaNotificationProvider(notificationProvider)
        stopping = false
        releaseWasExplicitStop = false
        engineReleased = false
        playerReleased = false
        mediaSessionReleased = false
        lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.READY
        synchronized(pendingLock) {
            instance = this
            explicitStopInProgress = false
        }
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
        installPlayerListener(playerGeneration)
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
        // Register the session with MediaSessionService so Media3 owns the
        // notification lifecycle and embeds this session's platform token in
        // every notification update.
        addSession(mediaSession)
        restorable = readRestorable()
        if (restorable != null) state = "restorable"
        // The service is started with startForegroundService even when a
        // restored item is paused. ALWAYS makes Media3 publish the real
        // session notification immediately, so Android's foreground-service
        // deadline is met without a second placeholder notification.
        setShowNotificationForIdlePlayer(SHOW_NOTIFICATION_FOR_IDLE_PLAYER_ALWAYS)
        drainPending()
    }

    private fun startForegroundImmediately() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    getString(R.string.site_lens_media_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Site Lens")
            .setContentText("原生媒体会话")
            .setContentIntent(open)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A start request can arrive after the previous service instance has
        // entered its release barrier. Drain only from a live instance; the
        // retiring instance leaves pending actions for onDestroy() to hand
        // over to its replacement.
        // MediaSessionService must see the original intent first so Android
        // media-button commands reach Media3's session callback.
        super.onStartCommand(intent, flags, startId)
        if (acceptsDispatch()) drainPending()
        return START_NOT_STICKY
    }

    private fun installPlayerListener(generation: Long) {
        playerListener?.let(player::removeListener)
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (!acceptsCallback(generation)) return
                if (playbackState == Player.STATE_READY) sourceRetryCount = 0
                syncState()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (acceptsCallback(generation)) syncState()
            }
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (!acceptsCallback(generation)) return
                if (NativeMediaSessionPolicy.isExplicitPlayWhenReadyChange(reason)) {
                    userPaused = !playWhenReady
                }
                syncState()
            }
            override fun onPlayerError(error: PlaybackException) {
                if (!acceptsCallback(generation)) return
                // ExoPlayer reports elapsed-realtime timestamps. An error
                // posted by the previous item after a rapid switch must not
                // retry or fail the newly opened media item.
                if (sessionId == null || error.timestampMs < mediaOpenedAtElapsedMs) {
                    syncState()
                    return
                }
                val recoverable = isRecoverableSourceError(error)
                if (recoverable && sourceRetryCount == 0 && sessionId != null) {
                    sourceRetryCount++
                    state = "preparing"
                    publish()
                    retrySourcePlayback(generation)
                    return
                }
                state = "failed"
                lastError = buildString {
                    append(error.errorCodeName)
                    append(": ").append(error.message ?: "播放失败")
                    append("; recoverable=").append(recoverable)
                    append("; mediaItem=")
                        .append(player.currentMediaItem?.localConfiguration?.uri?.scheme ?: "none")
                    error.cause?.let {
                        append("; cause=").append(it.javaClass.simpleName)
                        append(":").append(it.message ?: "")
                    }
                }
                NativeCrashStore.append(
                    this@NativeMediaSessionService,
                    module = "media.session",
                    message = "后台媒体播放失败",
                    details = lastError + "\n" + error.stackTraceToString(),
                    contextValue = "session=${sessionId ?: "unknown"}",
                )
                publish()
            }
        }
        playerListener = listener
        player.addListener(listener)
    }

    private fun isRecoverableSourceError(error: PlaybackException): Boolean =
        error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED ||
            error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT ||
            error.errorCode == PlaybackException.ERROR_CODE_TIMEOUT ||
            error.errorCode == PlaybackException.ERROR_CODE_IO_UNSPECIFIED ||
            error.errorCode == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession = mediaSession

    private fun retrySourcePlayback(generation: Long) {
        if (!acceptsCallback(generation)) return
        player.playWhenReady = !userPaused
        player.prepare()
    }

    private fun acceptsCallback(generation: Long): Boolean {
        if (generation != playerGeneration) return false
        return NativeMediaSessionPolicy.acceptsLifecycleCallback(
            callbackGeneration = generation,
            currentGeneration = playerGeneration,
            phase = lifecyclePhase,
        ) && sessionId != null && !stopping && !engineReleased
    }

    private fun applicationLifecycle(
        foreground: Boolean,
        allowBackground: Boolean,
        ownerId: String,
        sequence: Long,
    ): Map<String, Any?> {
        if (!NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = ownerId,
                sequence = sequence,
                currentOwnerId = lifecyclePolicyOwner,
                currentSequence = lifecyclePolicySequence,
            )
        ) return snapshot()
        lifecyclePolicyOwner = ownerId
        lifecyclePolicySequence = sequence
        applicationForeground = foreground
        allowNativeBackgroundPlayback = allowBackground
        statePrefs.edit()
            .putBoolean(PREF_ALLOW_NATIVE_BACKGROUND_PLAYBACK, allowBackground)
            .putBoolean(PREF_APPLICATION_FOREGROUND, foreground)
            .putString(PREF_POLICY_OWNER, ownerId)
            .putLong(PREF_POLICY_SEQUENCE, sequence)
            .commit()
        if (foreground) {
            backgroundPolicyPaused = false
        } else if (!allowBackground && sessionId != null &&
            (player.isPlaying || player.playWhenReady)
        ) {
            backgroundPolicyPaused = true
            player.pause()
            userPaused = false
            state = "paused"
        }
        if (sessionId != null && !stopping && !engineReleased) {
            if (state != "failed" && state != "stopped") {
                syncState()
            } else {
                publish()
            }
        }
        return snapshot()
    }

    private fun claimLifecycleOwner(ownerId: String) {
        lifecyclePolicyOwner = ownerId
        lifecyclePolicySequence = 0L
        statePrefs.edit()
            .putString(PREF_POLICY_OWNER, ownerId)
            .putLong(PREF_POLICY_SEQUENCE, 0L)
            .commit()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (sessionId == null) {
            // Starting the service to inspect a restorable snapshot must not
            // erase that snapshot when Android removes the launcher task.
            super.onTaskRemoved(rootIntent)
            return
        }
        when (
            NativeMediaSessionPolicy.taskRemovalAction(
                allowNativeBackgroundPlayback = allowNativeBackgroundPlayback,
                userPaused = userPaused,
                backgroundPolicyPaused = backgroundPolicyPaused,
                state = state,
            )
        ) {
            NativeMediaSessionPolicy.TaskRemovalAction.KEEP_RUNNING ->
                super.onTaskRemoved(rootIntent)
            NativeMediaSessionPolicy.TaskRemovalAction.PRESERVE_RESTORABLE ->
                stopAndPreserveRestorable()
            NativeMediaSessionPolicy.TaskRemovalAction.RELEASE -> stopAndRelease()
        }
    }

    override fun onDestroy() {
        stopping = true
        lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING
        playerGeneration++
        stopPositionPersistence()
        persistCurrentState()
        runCatching {
            releaseMediaEngine()
        }.onFailure { error ->
            NativeCrashStore.append(
                this,
                module = "media.session",
                message = "原生媒体引擎释放失败",
                details = error.stackTraceToString(),
                contextValue = "operation=onDestroy",
            )
        }
        runCatching {
            fileLease?.close()
        }.onFailure { error ->
            NativeCrashStore.append(
                this,
                module = "media.session",
                message = "原生媒体租约释放失败",
                details = error.stackTraceToString(),
                contextValue = "operation=onDestroy",
            )
        }
        fileLease = null
        ownerGeneration?.let { MediaPlaybackOwner.nativeStopped(applicationContext, it) }
        ownerGeneration = null
        val restartForPending = synchronized(pendingLock) {
            val restart = instance === this && pending.isNotEmpty()
            if (instance === this) {
                instance = null
                explicitStopInProgress = false
            }
            restart
        }
        super.onDestroy()
        if (restartForPending) {
            operationHandler.post {
                val shouldStart = synchronized(pendingLock) {
                    instance == null && pending.isNotEmpty()
                }
                if (shouldStart) {
                    runCatching {
                        ContextCompat.startForegroundService(
                            applicationContext,
                            Intent(applicationContext, NativeMediaSessionService::class.java),
                        )
                    }.onFailure { error ->
                        cancelPending()
                        NativeCrashStore.append(
                            applicationContext,
                            module = "media.session",
                            message = error.message ?: "无法重启原生媒体服务",
                            details = error.stackTraceToString(),
                            contextValue = "operation=restart_pending",
                        )
                    }
                }
            }
        }
    }

    private fun syncState() {
        if (state == "failed" || state == "stopped" || stopping || engineReleased) return
        state = when {
            backgroundPolicyPaused -> "paused"
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
        // Media3 getters are not safe after release; terminal snapshots must
        // remain observable without touching the retired player instance.
        "sessionId" to sessionId,
        "candidateId" to (candidateId ?: restorable?.candidateId),
        "taskId" to (taskId ?: restorable?.taskId),
        "state" to if (sessionId == null && restorable != null) "restorable" else state,
        "positionMs" to if (sessionId != null && !engineReleased) player.currentPosition.coerceAtLeast(0L)
        else restorable?.positionMs ?: 0L,
        "durationMs" to if (sessionId != null && !engineReleased) player.duration.coerceAtLeast(0L)
        else restorable?.durationMs ?: 0L,
        "videoWidth" to if (!engineReleased) player.videoSize.width else 0,
        "videoHeight" to if (!engineReleased) player.videoSize.height else 0,
        "speed" to if (sessionId != null) speed else restorable?.speed ?: 1f,
        "userPaused" to if (sessionId != null) userPaused else restorable?.userPaused ?: true,
        "backgroundPolicyPaused" to if (sessionId != null) {
            backgroundPolicyPaused
        } else {
            restorable?.backgroundPolicyPaused ?: false
        },
        "applicationForeground" to applicationForeground,
        "allowNativeBackgroundPlayback" to allowNativeBackgroundPlayback,
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
            .putBoolean("backgroundPolicyPaused", backgroundPolicyPaused)
            .putBoolean(
                PREF_ALLOW_NATIVE_BACKGROUND_PLAYBACK,
                allowNativeBackgroundPlayback,
            )
            .putBoolean(PREF_APPLICATION_FOREGROUND, applicationForeground)
            .putString(PREF_POLICY_OWNER, lifecyclePolicyOwner)
            .putLong(PREF_POLICY_SEQUENCE, lifecyclePolicySequence)
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
            backgroundPolicyPaused = statePrefs.getBoolean(
                "backgroundPolicyPaused",
                false,
            ),
            state = statePrefs.getString("state", "paused") ?: "paused",
        )
    }

    private fun clearRestorable() {
        restorable = null
        // Keep the current lifecycle policy across an explicit stop and the
        // next service instance. Clearing the whole preference record here
        // would also erase the trusted Bridge owner and sequence, so the next
        // lifecycle callback could be rejected as stale.
        val edit = statePrefs.edit()
            .remove("sessionId")
            .remove("taskId")
            .remove("candidateId")
            .remove("uri")
            .remove("mime")
            .remove("hls")
            .remove("title")
            .remove("positionMs")
            .remove("durationMs")
            .remove("speed")
            .remove("userPaused")
            .remove("backgroundPolicyPaused")
            .remove("state")
            .remove("known")
        check(edit.commit()) { "无法清理原生媒体恢复状态" }
    }

    private fun open(request: OpenRequest): Map<String, Any?> {
        check(!stopping && !engineReleased) { "媒体服务正在关闭" }
        applicationForeground = request.applicationForeground
        allowNativeBackgroundPlayback = request.allowNativeBackgroundPlayback
        val uri = Uri.parse(request.uri)
        require(uri.scheme == "file" || uri.scheme == "content") { "本地媒体地址无效" }
        if (uri.scheme == "file") {
            val file = File(uri.path ?: error("媒体路径无效")).canonicalFile
            val roots = listOfNotNull(
                applicationContext.filesDir.canonicalFile,
                applicationContext.getExternalFilesDir(null)?.canonicalFile,
            )
            val directRoot = applicationContext
                .getSharedPreferences("media_access", Context.MODE_PRIVATE)
                .getString("directRoot", null)
                ?.let { runCatching { File(it).canonicalFile }.getOrNull() }
            val directAllowed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                android.os.Environment.isExternalStorageManager() &&
                directRoot?.isDirectory == true &&
                !java.nio.file.Files.isSymbolicLink(directRoot.toPath()) &&
                (file.path == directRoot.path || file.path.startsWith("${directRoot.path}${File.separator}"))
            require(roots.any { file.path == it.path || file.path.startsWith("${it.path}${File.separator}") } || directAllowed) {
                "本地媒体路径越界"
            }
        }
        val leaseScope = MediaFileLeaseRegistry.Scope.task(request.taskId) +
            if (uri.scheme == "file" && request.hls) {
                MediaFileLeaseRegistry.Scope.file(File(uri.path!!).parentFile!!)
            } else {
                MediaFileLeaseRegistry.Scope.source(request.uri)
            }
        val nextLease = NativeMediaFileLeases.registry.acquireRead(leaseScope)
        var installedLease = false
        try {
            if (ownerGeneration == null) {
                ownerGeneration = MediaPlaybackOwner.nativeStarted(applicationContext)
            }
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
            mediaOpenedAtElapsedMs = SystemClock.elapsedRealtime()
            playerGeneration++
            lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.OPENING
            installPlayerListener(playerGeneration)
            title = request.title.ifBlank { "Site Lens" }.take(512)
            speed = 1f
            lastError = null
            sourceRetryCount = 0
            userPaused = false
            backgroundPolicyPaused = false
            clearRestorable()
            val item = MediaItem.Builder()
                .setMediaId(sessionId ?: "")
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
            val shouldAutoPlay = request.autoPlay &&
                NativeMediaSessionPolicy.canStartPlayback(
                    applicationForeground = applicationForeground,
                    allowNativeBackgroundPlayback = allowNativeBackgroundPlayback,
                )
            if (request.autoPlay && !shouldAutoPlay) {
                backgroundPolicyPaused = true
            }
            state = if (shouldAutoPlay) "preparing" else "paused"
            userPaused = !request.autoPlay
            player.playWhenReady = shouldAutoPlay
            player.prepare()
            lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE
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
        check(!stopping && !engineReleased) { "媒体服务正在关闭" }
        val requested = args["sessionId"] as? String
        require(sessionId != null && (requested.isNullOrBlank() || requested == sessionId)) {
            "播放会话已结束或已切换"
        }
        when (method) {
            "play" -> {
                require(
                    NativeMediaSessionPolicy.canStartPlayback(
                        applicationForeground = applicationForeground,
                        allowNativeBackgroundPlayback = allowNativeBackgroundPlayback,
                    ),
                ) { "后台播放已关闭" }
                backgroundPolicyPaused = false
                userPaused = false
                if (player.playbackState == Player.STATE_ENDED) player.seekToDefaultPosition()
                player.play()
            }
            "pause" -> {
                backgroundPolicyPaused = false
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

    private fun stopPlayerOnly(
        phaseAfter: NativeMediaSessionPolicy.LifecyclePhase =
            NativeMediaSessionPolicy.LifecyclePhase.READY,
    ) {
        playerGeneration++
        detachSurfaceFromPlayer()
        player.stop()
        player.clearMediaItems()
        lifecyclePhase = phaseAfter
        userPaused = false
        backgroundPolicyPaused = false
        state = "stopped"
        lastError = null
    }

    private fun stopAndRelease(): Map<String, Any?> {
        if (engineReleased && fileLease == null && ownerGeneration == null) return snapshot()
        markExplicitStop()
        if (!stopping) {
            stopping = true
            lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING
            playerGeneration++
            stopPositionPersistence()
            persistCurrentState()
        }
        var releaseFailure: Throwable? = null
        runCatching { releaseMediaEngine() }.onFailure { releaseFailure = it }
        state = "stopped"
        userPaused = false
        backgroundPolicyPaused = false
        lastError = null
        sessionId = null
        candidateId = null
        taskId = null
        mediaUri = null
        mediaMime = ""
        mediaIsHls = false
        clearRestorable()
        publish()
        val stopped = snapshot()
        fileLease?.close()
        fileLease = null
        ownerGeneration?.let { MediaPlaybackOwner.nativeStopped(applicationContext, it) }
        ownerGeneration = null
        stopSelf()
        releaseFailure?.let { throw it }
        return stopped
    }

    private fun stopAndPreserveRestorable() {
        if (engineReleased || stopping) return
        markExplicitStop()
        stopping = true
        lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING
        playerGeneration++
        stopPositionPersistence()
        persistCurrentState()
        restorable = readRestorable()
        state = "stopped"
        detachSurfaceFromPlayer()
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
        backgroundPolicyPaused = restorable?.backgroundPolicyPaused ?: false
        state = if (restorable != null) "restorable" else "stopped"
        publish()
        releaseMediaEngine()
        fileLease?.close()
        fileLease = null
        ownerGeneration?.let { MediaPlaybackOwner.nativeStopped(applicationContext, it) }
        ownerGeneration = null
        stopSelf()
    }

    private fun releaseMediaEngine() {
        if (engineReleased) return
        detachSurfaceFromPlayer()
        lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING
        playerGeneration++
        var firstFailure: Throwable? = null
        if (::player.isInitialized && !playerReleased) {
            runCatching {
                player.stop()
                player.clearMediaItems()
            }.onFailure { firstFailure = firstFailure ?: it }
        }
        if (::mediaSession.isInitialized && !mediaSessionReleased) {
            runCatching {
                if (isSessionAdded(mediaSession)) removeSession(mediaSession)
                mediaSession.release()
                mediaSessionReleased = true
            }.onFailure { firstFailure = firstFailure ?: it }
        }
        if (::player.isInitialized && !playerReleased) {
            runCatching {
                player.release()
                playerReleased = true
            }.onFailure { firstFailure = firstFailure ?: it }
        }
        engineReleased = mediaSessionReleased && playerReleased
        if (engineReleased) lifecyclePhase = NativeMediaSessionPolicy.LifecyclePhase.RELEASED
        firstFailure?.let { throw it }
    }

    private fun detachSurfaceFromPlayer() {
        if (!::player.isInitialized) {
            attachedSurface = null
            return
        }
        player.clearVideoSurface()
        attachedSurface = null
        attachedSurfaceBindingId = null
    }

    private fun attachSurface(
        surface: Surface?,
        requestedSessionId: String? = null,
        requestedBindingId: String? = null,
        requestedOwnerId: String? = null,
    ) {
        if (stopping || engineReleased) return
        if (surface == null) {
            detachSurface(requestedSessionId, requestedBindingId)
            return
        }
        if (!NativeMediaSessionPolicy.acceptsSurfaceBinding(
                requestedSessionId = requestedSessionId,
                requestedBindingId = requestedBindingId,
                requestedOwnerId = requestedOwnerId,
                activeSessionId = sessionId,
                activeOwnerId = lifecyclePolicyOwner,
                phase = lifecyclePhase,
            )
        ) return
        if (surface === attachedSurface) return
        detachSurfaceFromPlayer()
        player.setVideoSurface(surface)
        attachedSurface = surface
        attachedSurfaceBindingId = requestedBindingId
    }

    private fun detachSurface(
        requestedSessionId: String? = null,
        requestedBindingId: String? = null,
    ): Boolean {
        if (stopping || engineReleased || sessionId == null ||
            (!requestedSessionId.isNullOrBlank() && requestedSessionId != sessionId) ||
            (!requestedBindingId.isNullOrBlank() && requestedBindingId != attachedSurfaceBindingId)
        ) return false
        detachSurfaceFromPlayer()
        return true
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
        val applicationForeground: Boolean = true,
        val allowNativeBackgroundPlayback: Boolean = false,
        val surface: Surface?,
        val surfaceBindingId: String? = null,
        val surfaceOwnerId: String? = null,
        val isCurrent: () -> Boolean = { true },
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
        val backgroundPolicyPaused: Boolean,
        val state: String,
    )

    companion object {
        private const val CHANNEL = "site-lens-native-media"
        private const val ID = 24002
        private const val POSITION_PERSISTENCE_MS = 2_000L
        private const val PREF_ALLOW_NATIVE_BACKGROUND_PLAYBACK =
            "allowNativeBackgroundPlayback"
        private const val PREF_APPLICATION_FOREGROUND = "applicationForeground"
        private const val PREF_POLICY_OWNER = "policyOwner"
        private const val PREF_POLICY_SEQUENCE = "policySequence"
        private var instance: NativeMediaSessionService? = null
        private val observers = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
        private data class PendingAction(
            val generation: Long,
            val action: (NativeMediaSessionService) -> Unit,
            val cancel: () -> Unit,
            val retryOnRelease: Boolean,
        )

        private val pendingLock = Any()
        private val pending = ArrayDeque<PendingAction>()
        private var pendingGeneration = 0L
        private var explicitStopInProgress = false

        fun registerObserver(observer: (Map<String, Any?>) -> Unit) {
            observers.add(observer)
            instance?.takeIf { it.acceptsDispatch() }?.let { service -> observer(service.snapshot()) }
        }

        fun unregisterObserver(observer: (Map<String, Any?>) -> Unit) {
            observers.remove(observer)
        }

        fun owns(session: String?): Boolean =
            session != null && instance?.takeIf { it.acceptsDispatch() }?.sessionId == session

        fun hasActiveSession(): Boolean = instance?.takeIf { it.acceptsDispatch() }?.sessionId != null

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

        fun applicationLifecycle(
            context: Context,
            foreground: Boolean,
            allowBackground: Boolean,
            ownerId: String,
            sequence: Long,
            callback: (Result<Map<String, Any?>>) -> Unit,
        ) {
            val preferences = context.getSharedPreferences(
                "native_media_session_state",
                Context.MODE_PRIVATE,
            )
            val storedOwner = preferences.getString(PREF_POLICY_OWNER, "") ?: ""
            val storedSequence = preferences.getLong(PREF_POLICY_SEQUENCE, 0L)
            val service = synchronized(pendingLock) {
                instance?.takeIf { it.acceptsDispatch() }
            }
            if (service == null) {
                if (NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                        ownerId = ownerId,
                        sequence = sequence,
                        currentOwnerId = storedOwner,
                        currentSequence = storedSequence,
                    )
                ) {
                    preferences.edit()
                        .putBoolean(PREF_ALLOW_NATIVE_BACKGROUND_PLAYBACK, allowBackground)
                        .putBoolean(PREF_APPLICATION_FOREGROUND, foreground)
                        .putString(PREF_POLICY_OWNER, ownerId)
                        .putLong(PREF_POLICY_SEQUENCE, sequence)
                        .commit()
                }
                callback(
                    Result.success(
                        mapOf(
                            "sessionId" to null,
                            "state" to "stopped",
                            "backgroundPolicyPaused" to false,
                            "allowNativeBackgroundPlayback" to allowBackground,
                            "applicationForeground" to foreground,
                        ),
                    ),
                )
                return
            }
            service.enqueue(
                action = {
                    callback(
                        runCatching {
                            it.applicationLifecycle(
                                foreground,
                                allowBackground,
                                ownerId,
                                sequence,
                            )
                        },
                    )
                },
                cancel = {
                    callback(Result.failure(IllegalStateException("媒体服务已停止")))
                },
            )
        }

        fun open(context: Context, request: OpenRequest) {
            dispatch(
                context,
                action = { service ->
                    callbackResult(request.callback) {
                        check(request.isCurrent()) { "原生媒体请求已过期" }
                        val snapshot = service.open(request)
                        request.surface?.let { surface ->
                            service.attachSurface(
                                surface,
                                request.sessionId,
                                request.surfaceBindingId,
                                request.surfaceOwnerId,
                            )
                        }
                        snapshot
                    }
                },
                cancel = {
                    request.callback(
                        Result.failure(IllegalStateException("媒体服务已停止")),
                    )
                },
                retryOnRelease = true,
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

        fun attachSurface(
            context: Context,
            surface: Surface?,
            sessionId: String? = null,
            bindingId: String? = null,
            ownerId: String? = null,
        ) {
            existing({ service -> service.attachSurface(surface, sessionId, bindingId, ownerId) })
        }

        fun detachSurface(
            context: Context,
            sessionId: String? = null,
            bindingId: String? = null,
            callback: (Boolean) -> Unit = {},
        ) {
            existing(
                { service ->
                    val detached = service.detachSurface(sessionId, bindingId)
                    callback(detached)
                },
                { callback(true) },
                { callback(false) },
            )
        }

        fun stop(context: Context, callback: (Boolean) -> Unit = {}) {
            cancelPending()
            val service = synchronized(pendingLock) {
                instance?.takeIf { it.acceptsDispatch() }
            }
            if (service != null) {
                service.enqueue(
                    action = {
                        runCatching {
                            it.stopAndRelease()
                        }.onSuccess {
                            callback(true)
                        }.onFailure {
                            callback(false)
                        }
                    },
                    cancel = { callback(false) },
                )
            } else {
                context.stopService(Intent(context.applicationContext, NativeMediaSessionService::class.java))
                callback(true)
            }
        }

        fun claimLifecycleOwner(context: Context, ownerId: String) {
            require(ownerId.isNotBlank()) { "原生媒体 Bridge 身份无效" }
            synchronized(pendingLock) {
                instance?.claimLifecycleOwner(ownerId) ?: context.getSharedPreferences(
                    "native_media_session_state",
                    Context.MODE_PRIVATE,
                ).edit()
                    .putString(PREF_POLICY_OWNER, ownerId)
                    .putLong(PREF_POLICY_SEQUENCE, 0L)
                    .commit()
            }
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

        private fun existing(
            action: (NativeMediaSessionService) -> Unit,
            missing: () -> Unit = {},
            cancel: () -> Unit = {},
        ) {
            val service = synchronized(pendingLock) { instance } ?: run {
                missing()
                return
            }
            service.enqueue(action, cancel)
        }

        private fun dispatch(
            context: Context,
            action: (NativeMediaSessionService) -> Unit,
            cancel: () -> Unit = {},
            retryOnRelease: Boolean = false,
        ) {
            var service: NativeMediaSessionService? = null
            var shouldStart = false
            synchronized(pendingLock) {
                service = instance?.takeIf { it.acceptsDispatch() }
                if (service == null) {
                    pending.addLast(
                        PendingAction(pendingGeneration, action, cancel, retryOnRelease),
                    )
                    shouldStart = true
                }
            }
            service?.let {
                it.enqueue(action, cancel, retryOnRelease)
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
                if (active) {
                    service.enqueue(action.action, action.cancel, action.retryOnRelease)
                } else {
                    action.cancel()
                }
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

        private fun requeuePending(
            action: (NativeMediaSessionService) -> Unit,
            cancel: () -> Unit,
            retryOnRelease: Boolean,
            releaseWasExplicitStop: Boolean,
        ): Boolean {
            var shouldStart = false
            val cancelImmediately = synchronized(pendingLock) {
                if (!NativeMediaSessionPolicy.shouldRequeueAfterRelease(
                        retryOnRelease = retryOnRelease,
                        explicitStopInProgress = explicitStopInProgress || releaseWasExplicitStop,
                    )
                ) {
                    true
                } else {
                    pending.addLast(
                        PendingAction(pendingGeneration, action, cancel, retryOnRelease),
                    )
                    shouldStart = instance == null
                    false
                }
            }
            if (cancelImmediately) cancel()
            return shouldStart
        }
    }

    private fun enqueue(
        action: (NativeMediaSessionService) -> Unit,
        cancel: () -> Unit = {},
        retryOnRelease: Boolean = false,
    ) {
        val run: () -> Unit = {
            if (stopping || engineReleased) {
                if (retryOnRelease) {
                    val shouldStart = requeuePending(
                        action,
                        cancel,
                        retryOnRelease,
                        releaseWasExplicitStop,
                    )
                    if (shouldStart) {
                        runCatching {
                            ContextCompat.startForegroundService(
                                applicationContext,
                                Intent(
                                    applicationContext,
                                    NativeMediaSessionService::class.java,
                                ),
                            )
                        }.onFailure { error ->
                            cancelPending()
                            NativeCrashStore.append(
                                applicationContext,
                                module = "media.session",
                                message = error.message ?: "无法重启原生媒体服务",
                                details = error.stackTraceToString(),
                                contextValue = "operation=restart_late_pending",
                            )
                        }
                    }
                } else {
                    cancel()
                }
            } else {
                runCatching { action(this) }
                    .onFailure { error ->
                        runCatching {
                            NativeCrashStore.append(
                                this,
                                module = "media.session",
                                message = error.message ?: "原生媒体操作失败",
                                details = error.stackTraceToString(),
                                contextValue = "operation=serialized",
                            )
                        }
                    }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run() else operationHandler.post(run)
    }

    private fun markExplicitStop() {
        releaseWasExplicitStop = true
        synchronized(pendingLock) {
            if (instance === this) explicitStopInProgress = true
        }
        cancelPending()
    }

    private fun acceptsDispatch(): Boolean = NativeMediaSessionPolicy.acceptsServiceDispatch(
        stopping = stopping,
        engineReleased = engineReleased,
        phase = lifecyclePhase,
    )
}
