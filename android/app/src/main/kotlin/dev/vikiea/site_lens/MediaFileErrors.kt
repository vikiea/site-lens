package dev.vikiea.site_lens

import java.io.FileNotFoundException

/** Documents providers can flatten FileNotFoundException into an argument error. */
object MediaFileErrors {
    fun code(error: Throwable): String? {
        val seen = mutableSetOf<Throwable>()
        var current: Throwable? = error
        var missing = false
        while (current != null && seen.add(current)) {
            if (current is SecurityException) return "media_permission"
            if (current is FileNotFoundException) missing = true
            if (current is IllegalArgumentException) {
                val message = current.message?.lowercase().orEmpty()
                if (message.contains("filenotfoundexception") &&
                    (message.contains("missing file") || message.contains("no such file"))) {
                    missing = true
                }
            }
            current = current.cause
        }
        return if (missing) "media_file_missing" else null
    }
}
