package dev.vikiea.site_lens

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

internal data class NativeUpdateContentRange(
    val start: Long,
    val end: Long,
    val total: Long,
)

internal object NativeUpdatePolicy {
    const val MAX_APK_BYTES = 512L * 1024L * 1024L
    const val MAX_REDIRECTS = 5
    val RETRY_DELAYS_MS = longArrayOf(2_000L, 5_000L, 10_000L)

    private val trustedHosts = setOf(
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
    )
    private val tagPattern = Regex("^v(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)(?:\\.(?:alpha|beta|rc)(?:0|[1-9]\\d*))?$")
    private val apkPattern = Regex("^site-lens-v(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)(?:\\.(?:alpha|beta|rc)(?:0|[1-9]\\d*))?\\.apk$")
    private val contentRangePattern = Regex("^bytes\\s+(\\d+)-(\\d+)/(\\d+)$")

    fun initialUrl(raw: String, tagName: String, apkName: String): HttpUrl {
        require(tagPattern.matches(tagName)) { "更新标签格式错误" }
        require(apkPattern.matches(apkName)) { "更新文件名格式错误" }
        val url = trustedUrl(raw)
        require(url.host == "github.com") { "更新地址必须从 GitHub 发布地址开始" }
        require(url.querySize == 0 && url.fragment == null) { "GitHub 发布地址不能携带查询参数" }
        require(url.encodedPath == "/vikiea/site-lens/releases/download/$tagName/$apkName") {
            "更新地址不是 Site Lens 发布包"
        }
        return url
    }

    fun redirectUrl(raw: String): HttpUrl = trustedUrl(raw)

    fun isValidTagName(tagName: String): Boolean = tagPattern.matches(tagName)

    fun parseContentRange(raw: String?): NativeUpdateContentRange? {
        val match = contentRangePattern.matchEntire(raw?.trim() ?: "") ?: return null
        val start = match.groupValues[1].toLongOrNull() ?: return null
        val end = match.groupValues[2].toLongOrNull() ?: return null
        val total = match.groupValues[3].toLongOrNull() ?: return null
        if (end < start || total <= end) return null
        return NativeUpdateContentRange(start, end, total)
    }

    private fun trustedUrl(raw: String): HttpUrl {
        val url = runCatching { raw.toHttpUrl() }.getOrElse {
            throw IllegalArgumentException("更新地址无效")
        }
        require(url.scheme == "https") { "更新地址必须使用 HTTPS" }
        require(url.username.isEmpty() && url.password.isEmpty()) { "更新地址不能携带凭据" }
        require(url.port == 443) { "更新地址端口无效" }
        require(url.host in trustedHosts) { "更新地址不属于 GitHub 发布服务" }
        require(url.fragment == null) { "更新地址不能携带片段" }
        if (url.host == "github.com") {
            require(url.querySize == 0) { "GitHub 地址不能携带查询参数" }
        }
        return url
    }
}
