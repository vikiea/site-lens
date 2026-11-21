package dev.vikiea.site_lens

/**
 * 原生侧的凭证入口（ADR-0007），与 Dart 侧 `lib/media/native_credential_push.dart`
 * 的通道 `site_lens/credentials` 一一对应。
 *
 * 写入只有两个方法：`push` 与 `clear`。读取只有一个方法名 `has`，回答「这个档案
 * 有没有可用的凭证」——它不返回任何凭证值，回执里只有档案 id 与代次。原生从不
 * 回写这份副本：应用侧推什么，它就拿着什么。
 */
internal class SiteCredentialChannel(
    private val shelf: SiteCredentialRecord.Shelf,
    private val clock: () -> Long,
    private val loader: ((Loader) -> Unit)? = null,
) {
    fun interface Loader {
        fun accept(profileId: Int, raw: String)
    }

    /** 原生侧持久化落点。实现只负责把字符串存进/读出容器，不解释内容。 */
    interface Store {
        fun read(profileId: Int): String?

        fun write(profileId: Int, raw: String)

        fun delete(profileId: Int)
    }

    /** 原生侧可观测的代次：只随推送前进，从不回退，回执里用来对齐两份副本。 */
    private var sequence = 0L

    val shelfSize: Int get() = shelf.size

    /** 最近一次推送或撤回的序号：只前进，从不回退。 */
    val epoch: Long get() = sequence

    /** 进程启动时把持久化的副本读回内存。读不出来的记录直接跳过。 */
    fun restore() {
        val read = loader ?: return
        read { profileId, raw ->
            runCatching { shelf.store(SiteCredentialRecord.decode(profileId, raw)) }
        }
    }

    /** 应用侧推来一份凭证：整份替换原生侧那一份。 */
    fun push(profileId: Int, raw: String): Map<String, Any?> {
        require(profileId >= 0) { "站点档案无效" }
        val credential = SiteCredentialRecord.decode(profileId, raw)
        shelf.store(credential)
        return receipt(profileId)
    }

    /** 应用侧撤回凭证（登出、档案删除）。重复调用没有副作用。 */
    fun clear(profileId: Int): Map<String, Any?> {
        require(profileId >= 0) { "站点档案无效" }
        shelf.clear(profileId)
        return receipt(profileId)
    }

    /** 这个档案有没有一份「此刻可用」的凭证。只回答有或没有。 */
    fun has(profileId: Int): Boolean = usable(profileId) != null

    /** 远程来源的准入门槛（ADR-0009）：这条地址有没有站点凭证。 */
    fun remoteSourceEnabled(profileId: Int, raw: String): Boolean =
        admissionHeaders(raw, profileId).isNotEmpty()

    /**
     * 这次请求该带的头。回执只进请求，不进快照、日志或错误文案。
     *
     * 读不到凭证、读出来已经过期、或者记录版本不认识，一律当作「没有凭证」：
     * 公开内容照播；私有内容会在 401/403 时回传失效事件，由应用续期后重推。
     */
    fun admissionHeaders(raw: String, profileId: Int): Map<String, String> {
        val credential = shelf.get(profileId, raw) ?: return emptyMap()
        if (credential.isExpiredAt(clock())) return emptyMap()
        return credential.headers()
    }

    private fun usable(profileId: Int): SiteCredentialRecord? {
        val held = shelf.held(profileId) ?: return null
        return held.takeUnless { it.isExpiredAt(clock()) || it.isEmpty }
    }

    /** 回执只说「哪一份、什么时候收下的」，不说收下了什么。 */
    private fun receipt(profileId: Int): Map<String, Any?> {
        sequence += 1
        return mapOf(
            "accepted" to true,
            "profileId" to profileId,
            "epoch" to clock(),
        )
    }

    override fun toString(): String =
        "SiteCredentialChannel(profiles=$shelfSize, pushes=$sequence)"
}
