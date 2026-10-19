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
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** SAF delivery and local-input guard for the restricted FFmpeg/JNI boundary.
 * The native boundary validates paths and the Android extractor/muxer performs
 * a local remux of cached MPEG-TS/fMP4 segments. No caller-provided command
 * line or remote URI can reach this code. */
class NativeExportRuntime(private val context: Context) : MethodChannel.MethodCallHandler {
    private val filesRoot = context.filesDir.canonicalFile
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var disposed = false
    @Volatile private var activeCancellation: AtomicBoolean? = null
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private val cancelledJobs = ConcurrentHashMap.newKeySet<String>()
    private var pendingDirectoryResult: MethodChannel.Result? = null

    companion object {
        const val PICK_DIRECTORY_REQUEST = 6101
    }

    init { System.loadLibrary("site_lens_export") }

    private external fun nativeValidatePath(path: String, root: String): Boolean

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("media_export", "媒体服务已关闭", null); return }
        if (call.method == "cancel") {
            val jobId = call.argument<String>("jobId")
            if (jobId == null) activeCancellation?.set(true)
            else if (cancellations[jobId]?.let { it.set(true); true } != true) cancelledJobs.add(jobId)
            result.success(null)
            return
        }
        if (call.method == "pickDirectory") {
            try { pickDirectory(result) } catch (error: Exception) { fail(call, result, error) }
            return
        }
        val supported = setOf("validateLocalInput", "muxHls", "validateOutput", "deliver", "deliverToDirectory", "inspect", "materialize", "rename", "move", "delete")
        if (call.method !in supported) { result.notImplemented(); return }
        val jobId = call.argument<String>("jobId") ?: "job-${System.nanoTime()}"
        val cancellation = AtomicBoolean(false)
        cancellations[jobId] = cancellation
        if (cancelledJobs.remove(jobId)) cancellation.set(true)
        worker.execute {
            if (disposed) { main.post { result.error("media_export", "媒体服务已关闭", null) }; return@execute }
            activeCancellation = cancellation
            try {
                check(!cancellation.get()) { "导出已取消" }
                val value = execute(call, cancellation)
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { fail(call, result, error) }
            } finally {
                activeCancellation = null
                cancellations.remove(jobId)
            }
        }
    }

    private fun execute(call: MethodCall, cancellation: AtomicBoolean): Any? {
        fun argument(name: String) = call.argument<String>(name) ?: error("缺少 $name")
        return when (call.method) {
            "validateLocalInput" -> validateLocal(argument("path"))
            "muxHls" -> {
                val output = argument("output")
                muxHls(argument("playlist"), output, cancellation)
                mapOf("output" to output)
            }
            "validateOutput" -> validateOutput(argument("path"))
            "deliver" -> { deliver(argument("source"), Uri.parse(argument("destination"))); null }
            "deliverToDirectory" -> deliverToDirectory(argument("source"), Uri.parse(argument("directory")), argument("fileName"), call.argument<String>("subdirectory"))
            "inspect" -> inspect(argument("source"))
            "materialize" -> materialize(argument("source"))
            "rename" -> rename(argument("source"), argument("fileName"))
            "move" -> {
                val source = argument("source")
                val target = deliverToDirectory(source, Uri.parse(argument("directory")), argument("fileName"))
                runCatching { delete(source) }
                target
            }
            "delete" -> { delete(argument("source")); null }
            else -> error("未知媒体操作")
        }
    }

    private fun fail(call: MethodCall, result: MethodChannel.Result, error: Exception) {
        NativeCrashStore.append(context, module = "media.export", message = error.message ?: "媒体操作失败", details = error.stackTraceToString(), contextValue = "method=${call.method}")
        result.error("media_export", error.message ?: "媒体操作失败", null)
    }

    fun dispose() {
        disposed = true
        cancellations.values.forEach { it.set(true) }
        activeCancellation?.set(true)
        pendingDirectoryResult?.error("media_export", "媒体服务已关闭", null)
        pendingDirectoryResult = null
        worker.shutdown()
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
        val roots = listOfNotNull(filesRoot, context.getExternalFilesDir(null)?.canonicalFile)
        require(roots.any { nativeValidatePath(file.path, it.path) }) { "输入路径越界" }
        require(file.isFile && file.length() > 0) { "本地输入不存在或为空" }
        return true
    }

    private fun muxHls(playlistPath: String, outputPath: String, cancelled: AtomicBoolean) {
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
        var segmentStartUs = 0L
        try {
            for ((index, segment) in segments.withIndex()) {
                check(!cancelled.get() && !disposed) { "导出已取消" }
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
                    val firstSampleUs = extractor.sampleTime.coerceAtLeast(0L)
                    var segmentEndUs = segmentStartUs
                    val buffer = ByteBuffer.allocate(1024 * 1024)
                    val info = MediaCodec.BufferInfo()
                    while (true) {
                        check(!cancelled.get() && !disposed) { "导出已取消" }
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        val mime = extractor.getTrackFormat(extractor.sampleTrackIndex).getString(MediaFormat.KEY_MIME) ?: break
                        val track = trackIds[mime] ?: break
                        info.offset = 0
                        info.size = size
                        info.presentationTimeUs = segmentStartUs + (extractor.sampleTime - firstSampleUs).coerceAtLeast(0L)
                        info.flags = extractor.sampleFlags
                        muxer!!.writeSampleData(track, buffer, info)
                        segmentEndUs = maxOf(segmentEndUs, info.presentationTimeUs)
                        extractor.advance()
                    }
                    segmentStartUs = maxOf(segmentEndUs + 1, segmentStartUs + segment.durationUs)
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
        val durationUs: Long,
    )

    private fun parseHlsSegments(playlistPath: String): List<HlsSegment> {
        val playlist = File(playlistPath).canonicalFile
        val base = playlist.parentFile ?: error("HLS 清单目录无效")
        var sequence = 0L
        var keyFile: File? = null
        var explicitIv: ByteArray? = null
        var initFile: File? = null
        var durationUs = 0L
        val result = mutableListOf<HlsSegment>()
        for (raw in playlist.readLines(Charsets.UTF_8)) {
            val line = raw.trim()
            if (line.startsWith("#EXTINF:")) {
                durationUs = ((line.substringAfter(':').substringBefore(',').toDoubleOrNull() ?: 0.0) * 1_000_000).toLong().coerceAtLeast(0L)
                continue
            }
            if (line.startsWith("#EXT-X-MEDIA-SEQUENCE:")) {
                sequence = line.substringAfter(':').trim().toLongOrNull()
                    ?: error("HLS 序列号无效")
                continue
            }
            if (line.startsWith("#EXT-X-KEY:")) {
                val method = attribute(line, "METHOD")?.trim()
                val rawKey = attribute(line, "URI")?.trim()
                if (method.isNullOrEmpty()) {
                    // A few providers emit an empty key tag when switching
                    // back to clear segments, or omit METHOD while retaining
                    // an AES key URI. Treat the former as a clear reset and
                    // infer AES-128 for the latter; the key length check below
                    // still rejects unusable or unsupported key material.
                    if (rawKey == null) {
                        keyFile = null
                        explicitIv = null
                    } else {
                        keyFile = localResource(base, rawKey, "HLS 密钥")
                        explicitIv = attribute(line, "IV")?.let(::parseIv)
                    }
                } else if (method.equals("NONE", ignoreCase = true)) {
                    keyFile = null
                    explicitIv = null
                } else {
                    require(method.equals("AES-128", ignoreCase = true)) {
                        "暂不支持 $method HLS 加密"
                    }
                    keyFile = localResource(
                        base,
                        rawKey ?: error("HLS 密钥地址缺失"),
                        "HLS 密钥",
                    )
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
                durationUs = durationUs,
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

    /**
     * Reads an HLS attribute value in either its quoted or token form.
     *
     * HLS uses unquoted tokens for values such as METHOD=AES-128 and quoted
     * strings for most URIs. Some cached playlists also contain whitespace,
     * single quotes, or semicolon-separated attributes, so the parser accepts
     * those forms before the native muxer validates the resulting files.
     */
    private fun attribute(line: String, name: String): String? {
        val attributes = line.substringAfter(':', "")
        val pattern = Regex(
            "(?:^|[,;\\s])\\s*${Regex.escape(name)}\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^,;\\s]*))",
            RegexOption.IGNORE_CASE,
        )
        val match = pattern.find(attributes) ?: return null
        for (index in 1 until match.groupValues.size) {
            match.groupValues[index].takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

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
        val source = File(sourcePath).canonicalFile
        if (destination.scheme == "content" && DocumentsContract.isTreeUri(destination) &&
            !DocumentsContract.isDocumentUri(context, destination)) {
            deliverToDirectory(sourcePath, destination, source.name)
            return
        }
        val targetFile = when (destination.scheme) {
            "file", "", null -> File(destination.path ?: error("文件目标无效")).canonicalFile.also {
                require(it.isAbsolute && it != source) { "导出目标与源文件相同或无效" }
                it.parentFile?.mkdirs()
            }
            "content" -> null
            else -> error("导出目标类型不支持，请重新选择 MP4 保存目录")
        }
        fun openTargetInput() = if (targetFile != null) targetFile.inputStream()
            else context.contentResolver.openInputStream(destination) ?: error("导出目标无法读取校验")
        val expected = MessageDigest.getInstance("SHA-256")
        var count = 0L
        val output = if (targetFile != null) targetFile.outputStream()
            else context.contentResolver.openOutputStream(destination, "wt") ?: error("导出目标不可写，请重新选择 MP4 保存目录")
        source.inputStream().use { input ->
            output.use {
                val buffer = ByteArray(128 * 1024)
                while (true) {
                    check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                    val read = input.read(buffer)
                    if (read < 0) break
                    it.write(buffer, 0, read)
                    expected.update(buffer, 0, read)
                    count += read
                }
                it.flush()
            }
        }
        require(count > 0L) { "导出文件为空" }
        val actual = MessageDigest.getInstance("SHA-256")
        var actualSize = 0L
        openTargetInput().use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                val read = input.read(buffer)
                if (read < 0) break
                actual.update(buffer, 0, read)
                actualSize += read
            }
        }
        require(actualSize == count && actual.digest().contentEquals(expected.digest())) { "导出文件校验失败" }
    }

    private fun deliverToDirectory(sourcePath: String, directory: Uri, fileName: String, subdirectory: String? = null): String {
        sourceStream(sourcePath).close()
        require(directory.scheme == "content") { "系统目录无效" }
        validateName(fileName)
        require(context.contentResolver.persistedUriPermissions.any { it.uri == directory && it.isWritePermission && it.isReadPermission }) {
            "保存目录权限已失效，请在媒体管理中重新选择 MP4 保存目录"
        }
        var treeDocument = DocumentsContract.buildDocumentUriUsingTree(
            directory,
            DocumentsContract.getTreeDocumentId(directory),
        )
        if (!subdirectory.isNullOrBlank()) {
            validateName(subdirectory)
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(
                directory, DocumentsContract.getDocumentId(treeDocument),
            )
            var folder: Uri? = null
            context.contentResolver.query(children, arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getString(1) != subdirectory) continue
                    require(cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) { "批次目录名称已被文件占用" }
                    folder = DocumentsContract.buildDocumentUriUsingTree(directory, cursor.getString(0))
                    break
                }
            }
            treeDocument = folder ?: DocumentsContract.createDocument(
                context.contentResolver, treeDocument, DocumentsContract.Document.MIME_TYPE_DIR, subdirectory,
            ) ?: error("无法创建批次目录")
        }
        val target = DocumentsContract.createDocument(
            context.contentResolver,
            treeDocument,
            "video/mp4",
            fileName,
        ) ?: error("系统目录不可写，请重新选择目录")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            sourceStream(sourcePath).use { input ->
                val output = context.contentResolver.openOutputStream(target, "wt") ?: error("无法打开系统目录")
                output.use {
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                        val read = input.read(buffer)
                        if (read < 0) break
                        it.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        count += read
                    }
                    it.flush()
                }
            }
            require(count > 0L) { "导出文件为空" }
            val written = MessageDigest.getInstance("SHA-256")
            var actualSize = 0L
            context.contentResolver.openInputStream(target)!!.use { input ->
                val buffer = ByteArray(128 * 1024)
                while (true) {
                    check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                    val read = input.read(buffer)
                    if (read < 0) break
                    written.update(buffer, 0, read)
                    actualSize += read
                }
            }
            require(actualSize == count && written.digest().contentEquals(digest.digest())) { "导出文件校验失败" }
            return target.toString()
        } catch (error: Exception) {
            runCatching { DocumentsContract.deleteDocument(context.contentResolver, target) }
            throw error
        }
    }

    private fun sourceStream(source: String): java.io.InputStream {
        val uri = Uri.parse(source)
        if (uri.scheme == "content") return context.contentResolver.openInputStream(uri) ?: error("媒体文件不可读")
        val path = if (uri.scheme == "file") uri.path ?: error("媒体路径无效") else source
        require(uri.scheme == null || uri.scheme == "file") { "仅允许本地媒体文件" }
        validateLocal(path)
        return File(path).inputStream()
    }

    private fun validateName(name: String) {
        require(name.isNotBlank() && name != "." && name != ".." && !name.contains("..") && name.length <= 220 && !name.any { it == '/' || it == '\\' || it.code < 32 }) { "媒体文件名无效" }
    }

    private fun delete(source: String) {
        val uri = Uri.parse(source)
        if (uri.scheme == "content") {
            check(DocumentsContract.deleteDocument(context.contentResolver, uri)) { "无法删除媒体文件" }
        } else {
            val path = if (uri.scheme == "file") uri.path!! else source
            validateLocal(path)
            check(File(path).delete()) { "无法删除媒体文件" }
        }
    }

    private fun rename(source: String, name: String): String {
        validateName(name)
        val uri = Uri.parse(source)
        if (uri.scheme == "content") return DocumentsContract.renameDocument(context.contentResolver, uri, name)?.toString() ?: error("当前目录不支持重命名")
        val path = if (uri.scheme == "file") uri.path!! else source
        validateLocal(path)
        val file = File(path).canonicalFile
        val destination = File(file.parentFile, name)
        require(!destination.exists()) { "已存在同名文件" }
        check(file.renameTo(destination)) { "重命名失败" }
        return destination.path
    }

    private fun materialize(source: String): String {
        val uri = Uri.parse(source)
        if (uri.scheme != "content") {
            val path = if (uri.scheme == "file") uri.path!! else source
            validateLocal(path)
            return path
        }
        val key = MessageDigest.getInstance("SHA-256").digest(source.toByteArray()).joinToString("") { "%02x".format(it) }
        val directory = File(filesRoot, "media_exports/materialized").apply { mkdirs() }
        val file = File(directory, "$key.mp4")
        val temporary = File(directory, "$key.part")
        try {
            sourceStream(source).use { input -> temporary.outputStream().use { input.copyTo(it) } }
            require(temporary.length() > 0L && validateOutput(temporary.path)) { "本地媒体副本无效" }
            if (file.exists()) check(file.delete())
            check(temporary.renameTo(file)) { "无法保存播放副本" }
            return file.path
        } finally { if (temporary.exists()) temporary.delete() }
    }

    private fun inspect(source: String): Map<String, Any?> {
        val uri = Uri.parse(source)
        var size: Long
        var modified: Long
        val retriever = MediaMetadataRetriever()
        try {
            if (uri.scheme == "content") {
                sourceStream(source).close()
                size = -1L
                modified = 0L
                context.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use {
                    if (it.moveToFirst()) {
                        if (!it.isNull(0)) size = it.getLong(0)
                        if (!it.isNull(1)) modified = it.getLong(1)
                    }
                }
                retriever.setDataSource(context, uri)
            } else {
                val path = if (uri.scheme == "file") uri.path!! else source
                validateLocal(path)
                val file = File(path)
                size = file.length()
                modified = file.lastModified()
                retriever.setDataSource(path)
            }
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            val key = MessageDigest.getInstance("SHA-256").digest("$source:$size:$modified".toByteArray()).joinToString("") { "%02x".format(it) }
            val thumbnail = File(File(filesRoot, "media_thumbnails").apply { mkdirs() }, "$key.jpg")
            if (!thumbnail.isFile) runCatching {
                val frame = if (Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 320, 180) else retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                frame?.let { bitmap ->
                    val scaled = Bitmap.createScaledBitmap(bitmap, 320, 180, true)
                    try { thumbnail.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 80, it) } }
                    finally { if (scaled !== bitmap) scaled.recycle(); bitmap.recycle() }
                }
            }
            return mapOf("size" to size, "modifiedMs" to modified, "mime" to (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE) ?: "video/mp4"), "durationMs" to duration, "width" to width, "height" to height, "thumbnailPath" to thumbnail.takeIf { it.isFile && it.length() > 0L }?.path)
        } finally { retriever.release() }
    }
}
