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
 * 判定对象不依赖 Android 类，唯一的外部输入是「这次请求有没有站点凭证」。
 *
 * 远程来源的准入门槛是站点凭证（ADR-0009）：有凭证就带上注入请求头，没有凭证
 * 就按公开内容放行——两者都允许远程会话，区别只在请求头。ADR-0008 那个默认关闭
 * 的配置开关已经退休，判定对象不再读任何配置。
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

    /**
     * 这次请求要注入的凭证：只有远程会话、且这份凭证确实服务这条地址时才有。
     * 公开内容（没有凭证）得到的是 [SiteCredentialRecord.NONE]，不是错误。
     */
    data class Admission(
        val route: NativeMediaSessionRoute,
        val credential: SiteCredentialRecord?,
    ) {
        val headers: Map<String, String> get() = credential?.headers() ?: emptyMap()
    }

    /** 本次会话使用的数据源类别。 */
    fun sourceOf(isHls: Boolean): SourceKind = when {
        holdsFileLease && scheme == Scheme.FILE && isHls -> SourceKind.LOCAL_GROWING_FILE
        holdsFileLease -> SourceKind.LOCAL_DEFAULT
        isHls -> SourceKind.REMOTE_HTTP
        else -> SourceKind.REMOTE_HTTP_PROGRESSIVE
    }

    companion object {
        private val SCHEMES = mapOf(
            "file" to Scheme.FILE,
            "content" to Scheme.CONTENT,
            "http" to Scheme.HTTP,
            "https" to Scheme.HTTPS,
        )

        fun isPlayable(raw: String): Boolean = runCatching { classify(raw) }.isSuccess

        /**
         * 按 request uri 判定会话类型。
         *
         * 与既有本地规则一致：`file` 与 `content` 始终放行（路径越界由服务另行校验），
         * `http(s)` 必须有主机、没有 userinfo。其余 scheme 保持原有的拒绝。
         */
        fun classify(raw: String, hasCredential: Boolean = false): NativeMediaSessionRoute {
            if (raw.isBlank()) throw IllegalArgumentException("媒体地址无效")
            val uri = try {
                URI(raw)
            } catch (error: java.net.URISyntaxException) {
                throw IllegalArgumentException("媒体地址无效")
            }
            val scheme = SCHEMES[uri.scheme?.lowercase(Locale.ROOT) ?: ""]
                ?: throw IllegalArgumentException("媒体地址仅支持本地文件或远程地址")
            return when (scheme) {
                Scheme.FILE, Scheme.CONTENT -> of(scheme, true, hasCredential)
                Scheme.HTTP, Scheme.HTTPS -> {
                    if (uri.host.isNullOrBlank() || uri.userInfo != null) {
                        throw IllegalArgumentException("远程媒体地址无效")
                    }
                    of(
                        scheme,
                        playableLocalFile = false,
                        hasCredential = hasCredential,
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
         * - [hasCredential]：这次请求是否带着站点凭证。它只决定请求要不要注入凭证，
         *   不再决定远程来源能否放行：公开内容没有凭证也必须能播（ADR-0009）。
         */
        fun of(
            scheme: Scheme,
            playableLocalFile: Boolean,
            hasCredential: Boolean,
        ): NativeMediaSessionRoute {
            val local = scheme == Scheme.FILE || scheme == Scheme.CONTENT || playableLocalFile
            return NativeMediaSessionRoute(scheme, if (local) Family.LOCAL else Family.REMOTE)
        }

        /**
         * 一次播放入口的完整判定：会话类型 + 这条地址该带的凭证。
         *
         * 取不到凭证不是失败：`credential` 为 null，`headers` 为空，按公开内容播。
         * 取到的凭证只服务于它自己那个站点，别的站点拿不到。
         */
        fun admit(
            raw: String,
            shelf: SiteCredentialRecord.Shelf,
            profileId: Int,
        ): Admission {
            val credential = shelf.get(profileId, raw)
            return Admission(
                route = classify(raw, hasCredential = credential != null),
                credential = credential,
            )
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
