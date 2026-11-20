package dev.vikiea.site_lens

import java.net.URI

/**
 * Pure decision logic for the background media authorization refresh.
 *
 * The service decides *when* to load a page; this object decides *what* the
 * page's requests mean. It has no Android dependency on purpose (no `Uri`, no
 * `WebView`, no `Context`, no `SystemClock`) so it can be covered by a plain
 * JVM test instead of a device.
 *
 * Terms:
 * - **main playlist**: the HLS (`.m3u8` / `.m3u`, or an `mpegurl` Accept type)
 *   or DASH (`.mpd`, or a `dash+xml` Accept type) manifest the page itself
 *   loads. Only that address can replace a media address.
 * - **transport artefact**: segments, init segments and concrete media files.
 *   They are real media requests but never the address a task is bound to.
 * - **logical identity**: the task-level resource identity the capture and the
 *   queued requests are matched on, supplied by the caller.
 */
internal object MediaAuthRefreshPolicy {
    /** A media request captured from the page a refresh actually loaded. */
    data class CapturedPlaylist(val url: String, val logicalIdentity: String)

    /** A queued refresh, and the identities used to route a capture to it. */
    data class RefreshRequestIdentity(
        val taskId: String,
        val logicalIdentity: String,
        val pageUrl: String,
        val mediaUrl: String,
    )

    /** Three-state result of one refresh page load. */
    sealed class RefreshOutcome {
        /** The page requested a main playlist for this task. */
        data class Refreshed(val mediaUrl: String) : RefreshOutcome()

        /** A cookie change was observed but no address was captured. */
        object Unchanged : RefreshOutcome()

        /** The page settled without an address and without a cookie change. */
        data class PageRequired(val reason: String) : RefreshOutcome()
    }

    const val PAGE_REQUIRED_REASON = "页面加载完成但没有捕获到主清单地址"

    private val MANIFEST_PATH = Regex("\\.(?:m3u8|m3u|mpd)(?:$|/)", RegexOption.IGNORE_CASE)
    private val TRANSPORT_PATH = Regex(
        "\\.(?:ts|m4s|mp4|m4a|aac|mp3|ogg|wav|webm|mov|mkv|m4v|mp2t)(?:$|/)",
        RegexOption.IGNORE_CASE,
    )
    private val INIT_SEGMENT = Regex("(?:^|/)init(?:[-_.][a-z0-9]+)?(?:$|\\.|/|\\?)", RegexOption.IGNORE_CASE)

    /**
     * True when [url] with [acceptHeader] is the page's own main playlist.
     *
     * Transport artefacts win over the Accept header: a `.ts` segment fetched
     * with a media Accept type is still a segment, not a manifest.
     */
    fun isMainPlaylist(url: String, acceptHeader: String?): Boolean {
        if (url.isBlank()) return false
        val path = runCatching { URI(url).rawPath }.getOrNull().orEmpty()
        if (TRANSPORT_PATH.containsMatchIn(path) || INIT_SEGMENT.containsMatchIn(path)) return false
        if (MANIFEST_PATH.containsMatchIn(path)) return true
        return acceptHeader.orEmpty()
            .split(',')
            .map { it.substringBefore(';').trim().lowercase() }
            .any { it.contains("mpegurl") || it.contains("dash+xml") }
    }

    /**
     * True when [candidateUrl] shares scheme, host and effective port with
     * [pageOrigin]. Scheme and host are compared case-insensitively and the
     * default port is elided. A URL without a scheme, without a host, or with
     * embedded credentials never matches.
     */
    fun isSameSessionOrigin(pageOrigin: String, candidateUrl: String): Boolean {
        val page = originOf(pageOrigin) ?: return false
        val candidate = originOf(candidateUrl) ?: return false
        return page == candidate
    }

    /**
     * The three-state outcome of one page load.
     *
     * Returns `null` while the refresh is still pending: the page has not
     * settled yet and no acceptable capture has appeared, so the caller keeps
     * waiting instead of reporting a verdict.
     */
    fun classify(
        capturedUrl: String?,
        acceptHeader: String?,
        pageOrigin: String,
        cookieChanged: Boolean,
        pageSettled: Boolean,
    ): RefreshOutcome? {
        if (!capturedUrl.isNullOrBlank() &&
            isMainPlaylist(capturedUrl, acceptHeader) &&
            isSameSessionOrigin(pageOrigin, capturedUrl)
        ) {
            return RefreshOutcome.Refreshed(capturedUrl)
        }
        if (!pageSettled) return null
        return if (cookieChanged) {
            RefreshOutcome.Unchanged
        } else {
            RefreshOutcome.PageRequired(PAGE_REQUIRED_REASON)
        }
    }

    /**
     * Hand each capture to the first still-unassigned request whose logical
     * identity matches and whose page origin matches the capture origin.
     * Captures are consumed in order, so one address never serves two tasks.
     * A request without a match is absent from the result.
     */
    fun assignCapture(
        captured: List<CapturedPlaylist>,
        requests: List<RefreshRequestIdentity>,
    ): Map<String, String> {
        val remaining = captured.toMutableList()
        val assignment = LinkedHashMap<String, String>()
        for (request in requests) {
            val identity = request.logicalIdentity.trim()
            if (identity.isEmpty()) continue
            if (request.taskId in assignment) continue
            val pageOrigin = originOf(request.pageUrl) ?: continue
            val index = remaining.indexOfFirst { candidate ->
                candidate.logicalIdentity.trim().equals(identity, ignoreCase = true) &&
                    originOf(candidate.url) == pageOrigin
            }
            if (index < 0) continue
            assignment[request.taskId] = remaining.removeAt(index).url
        }
        return assignment
    }

    /**
     * Group requests that share one page origin, so a batch needs one service
     * lifetime and one page load per origin. First-seen order is preserved.
     */
    fun groupByOrigin(requests: List<RefreshRequestIdentity>): List<List<RefreshRequestIdentity>> {
        val groups = LinkedHashMap<String, MutableList<RefreshRequestIdentity>>()
        for (request in requests) {
            val origin = originOf(request.pageUrl) ?: continue
            groups.getOrPut(origin) { mutableListOf() }.add(request)
        }
        return groups.values.toList()
    }

    /** Distinct page URLs in navigation order; the page loads once per URL. */
    fun distinctPageUrls(requests: List<RefreshRequestIdentity>): List<String> {
        val seen = HashSet<String>()
        return requests.map { it.pageUrl.trim() }
            .filter { it.isNotEmpty() && seen.add(navigationKey(it)) }
    }

    /**
     * Two spellings of one navigation share a key when they agree on origin,
     * path and query; the fragment is dropped because it never reaches the
     * server. Host case and default ports are already normalized by [originOf].
     */
    private fun navigationKey(url: String): String {
        val origin = originOf(url) ?: return url
        val uri = runCatching { URI(url) }.getOrNull() ?: return url
        val path = uri.rawPath.orEmpty()
        val query = uri.rawQuery?.let { "?$it" }.orEmpty()
        return "$origin$path$query"
    }

    private fun originOf(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        if (uri.rawUserInfo != null) return null
        val port = uri.port
        if (port < -1 || port > 65535) return null
        val effectivePort = if (port == -1) defaultPort(scheme) ?: return null else port
        return "$scheme://$host:$effectivePort"
    }

    private fun defaultPort(scheme: String): Int? = when (scheme) {
        "http" -> 80
        "https" -> 443
        else -> null
    }
}
