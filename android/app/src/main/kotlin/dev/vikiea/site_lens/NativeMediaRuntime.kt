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
    private var channel: MethodChannel? = null

    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> open(call, result)
                "play" -> { player?.start(); emit("playing"); result.success(snapshot()) }
                "pause" -> { player?.pause(); emit("paused"); result.success(snapshot()) }
                "seek" -> {
                    val position = (call.argument<Number>("positionMs")?.toInt() ?: -1)
                    require(position >= 0 && player != null) { "播放位置无效" }
                    player!!.seekTo(position)
                    result.success(snapshot())
                }
                "speed" -> {
                    val speed = call.argument<Number>("speed")?.toFloat() ?: 0f
                    require(speed > 0f && speed <= 4f && player != null) { "播放倍速无效" }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        player!!.playbackParams = player!!.playbackParams.setSpeed(speed)
                    }
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
        val next = MediaPlayer()
        player = next
        next.setOnPreparedListener { media ->
            media.start()
            emit("playing")
        }
        next.setOnCompletionListener { emit("completed") }
        next.setOnErrorListener { _, what, extra -> emit("failed", "$what:$extra"); true }
        next.setDataSource(context, uri)
        next.prepareAsync()
        result.success(snapshot())
    }

    private fun emit(state: String, error: String? = null) {
        channel?.invokeMethod("state", snapshot(state, error))
    }

    private fun snapshot(overrideState: String? = null, error: String? = null): Map<String, Any?> {
        val active = player
        val state = overrideState ?: when {
            active == null -> "stopped"
            active.isPlaying -> "playing"
            else -> "paused"
        }
        return mapOf(
            "sessionId" to sessionId,
            "state" to state,
            "positionMs" to (runCatching { active?.currentPosition ?: 0 }.getOrDefault(0)),
            "durationMs" to (runCatching { active?.duration ?: 0 }.getOrDefault(0)),
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
    }

    fun dispose() {
        stop()
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
