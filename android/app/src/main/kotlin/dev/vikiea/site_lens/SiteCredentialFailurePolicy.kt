package dev.vikiea.site_lens

/**
 * 401/403 的处置判定（GLOSSARY: 凭证失效；ADR-0007）。
 *
 * 站点用 401/403 明确拒绝，才知道「凭证不再有效」。网络失败、超时、内容不可用
 * 都不是这件事：把它们也算成凭证失效，用户会在网络不好时被要求重新登录。
 *
 * 重试有界：一段播放会话至多回传一次「可以重试」的失效事件，应用续期成功并重推
 * 之后原生只重试一次；第二次拒绝只回传终局结论，不再重试。
 */
internal object SiteCredentialFailurePolicy {
    enum class Kind {
        /** 站点明确拒绝：凭证失效。 */
        CREDENTIAL_REJECTED,

        /** 连接、超时、DNS 之类的传输失败。 */
        NETWORK,

        /** 地址不存在、服务器错误、限流等：内容不可用。 */
        CONTENT_UNAVAILABLE,
    }

    data class Disposition(val kind: Kind) {
        val isCredentialRejection: Boolean get() = kind == Kind.CREDENTIAL_REJECTED

        /** 只有凭证失效会让应用介入（刷新、重推、要求重新登录）。 */
        val shouldAskApplication: Boolean get() = isCredentialRejection
    }

    const val MAX_RETRIES = 1

    /** 原生回传给应用的事件种类；与 Dart 侧 `NativeCredentialEvent.kind` 对齐。 */
    const val EVENT_CREDENTIAL_REJECTED = "credentialRejected"

    fun forHttpStatus(status: Int): Disposition = when (status) {
        401, 403 -> Disposition(Kind.CREDENTIAL_REJECTED)
        else -> Disposition(Kind.CONTENT_UNAVAILABLE)
    }

    /**
     * 原生读到一份已过期的副本。它不刷新、不清空，只把判定交回应用——续期属于
     * 应用侧（GLOSSARY: 凭证刷新）。
     */
    fun forExpiredCopy(): Disposition = Disposition(Kind.CREDENTIAL_REJECTED)

    /** 没有 HTTP 状态可看时（连接断开、超时），一律按网络失败处置。 */
    fun networkFailure(): Disposition = Disposition(Kind.NETWORK)

    fun mayRetry(attempt: Int): Boolean = attempt in 1..MAX_RETRIES

    fun eventFor(
        status: Int,
        sessionId: String,
        profileId: Int,
        attempt: Int,
    ): Map<String, Any?> = mapOf(
        "kind" to EVENT_CREDENTIAL_REJECTED,
        "status" to status,
        "sessionId" to sessionId,
        "profileId" to profileId,
        "attempt" to attempt,
        "retries" to attempt.coerceAtLeast(0),
        "terminal" to !mayRetry(attempt),
    )

    /**
     * 一段播放会话的失效预算。
     *
     * [attempt] 是这段会话已经回传过的失效次数；推送一份新凭证只清空配额，不会
     * 让**当前**这次失败再试一次——否则网络抖动与过期副本会互相掩护，重试就没有
     * 上限了。
     */
    class State(
        var sessionId: String? = null,
        var attempt: Int = 0,
        private var retried: Boolean = false,
    ) {
        init {
            // 推送只重置配额、不重置「这段会话已经用掉过配额」：当前这次失败不会
            // 因为中途来了一份新凭证而获得第二次机会。
            retried = attempt > 0
        }

        fun mayAskApplication(session: String): Boolean = sessionId == session && !retried

        fun nextAttempt(session: String): Int {
            if (sessionId != session) {
                sessionId = session
                attempt = 0
                retried = false
            }
            attempt += 1
            retried = true
            return attempt
        }

        fun event(session: String, status: Int): Map<String, Any?> = eventFor(
            status = status,
            sessionId = session,
            profileId = profileId,
            attempt = if (sessionId == session) attempt else 1,
        )

        /** 应用推来一份新凭证：下一段会话重新开始配额。 */
        fun onCredentialPushed(session: String?) {
            if (session == null || session == sessionId) {
                attempt = 0
                retried = false
            }
        }

        var profileId: Int = -1
            private set

        fun bindProfile(profileId: Int) {
            this.profileId = profileId
        }
    }
}
