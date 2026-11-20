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

    /**
     * What one queued task is owed by the batch it joined.
     *
     * [state] uses the same three-state vocabulary as [RefreshOutcome], spelled
     * the way the platform channel spells it: `refreshed`, `unchanged`,
     * `reauthorize`. [mediaUrl] is present only for `refreshed`.
     */
    data class RequestOutcome(val state: String, val reason: String?, val mediaUrl: String?)

    /**
     * One page origin and every queued task it serves. A slot is filled by the
     * first capture whose origin matches, so a page load can answer all of the
     * slot's tasks that share the captured logical identity.
     */
    data class CaptureSlot(
        val origin: String,
        val requests: List<RefreshRequestIdentity>,
        val captured: List<CapturedPlaylist> = emptyList(),
    )

    /** Slots for one batch, in first-seen origin order. */
    data class CapturePlan(val slots: List<CaptureSlot>) {
        /**
         * Slots still able to answer: those that already hold a capture (to
         * hand it to the rest of their tasks) as well as those whose page is
         * still loading. A closed slot is absent from the plan.
         */
        val freeSlots: Int
            get() = slots.size

        /** The slot a capture at [capturedUrl] belongs to, if any. */
        fun slotFor(capturedUrl: String): Int? {
            val capture = originOf(capturedUrl) ?: return null
            val index = slots.indexOfFirst { slot -> slot.origin == capture }
            return if (index < 0) null else index
        }
    }

    /** One slot plus what has already been adopted from it. */
    data class CaptureSlotState(
        val slot: CaptureSlot,
        val captured: List<CapturedPlaylist> = emptyList(),
    )

    /** Progress of one batch page load. */
    data class PlanProgress(
        val assignments: Map<String, String>,
        val captured: List<CapturedPlaylist> = emptyList(),
        val settledOrigins: Set<String> = emptySet(),
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
     * Batch layout for [requests]: one capture slot per page origin. A slot
     * still holds its captures after adoption, which is what lets a second
     * capture on the same page answer the slot's remaining tasks without
     * repeating the load. A task already in [PlanProgress.assignments] is
     * dropped, so one task is answered exactly once.
     */
    fun capturePlan(
        requests: List<RefreshRequestIdentity>,
        progress: PlanProgress? = null,
    ): CapturePlan {
        val assigned = progress?.assignments.orEmpty()
        val captured = progress?.captured.orEmpty()
        val settled = progress?.settledOrigins.orEmpty().map(::originOf)
        val pending = requests.filter { it.taskId !in assigned }
        val slots = ArrayList<CaptureSlot>()
        for (group in groupByOrigin(pending)) {
            val origin = originOf(group.first().pageUrl) ?: continue
            // [PlanProgress.settledOrigins] accepts a page URL or an origin.
            if (settled.contains(origin)) continue
            slots.add(
                CaptureSlot(
                    origin = origin,
                    requests = group,
                    captured = captured.filter { item -> originOf(item.url) == origin },
                ),
            )
        }
        return CapturePlan(slots)
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

    /**
     * The identity one page load is asked with.
     *
     * A refresh load can only answer *this* origin, not one task's address, so
     * the identity it records has to be recognisable and deliberately unable to
     * match a task: [finishBatch] then decides which request, if any, the
     * capture belongs to. Harmless for a single task, whose own load still
     * answers through [classify].
     */
    fun captureProbeIdentity(requests: List<RefreshRequestIdentity>): String {
        val origin = requests.firstNotNullOfOrNull { originOf(it.pageUrl) } ?: "origin-unknown"
        val oldest = requests.minOfOrNull { it.taskId }.orEmpty()
        return "probe:$origin:$oldest"
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
