package dev.vikiea.site_lens

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.view.Surface
import androidx.media3.common.Player
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.Closeable
import java.util.UUID
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
    private var sessionId: String? = null
    private var candidateId: String? = null
    private var speed: Float = 1f
    private var channel: MethodChannel? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var state: String = "stopped"
    private var lastError: String? = null
    private var serviceSessionId: String? = null
    private var serviceObserver: ((Map<String, Any?>) -> Unit)? = null
    private var localGeneration = 0L
    private var bridgeGeneration = 0L
    private var disposed = false
    private val bridgeId = UUID.randomUUID().toString()
    private var lifecycleOwnerId = UUID.randomUUID().toString()
    private var serviceSurfaceBindingId: String? = null
    private var openRequestId = 0L
    private var applicationForeground = true
    private var allowNativeBackgroundPlayback = false
    private var backgroundPolicyPaused = false
    private var lifecycleSequence = 0L

    fun attach(channel: MethodChannel) {
        serviceObserver?.let(NativeMediaSessionService::unregisterObserver)
        disposed = false
        val observerGeneration = ++bridgeGeneration
        lifecycleOwnerId = UUID.randomUUID().toString()
        NativeMediaSessionService.claimLifecycleOwner(context, lifecycleOwnerId)
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
                    lifecycleOwnerId,
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
            if (call.method == "applicationLifecycle") {
                val foreground = call.argument<Boolean>("foreground") ?: true
                val allowed =
                    call.argument<Boolean>("allowNativeBackgroundPlayback") ?: false
                val sequence = ++lifecycleSequence
                applicationForeground = foreground
                allowNativeBackgroundPlayback = allowed
                // 进程内不再有播放器；后台策略只由媒体会话执行。
                if (foreground) backgroundPolicyPaused = false
                val hadServiceSession = serviceSessionId != null
                NativeMediaSessionService.applicationLifecycle(
                    context,
                    foreground,
                    allowed,
                    lifecycleOwnerId,
                    sequence,
                ) { outcome ->
                    if (!hadServiceSession) {
                        result.success(snapshot())
                        return@applicationLifecycle
                    }
                    outcome.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { error ->
                            result.error("native_media", error.message, null)
                        },
                    )
                }
                return
            }
            if (call.method == "state" &&
                (NativeMediaSessionService.hasActiveSession() ||
                    NativeMediaSessionService.hasRestorableState(context))) {
                NativeMediaSessionService.state(context) { outcome ->
                    outcome.fold(
                        onSuccess = { raw ->
                            serviceSessionId = raw["sessionId"] as? String
                            if (serviceSessionId != null) {
                                ensureTexture()
                            } else {
                                releaseSurface()
                            }
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
                // 播放控制一律走媒体会话（isServiceCall 先行分流）；走到这里的
                // 本地分支只可能是过期请求。
                "play", "pause", "seek", "speed" -> error("播放会话已结束或已切换")
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
                    // stale route from stopping the new session.
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

    private fun isServiceCall(call: MethodCall): Boolean {
        if (call.method !in setOf("play", "pause", "seek", "speed", "stop", "close")) return false
        val requested = call.argument<String>("sessionId")
        return NativeMediaSessionService.owns(requested) ||
            (requested.isNullOrBlank() && NativeMediaSessionService.hasActiveSession())
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
        val route = NativeMediaSessionRoute.classify(
            raw,
            remoteSourceAllowed = remoteSourceEnabled(context),
        )
        require(route.family == NativeMediaSessionRoute.Family.REMOTE) { "媒体地址无效" }
        val mime = call.argument<String>("mime")?.trim().orEmpty()
        val uri = Uri.parse(raw)
        val hls = mime.contains("mpegurl", ignoreCase = true) ||
            uri.path?.lowercase()?.let { it.endsWith(".m3u8") || it.endsWith(".m3u") } == true
        // 进程内播放器不再是任何界面的主路径（ADR-0005）：远程地址一律交给媒体
        // 会话，由它统一提供锁屏、通知栏、媒体键与后台策略。
        openInService(call, result, taskId = "", uri = raw, mime = mime, hls = hls)
    }

    private fun remoteSourceEnabled(context: Context): Boolean {
        // 站点凭证是后续票；凭证接入前媒体会话只放行经开关授权的远程地址。
        return NativeMediaSessionRoute.preferenceAllowsRemoteSource(
            context.getSharedPreferences("media_access", Context.MODE_PRIVATE)
                .getString(NativeMediaSessionRoute.PREF_REMOTE_SOURCE_ALLOWED, null),
        )
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
        applicationForeground =
            call.argument<Boolean>("applicationForeground") ?: applicationForeground
        allowNativeBackgroundPlayback =
            call.argument<Boolean>("allowNativeBackgroundPlayback")
                ?: allowNativeBackgroundPlayback
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
                    applicationForeground = applicationForeground,
                    allowNativeBackgroundPlayback = allowNativeBackgroundPlayback,
                surface = surface,
                surfaceBindingId = bindingId,
                    surfaceOwnerId = lifecycleOwnerId,
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

    /** 进程内状态只反映媒体会话的回执，不再来自本地播放器。 */
    private fun emit(nextState: String, error: String? = null) {
        if (disposed) return
        sessionId?.let { NativeMediaObservations.recordPlayback(it, nextState) }
        channel?.invokeMethod("state", snapshot(nextState, error))
    }

    private fun snapshot(overrideState: String? = null, error: String? = null): Map<String, Any?> {
        val currentState = overrideState ?: state
        return mapOf(
            "sessionId" to sessionId,
            "candidateId" to candidateId,
            "textureId" to textureEntry?.id(),
            "state" to currentState,
            "positionMs" to 0L,
            "durationMs" to 0L,
            "videoWidth" to 0,
            "videoHeight" to 0,
            "speed" to speed,
            "userPaused" to false,
            "backgroundPolicyPaused" to backgroundPolicyPaused,
            "applicationForeground" to applicationForeground,
            "allowNativeBackgroundPlayback" to allowNativeBackgroundPlayback,
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
        // 进程内不再持有播放器或文件租约；这里只回收本桥的会话标识与 surface。
        sessionId?.let { NativeMediaObservations.recordPlayback(it, "stopped") }
        if (releaseSurface) releaseSurface()
        sessionId = null
        candidateId = null
        speed = 1f
        backgroundPolicyPaused = false
        state = "stopped"
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
                // Keep the bridge reachable for a retry; a failed native
                // release must not become a silent teardown.
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
