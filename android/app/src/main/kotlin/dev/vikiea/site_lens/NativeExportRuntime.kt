package dev.vikiea.site_lens

import android.content.Context
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** SAF delivery and local-input guard for the restricted FFmpeg/JNI boundary.
 * The native boundary validates paths and the Android extractor/muxer performs
 * a local remux of cached MPEG-TS/fMP4 segments. No caller-provided command
 * line or remote URI can reach this code. */
class NativeExportRuntime(private val context: Context) : MethodChannel.MethodCallHandler {
    private val filesRoot = context.filesDir.canonicalFile
    @Volatile private var cancelled = false

    init { System.loadLibrary("site_lens_export") }

    private external fun nativeValidatePath(path: String, root: String): Boolean

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "validateLocalInput" -> {
                    val path = call.argument<String>("path") ?: error("缺少输入路径")
                    result.success(validateLocal(path))
                }
                "muxHls" -> {
                    val playlist = call.argument<String>("playlist") ?: error("缺少 HLS 清单")
                    val output = call.argument<String>("output") ?: error("缺少输出文件")
                    muxHls(playlist, output)
                    result.success(mapOf("output" to output))
                }
                "validateOutput" -> {
                    val path = call.argument<String>("path") ?: error("缺少输出文件")
                    result.success(validateOutput(path))
                }
                "cancel" -> { cancelled = true; result.success(null) }
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
        require(nativeValidatePath(file.path, filesRoot.path)) { "输入路径越界" }
        require(file.isFile && file.length() > 0) { "本地输入不存在或为空" }
        return true
    }

    private fun muxHls(playlistPath: String, outputPath: String) {
        cancelled = false
        validateLocal(playlistPath)
        val output = File(outputPath).canonicalFile
        require(nativeValidatePath(output.path, filesRoot.path)) { "输出路径越界" }
        output.parentFile?.mkdirs()
        val lines = File(playlistPath).readLines(Charsets.UTF_8)
        val segments = lines.asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { File(File(playlistPath).parentFile, it).canonicalFile }
            .onEach { segment ->
                require(nativeValidatePath(segment.path, filesRoot.path) && segment.isFile) { "HLS 输入分片缺失或越界" }
            }
            .toList()
        require(segments.isNotEmpty()) { "HLS 清单没有媒体分片" }
        val temp = File("${output.path}.part")
        if (temp.exists()) temp.delete()
        var muxer: MediaMuxer? = null
        val trackIds = mutableMapOf<String, Int>()
        val timestampOffsets = mutableMapOf<String, Long>()
        try {
            for (segment in segments) {
                check(!cancelled) { "导出已取消" }
                val extractor = MediaExtractor()
                extractor.setDataSource(segment.path)
                try {
                    if (muxer == null) {
                        muxer = MediaMuxer(temp.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                        for (index in 0 until extractor.trackCount) {
                            val format = extractor.getTrackFormat(index)
                            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                            if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                                trackIds[mime] = muxer!!.addTrack(format)
                                timestampOffsets[mime] = 0L
                            }
                        }
                        require(trackIds.isNotEmpty()) { "HLS 分片不含音视频轨道" }
                        muxer!!.start()
                    }
                    val selected = (0 until extractor.trackCount).filter { index ->
                        val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME) ?: ""
                        mime.startsWith("video/") || mime.startsWith("audio/")
                    }
                    selected.forEach(extractor::selectTrack)
                    val buffer = ByteBuffer.allocate(1024 * 1024)
                    val info = MediaCodec.BufferInfo()
                    while (true) {
                        check(!cancelled) { "导出已取消" }
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        val mime = extractor.getTrackFormat(extractor.sampleTrackIndex).getString(MediaFormat.KEY_MIME) ?: break
                        val track = trackIds[mime] ?: break
                        val offset = timestampOffsets[mime] ?: 0L
                        info.offset = 0
                        info.size = size
                        info.presentationTimeUs = extractor.sampleTime + offset
                        info.flags = extractor.sampleFlags
                        muxer!!.writeSampleData(track, buffer, info)
                        timestampOffsets[mime] = info.presentationTimeUs + 1
                        extractor.advance()
                    }
                } finally {
                    extractor.release()
                }
            }
            muxer?.stop()
            muxer?.release()
            muxer = null
            require(temp.isFile && temp.length() > 0) { "导出文件为空" }
            if (output.exists()) output.delete()
            check(temp.renameTo(output)) { "无法提交导出文件" }
        } catch (error: Exception) {
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            if (temp.exists()) temp.delete()
            throw error
        }
    }

    private fun validateOutput(path: String): Boolean {
        val file = File(path).canonicalFile
        if (!file.isFile || file.length() <= 0L) return false
        require(nativeValidatePath(file.path, filesRoot.path)) { "输出路径越界" }
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            extractor.trackCount > 0 && (0 until extractor.trackCount).any { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.let { it.startsWith("audio/") || it.startsWith("video/") } == true
            }
        } finally { extractor.release() }
    }

    private fun deliver(sourcePath: String, destination: Uri) {
        validateLocal(sourcePath)
        require(destination.scheme == "content") { "SAF 目标无效" }
        val source = File(sourcePath)
        val output = context.contentResolver.openOutputStream(destination, "w") ?: error("无法打开 SAF 目标")
        source.inputStream().use { input -> output.use { input.copyTo(it) } }
    }
}
