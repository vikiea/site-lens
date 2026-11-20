package dev.vikiea.site_lens

import java.net.URI
import java.security.MessageDigest

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
 * - **logical identity**: the task-level resource identity a queued request
 *   carries, supplied by the caller.
 * - **capture owner**: a capture belongs to the page load that asked for it,
 *   not to a task. The service records the load's page URL with the capture;
 *   [assignCapture] decides which queued request, if any, owns the captured
 *   address.
 */
internal object MediaAuthRefreshPolicy {
    /**
     * A main playlist captured from the page a refresh actually loaded.
     *
     * A capture is the page's own request, so it is attributed by the page that
     * made it ([pageUrl]) and never by a task identity: the page load is shared
     * by every task on that page, and no task can be named in advance. The
     * owner is decided by [assignCapture] from the address itself.
     */
    data class CapturedPlaylist(val url: String, val pageUrl: String)

    /** A queued refresh, and the identities used to route a capture to it. */
    data class RefreshRequestIdentity(
        val taskId: String,
        val logicalIdentity: String,
        val pageUrl: String,
        val mediaUrl: String,
    )

    /**
     * What one queued task is owed by the batch it joined.
     *
     * [state] uses the same three-state vocabulary as [RefreshOutcome], spelled
     * the way the platform channel spells it: `refreshed`, `unchanged`,
     * `reauthorize`. [mediaUrl] is present only for `refreshed`.
     */
    data class RequestOutcome(val state: String, val reason: String?, val mediaUrl: String?)

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

    /**
     * Second-level labels that are themselves suffixes, so `co.uk` is never
     * treated as one site. Not a full Public Suffix List: it only has to keep
     * the site rule from collapsing unrelated hosts, and anything unlisted
     * still needs three labels to match a sibling.
     */
    private val PUBLIC_SUFFIXES = setOf(
        "co.uk",
        "org.uk",
        "ac.uk",
        "gov.uk",
        "com.cn",
        "net.cn",
        "org.cn",
        "gov.cn",
        "com.au",
        "net.au",
        "org.au",
        "co.jp",
        "or.jp",
        "ne.jp",
        "com.br",
        "com.mx",
        "co.in",
        "co.kr",
        "co.za",
        "co.nz",
        "com.tw",
        "com.hk",
        "com.sg",
    )

    /** Channel spelling of [RefreshOutcome.Refreshed]. */
    const val STATE_REFRESHED = "refreshed"

    /** Channel spelling of [RefreshOutcome.Unchanged]. */
    const val STATE_UNCHANGED = "unchanged"

    /** Channel spelling of [RefreshOutcome.PageRequired]. */
    const val STATE_REAUTHORIZE = "reauthorize"

    /** The system did not allow the background refresh to run at all. */
    const val STATE_WAITING_EXECUTION = "waiting_execution"

    /**
     * Query keys that only select a presentation of the same resource. Any
     * other key may be a signature or an expiry, which is why presence of one
     * is reported as a diagnostic instead of blocking the page load.
     */
    private val PRESENTATION_QUERY_KEYS = setOf(
        "quality",
        "audio",
        "format",
        "type",
        "profile",
        "resolution",
        "codec",
        "lang",
        "language",
        "track",
        "channel",
        "bitrate",
        "width",
        "height",
        "fps",
        "variant",
        "version",
        "v",
        "source",
        "episode",
        "season",
        "start",
        "offset",
        "range",
        "download",
        "filename",
        "container",
    )

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
     * True when [candidateUrl] is served from the same site as [pageOrigin].
     *
     * The rule is the one the specification states — a capture must share the
     * session's *site domain* — and not scheme/port equality: pages routinely
     * serve their manifest from `https://cdn.example/...`, so requiring an
     * identical origin would make every CDN-hosted playlist uncapturable.
     *
     * Matching is therefore on the host only:
     * - an identical host (case-insensitive) always matches, whatever the
     *   scheme and port;
     * - a sibling host of the same registrable site matches only when both
     *   hosts are plainly multi-label (`www.site.example` / `cdn.site.example`);
     * - single-label hosts (`example`, `localhost`) match only exactly, so two
     *   unrelated intranet names never collapse into one site;
     * - a public suffix (`example`, `co.uk`) is a site label, not a site.
     *
     * A URL without a scheme, without a host, or with embedded credentials never
     * matches: an address that carries its own credentials is not something the
     * page handed over in the session.
     */
    fun isSameSessionOrigin(pageOrigin: String, candidateUrl: String): Boolean {
        val page = originOf(pageOrigin) ?: return false
        val candidate = originOf(candidateUrl) ?: return false
        if (page == candidate) return true
        val pageHost = hostOf(page) ?: return false
        val candidateHost = hostOf(candidate) ?: return false
        if (pageHost == candidateHost) return true
        val pageSite = registrableSite(pageHost) ?: return false
        return pageSite == registrableSite(candidateHost)
    }

    /**
     * The two-label site a host belongs to, or `null` when the host cannot name
     * one on its own (`localhost`, a bare intranet name, or a public suffix).
     */
    private fun registrableSite(host: String): String? {
        val parts = host.split('.')
        val labels = ArrayList<String>(parts.size)
        for (part in parts) {
            if (part.isNotEmpty()) labels.add(part)
        }
        // A two-label host under no public suffix (`site.example`) is a
        // registrable site in its own right; `cdn.example` is a different
        // site, not a sibling of it.
        if (labels.size < 2) return null
        val suffix = labels[labels.size - 2] + "." + labels[labels.size - 1]
        // A public suffix (`co.uk`) is never a site by itself, and a host that
        // is only a suffix names no site at all.
        if (suffix in PUBLIC_SUFFIXES) {
            if (labels.size < 3) return null
            return labels[labels.size - 3] + "." + suffix
        }
        return suffix
    }

    /**
     * The host part of a normalized origin, without the port.
     *
     * [originOf] always appends the effective port, so the authority has to be
     * split from the right; taking everything before the first colon would
     * truncate an IPv6 literal.
     */
    private fun hostOf(origin: String): String? {
        val afterScheme = origin.substringAfter("://", "")
        if (afterScheme.isEmpty()) return null
        return afterScheme.substringBeforeLast(':').ifEmpty { null }
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
     * Hand each capture to the request whose own media address it replaces.
     *
     * A capture is the page's request, so it cannot name the task it belongs
     * to; the address is the only thing both sides know. Ownership is decided
     * without any trust in a caller-supplied probe:
     * - a capture is dropped unless its address is a main playlist on the
     *   capture's own site ([isSameSessionOrigin]);
     * - the owning request must have been asked for that page
     *   ([isSameSessionOrigin] against the request's page) and must describe the
     *   same resource: the same scheme, host, port and path, with the query
     *   treated as the part a refresh replaces ([sameMediaAddress]);
     * - when several requests claim one address, the tie is broken only by the
     *   resource identity both sides can derive from the address itself — never
     *   by a caller-supplied probe string;
     * - one address never serves two tasks, and a request is answered at most
     *   once.
     * A capture no request owns is left unassigned, and so is a request with no
     * capture: no task ever inherits another task's address.
     */
    fun assignCapture(
        captured: List<CapturedPlaylist>,
        requests: List<RefreshRequestIdentity>,
    ): Map<String, String> {
        val assignment = LinkedHashMap<String, String>()
        val claimed = HashSet<String>()
        for (capture in captured) {
            val url = capture.url.trim()
            if (url.isEmpty() || !claimed.add(url)) continue
            if (!isMainPlaylist(url, null)) continue
            if (!isSameSessionOrigin(capture.pageUrl, url)) continue
            val owners = requests.filter { request ->
                request.taskId !in assignment &&
                    isSameSessionOrigin(request.pageUrl, url) &&
                    sameMediaAddress(request.mediaUrl, url)
            }
            if (owners.isEmpty()) continue
            // One address belongs to one task. When only one request claims it
            // that request is the owner; when several do, the tie is broken
            // only by the task's own recognized media identity, never by a
            // caller-supplied probe string.
            val owner = owners.singleOrNull() ?: owners.firstOrNull { request ->
                request.logicalIdentity.isNotBlank() &&
                    logicalIdentityOf(request.mediaUrl) == logicalIdentityOf(url)
            } ?: continue
            assignment[owner.taskId] = url
        }
        return assignment
    }

    /**
     * True when the captured [url] is a refreshed spelling of [mediaUrl].
     *
     * The query is part of the identity: a playlist address usually carries a
     * signature or an expiry, and that is exactly what a refresh replaces. So
     * equality is on scheme, host, port and path; the query only has to agree
     * on the keys it keeps, and the fresh signature is adopted from the
     * capture. Anything else (a different path, a different host) is another
     * resource and never replaces the request's own address.
     */
    internal fun sameMediaAddress(mediaUrl: String, url: String): Boolean {
        val left = runCatching { URI(mediaUrl.trim()) }.getOrNull() ?: return false
        val right = runCatching { URI(url.trim()) }.getOrNull() ?: return false
        if (!left.scheme.equals(right.scheme, ignoreCase = true)) return false
        if (!left.host.equals(right.host, ignoreCase = true)) return false
        if (effectivePort(left) != effectivePort(right)) return false
        return left.rawPath.orEmpty() == right.rawPath.orEmpty()
    }

    private fun logicalIdentityOf(url: String): String {
        val uri = runCatching { URI(url.trim()) }.getOrNull() ?: return url.trim()
        return buildString {
            append(uri.scheme?.lowercase().orEmpty())
            append("://")
            append(uri.host?.lowercase().orEmpty())
            append(':')
            append(effectivePort(uri))
            append(uri.rawPath.orEmpty())
        }
    }

    private fun effectivePort(uri: URI): Int {
        val port = uri.port
        if (port != -1) return port
        return when (uri.scheme?.lowercase()) {
            "http" -> 80
            "https" -> 443
            else -> -1
        }
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

    /**
     * True when [url] carries a query key that is not a presentation key.
     *
     * A signed address is only *classified* by this: the refresh still loads
     * the page, and the answer is attached afterwards as a diagnostic.
     */
    fun hasUnknownQuery(url: String): Boolean {
        if (url.isBlank()) return false
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        val raw = uri.rawQuery ?: return false
        return raw.split('&').any { pair ->
            val key = pair.substringBefore('=').trim()
            key.isNotEmpty() && key.lowercase() !in PRESENTATION_QUERY_KEYS
        }
    }

    /**
     * A log-safe stand-in for a captured address: scheme, host, and a hash of
     * the path. It never contains the query, the path, or credentials, so two
     * signed spellings of one playlist produce the same digest.
     */
    fun captureDigest(url: String): String? {
        val uri = runCatching { URI(url.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        if (uri.rawUserInfo != null) return null
        if (scheme.isEmpty() || host.isEmpty()) return null
        val pathHash = MessageDigest.getInstance("SHA-256")
            .digest(uri.rawPath.orEmpty().toByteArray(Charsets.UTF_8))
            .take(8)
            .joinToString("") { byte -> "%02x".format(byte) }
        return "$scheme://$host/$pathHash"
    }

    /**
     * Close out a batch that will capture nothing further.
     *
     * A capture goes only to the request whose logical identity matches; every
     * other request settles on [Unchanged] when the page's cookies changed and
     * on [PageRequired] otherwise. No task ever inherits another task's URL.
     */
    fun finishBatch(
        requests: List<RefreshRequestIdentity>,
        captured: List<CapturedPlaylist>,
        cookieChanged: Boolean,
    ): Map<String, RequestOutcome> {
        val assigned = assignCapture(captured, requests)
        return requests.associate { request ->
            val url = assigned[request.taskId]
            request.taskId to if (!url.isNullOrBlank()) {
                RequestOutcome(STATE_REFRESHED, null, url)
            } else if (cookieChanged) {
                RequestOutcome(STATE_UNCHANGED, STATE_UNCHANGED, null)
            } else {
                RequestOutcome(STATE_REAUTHORIZE, PAGE_REQUIRED_REASON, null)
            }
        }
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
