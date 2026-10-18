package dev.vikiea.site_lens

import android.content.Context
import android.net.Uri
import android.view.Surface
import android.webkit.WebSettings
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.UUID

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
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var state: String = "stopped"

    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> open(call, result)
                "openLocal" -> openLocal(call, result)
                "play" -> {
                    requireSession(call)
                    player!!.play()
                    state = "playing"
                    emit("playing")
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
                    require(nextSpeed > 0f && nextSpeed <= 4f) { "播放倍速无效" }
                    player!!.setPlaybackSpeed(nextSpeed)
                    speed = nextSpeed
                    result.success(snapshot())
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
            result.error("native_media", error.message ?: "原生播放失败", null)
        }
    }

    private fun owns(call: MethodCall): Boolean {
        val requested = call.argument<String>("sessionId")
        return requested.isNullOrBlank() || requested == sessionId
    }

    private fun requireSession(call: MethodCall) {
        require(player != null && owns(call)) { "播放会话已结束或已切换" }
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
        val raw = call.argument<String>("path")?.trim() ?: error("缺少本地媒体路径")
        val file = File(raw).canonicalFile
        val roots = listOfNotNull(
            context.filesDir.canonicalFile,
            context.getExternalFilesDir(null)?.canonicalFile,
        )
        require(roots.any { file.path == it.path || file.path.startsWith("${it.path}${File.separator}") }) {
            "本地媒体路径越界"
        }
        require(file.isFile && file.length() > 0) { "本地媒体不存在或为空" }
        val mime = call.argument<String>("mime")?.trim().orEmpty()
        start(call, result, Uri.fromFile(file), mime, null, null)
    }

    private fun start(
        call: MethodCall,
        result: MethodChannel.Result,
        uri: Uri,
        mime: String,
        referer: String?,
        origin: String?,
    ) {
        stop()
        sessionId = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() }
            ?: "native_${UUID.randomUUID()}"
        candidateId = call.argument<String>("candidateId")
        speed = 1f

        val playerBuilder = ExoPlayer.Builder(context)
        val dataSourceFactory: DataSource.Factory
        if (referer != null) {
            val http = DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(30_000)
                .setReadTimeoutMs(30_000)
                .setUserAgent(WebSettings.getDefaultUserAgent(context))
                .setDefaultRequestProperties(
                    buildMap {
                        put("Referer", referer)
                        if (origin != null) put("Origin", origin)
                        put("Accept", "*/*")
                    },
                )
            playerBuilder.setMediaSourceFactory(DefaultMediaSourceFactory(http))
            dataSourceFactory = http
        } else {
            dataSourceFactory = DefaultDataSource.Factory(context)
        }
        val next = playerBuilder.build()
        player = next
        attachSurface(next)
        next.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        state = "buffering"
                        emit("buffering")
                    }
                    Player.STATE_READY -> {
                        state = if (next.isPlaying) "playing" else "paused"
                        emit(state)
                    }
                    Player.STATE_ENDED -> {
                        state = "completed"
                        emit("completed")
                    }
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (state == "completed" || state == "failed" || state == "stopped") return
                state = if (isPlaying) "playing" else "paused"
                emit(state)
            }

            override fun onPlayerError(error: PlaybackException) {
                state = "failed"
                emit("failed", "${error.errorCodeName}:${error.message ?: "播放失败"}")
            }
        })

        val item = MediaItem.Builder()
            .setUri(uri)
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
        next.playWhenReady = true
        next.prepare()
        state = "preparing"
        result.success(snapshot())
    }

    private fun emit(nextState: String, error: String? = null) {
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
            "speed" to speed,
            "errorCode" to error,
        )
    }

    private fun stop() {
        player?.let { media ->
            runCatching { media.clearVideoSurface() }
            media.release()
        }
        player = null
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        sessionId = null
        candidateId = null
        speed = 1f
        state = "stopped"
    }

    private fun attachSurface(next: ExoPlayer) {
        val entry = textures.createSurfaceTexture()
        textureEntry = entry
        surface = Surface(entry.surfaceTexture())
        next.setVideoSurface(surface)
    }

    fun dispose() {
        stop()
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
