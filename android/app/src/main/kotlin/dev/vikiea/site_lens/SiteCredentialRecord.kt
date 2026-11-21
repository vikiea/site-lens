package dev.vikiea.site_lens

import org.json.JSONException
import org.json.JSONObject
import java.net.URI
import java.util.Locale

/**
 * 原生侧持有的站点凭证（ADR-0007）。应用侧写入，原生只读。
 *
 * 这个类型没有「转成字符串」的入口：[toString] 只说有没有值、属于哪个档案，任何
 * 一条日志或异常都不会把令牌、cookie、设备标识带出去。字段名与
 * `lib/site_credentials/site_credential_store.dart` 的记录一一对应，版本号不同就
 * 整体不认识——宁可当成「没有凭证」，也不要读出一个半截会话。
 */
data class SiteCredentialRecord(
    val profileId: Int,
    val accountId: String,
    /** 这份凭证所服务的站点 origin；为空表示不限定站点。 */
    val station: String?,
    val accessToken: String?,
    val refreshToken: String?,
    val cookies: Map<String, String>,
    val installationStamp: String?,
    val expiresAtEpochMs: Long?,
) {
    val hasAccessToken: Boolean get() = !accessToken.isNullOrBlank()

    val hasCookies: Boolean get() = cookies.isNotEmpty()

    /** 令牌与 cookie 都在才算一份会话（GLOSSARY: 站点凭证）。 */
    val isEmpty: Boolean get() = !hasAccessToken && !hasCookies

    /**
     * 过期时间是否已过。原生不会因此自己刷新，也不会清掉这一份：它只是把「这是
     * 一份过期副本」这件事交给应用判定（ADR-0007 Consequences）。
     */
    fun isExpiredAt(nowEpochMs: Long): Boolean {
        val at = expiresAtEpochMs ?: return false
        return nowEpochMs >= at
    }

    /** 播放入口拿来判定「这条地址有没有站点凭证」。 */
    fun appliesAt(raw: String): Boolean {
        if (isEmpty) return false
        val named = station ?: return true
        val requested = runCatching { URI(raw) }.getOrNull() ?: return false
        val expected = runCatching { URI(named) }.getOrNull() ?: return false
        if (requested.scheme == null || expected.scheme == null) return false
        if (!requested.scheme.equals(expected.scheme, ignoreCase = true)) return false
        if (!requested.host.equals(expected.host, ignoreCase = true)) return false
        return requested.port == expected.port
    }

    /**
     * 请求头。只有令牌与 cookie 参与：设备标识是站点自己的东西，止步于适配器
     * （ADR-0004）。
     */
    fun headers(): Map<String, String> {
        if (isEmpty) return emptyMap()
        val values = LinkedHashMap<String, String>(2)
        accessToken?.takeIf { it.isNotBlank() }?.let { values[HEADER_AUTHORIZATION] = "Bearer $it" }
        if (cookies.isNotEmpty()) {
            values[HEADER_COOKIE] = cookies.entries.joinToString("; ") { "${it.key}=${it.value}" }
        }
        return values
    }

    /** 不打印任何值：日志、诊断、错误文案只允许说到「有没有」。 */
    override fun toString(): String =
        "SiteCredentialRecord(profileId=$profileId, station=${station ?: "any"}, " +
            "accessTokenPresent=$hasAccessToken, refreshTokenPresent=${!refreshToken.isNullOrBlank()}, " +
            "cookieCount=${cookies.size}, expiresAtPresent=${expiresAtEpochMs != null})"

    companion object {
        const val HEADER_AUTHORIZATION = "Authorization"
        const val HEADER_COOKIE = "Cookie"

        /** 与 Dart 侧 `SiteCredentialStore.recordVersion` 对齐。 */
        const val RECORD_VERSION = 1

        /** 单字段上限，与 Dart 侧 `maxFieldLength` 一致。 */
        const val MAX_FIELD_LENGTH = 8192

        /** 整条记录上限，先看大小再解析。 */
        const val MAX_RECORD_LENGTH = MAX_FIELD_LENGTH * 8

        const val MAX_COOKIE_COUNT = 64
        const val MAX_COOKIE_NAME_LENGTH = 256
        const val MAX_COOKIE_VALUE_LENGTH = 2048
        const val DEFAULT_ACCOUNT_ID = "default"
        const val MAX_ACCOUNT_LENGTH = 64

        /** 读不懂的记录统一用这句话回答，内容不点名具体字段。 */
        const val UNREADABLE = "站点凭证记录无法识别"

        /** 消费端不存在「从字符串造一份凭证」的路；调用它本身就是错误。 */
        const val NOT_A_STRING = "原生侧只接受应用侧写入的凭证"

        /** 没有凭证。远程来源的准入判定用它代表「公开内容」。 */
        val NONE = SiteCredentialRecord(0, DEFAULT_ACCOUNT_ID, null, null, null, emptyMap(), null, null)

        fun of(source: String): Nothing = throw IllegalArgumentException(NOT_A_STRING)

        /**
         * 把应用侧写入的记录读成一份凭证。任何不完整都整体拒绝：半截会话比没有
         * 会话更糟，它会让原生以为「这个站点已经登录了」。
         */
        fun decode(profileId: Int, raw: String): SiteCredentialRecord {
            if (raw.length > MAX_RECORD_LENGTH) throw IllegalArgumentException(UNREADABLE)
            val root = runCatching { JSONObject(raw) }
                .getOrElse { throw IllegalArgumentException(UNREADABLE) }
            return runCatching { build(profileId, root) }
                .getOrElse { throw IllegalArgumentException(UNREADABLE) }
        }

        private fun build(profileId: Int, root: JSONObject): SiteCredentialRecord {
            val version = if (root.has("version") && !root.isNull("version")) {
                root.optString("version", "").toIntOrNull()
            } else {
                null
            } ?: throw IllegalArgumentException(UNREADABLE)
            if (version != RECORD_VERSION) throw IllegalArgumentException(UNREADABLE)
            val account = account(root) ?: DEFAULT_ACCOUNT_ID
            // Dart 侧 `jsonEncode` 把 null 原样写出：没有站点限制就是没有，不是坏
            // 记录；别的形状（数字、对象）仍然整体拒绝。
            val station = parseStation(root, "station")
            val accessToken = text(root, "accessToken")?.also { bounded(it) }
            val refreshToken = text(root, "refreshToken")?.also { bounded(it) }
            val installationStamp = text(root, "installationStamp")?.also { bounded(it) }
            val expiresAt = text(root, "expiresAt")?.also { bounded(it) }?.let { parseInstant(it) }
            val cookieNode = if (root.has("cookies") && !root.isNull("cookies")) root.get("cookies") else null
            if (cookieNode != null && cookieNode !is JSONObject) throw IllegalArgumentException(UNREADABLE)
            val cookies = LinkedHashMap<String, String>()
            val cookieObject = cookieNode as? JSONObject
            for (name in cookieObject?.keys()?.asSequence() ?: emptySequence()) {
                val cookieName = name.trim()
                if (cookieName.isEmpty() || cookieName.length > MAX_COOKIE_NAME_LENGTH) {
                    throw IllegalArgumentException(UNREADABLE)
                }
                val cookieValue = text(cookieObject, name) ?: throw IllegalArgumentException(UNREADABLE)
                if (cookieValue.length > MAX_COOKIE_VALUE_LENGTH) throw IllegalArgumentException(UNREADABLE)
                cookies[cookieName] = cookieValue
                if (cookies.size > MAX_COOKIE_COUNT) throw IllegalArgumentException(UNREADABLE)
            }
            // 令牌与 cookie 缺一不可：分片与 CDN 常只认 cookie，而清单要令牌。
            if (accessToken == null || cookies.isEmpty()) throw IllegalArgumentException(UNREADABLE)
            return SiteCredentialRecord(
                profileId = profileId,
                accountId = account,
                station = station,
                accessToken = accessToken,
                refreshToken = refreshToken,
                cookies = cookies,
                installationStamp = installationStamp,
                expiresAtEpochMs = expiresAt,
            )
        }

        private fun text(root: JSONObject, key: String): String? {
            if (!root.has(key) || root.isNull(key)) return null
            val node = root.get(key)
            // 只接受 JSON 字符串；数字、对象、数组都算坏记录。
            if (node !is String) throw IllegalArgumentException(UNREADABLE)
            return node.trim().ifEmpty { null }
        }

        /** 与 [text] 分开：账号名是一个受限标识，不是任意文本。 */
        private fun account(root: JSONObject): String? {
            val value = text(root, "account") ?: return null
            if (value.length > MAX_ACCOUNT_LENGTH) throw IllegalArgumentException(UNREADABLE)
            return value
        }

        private fun normalizeOrigin(raw: String): String? {
            val uri = runCatching { URI(raw) }.getOrNull() ?: throw IllegalArgumentException(UNREADABLE)
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: throw IllegalArgumentException(UNREADABLE)
            val host = uri.host?.lowercase(Locale.ROOT) ?: throw IllegalArgumentException(UNREADABLE)
            if (scheme != "http" && scheme != "https") throw IllegalArgumentException(UNREADABLE)
            return if (uri.port > 0) "$scheme://$host:${uri.port}" else "$scheme://$host"
        }

        /** 没有站点、或者 Dart 侧显式写出的 `null`，都表示不限定站点。 */
        private fun parseStation(root: JSONObject, key: String): String? =
            text(root, key)?.let { normalizeOrigin(it) }

        private fun bounded(value: String) {
            if (value.length > MAX_FIELD_LENGTH) throw IllegalArgumentException(UNREADABLE)
        }

        private fun parseInstant(raw: String): Long? =
            runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
                ?: throw IllegalArgumentException(UNREADABLE)
    }

    /**
     * 原生侧此刻持有的凭证，按档案分开。
     *
     * 这里是**消费端副本**：应用侧每次推送都整份替换，原生从不修改、也从不回写。
     * 读到不认识或过期的记录时原生不自行修补——它不刷新凭证（凭证刷新属于应用
     * 侧），只把这件事报给应用，由应用决定重推、续期还是要求重新登录。
     */
    class Shelf {
        private val held = LinkedHashMap<Int, SiteCredentialRecord>()

        @get:Synchronized
        val isEmpty: Boolean get() = held.isEmpty()

        @get:Synchronized
        val size: Int get() = held.size

        @Synchronized
        fun store(credential: SiteCredentialRecord) {
            // 整份替换：新记录里没有的字段（比如刷新令牌）不会从旧记录残留下来。
            held[credential.profileId] = credential
        }

        @Synchronized
        fun clear(profileId: Int) {
            held.remove(profileId)
        }

        @Synchronized
        fun get(profileId: Int, raw: String): SiteCredentialRecord? =
            held[profileId]?.takeIf { it.appliesAt(raw) }

        @get:Synchronized
        val profileIds: Set<Int> get() = held.keys.toSet()

        /** 这个档案此刻持有的那一份；不按地址过滤。 */
        @Synchronized
        fun held(profileId: Int): SiteCredentialRecord? = held[profileId]

        override fun toString(): String = "SiteCredentialRecord.Shelf(profiles=${held.size})"
    }
}
