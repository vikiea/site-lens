package dev.vikiea.site_lens

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** SAF delivery and local-input guard for the restricted FFmpeg/JNI boundary.
 * The native boundary validates paths and the Android extractor/muxer performs
 * a local remux of cached MPEG-TS/fMP4 segments. No caller-provided command
 * line or remote URI can reach this code. */
class NativeExportRuntime(private val context: Context) : MethodChannel.MethodCallHandler {
    private val filesRoot = context.filesDir.canonicalFile
    @Volatile private var cancelled = false
    private var pendingDirectoryResult: MethodChannel.Result? = null

    companion object {
        const val PICK_DIRECTORY_REQUEST = 6101
    }

    init { System.loadLibrary("site_lens_export") }

    private external fun nativeValidatePath(path: String, root: String): Boolean

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickDirectory" -> pickDirectory(result)
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
                "deliverToDirectory" -> {
                    val source = call.argument<String>("source") ?: error("缺少输出文件")
                    val directory = call.argument<String>("directory") ?: error("缺少导出目录")
                    val fileName = call.argument<String>("fileName") ?: error("缺少导出文件名")
                    deliverToDirectory(source, Uri.parse(directory), fileName)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            NativeCrashStore.append(
                context,
                module = "media.export",
                message = error.message ?: "媒体导出失败",
                details = error.stackTraceToString(),
                contextValue = "method=${call.method}",
            )
            result.error("media_export", error.message ?: "导出失败", null)
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        require(pendingDirectoryResult == null) { "目录选择器已打开" }
        pendingDirectoryResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
            (context as? android.app.Activity)?.startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
                ?: error("无法打开系统目录选择器")
        } catch (error: Exception) {
            pendingDirectoryResult = null
            throw error
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_DIRECTORY_REQUEST) return false
        val result = pendingDirectoryResult
        pendingDirectoryResult = null
        if (result == null) return true
        if (resultCode != android.app.Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }
        val uri = data.data!!
        try {
            val flags = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            context.contentResolver.takePersistableUriPermission(uri, flags)
        } catch (error: SecurityException) {
            result.error("media_export", "无法保存目录访问权限，请重新选择目录", null)
            return true
        }
        result.success(uri.toString())
        return true
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
        val segments = parseHlsSegments(playlistPath)
        require(segments.isNotEmpty()) { "HLS 清单没有媒体分片" }
        val temp = File("${output.path}.part")
        val workDir = File("${output.path}.segments")
        if (temp.exists()) temp.delete()
        if (workDir.exists()) workDir.deleteRecursively()
        workDir.mkdirs()
        var muxer: MediaMuxer? = null
        val trackIds = mutableMapOf<String, Int>()
        val timestampOffsets = mutableMapOf<String, Long>()
        try {
            for ((index, segment) in segments.withIndex()) {
                check(!cancelled) { "导出已取消" }
                val input = prepareSegment(segment, workDir, index)
                val extractor = MediaExtractor()
                extractor.setDataSource(input.path)
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
        } finally {
            if (workDir.exists()) workDir.deleteRecursively()
        }
    }

    private data class HlsSegment(
        val file: File,
        val key: File?,
        val explicitIv: ByteArray?,
        val sequence: Long,
        val init: File?,
    )

    private fun parseHlsSegments(playlistPath: String): List<HlsSegment> {
        val playlist = File(playlistPath).canonicalFile
        val base = playlist.parentFile ?: error("HLS 清单目录无效")
        var sequence = 0L
        var keyFile: File? = null
        var explicitIv: ByteArray? = null
        var initFile: File? = null
        val result = mutableListOf<HlsSegment>()
        for (raw in playlist.readLines(Charsets.UTF_8)) {
            val line = raw.trim()
            if (line.startsWith("#EXT-X-MEDIA-SEQUENCE:")) {
                sequence = line.substringAfter(':').trim().toLongOrNull()
                    ?: error("HLS 序列号无效")
                continue
            }
            if (line.startsWith("#EXT-X-KEY:")) {
                val method = attribute(line, "METHOD") ?: error("HLS 加密方式缺失")
                if (method.equals("NONE", ignoreCase = true)) {
                    keyFile = null
                    explicitIv = null
                } else {
                    require(method.equals("AES-128", ignoreCase = true)) {
                        "暂不支持 $method HLS 加密"
                    }
                    val rawKey = attribute(line, "URI") ?: error("HLS 密钥地址缺失")
                    keyFile = localResource(base, rawKey, "HLS 密钥")
                    explicitIv = attribute(line, "IV")?.let(::parseIv)
                }
                continue
            }
            if (line.startsWith("#EXT-X-MAP:")) {
                val rawInit = attribute(line, "URI") ?: error("HLS 初始化分片地址缺失")
                initFile = localResource(base, rawInit, "HLS 初始化分片")
                continue
            }
            if (line.isEmpty() || line.startsWith("#")) continue
            if (line.startsWith("http://") || line.startsWith("https://")) {
                error("HLS 清单包含远程分片")
            }
            result += HlsSegment(
                file = localResource(base, line, "HLS 输入分片"),
                key = keyFile,
                explicitIv = explicitIv,
                sequence = sequence++,
                init = initFile,
            )
        }
        return result
    }

    private fun localResource(base: File, raw: String, label: String): File {
        val value = raw.trim().removeSurrounding("\"")
        val file = File(base, value).canonicalFile
        require(nativeValidatePath(file.path, filesRoot.path) && file.isFile) {
            "${label}缺失或越界"
        }
        return file
    }

    private fun attribute(line: String, name: String): String? =
        Regex("$name=\\\"([^\\\"]+)\\\"").find(line)?.groupValues?.get(1)

    private fun parseIv(raw: String): ByteArray {
        val value = raw.removePrefix("0x").removePrefix("0X")
        require(value.length <= 32 && value.matches(Regex("[0-9a-fA-F]+"))) { "HLS 初始向量无效" }
        val padded = value.padStart(32, '0')
        return ByteArray(16) { index -> padded.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }

    private fun sequenceIv(sequence: Long): ByteArray {
        require(sequence >= 0) { "HLS 序列号无效" }
        val iv = ByteArray(16)
        ByteBuffer.wrap(iv).putLong(8, sequence)
        return iv
    }

    private fun prepareSegment(segment: HlsSegment, workDir: File, index: Int): File {
        if (segment.key == null && segment.init == null) return segment.file
        val segmentBytes = if (segment.key == null) {
            segment.file.readBytes()
        } else {
            val key = segment.key.readBytes()
            require(key.size == 16) { "HLS AES-128 密钥长度无效" }
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                IvParameterSpec(segment.explicitIv ?: sequenceIv(segment.sequence)),
            )
            cipher.doFinal(segment.file.readBytes())
        }
        val output = File(workDir, "segment_${index.toString().padStart(5, '0')}.bin")
        if (segment.init == null) {
            output.writeBytes(segmentBytes)
            return output
        }
        output.outputStream().use { stream ->
            segment.init.inputStream().use { it.copyTo(stream) }
            stream.write(segmentBytes)
        }
        return output
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
        val source = File(sourcePath)
        val output = when (destination.scheme) {
            "content" -> context.contentResolver.openOutputStream(destination, "w")
            "file" -> File(destination.path ?: error("文件目标无效")).outputStream()
            "" -> File(destination.path ?: error("文件目标无效")).outputStream()
            else -> null
        } ?: error("导出目标无效")
        source.inputStream().use { input -> output.use { input.copyTo(it) } }
    }

    private fun deliverToDirectory(sourcePath: String, directory: Uri, fileName: String) {
        validateLocal(sourcePath)
        require(directory.scheme == "content") { "系统目录无效" }
        require(fileName.isNotBlank() && !fileName.contains('/') && !fileName.contains('\\')) { "导出文件名无效" }
        val treeDocument = DocumentsContract.buildDocumentUriUsingTree(
            directory,
            DocumentsContract.getTreeDocumentId(directory),
        )
        val target = DocumentsContract.createDocument(
            context.contentResolver,
            treeDocument,
            "video/mp4",
            fileName,
        ) ?: error("系统目录不可写，请重新选择目录")
        val output = context.contentResolver.openOutputStream(target, "w")
            ?: error("无法打开系统目录")
        File(sourcePath).inputStream().use { input -> output.use { input.copyTo(it) } }
    }
}
