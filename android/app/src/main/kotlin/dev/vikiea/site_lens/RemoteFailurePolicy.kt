package dev.vikiea.site_lens

/**
 * 远程播放失败的四类归因与重试预算（T8，ADR-0005）。
 *
 * 远程播放可以不建任务，所以它不能用 `MediaTaskState` 表达结局；这里给出原生
 * 侧的一份判定与预算，形状与应用侧的 `RemoteFailureKind` 一一对应，但**不**与
 * 本地下载/播放的 `MediaErrorCode` 共用任何常量。
 *
 * 判定只看两件事：原生自己判定的「传输层抖动」（[Recoverable]）与数据源报出的
 * 清单/分片失败。站点明确拒绝（401/403）仍然由
 * [SiteCredentialFailurePolicy] 判定，它是四类里的一类，但预算归那边管。
 */
internal object RemoteFailurePolicy {
    enum class Kind {
        /** 站点明确拒绝（401/403）：凭证失效。 */
        CREDENTIAL_REJECTED,

        /** 主清单取不到：清单失效。 */
        MANIFEST_UNAVAILABLE,

        /** 清单还能读，但某一个分片取不到：分片失败。 */
        SEGMENT_FAILED,

        /** 连接、超时、DNS 之类的传输失败。 */
        NETWORK,
    }

    /** 与应用侧 `RemoteFailureCode.prefix` 对齐的事件名。 */
    const val EVENT_REMOTE_FAILURE = "remoteFailure"

    /**
     * 每一类在同一段会话里的自动重试硬上限。凭证失效与清单失效各自「只自动
     * 重试一次」就是它；分片失败与网络失败不重开整集，恒为 0。
     */
    const val MAX_AUTO_RETRIES = 1

    fun budgetFor(kind: Kind): Int = when (kind) {
        Kind.CREDENTIAL_REJECTED, Kind.MANIFEST_UNAVAILABLE -> MAX_AUTO_RETRIES
        Kind.SEGMENT_FAILED, Kind.NETWORK -> 0
    }

    /** 哪些种类会重开整集。分片失败与网络失败不重开。 */
    fun reopensEpisode(kind: Kind): Boolean = budgetFor(kind) > 0

    /**
     * 一次播放错误归到哪一类。
     *
     * [recoverable] 来自既有的 `isRecoverableSourceError`：原生对它已经用过自己
     * 的一次预算，仍失败时用户的结论就是网络失败。清单/分片失败来自数据源；
     * 404 与 5xx 这类 4xx/5xx 只能是那段地址坏了，不可能是凭证问题——401/403
     * 在那之前就已经被判定成凭证失效，走不到这里。
     */
    fun classify(
        recoverable: Boolean,
        manifestFailed: Boolean = false,
        segmentFailed: Boolean = false,
        httpStatus: Int? = null,
    ): Kind = when {
        httpStatus != null && (httpStatus == 401 || httpStatus == 403) -> Kind.CREDENTIAL_REJECTED
        manifestFailed -> Kind.MANIFEST_UNAVAILABLE
        segmentFailed -> Kind.SEGMENT_FAILED
        recoverable -> Kind.NETWORK
        else -> Kind.NETWORK
    }

    /**
     * 一段会话的远程失败预算。
     *
     * 按「会话 + 种类」记：同一段会话的凭证失效与清单失效各有一次机会，互不
     * 占用；换一段会话重新开始。
     */
    class State {
        private val attempts = mutableMapOf<String, Int>()

        fun attemptsFor(sessionId: String, kind: Kind): Int =
            attempts[key(sessionId, kind)] ?: 0

        /** 一段会话结束：预算回收，避免长会话里无限增长。 */
        fun forget(sessionId: String) {
            attempts.keys.removeAll { it.startsWith("$sessionId\u0000") }
        }

        /**
         * 这一次还该不该重开整集。返回 true 时预算被扣掉一次——调用方必须真的
         * 重开，不能只看不试；返回 false 时结论是「给建议」，不是静默重试。
         */
        fun mayReopen(sessionId: String, kind: Kind): Boolean {
            val budget = budgetFor(kind)
            if (budget <= 0) return false
            val used = attemptsFor(sessionId, kind)
            if (used >= budget) return false
            attempts[key(sessionId, kind)] = used + 1
            return true
        }

        private fun key(sessionId: String, kind: Kind): String =
            "$sessionId\u0000${kind.name}"
    }

    /**
     * 失败事件的对外形状：只有种类与次数，没有任何凭证值、地址或分片内容。
     * 与应用侧 `RemoteFailureFields.parse` 对齐。
     */
    fun eventFor(
        kind: Kind,
        sessionId: String,
        profileId: Int,
        attempt: Int,
    ): String = buildString {
        append(EVENT_REMOTE_FAILURE)
        append("; kind=").append(nameOf(kind))
        append("; profile=").append(profileId)
        append("; attempt=").append(attempt)
        // 只有会重开整集的种类才谈得上「终局」：分片与网络失败本来就不重开。
        append("; terminal=").append(reopensEpisode(kind) && attempt >= MAX_AUTO_RETRIES)
    }

    fun nameOf(kind: Kind): String = when (kind) {
        Kind.CREDENTIAL_REJECTED -> "credentialRejected"
        Kind.MANIFEST_UNAVAILABLE -> "manifestUnavailable"
        Kind.SEGMENT_FAILED -> "segmentFailed"
        Kind.NETWORK -> "network"
    }
}
