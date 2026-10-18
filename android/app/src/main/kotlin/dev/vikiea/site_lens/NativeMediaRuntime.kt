package dev.vikiea.site_lens

import android.content.Context
import android.net.Uri
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
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
                    require(player != null) { "没有活动播放会话" }
                    player!!.play()
                    state = "playing"
                    emit("playing")
                    result.success(snapshot())
                }
                "pause" -> {
                    require(player != null) { "没有活动播放会话" }
                    player!!.pause()
                    state = "paused"
                    emit("paused")
                    result.success(snapshot())
                }
                "seek" -> {
                    val position = call.argument<Number>("positionMs")?.toLong() ?: -1L
                    require(position >= 0L && player != null) { "播放位置无效" }
                    player!!.seekTo(position)
                    result.success(snapshot())
                }
                "speed" -> {
                    val nextSpeed = call.argument<Number>("speed")?.toFloat() ?: 0f
                    require(nextSpeed > 0f && nextSpeed <= 4f && player != null) { "播放倍速无效" }
                    player!!.setPlaybackSpeed(nextSpeed)
                    speed = nextSpeed
                    result.success(snapshot())
                }
                "stop", "close" -> {
                    stop()
                    result.success(snapshot())
                }
                "state" -> result.success(snapshot())
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("native_media", error.message ?: "原生播放失败", null)
        }
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("url")?.trim() ?: error("缺少媒体地址")
        val uri = Uri.parse(raw)
        require(uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) {
            "媒体地址无效"
        }
        val mime = call.argument<String>("mime")?.trim().orEmpty()
        val sourceUrl = call.argument<String>("sourceUrl")?.trim().orEmpty()
        val referer = if (sourceUrl.isEmpty()) null else Uri.parse(sourceUrl).let { source ->
            require(source.scheme?.lowercase() in setOf("http", "https") && !source.host.isNullOrBlank() && source.userInfo == null) {
                "来源页面地址无效"
            }
            source.toString()
        }
        start(call, result, uri, mime, referer)
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
        start(call, result, Uri.fromFile(file), mime, null)
    }

    private fun start(
        call: MethodCall,
        result: MethodChannel.Result,
        uri: Uri,
        mime: String,
        referer: String?,
    ) {
        stop()
        sessionId = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() }
            ?: "native_${UUID.randomUUID()}"
        candidateId = call.argument<String>("candidateId")
        speed = 1f

        val playerBuilder = ExoPlayer.Builder(context)
        if (referer != null) {
            val http = DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setDefaultRequestProperties(mapOf("Referer" to referer))
            playerBuilder.setMediaSourceFactory(DefaultMediaSourceFactory(http))
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
        next.setMediaItem(item)
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
