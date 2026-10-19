package dev.vikiea.site_lens

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Small append-only handoff from Android fatal paths to the next Dart start. */
object NativeCrashStore {
    private const val FILE_NAME = "site_lens_native_errors.jsonl"
    private const val MAX_BYTES = 512 * 1024L
    private const val MAX_EXIT_HISTORY = 16
    private const val MAX_TRACE_BYTES = 1024 * 1024
    private const val EXIT_TRACE_DIR = "site_lens_exit_traces"
    private val historyLock = Any()

    @Synchronized
    fun append(
        context: Context,
        module: String,
        message: String,
        details: String,
        contextValue: String? = null,
    ) {
        appendRow(context, module, message, details, contextValue)
    }

    @Synchronized
    private fun appendRow(
        context: Context,
        module: String,
        message: String,
        details: String,
        contextValue: String?,
    ): Boolean {
        try {
            val file = File(context.filesDir, FILE_NAME)
            if (file.length() > MAX_BYTES) file.delete()
            val row = JSONObject()
                .put("reportId", if (module == "android.process_exit") contextValue else java.util.UUID.randomUUID().toString())
                .put("level", "fatal")
                .put("module", module.take(80))
                .put("message", redact(message).take(240))
                .put("details", redact(details).take(16_000))
            if (contextValue != null) row.put("context", redact(contextValue).take(300))
            FileOutputStream(file, true).use { output ->
                output.write((row.toString() + "\n").toByteArray(Charsets.UTF_8))
                output.flush()
                output.fd.sync()
            }
            return true
        } catch (_: Throwable) {
            // A fatal-path logger must never recurse into the fatal path.
            return false
        }
    }

    /** Run on the diagnostics background task queue, never the Android UI thread. */
    fun drainIncludingHistoricalExits(context: Context): List<String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { synchronized(historyLock) { captureHistoricalExits(context) } }
        }
        return drain(context)
    }

    @android.annotation.TargetApi(30)
    private fun captureHistoricalExits(context: Context) {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return
        val history = manager.getHistoricalProcessExitReasons(context.packageName, 0, MAX_EXIT_HISTORY)
        val preferences = context.getSharedPreferences("site_lens_exit_history", Context.MODE_PRIVATE)
        val seen = preferences.getStringSet("recorded", emptySet())!!.toMutableSet()
        val currentKeys = mutableSetOf<String>()
        for (exit in history) {
            val key = listOf(exit.timestamp, exit.pid, exit.processName, exit.reason, exit.status).joinToString(":")
            currentKeys.add(key)
            if (key in seen) continue
            val reason = when (exit.reason) {
                ApplicationExitInfo.REASON_CRASH -> "CRASH"
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
                ApplicationExitInfo.REASON_ANR -> "ANR"
                ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
                // Devices without LMK reporting can use SIGNALED/SIGKILL.
                // Preserve the status without guessing that it proves an OOM.
                ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
                else -> continue
            }
            val trace = captureExitTrace(context, exit, key)
            val recorded = appendRow(
                context,
                module = "android.process_exit",
                message = "应用进程退出：" + reason,
                details = buildString {
                    append("reason=").append(reason).append('\n')
                    append("timestamp=").append(exit.timestamp).append('\n')
                    append("process=").append(exit.processName).append('\n')
                    append("pid=").append(exit.pid).append('\n')
                    append("status=").append(exit.status).append('\n')
                    append("importance=").append(exit.importance).append('\n')
                    append("pssKb=").append(exit.pss).append('\n')
                    append("rssKb=").append(exit.rss).append('\n')
                    append("description=").append(exit.description ?: "").append('\n')
                    append(trace)
                },
                contextValue = "exit=" + key,
            )
            // Advance only after a durable row; a failed write is retried.
            if (recorded) seen.add(key)
        }
        check(preferences.edit().putStringSet("recorded", seen.intersect(currentKeys)).commit()) {
            "无法保存退出诊断去重状态"
        }
        val traces = File(context.noBackupFilesDir, EXIT_TRACE_DIR)
        traces.listFiles()?.sortedByDescending { it.lastModified() }
            ?.drop(MAX_EXIT_HISTORY)?.forEach { it.delete() }
    }

    @android.annotation.TargetApi(30)
    private fun captureExitTrace(context: Context, exit: ApplicationExitInfo, key: String): String {
        val native = exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE
        if (native && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return "trace=unavailable_before_api31"
        // The native tombstone stream is protobuf, not UTF-8. Preserve bytes in
        // private, non-backed-up storage; expose only metadata to the Dart log.
        val stream = runCatching { exit.traceInputStream }.getOrNull() ?: return "trace=unavailable"
        val extension = if (native) ".pb" else ".trace"
        val fileName = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) } + extension
        val directory = File(context.noBackupFilesDir, EXIT_TRACE_DIR)
        val target = File(directory, fileName)
        return try {
            stream.use { input ->
                val outputBytes = ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (outputBytes.size() <= MAX_TRACE_BYTES) {
                    val read = input.read(buffer, 0, minOf(buffer.size, MAX_TRACE_BYTES + 1 - outputBytes.size()))
                    if (read < 0) break
                    if (read == 0) continue
                    outputBytes.write(buffer, 0, read)
                }
                val bytes = outputBytes.toByteArray()
                // Never save a truncated protobuf as a usable tombstone.
                if (bytes.size > MAX_TRACE_BYTES) return "trace=over_size_limit"
                check(directory.isDirectory || directory.mkdirs())
                FileOutputStream(target).use { output ->
                    output.write(bytes)
                    output.flush()
                    output.fd.sync()
                }
                "traceFormat=" + (if (native) "tombstone.protobuf" else "anr.trace") +
                    "\ntraceFile=" + fileName + "\ntraceBytes=" + bytes.size
            }
        } catch (_: Throwable) {
            runCatching { target.delete() }
            "trace=unavailable"
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
            rows
        } catch (_: Throwable) {
            emptyList()
        }
    }

    @Synchronized
    fun acknowledge(context: Context, rows: List<String>) {
        val file = File(context.filesDir, FILE_NAME)
        if (!file.isFile || rows.isEmpty()) return
        val acknowledged = rows.toSet()
        val remaining = file.readLines(Charsets.UTF_8).filter { it !in acknowledged }
        val temporary = File(context.filesDir, FILE_NAME + ".part")
        FileOutputStream(temporary).use { output ->
            output.write((remaining.joinToString("\n") + if (remaining.isEmpty()) "" else "\n").toByteArray(Charsets.UTF_8))
            output.flush()
            output.fd.sync()
        }
        check(temporary.renameTo(file)) { "无法确认诊断记录" }
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
