package dev.vikiea.site_lens

import java.util.LinkedHashMap
import org.json.JSONObject

/**
 * Process-local facts that were observed during normal media use. This class
 * never creates a player or codec and never persists media identifiers.
 * NativeMediaRuntime can feed it from its existing callbacks without changing
 * the playback contract.
 */
object NativeMediaObservations {
    private const val MAX_SESSIONS = 32
    private val lock = Any()
    private val rows = LinkedHashMap<String, CapabilityRecord>()
    private val sessions = LinkedHashMap<String, MutableSet<String>>()

    fun recordDecoder(sessionId: String, name: String, mime: String?, trackType: String) {
        val now = System.currentTimeMillis()
        val id = "media.decoder.$sessionId.$trackType"
        val details = "{\"sessionId\":${json(sessionId)},\"trackType\":${json(trackType)}}"
        val row = CapabilityRecord(
            id = id,
            state = if (name.isBlank()) CapabilityState.UNKNOWN else CapabilityState.SUPPORTED,
            observed = name.takeIf { it.isNotBlank() },
            reason = if (name.isBlank()) "解码器名称未提供" else "播放器会话实际报告的解码器",
            source = "NativeMediaObservations",
            capturedAtMs = now,
            observedAtMs = now,
            detailsJson = "${details.dropLast(1)},\"mime\":${json(mime)}}",
        )
        synchronized(lock) {
            remember(sessionId, id)
            rows[id] = row
        }
    }

    fun recordPlayback(sessionId: String, state: String) {
        val now = System.currentTimeMillis()
        val id = "media.playback.$sessionId"
        val normalized = state.trim().ifEmpty { "unknown" }
        val failed = normalized.equals("error", ignoreCase = true) ||
            normalized.equals("failed", ignoreCase = true)
        val row = CapabilityRecord(
            id = id,
            state = if (failed) CapabilityState.ERROR else CapabilityState.SUPPORTED,
            observed = normalized,
            reason = "播放器会话实际状态",
            source = "NativeMediaObservations",
            capturedAtMs = now,
            observedAtMs = now,
            detailsJson = "{\"sessionId\":${json(sessionId)}}",
        )
        synchronized(lock) {
            remember(sessionId, id)
            rows[id] = row
        }
    }

    fun snapshot(): List<CapabilityRecord> = synchronized(lock) { rows.values.toList() }

    private fun json(value: String?): String =
        value?.let(JSONObject::quote) ?: "null"

    private fun remember(sessionId: String, rowId: String) {
        val rowIds = sessions.remove(sessionId) ?: linkedSetOf()
        rowIds += rowId
        sessions[sessionId] = rowIds
        while (sessions.size > MAX_SESSIONS) {
            val oldest = sessions.entries.first()
            oldest.value.forEach(rows::remove)
            sessions.remove(oldest.key)
        }
    }
}
