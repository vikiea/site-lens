package dev.vikiea.site_lens

import android.content.Context
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Process-local native playback session.  The app owns the candidate/task
 * authorization in Dart; this bridge accepts only the already validated
 * credential-free URL and keeps one replaceable session at a time. Android's
 * platform MediaPlayer is the fixed platform equivalent used by this build;
 * it is deliberately isolated behind the same lifecycle that the planned
 * Media3 adapter will implement.
 */
class NativeMediaRuntime(private val context: Context) : MethodChannel.MethodCallHandler {
    private var player: MediaPlayer? = null
    private var sessionId: String? = null
    private var candidateId: String? = null
    private var speed: Float = 1f
    private var channel: MethodChannel? = null
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
                "play" -> { require(player != null) { "没有活动播放会话" }; player?.start(); state = "playing"; emit("playing"); result.success(snapshot()) }
                "pause" -> { require(player != null) { "没有活动播放会话" }; player?.pause(); state = "paused"; emit("paused"); result.success(snapshot()) }
                "seek" -> {
                    val position = (call.argument<Number>("positionMs")?.toInt() ?: -1)
                    require(position >= 0 && player != null) { "播放位置无效" }
                    player!!.seekTo(position)
                    state = if (player!!.isPlaying) "playing" else state
                    result.success(snapshot())
                }
                "speed" -> {
                    val speed = call.argument<Number>("speed")?.toFloat() ?: 0f
                    require(speed > 0f && speed <= 4f && player != null) { "播放倍速无效" }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        player!!.playbackParams = player!!.playbackParams.setSpeed(speed)
                    }
                    this.speed = speed
                    result.success(snapshot())
                }
                "stop", "close" -> { stop(); result.success(snapshot()) }
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
        require(uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) { "媒体地址无效" }
        stop()
        val id = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() } ?: "native_${UUID.randomUUID()}"
        sessionId = id
        candidateId = call.argument<String>("candidateId")
        speed = 1f
        val next = MediaPlayer()
        player = next
        next.setOnPreparedListener { media ->
            state = "playing"
            media.start()
            emit("playing")
        }
        next.setOnCompletionListener { state = "completed"; emit("completed") }
        next.setOnInfoListener { _, what, _ ->
            if (what == MediaPlayer.MEDIA_INFO_BUFFERING_START) { state = "buffering"; emit("buffering") }
            if (what == MediaPlayer.MEDIA_INFO_BUFFERING_END) { state = "playing"; emit("playing") }
            false
        }
        next.setOnErrorListener { _, what, extra -> state = "failed"; emit("failed", "$what:$extra"); true }
        next.setDataSource(context, uri)
        next.prepareAsync()
        state = "preparing"
        result.success(snapshot())
    }

    private fun openLocal(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("path")?.trim() ?: error("缺少本地媒体路径")
        val file = java.io.File(raw).canonicalFile
        val roots = listOfNotNull(context.filesDir.canonicalFile, context.getExternalFilesDir(null)?.canonicalFile)
        require(roots.any { file.path == it.path || file.path.startsWith("${it.path}${java.io.File.separator}") }) { "本地媒体路径越界" }
        require(file.isFile && file.length() > 0) { "本地媒体不存在或为空" }
        stop()
        val id = call.argument<String>("sessionId")?.takeIf { it.isNotBlank() } ?: "native_${UUID.randomUUID()}"
        sessionId = id
        candidateId = call.argument<String>("candidateId")
        speed = 1f
        val next = MediaPlayer()
        player = next
        next.setOnPreparedListener { media -> state = "playing"; media.start(); emit("playing") }
        next.setOnCompletionListener { state = "completed"; emit("completed") }
        next.setOnInfoListener { _, what, _ ->
            if (what == MediaPlayer.MEDIA_INFO_BUFFERING_START) { state = "buffering"; emit("buffering") }
            if (what == MediaPlayer.MEDIA_INFO_BUFFERING_END) { state = "playing"; emit("playing") }
            false
        }
        next.setOnErrorListener { _, what, extra -> state = "failed"; emit("failed", "$what:$extra"); true }
        next.setDataSource(file.path)
        next.prepareAsync()
        state = "preparing"
        result.success(snapshot())
    }

    private fun emit(state: String, error: String? = null) {
        channel?.invokeMethod("state", snapshot(state, error))
    }

    private fun snapshot(overrideState: String? = null, error: String? = null): Map<String, Any?> {
        val active = player
        val currentState = overrideState ?: if (active == null) "stopped" else state
        return mapOf(
            "sessionId" to sessionId,
            "candidateId" to candidateId,
            "state" to currentState,
            "positionMs" to (runCatching { active?.currentPosition ?: 0 }.getOrDefault(0)),
            "durationMs" to (runCatching { active?.duration ?: 0 }.getOrDefault(0)),
            "speed" to speed,
            "errorCode" to error,
        )
    }

    private fun stop() {
        player?.let { media ->
            runCatching { media.stop() }
            media.reset()
            media.release()
        }
        player = null
        sessionId = null
        candidateId = null
        speed = 1f
        state = "stopped"
    }

    fun dispose() {
        stop()
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
