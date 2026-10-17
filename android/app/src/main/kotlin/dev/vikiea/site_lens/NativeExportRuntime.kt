package dev.vikiea.site_lens

import android.content.Context
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** SAF delivery and local-input guard for the restricted FFmpeg/JNI boundary.
 * The muxer itself is injected by [Mp4ExportService]; this bridge never opens
 * a remote URI and never executes a caller-provided command line. */
class NativeExportRuntime(private val context: Context) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "validateLocalInput" -> {
                    val path = call.argument<String>("path") ?: error("缺少输入路径")
                    result.success(validateLocal(path))
                }
                "deliver" -> {
                    val source = call.argument<String>("source") ?: error("缺少输出文件")
                    val destination = call.argument<String>("destination") ?: error("缺少 SAF 目标")
                    deliver(source, Uri.parse(destination))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("media_export", error.message ?: "导出失败", null)
        }
    }

    private fun validateLocal(path: String): Boolean {
        val file = File(path).canonicalFile
        val root = context.filesDir.canonicalFile
        require(file.path == root.path || file.path.startsWith(root.path + File.separator)) { "输入路径越界" }
        require(file.isFile && file.length() > 0) { "本地输入不存在或为空" }
        return true
    }

    private fun deliver(sourcePath: String, destination: Uri) {
        validateLocal(sourcePath)
        require(destination.scheme == "content") { "SAF 目标无效" }
        val source = File(sourcePath)
        val output = context.contentResolver.openOutputStream(destination, "w") ?: error("无法打开 SAF 目标")
        source.inputStream().use { input -> output.use { input.copyTo(it) } }
    }
}
