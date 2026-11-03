package dev.vikiea.site_lens

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Short-lived native-only media request headers observed by WebView.
 *
 * Cookies and proxy credentials are intentionally excluded. The registry is
 * keyed by the current host/document generation and is cleared on navigation,
 * host destruction, or expiry so a later page cannot inherit authorization.
 */
object MediaRequestContextRegistry {
    data class Context(
        val id: String,
        val hostId: Long,
        val generation: Long,
        val sourceUrl: String,
        val mediaUrl: String,
        val headers: Map<String, String>,
        val expiresAtMs: Long,
    )

    private const val TTL_MS = 45_000L
    private val values = ConcurrentHashMap<String, Context>()

    fun record(
        hostId: Long,
        generation: Long,
        sourceUrl: String,
        mediaUrl: String,
        rawHeaders: Map<String, String>,
    ): Context? {
        val headers = rawHeaders.entries.mapNotNull { (name, value) ->
            val key = name.trim().lowercase()
            val text = value.trim()
            if (text.isEmpty() || text.length > 4096) return@mapNotNull null
            if (key == "authorization" || key.startsWith("x-cdn-")) key to text else null
        }.toMap()
        if (headers.isEmpty()) return null
        val context = Context(
            id = "mrc_" + UUID.randomUUID().toString().replace("-", ""),
            hostId = hostId,
            generation = generation,
            sourceUrl = sourceUrl,
            mediaUrl = mediaUrl,
            headers = headers,
            expiresAtMs = System.currentTimeMillis() + TTL_MS,
        )
        values[context.id] = context
        prune()
        return context
    }

    fun get(id: String?): Context? {
        if (id.isNullOrBlank()) return null
        val value = values[id] ?: return null
        if (value.expiresAtMs < System.currentTimeMillis()) {
            values.remove(id, value)
            return null
        }
        return value
    }

    fun latest(mediaUrl: String, sourceUrl: String): Context? {
        val now = System.currentTimeMillis()
        return values.values.asSequence()
            .filter { it.expiresAtMs >= now && it.mediaUrl == mediaUrl && it.sourceUrl == sourceUrl }
            .maxByOrNull { it.expiresAtMs }
    }

    fun clearHost(hostId: Long) {
        values.entries.removeIf { it.value.hostId == hostId }
    }

    fun clearGeneration(hostId: Long, generation: Long) {
        values.entries.removeIf { it.value.hostId == hostId && it.value.generation == generation }
    }

    private fun prune() {
        val now = System.currentTimeMillis()
        values.entries.removeIf { it.value.expiresAtMs < now }
        while (values.size > 256) values.remove(values.keys.firstOrNull() ?: return)
    }
}
