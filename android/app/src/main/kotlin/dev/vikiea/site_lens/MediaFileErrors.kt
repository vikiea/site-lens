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
            val message = current.message?.lowercase().orEmpty()
            if (message.contains("权限已失效") ||
                message.contains("permission") ||
                message.contains("not granted") ||
                message.contains("permission denied")) {
                return "media_permission"
            }
            if (message.contains("媒体文件过大")) return "media_file_too_large"
            if (message.contains("媒体文件为空")) return "media_file_empty"
            if (message.contains("媒体检查超时")) return "media_inspection_timeout"
            if (current is IllegalArgumentException) {
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
