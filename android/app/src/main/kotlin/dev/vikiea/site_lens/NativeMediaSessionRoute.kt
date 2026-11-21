package dev.vikiea.site_lens

import java.io.File
import java.net.URI
import java.util.Locale

/**
 * 远程会话与本地会话的唯一判定点（ADR-0005）。
 *
 * 媒体会话在租约、可恢复状态与冷恢复三处的语义不同：
 *
 * - 租约：本地会话持有文件读租约，防止下载/导出改动正在读取的文件；远程会话不
 *   持有文件租约，同一候选可以同时存在远程播放与本地下载。
 * - 可恢复状态：本地会话把 uri/mime/position 写进 `native_media_session_state`，
 *   任务被移除时保留可恢复记录；远程地址是短期凭证，不写可恢复记录。
 * - 冷恢复：只有本地记录会被读回并重新开播。
 *
 * 判定对象不依赖 Android 类，唯一的外部输入是站点凭证是否允许远程来源（后续票）。
 */
internal data class NativeMediaSessionRoute(
    val scheme: Scheme,
    val family: Family,
) {
    enum class Scheme {
        FILE,
        CONTENT,
        HTTP,
        HTTPS,
    }

    enum class Family {
        LOCAL,
        REMOTE,
    }

    enum class SourceKind {
        /** 边界可变的本地 HLS：只读已提交分片。 */
        LOCAL_GROWING_FILE,

        /** 本地 MP4 或 SAF 文档。 */
        LOCAL_DEFAULT,

        /** 远程 HLS：由 HTTP 数据源拉取清单与分片。 */
        REMOTE_HTTP,

        /** 远程渐进式：由 HTTP 数据源拉取字节区间。 */
        REMOTE_HTTP_PROGRESSIVE,
    }

    /** 本地会话持有文件读租约，远程会话不持有。 */
    val holdsFileLease: Boolean get() = family == Family.LOCAL

    /** 只有本地会话把会话写进可恢复记录。 */
    val isRestorable: Boolean get() = family == Family.LOCAL

    /**
     * 本次会话要获取的读租约；远程会话返回 `null`，表示不获取文件租约。
     *
     * [rawUri] 是请求里的原始地址。远程播放允许没有任务，也不读这个地址。
     */
    fun leaseForOpening(taskId: String, rawUri: String, hls: Boolean): MediaFileLeaseRegistry.Scope? {
        // 远程会话不读本地文件，因此这里刻意不解析 rawUri。
        if (!holdsFileLease) return null
        val scope = MediaFileLeaseRegistry.Scope.task(taskId)
        val resource = if (scheme == Scheme.FILE && hls) {
            val parent = File(URI(rawUri).path ?: throw IllegalArgumentException("媒体路径无效")).parentFile
                ?: throw IllegalArgumentException("媒体路径无效")
            MediaFileLeaseRegistry.Scope.file(parent)
        } else {
            MediaFileLeaseRegistry.Scope.source(rawUri)
        }
        return scope + resource
    }

    /** 本次会话使用的数据源类别。 */
    fun sourceOf(isHls: Boolean): SourceKind = when {
        holdsFileLease && scheme == Scheme.FILE && isHls -> SourceKind.LOCAL_GROWING_FILE
        holdsFileLease -> SourceKind.LOCAL_DEFAULT
        isHls -> SourceKind.REMOTE_HTTP
        else -> SourceKind.REMOTE_HTTP_PROGRESSIVE
    }

    companion object {
        /** 应用设置：允许媒体会话打开远程地址。凭证接入前默认关闭。 */
        const val PREF_REMOTE_SOURCE_ALLOWED = "remoteSourceAllowed"

        private val SCHEMES = mapOf(
            "file" to Scheme.FILE,
            "content" to Scheme.CONTENT,
            "http" to Scheme.HTTP,
            "https" to Scheme.HTTPS,
        )

        fun preferenceAllowsRemoteSource(raw: String?): Boolean = raw?.trim() == "true"

        fun isPlayable(raw: String): Boolean = runCatching { classify(raw) }.isSuccess

        /**
         * 按 request uri 判定会话类型。
         *
         * 与既有本地规则一致：`file` 与 `content` 始终放行（路径越界由服务另行校验），
         * `http(s)` 必须有主机、没有 userinfo，且受 [remoteSourceAllowed] 约束。
         * 其余 scheme 保持原有的拒绝。
         */
        fun classify(raw: String, remoteSourceAllowed: Boolean = true): NativeMediaSessionRoute {
            if (raw.isBlank()) throw IllegalArgumentException("媒体地址无效")
            val uri = try {
                URI(raw)
            } catch (error: java.net.URISyntaxException) {
                throw IllegalArgumentException("媒体地址无效")
            }
            val scheme = SCHEMES[uri.scheme?.lowercase(Locale.ROOT) ?: ""]
                ?: throw IllegalArgumentException("媒体地址仅支持本地文件或远程地址")
            return when (scheme) {
                Scheme.FILE, Scheme.CONTENT -> of(scheme, true, remoteSourceAllowed)
                Scheme.HTTP, Scheme.HTTPS -> {
                    if (uri.host.isNullOrBlank() || uri.userInfo != null) {
                        throw IllegalArgumentException("远程媒体地址无效")
                    }
                    of(
                        scheme,
                        playableLocalFile = false,
                        remoteSourceAllowed = remoteSourceAllowed,
                    )
                }
            }
        }

        /**
         * 组合判定。
         *
         * - [playableLocalFile]：候选是否已有可播放本地文件。为真时即使 request uri
         *   是远程地址，也按本地会话处理（ADR-0002「远程路径按候选是否已有可播放
         *   本地文件分流」）。
         * - [remoteSourceAllowed]：站点凭证/设置是否允许远程来源。为假时远程地址
         *   保持既有拒绝，本地地址不受影响。
         */
        fun of(
            scheme: Scheme,
            playableLocalFile: Boolean,
            remoteSourceAllowed: Boolean,
        ): NativeMediaSessionRoute {
            val local = scheme == Scheme.FILE || scheme == Scheme.CONTENT || playableLocalFile
            if (!local && !remoteSourceAllowed) {
                throw IllegalArgumentException("远程媒体来源未开启")
            }
            return NativeMediaSessionRoute(scheme, if (local) Family.LOCAL else Family.REMOTE)
        }

        /** 任务被移除时是否可以保留可恢复记录。 */
        fun shouldPreserveRestorable(raw: String): Boolean =
            isPlayable(raw) && classify(raw).isRestorable

        /**
         * 冷恢复：服务启动时读到的持久记录是否值得重新开播。
         *
         * 只有本地记录会被读回；远程地址不是可恢复状态，读到时直接丢弃。
         */
        fun shouldRestore(raw: String): Boolean =
            isPlayable(raw) && classify(raw).isRestorable
    }
}
