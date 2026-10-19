package dev.vikiea.site_lens

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter

/** Small append-only handoff from Android fatal paths to the next Dart start. */
object NativeCrashStore {
    private const val FILE_NAME = "site_lens_native_errors.jsonl"
    private const val MAX_BYTES = 512 * 1024L

    @Synchronized
    fun append(
        context: Context,
        module: String,
        message: String,
        details: String,
        contextValue: String? = null,
    ) {
        try {
            val file = File(context.filesDir, FILE_NAME)
            if (file.length() > MAX_BYTES) file.delete()
            val row = JSONObject()
                .put("level", "fatal")
                .put("module", module.take(80))
                .put("message", redact(message).take(240))
                .put("details", redact(details).take(16_000))
            if (contextValue != null) row.put("context", redact(contextValue).take(300))
            FileOutputStream(file, true).use { output ->
                OutputStreamWriter(output, Charsets.UTF_8).use { writer ->
                    writer.append(row.toString()).append('\n')
                    writer.flush()
                }
                runCatching { output.fd.sync() }
            }
        } catch (_: Throwable) {
            // A fatal-path logger must never recurse into the fatal path.
        }
    }

    private fun redact(value: String): String {
        var result = value.replace(Regex("https?://[^\\s,)]+", RegexOption.IGNORE_CASE)) { match ->
            runCatching {
                val uri = android.net.Uri.parse(match.value)
                "${uri.scheme}://${uri.host ?: "[网址已隐藏]"}${uri.path ?: "/"}"
            }.getOrDefault("[网址已隐藏]")
        }
        result = result.replace(
            Regex("(auth[_-]?key|token|access[_-]?token|password|cookie|signature)=([^\\s&,)]*)", RegexOption.IGNORE_CASE),
            "$1=[已隐藏]",
        )
        return result
    }

    @Synchronized
    fun drain(context: Context): List<String> {
        val file = File(context.filesDir, FILE_NAME)
        if (!file.isFile) return emptyList()
        return try {
            val rows = file.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
            file.delete()
            rows
        } catch (_: Throwable) {
            emptyList()
        }
    }
}

class SiteLensApplication : android.app.Application() {
    override fun onCreate() {
        super.onCreate()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            NativeCrashStore.append(
                this,
                module = "android.uncaught",
                message = error.message ?: error.javaClass.simpleName,
                details = buildString {
                    append("线程：").append(thread.name).append('\n')
                    append(error.stackTraceToString())
                },
            )
            previous?.uncaughtException(thread, error)
        }
    }
}
