package dev.vikiea.site_lens

import java.io.Closeable
import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.util.Locale

/** Native playback readers and file mutations share one process-wide fence. */
internal class MediaFileLeaseRegistry {
    data class Scope(
        val taskIds: Set<String> = emptySet(),
        val paths: Set<String> = emptySet(),
        val documents: Set<String> = emptySet(),
    ) {
        operator fun plus(other: Scope) = Scope(
            taskIds + other.taskIds, paths + other.paths, documents + other.documents,
        )

        fun overlaps(other: Scope): Boolean =
            taskIds.any { it in other.taskIds } || documents.any { it in other.documents } ||
                paths.any { left -> other.paths.any { right ->
                    left == right || left.startsWith(right + File.separator) ||
                        right.startsWith(left + File.separator)
                } }

        companion object {
            fun task(id: String) = Scope(taskIds = setOf(id))
            fun file(file: File) = Scope(paths = setOf(file.canonicalPath))
            fun source(raw: String): Scope {
                if (!raw.matches(Regex("^[A-Za-z][A-Za-z0-9+.-]*:.*", RegexOption.DOT_MATCHES_ALL))) {
                    return file(File(raw))
                }
                val uri = URI(raw)
                return when (uri.scheme?.lowercase()) {
                    null -> file(File(raw))
                    "file" -> file(File(uri))
                    "content" -> {
                        require(!uri.rawAuthority.isNullOrBlank() && uri.rawUserInfo == null) { "媒体文件地址无效" }
                        // SAF direct and tree-scoped URIs name the same document.
                        // Decode path segments exactly once, preserving literal +.
                        // The structure is fixed by DocumentsContract:
                        // /document/<id> or /tree/<tree-id>/document/<id>.
                        val parts = uri.rawPath.orEmpty()
                            .split('/')
                            .filter { it.isNotEmpty() }
                            .map { decodePathSegment(it) }
                        val documentId = when {
                            parts.size == 2 && parts[0] == "document" -> parts[1]
                            parts.size == 4 && parts[0] == "tree" && parts[2] == "document" -> parts[3]
                            else -> null
                        }
                        val identity = if (documentId != null) {
                            require(documentId.isNotEmpty()) { "媒体文档身份无效" }
                            "${uri.rawAuthority.lowercase(Locale.ROOT)}\u0000$documentId"
                        } else {
                            // Non-SAF providers retain their path identity. Arbitrary
                            // provider-specific aliases cannot be inferred here.
                            URI("content", uri.rawAuthority.lowercase(Locale.ROOT), uri.path, null, null).toString()
                        }
                        Scope(documents = setOf(identity))
                    }
                    else -> throw IllegalArgumentException("仅允许本地媒体文件")
                }
            }

        private fun decodePathSegment(raw: String): String =
            URLDecoder.decode(raw.replace("+", "%2B"), "UTF-8")
        }
    }

    private val monitor = Any()
    private val readers = mutableMapOf<Any, Scope>()
    private val mutations = mutableMapOf<Any, Scope>()

    fun acquireRead(scope: Scope): Closeable = synchronized(monitor) {
        check(mutations.values.none(scope::overlaps)) { "媒体文件正在变更，请稍后重试" }
        register(readers, scope)
    }

    fun acquireMutation(scope: Scope): Closeable = synchronized(monitor) {
        check(readers.values.none(scope::overlaps)) { "媒体正在播放，请先停止" }
        check(mutations.values.none(scope::overlaps)) { "媒体文件正在变更，请稍后重试" }
        register(mutations, scope)
    }

    private fun register(entries: MutableMap<Any, Scope>, scope: Scope): Closeable {
        val token = Any()
        entries[token] = scope
        return Closeable { synchronized(monitor) { entries.remove(token) } }
    }

    fun <T> mutate(scope: Scope, action: () -> T): T = acquireMutation(scope).use { action() }
}

internal object NativeMediaFileLeases {
    val registry = MediaFileLeaseRegistry()
}
