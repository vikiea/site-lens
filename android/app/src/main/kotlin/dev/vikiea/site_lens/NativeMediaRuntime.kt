package dev.vikiea.site_lens

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.view.Surface
import android.webkit.WebSettings
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.Closeable
import java.util.UUID
import java.net.InetAddress
import java.net.Proxy
import java.net.URI
import okhttp3.Dns
import okhttp3.OkHttpClient
import kotlin.math.roundToInt

/**
 * Process-local native playback session. Dart authorizes the candidate before
 * it reaches this bridge; Media3 owns buffering and HLS/progressive decoding,
 * and Flutter displays the video through a texture surface.
 */
class NativeMediaRuntime(
    private val context: Context,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {
    private var player: ExoPlayer? = null
    private var sessionId: String? = null
    private var candidateId: String? = null
    private var speed: Float = 1f
    private var channel: MethodChannel? = null
    private val secureDnsResolver = SecureDnsResolver()
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var state: String = "stopped"
    private var lastError: String? = null
    private var fileLease: Closeable? = null
    private var serviceSessionId: String? = null
    private var serviceObserver: ((Map<String, Any?>) -> Unit)? = null
    private var localGeneration = 0L
    private var bridgeGeneration = 0L
    private var disposed = false
    private val bridgeId = UUID.randomUUID().toString()
    private var serviceSurfaceBindingId: String? = null
    private var openRequestId = 0L

    fun attach(channel: MethodChannel) {
        serviceObserver?.let(NativeMediaSessionService::unregisterObserver)
        disposed = false
        val observerGeneration = ++bridgeGeneration
        this.channel = channel
        channel.setMethodCallHandler(this)
        val observer: (Map<String, Any?>) -> Unit = observer@{ raw ->
            if (disposed || observerGeneration != bridgeGeneration) return@observer
            val active = raw["sessionId"] as? String
            if (active != null) {
                serviceSessionId = active
                serviceSurfaceBindingId = surfaceBindingId(active, observerGeneration)
                ensureTexture()
                NativeMediaSessionService.attachSurface(
                    context,
                    surface,
                    active,
                    serviceSurfaceBindingId,
                )
                val snapshot = raw.toMutableMap().apply { this["textureId"] = textureEntry?.id() }
                channel.invokeMethod("state", snapshot)
            } else if (raw["restorable"] == true) {
                channel.invokeMethod("state", raw.toMutableMap().apply { this["textureId"] = null })
            } else if (serviceSessionId != null) {
                serviceSessionId = null
                releaseSurface()
                channel.invokeMethod("state", raw + ("textureId" to null))
            }
        }
        serviceObserver = observer
        NativeMediaSessionService.registerObserver(observer)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            check(!disposed) { "原生媒体桥接已释放" }
            if (isServiceCall(call)) {
                serviceCommand(call, result)
                return
            }
            if (call.method == "state" && player == null &&
                (NativeMediaSessionService.hasActiveSession() ||
                    NativeMediaSessionService.hasRestorableState(context))) {
                NativeMediaSessionService.state(context) { outcome ->
                    outcome.fold(
                        onSuccess = { raw ->
                            serviceSessionId = raw["sessionId"] as? String
                            if (serviceSessionId != null) ensureTexture()
                            result.success(raw.toMutableMap().apply { this["textureId"] = textureEntry?.id() })
                        },
                        onFailure = { error -> result.error("native_media", error.message, null) },
                    )
                }
                return
            }
            if (call.method == "discardRestorable") {
                NativeMediaSessionService.abandonRestorable(context)
                result.success(null)
                return
            }
            when (call.method) {
                "open" -> open(call, result)
                "openLocal" -> openLocal(call, result)
                "play" -> {
                    requireSession(call)
                    if (player!!.playbackState == Player.STATE_ENDED) {
                        player!!.seekToDefaultPosition()
                    }
                    player!!.play()
                    syncPlaybackState(player!!, localGeneration)
                    result.success(snapshot())
                }
                "pause" -> {
                    requireSession(call)
                    player!!.pause()
                    state = "paused"
                    emit("paused")
                    result.success(snapshot())
                }
                "seek" -> {
                    val position = call.argument<Number>("positionMs")?.toLong() ?: -1L
                    requireSession(call)
                    require(position >= 0L) { "播放位置无效" }
                    player!!.seekTo(position)
                    result.success(snapshot())
                }
                "speed" -> {
                    val nextSpeed = call.argument<Number>("speed")?.toFloat() ?: 0f
                    requireSession(call)
                    require(nextSpeed > 0f && nextSpeed <= 8f) { "播放倍速无效" }
                    player!!.setPlaybackSpeed(nextSpeed)
                    speed = nextSpeed
                    result.success(snapshot())
                }
                "levels" -> result.success(levels())
                "brightness" -> {
                    val value = call.argument<Number>("value")?.toFloat() ?: error("亮度值无效")
                    setBrightness(value)
                    result.success(levels())
                }
                "volume" -> {
                    val value = call.argument<Number>("value")?.toFloat() ?: error("音量值无效")
                    setVolume(value)
                    result.success(levels())
                }
                "stop", "close" -> {
                    // A route can finish disposing after a newer route has
                    // already opened another session. Ownership prevents the
                    // stale route from stopping the new player.
                    if (owns(call)) stop()
                    result.success(snapshot())
                }
                "state" -> result.success(snapshot())
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            NativeCrashStore.append(
                context,
                module = "android.media",
                message = error.message ?: "原生播放操作失败",
                details = error.stackTraceToString(),
                contextValue = "method=${call.method}",
            )
            result.error(MediaFileErrors.code(error) ?: "native_media", error.message ?: "原生播放失败", null)
        }
    }

    private fun owns(call: MethodCall): Boolean {
        val requested = call.argument<String>("sessionId")
        return requested.isNullOrBlank() || requested == sessionId
    }

    private fun requireSession(call: MethodCall) {
        require(player != null && owns(call)) { "播放会话已结束或已切换" }
    }

    private fun isServiceCall(call: MethodCall): Boolean {
        if (call.method !in setOf("play", "pause", "seek", "speed", "stop", "close")) return false
        val requested = call.argument<String>("sessionId")
        return NativeMediaSessionService.owns(requested) ||
            (requested.isNullOrBlank() && player == null && NativeMediaSessionService.hasActiveSession())
    }

    private fun serviceCommand(call: MethodCall, result: MethodChannel.Result) {
        val requestGeneration = bridgeGeneration
        val args = mutableMapOf<String, Any?>()
        (call.arguments as? Map<*, *>)?.forEach { (key, value) ->
            if (key is String) args[key] = value
        }
        if ((args["sessionId"] as? String).isNullOrBlank()) {
            serviceSessionId?.let { args["sessionId"] = it }
        }
        NativeMediaSessionService.command(context, call.method, args) commandCallback@{ outcome ->
            if (disposed || requestGeneration != bridgeGeneration) {
                result.error("native_media_stale", "原生媒体桥接已重绑定", null)
                return@commandCallback
            }
            outcome.fold(
                onSuccess = { raw ->
                    if (call.method == "stop" || call.method == "close") {
                        serviceSessionId = null
                        releaseSurface()
                    }
                    result.success(raw.toMutableMap().apply { this["textureId"] = textureEntry?.id() })
                },
                onFailure = { error -> result.error("native_media", error.message, null) },
            )
        }
    }

    private fun levels(): Map<String, Any> {
        val activity = context as? Activity
        val brightness = activity?.window?.attributes?.screenBrightness
            ?.takeIf { it >= 0f } ?: 0.5f
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        return mapOf(
            "brightness" to brightness.coerceIn(0f, 1f),
            "volume" to (current.toFloat() / max).coerceIn(0f, 1f),
        )
    }

    private fun setBrightness(value: Float) {
        val activity = context as? Activity ?: error("当前平台不支持亮度调节")
        val attributes = activity.window.attributes
        attributes.screenBrightness = value.coerceIn(0.05f, 1f)
        activity.window.attributes = attributes
    }

    private fun setVolume(value: Float) {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val next = (value.coerceIn(0f, 1f) * max).roundToInt()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, next.coerceIn(0, max), 0)
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("url")?.trim() ?: error("缺少媒体地址")
        val uri = Uri.parse(raw)
        require(uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) {
            "媒体地址无效"
        }
        val mime = call.argument<String>("mime")?.trim().orEmpty()
        val sourceUrl = call.argument<String>("sourceUrl")?.trim().orEmpty()
        val source = if (sourceUrl.isEmpty()) null else Uri.parse(sourceUrl).also { source ->
            require(source.scheme?.lowercase() in setOf("http", "https") && !source.host.isNullOrBlank() && source.userInfo == null) {
                "来源页面地址无效"
            }
        }
        val referer = source?.toString()
        val origin = source?.let { "${it.scheme}://${it.host}${if (it.port != -1) ":${it.port}" else ""}" }
        start(call, result, uri, mime, referer, origin)
    }

    private fun openLocal(call: MethodCall, result: MethodChannel.Result) {
        val taskId = call.argument<String>("taskId")?.takeIf { it.isNotBlank() }
            ?: error("缺少本地媒体身份")
        val document = call.argument<String>("uri")
        if (document != null) {
            val uri = Uri.parse(document)
            require(uri.scheme == "content" && !uri.authority.isNullOrBlank()) { "本地媒体地址无效" }
            context.contentResolver.openFileDescriptor(uri, "r")?.use {
                require(it.statSize != 0L) { "本地媒体不存在或为空" }
            } ?: error("无法读取本地媒体文件")
            openInService(call, result, taskId, document, "video/mp4", false)
            return
        }
        val raw = call.argument<String>("path")?.trim() ?: error("缺少本地媒体路径")
        val file = File(raw).canonicalFile
        val roots = listOfNotNull(
            context.filesDir.canonicalFile,
            context.getExternalFilesDir(null)?.canonicalFile,
        )
        val directRoot = context.getSharedPreferences("media_access", Context.MODE_PRIVATE)
            .getString("directRoot", null)
            ?.let { runCatching { File(it).canonicalFile }.getOrNull() }
        val directAllowed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            Environment.isExternalStorageManager() &&
            directRoot?.isDirectory == true &&
            !java.nio.file.Files.isSymbolicLink(directRoot.toPath()) &&
            (file.path == directRoot.path || file.path.startsWith("${directRoot.path}${File.separator}"))
        require(roots.any { file.path == it.path || file.path.startsWith("${it.path}${File.separator}") } || directAllowed) {
            "本地媒体路径越界"
        }
        val mime = call.argument<String>("mime")?.trim().orEmpty()
        // HLS readers open key/init/segments after the playlist; protect the
        // complete directory, including against deleting a parent directory.
        val hls = mime.contains("mpegurl", ignoreCase = true) ||
            file.extension.lowercase() in setOf("m3u8", "m3u")
        require(file.isFile && file.length() > 0) { "本地媒体不存在或为空" }
        openInService(call, result, taskId, Uri.fromFile(file).toString(), mime, hls)
    }

    private fun openInService(
        call: MethodCall,
        result: MethodChannel.Result,
        taskId: String,
        uri: String,
        mime: String,
        hls: Boolean,
    ) {
        openRequestId++
        // NativeMediaSessionService.open() replaces the current item while
        // keeping the process-owned MediaSession alive. Stopping the service
        // first creates a release/restart window in which the next-episode
        // request can be sent to the instance that is already being torn
        // down.
        if (serviceSessionId == null && player != null) {
            stopLocalPlayer(releaseSurface = false)
        }
        openInServiceAfterStop(call, result, taskId, uri, mime, hls)
    }

    private fun openInServiceAfterStop(
        call: MethodCall,
        result: MethodChannel.Result,
        taskId: String,
        uri: String,
        mime: String,
        hls: Boolean,
    ) {
        ensureTexture()
        val requestGeneration = bridgeGeneration
        val requestId = openRequestId
        val requestedSession = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() }
            ?: "play_${taskId}_${UUID.randomUUID()}"
        val bindingId = surfaceBindingId(requestedSession, requestGeneration)
        NativeMediaSessionService.open(
            context,
            NativeMediaSessionService.OpenRequest(
                sessionId = requestedSession,
                taskId = taskId,
                candidateId = call.argument<String>("candidateId"),
                uri = uri,
                mime = mime,
                title = call.argument<String>("title").orEmpty(),
                hls = hls,
                autoPlay = call.argument<Boolean>("autoPlay") ?: true,
                surface = surface,
                surfaceBindingId = bindingId,
                isCurrent = {
                    !disposed &&
                        requestGeneration == bridgeGeneration &&
                        requestId == openRequestId
                },
            ) callback@{ outcome ->
                if (disposed || requestGeneration != bridgeGeneration || requestId != openRequestId) {
                    result.error("native_media_stale", "原生媒体桥接已重绑定", null)
                    return@callback
                }
                outcome.fold(
                    onSuccess = { raw ->
                        serviceSessionId = raw["sessionId"] as? String
                        serviceSurfaceBindingId = bindingId
                        result.success(raw.toMutableMap().apply { this["textureId"] = textureEntry?.id() })
                    },
                    onFailure = { error ->
                        serviceSessionId = null
                        serviceSurfaceBindingId = null
                        releaseSurface()
                        result.error("native_media", error.message, null)
                    },
                )
            },
        )
    }

    private fun start(
        call: MethodCall,
        result: MethodChannel.Result,
        uri: Uri,
        mime: String,
        referer: String?,
        origin: String?,
        inputLease: Closeable? = null,
    ) {
        stop startCallback@{ completed ->
            if (!completed) {
                result.error("native_media_stop", "原生播放器仍在释放，媒体未打开", null)
                return@startCallback
            }
            startAfterStop(call, result, uri, mime, referer, origin, inputLease)
        }
    }

    private fun startAfterStop(
        call: MethodCall,
        result: MethodChannel.Result,
        uri: Uri,
        mime: String,
        referer: String?,
        origin: String?,
        inputLease: Closeable? = null,
    ) {
        val generation = ++localGeneration
        fileLease = inputLease
        sessionId = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() }
            ?: "native_${UUID.randomUUID()}"
        candidateId = call.argument<String>("candidateId")
        speed = 1f
        lastError = null

        val playerBuilder = ExoPlayer.Builder(
            context,
            DefaultRenderersFactory(context).setEnableDecoderFallback(true),
        )
        val dataSourceFactory: DataSource.Factory
        if (referer != null) {
            val requestProperties = buildMap {
                put("Referer", referer)
                if (origin != null) put("Origin", origin)
                put("Accept", "*/*")
                put("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
                val cookie = AndroidCookieReader.get(uri.toString())
                    ?: AndroidCookieReader.get(referer)
                if (!cookie.isNullOrBlank()) put("Cookie", cookie)
            }
            val secureDnsProvider = call.argument<String>("secureDnsProvider")?.trim().orEmpty()
            val routeOwnsDns = runCatching {
                SystemMediaNetwork.routeInfo(context, URI(uri.toString())).fakeIpAllowed
            }.getOrDefault(false)
            // The in-process player must follow the same OS proxy as the
            // browser and the download queue. DefaultHttpDataSource ignores
            // system proxies entirely, so a proxied page would open media that
            // the player could never fetch.
            val systemProxy = runCatching {
                SystemMediaNetwork.mediaProxy(context, URI(uri.toString()))
            }.getOrDefault(Proxy.NO_PROXY)
            val useSecureDns =
                secureDnsProvider.isNotBlank() && secureDnsProvider != "off" && !routeOwnsDns
            val http: DataSource.Factory = if (useSecureDns || systemProxy != Proxy.NO_PROXY) {
                val client = OkHttpClient.Builder()
                    .proxy(systemProxy)
                    .retryOnConnectionFailure(true)
                    .apply {
                        if (useSecureDns) {
                            dns(object : Dns {
                                override fun lookup(hostname: String): List<InetAddress> =
                                    runCatching {
                                        secureDnsResolver.lookup(secureDnsProvider, hostname)
                                            .map(InetAddress::getByName)
                                    }.getOrElse { Dns.SYSTEM.lookup(hostname) }
                            })
                        }
                    }
                    .build()
                OkHttpDataSource.Factory(client)
                    .setUserAgent(WebSettings.getDefaultUserAgent(context))
                    .setDefaultRequestProperties(requestProperties)
            } else {
                DefaultHttpDataSource.Factory()
                    .setAllowCrossProtocolRedirects(true)
                    .setConnectTimeoutMs(30_000)
                    .setReadTimeoutMs(30_000)
                    .setUserAgent(WebSettings.getDefaultUserAgent(context))
                    .setDefaultRequestProperties(requestProperties)
            }
            playerBuilder.setMediaSourceFactory(DefaultMediaSourceFactory(http))
            dataSourceFactory = http
        } else {
            dataSourceFactory = DefaultDataSource.Factory(context)
        }
        val next = playerBuilder.build()
        player = next
        val observationSession = sessionId!!
        next.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) {
                if (!isCurrentPlayer(next, generation) || observationSession != sessionId) return
                NativeMediaObservations.recordDecoder(observationSession, decoderName,
                    next.videoFormat?.sampleMimeType, "video")
            }

            override fun onAudioDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) {
                if (!isCurrentPlayer(next, generation) || observationSession != sessionId) return
                NativeMediaObservations.recordDecoder(observationSession, decoderName,
                    next.audioFormat?.sampleMimeType, "audio")
            }
        })
        next.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        next.setHandleAudioBecomingNoisy(true)
        attachSurface(next)
        next.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                syncPlaybackState(next, generation)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                syncPlaybackState(next, generation)
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                syncPlaybackState(next, generation)
            }

            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                if (!isCurrentPlayer(next, generation)) return
                emit(state)
            }

            override fun onPlayerError(error: PlaybackException) {
                if (!isCurrentPlayer(next, generation)) return
                state = "failed"
                val detail = buildString {
                    append(error.errorCodeName).append(':')
                    append(error.message ?: "播放失败")
                    error.cause?.let {
                        append('\n').append(it.stackTraceToString())
                    }
                }
                NativeCrashStore.append(
                    context,
                    module = "media.playback",
                    message = "原生媒体播放失败",
                    details = detail,
                    contextValue = "session=${sessionId ?: "unknown"}",
                )
                lastError = detail
                emit("failed", detail)
            }
        })

        val item = MediaItem.Builder()
            .setUri(uri)
            .setMediaMetadata(MediaMetadata.Builder().setTitle(call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: "Site Lens").build())
            .apply { if (mime.isNotEmpty()) setMimeType(mime) }
            .build()
        val hls = mime.contains("mpegurl", ignoreCase = true) ||
            uri.path?.lowercase()?.let { it.endsWith(".m3u8") || it.endsWith(".m3u") } == true
        if (hls) {
            // Select the HLS parser explicitly. Relying on URL inference can
            // misclassify signed playlists whose path has no extension.
            next.setMediaSource(
                HlsMediaSource.Factory(dataSourceFactory)
                    // A segment edge may reset one connection while the
                    // signed playlist remains valid. Keep the native player
                    // alive long enough to retry that segment.
                    .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(6))
                    .createMediaSource(item),
            )
        } else {
            next.setMediaItem(item)
        }
        state = "preparing"
        next.playWhenReady = true
        next.prepare()
        result.success(snapshot())
    }

    /**
     * ExoPlayer reports isPlaying=false while an item is preparing or buffering.
     * Treating every false callback as user pause makes the Flutter control
     * immediately switch back to Play and a subsequent tap only repeats
     * playWhenReady=true. Keep preparation/buffering states until the player is
     * ready, and only expose paused after an explicit playWhenReady=false.
     */
    private fun isCurrentPlayer(active: ExoPlayer, generation: Long): Boolean =
        !disposed && generation == localGeneration && active === player

    private fun syncPlaybackState(active: ExoPlayer, generation: Long) {
        if (!isCurrentPlayer(active, generation) || state == "failed" || state == "stopped") return
        val nextState = NativePlaybackState.resolve(
            state, active.playbackState, active.isPlaying, active.playWhenReady,
        )
        if (nextState != state) {
            state = nextState
            emit(nextState)
        }
    }

    private fun emit(nextState: String, error: String? = null) {
        if (disposed) return
        sessionId?.let { NativeMediaObservations.recordPlayback(it, nextState) }
        channel?.invokeMethod("state", snapshot(nextState, error))
    }

    private fun snapshot(overrideState: String? = null, error: String? = null): Map<String, Any?> {
        val active = player
        val currentState = overrideState ?: if (active == null) "stopped" else state
        val duration = active?.duration ?: 0L
        return mapOf(
            "sessionId" to sessionId,
            "candidateId" to candidateId,
            "textureId" to textureEntry?.id(),
            "state" to currentState,
            "positionMs" to (active?.currentPosition ?: 0L).coerceAtLeast(0L),
            "durationMs" to if (duration >= 0L) duration else 0L,
            "videoWidth" to (active?.videoSize?.width ?: 0),
            "videoHeight" to (active?.videoSize?.height ?: 0),
            "speed" to speed,
            "errorCode" to (error ?: lastError),
        )
    }

    private fun surfaceBindingId(sessionId: String?, generation: Long): String =
        "$bridgeId:$generation:${sessionId ?: "unknown"}"

    private fun stop(onComplete: (Boolean) -> Unit = {}) {
        // A runtime may outlive a Flutter bridge rebind. Never stop or detach
        // a service session that this runtime did not bind to.
        val hasServiceSession = serviceSessionId != null
        if (hasServiceSession) {
            NativeMediaSessionService.stop(context) stopCallback@{ completed ->
                if (!completed) {
                    onComplete(false)
                    return@stopCallback
                }
                serviceSessionId = null
                serviceSurfaceBindingId = null
                stopLocalPlayer(releaseSurface = false)
                releaseSurface()
                onComplete(true)
            }
            return
        }
        stopLocalPlayer()
        onComplete(true)
    }

    private fun stopLocalPlayer() = stopLocalPlayer(releaseSurface = true)

    private fun stopLocalPlayer(releaseSurface: Boolean) {
        localGeneration++
        val media = player
        player = null
        if (media != null) {
            // Invalidate callbacks before touching the player. Media3 can
            // deliver queued state/error events while stop() and release()
            // are unwinding on the playback looper.
            try {
                media.clearVideoSurface()
                media.stop()
                media.clearMediaItems()
                media.release()
            } catch (error: Throwable) {
                player = media
                state = "stopping"
                lastError = error.message ?: "原生播放器释放失败"
                throw error
            }
        }
        sessionId?.let { NativeMediaObservations.recordPlayback(it, "stopped") }
        closeFileLease()
        if (releaseSurface) releaseSurface()
        sessionId = null
        candidateId = null
        speed = 1f
        state = "stopped"
    }

    private fun closeFileLease() {
        fileLease?.close()
        fileLease = null
    }

    private fun ensureTexture() {
        if (textureEntry != null && surface != null) return
        val entry = textures.createSurfaceTexture()
        textureEntry = entry
        surface = Surface(entry.surfaceTexture())
    }

    private fun releaseSurface() {
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        serviceSurfaceBindingId = null
    }

    private fun attachSurface(next: ExoPlayer) {
        val entry = textures.createSurfaceTexture()
        textureEntry = entry
        surface = Surface(entry.surfaceTexture())
        next.setVideoSurface(surface)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        bridgeGeneration++
        openRequestId++
        NativeMediaSessionService.cancelPendingActions()
        // The MediaSessionService intentionally survives Flutter engine
        // teardown. Only detach the temporary video surface and unregister
        // callbacks; an explicit Dart stop/close command still stops it.
        if (serviceSessionId != null) {
            val expectedSessionId = serviceSessionId
            val expectedBindingId = serviceSurfaceBindingId
            serviceSessionId = null
            serviceSurfaceBindingId = null
            // NativeMediaSessionService.detachSurface(context) is the
            // service-owned boundary; generation IDs below narrow it to this
            // bridge's current surface binding.
            NativeMediaSessionService.detachSurface(
                context,
                expectedSessionId,
                expectedBindingId,
            ) { _ ->
                // A stale detach can be rejected after service teardown has
                // started. The Flutter-owned Surface/Texture still belongs to
                // this runtime and must be released either way.
                releaseSurface()
                finishDispose()
            }
        } else {
            try {
                stop()
            } catch (error: Throwable) {
                // Keep the player, lease, and bridge reachable for a retry;
                // a failed native release must not become a silent teardown.
                disposed = false
                throw error
            }
            finishDispose()
            return
        }
    }

    private fun finishDispose() {
        serviceObserver?.let(NativeMediaSessionService::unregisterObserver)
        serviceObserver = null
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
