package dev.vikiea.site_lens

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.media3.common.Format
import androidx.media3.common.C
import androidx.media3.common.util.MediaFormatUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.muxer.Mp4Muxer
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.SeekableMuxerOutput
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.FileNotFoundException
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
@androidx.annotation.OptIn(UnstableApi::class)
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
        val supported = setOf("validateLocalInput", "muxHls", "validateOutput", "deliver", "deliverToDirectory", "stat", "inspect", "scanMedia", "materialize", "rename", "move", "delete")
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
            "stat" -> stat(argument("source"))
            "inspect" -> inspect(argument("source"))
            "scanMedia" -> scanMedia(call.argument<String>("directory"), cancellation)
            "materialize" -> materialize(argument("source"))
            "rename" -> rename(argument("source"), argument("fileName"))
            "move" -> {
                val source = argument("source")
                val target = deliverToDirectory(source, Uri.parse(argument("directory")), argument("fileName"))
                runCatching { delete(source) }
                target
            }
            "delete" -> { delete(argument("source"), call.argument<Boolean>("allowMissing") == true); null }
            else -> error("未知媒体操作")
        }
    }

    private fun fail(call: MethodCall, result: MethodChannel.Result, error: Exception) {
        NativeCrashStore.append(context, module = "media.export", message = error.message ?: "媒体操作失败", details = error.stackTraceToString(), contextValue = "method=${call.method}")
        val code = MediaFileErrors.code(error) ?: "media_export"
        result.error(code, error.message ?: "媒体操作失败", null)
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
        val file = validateLocalPath(path)
        require(file.isFile && file.length() > 0) { "本地输入不存在或为空" }
        return true
    }

    private fun validateLocalPath(path: String): File {
        val file = File(path).canonicalFile
        val roots = listOfNotNull(filesRoot, context.getExternalFilesDir(null)?.canonicalFile)
        require(roots.any { nativeValidatePath(file.path, it.path) }) { "输入路径越界" }
        return file
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
        var muxer: Mp4Muxer? = null
        val trackIds = mutableMapOf<String, Int>()
        var segmentStartUs = 0L
        try {
            // Prepare and inspect every segment before adding muxer tracks. A
            // later HLS segment may be the first one containing AAC (or may
            // expose tracks in a different order); building tracks from only
            // segment zero used to silently discard the rest of that segment.
            val prepared = segments.mapIndexed { index, segment ->
                check(!cancelled.get() && !disposed) { "导出已取消" }
                prepareSegment(segment, workDir, index)
            }
            val formats = linkedMapOf<String, MediaFormat>()
            val formatSignatures = mutableMapOf<String, String>()
            val firstSamples = mutableListOf<Long>()
            val inputCounts = mutableMapOf<String, Int>()
            var audioSegments = 0
            var videoSegments = 0
            for (input in prepared) {
                check(!cancelled.get() && !disposed) { "导出已取消" }
                val extractor = MediaExtractor()
                extractor.setDataSource(input.path)
                try {
                    val selected = linkedMapOf<String, Int>()
                    for (index in 0 until extractor.trackCount) {
                        val format = extractor.getTrackFormat(index)
                        val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                        val kind = mediaTrackKind(mime) ?: continue
                        require(selected[kind] == null) { "HLS 分片包含多个${if (kind == "audio") "音频" else "视频"}轨道" }
                        val signature = mediaFormatSignature(format)
                        val previous = formatSignatures.putIfAbsent(kind, signature)
                        require(previous == null || previous == signature) { "HLS ${if (kind == "audio") "音频" else "视频"}轨道格式发生变化" }
                        selected[kind] = index
                        formats.putIfAbsent(kind, format)
                    }
                    require(selected.containsKey("video")) { "HLS 分片缺少视频轨道" }
                    if (selected.containsKey("audio")) audioSegments++
                    videoSegments++
                    selected.values.forEach(extractor::selectTrack)
                    val lastSampleByKind = mutableMapOf<String, Long>()
                    val sampleCountByKind = mutableMapOf<String, Int>()
                    var firstSampleUs: Long? = null
                    while (extractor.sampleTrackIndex >= 0) {
                        val sampleTrack = extractor.sampleTrackIndex
                        val mime = extractor.getTrackFormat(sampleTrack).getString(MediaFormat.KEY_MIME)
                            ?: error("HLS 样本轨道格式缺失")
                        val kind = mediaTrackKind(mime) ?: error("HLS 样本轨道不支持")
                        if (kind == "video" && sampleCountByKind[kind] == null) {
                            require(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                                "HLS 分片不是从视频关键帧开始"
                            }
                        }
                        val sampleTime = extractor.sampleTime
                        val previous = lastSampleByKind[kind]
                        require(kind != "audio" || previous == null || sampleTime >= previous) {
                            "HLS 音频轨道时间顺序无效"
                        }
                        lastSampleByKind[kind] = sampleTime
                        sampleCountByKind[kind] = (sampleCountByKind[kind] ?: 0) + 1
                        firstSampleUs = minOf(firstSampleUs ?: sampleTime, sampleTime)
                        extractor.advance()
                    }
                    require(sampleCountByKind.keys.containsAll(selected.keys)) {
                        "HLS 分片存在空音视频轨道"
                    }
                    sampleCountByKind.forEach { (kind, count) -> inputCounts[kind] = (inputCounts[kind] ?: 0) + count }
                    firstSamples += firstSampleUs ?: error("HLS 分片没有可写入样本")
                } finally {
                    extractor.release()
                }
            }
            require(videoSegments == prepared.size) { "HLS 分片视频样本不完整" }
            require(audioSegments == 0 || audioSegments == prepared.size) {
                "HLS 音频轨道只覆盖部分分片，无法生成连续有声 MP4"
            }
            require(formats.isNotEmpty()) { "HLS 分片不含音视频轨道" }
            muxer = Mp4Muxer.Builder(SeekableMuxerOutput.of(temp.path))
                .setSampleBatchingEnabled(false)
                .setLastSampleDurationBehavior(Mp4Muxer.LAST_SAMPLE_DURATION_BEHAVIOR_SET_FROM_END_OF_STREAM_BUFFER_OR_DUPLICATE_PREVIOUS)
                .build()
            formats.forEach { (kind, format) ->
                trackIds[kind] = muxer.addTrack(toMuxerFormat(format))
            }
            val lastOutputPtsByKind = mutableMapOf<String, Long>()
            val outputCounts = mutableMapOf<String, Int>()
            var audioEndUs = 0L
            val aacClock = formats["audio"]?.takeIf { it.getString(MediaFormat.KEY_MIME) == "audio/mp4a-latm" }
                ?.let { AacAccessUnits.Clock(it.getInteger(MediaFormat.KEY_SAMPLE_RATE)) }
            for ((index, input) in prepared.withIndex()) {
                check(!cancelled.get() && !disposed) { "导出已取消" }
                val segment = segments[index]
                val extractor = MediaExtractor()
                extractor.setDataSource(input.path)
                try {
                    val selected = (0 until extractor.trackCount).mapNotNull { trackIndex ->
                        val mime = extractor.getTrackFormat(trackIndex).getString(MediaFormat.KEY_MIME) ?: return@mapNotNull null
                        val kind = mediaTrackKind(mime) ?: return@mapNotNull null
                        if (kind !in trackIds) return@mapNotNull null
                        kind to trackIndex
                    }.groupBy({ it.first }, { it.second }).mapValues { it.value.first() }
                    selected.values.forEach(extractor::selectTrack)
                    require(selected.isNotEmpty()) { "HLS 分片缺少已选择的音视频轨道" }
                    val firstSampleUs = firstSamples[index]
                    var segmentEndUs = segmentStartUs
                    var buffer = ByteBuffer.allocateDirect(1024 * 1024)
                    while (true) {
                        check(!cancelled.get() && !disposed) { "导出已取消" }
                        val requiredSize = extractor.sampleSize
                        require(requiredSize <= 32L * 1024L * 1024L) { "HLS 单个样本过大" }
                        if (requiredSize > buffer.capacity()) buffer = ByteBuffer.allocateDirect(requiredSize.toInt())
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        val sampleTrack = extractor.sampleTrackIndex
                        val mime = extractor.getTrackFormat(sampleTrack).getString(MediaFormat.KEY_MIME)
                            ?: error("HLS 样本轨道格式缺失")
                        val kind = mediaTrackKind(mime) ?: error("HLS 样本轨道不支持")
                        val track = trackIds[kind] ?: error("HLS 样本轨道未映射")
                        // Audio and video share one segment offset. Keep the
                        // extractor's decode order and original PTS spacing;
                        // do not sort or independently zero each track, since
                        // B-frame composition offsets are valid here.
                        val relativePts = extractor.sampleTime - firstSampleUs
                        require(relativePts >= 0L) { "HLS 样本时间早于分片起点" }
                        val outputPts = segmentStartUs + relativePts
                        buffer.position(0)
                        buffer.limit(size)
                        val flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                            C.BUFFER_FLAG_KEY_FRAME else 0
                        val format = extractor.getTrackFormat(sampleTrack)
                        val frames = if (mime == "audio/mp4a-latm") {
                            val csd = format.getByteBuffer("csd-0")?.duplicate() ?: error("AAC 解码初始化信息缺失")
                            val config = ByteArray(csd.remaining()).also { csd.get(it) }
                            AacAccessUnits.split(buffer, format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT), config,
                                format.containsKey(MediaFormat.KEY_IS_ADTS) && format.getInteger(MediaFormat.KEY_IS_ADTS) == 1)
                        } else listOf(AacAccessUnits.Frame(buffer, 0L))
                        for (frame in frames) {
                            // TS extractors can return several complete ADTS
                            // frames as one sample. MP4 needs one raw AAC AU
                            // per sample, with the ADTS transport header removed.
                            val pts = if (frame.adts) aacClock!!.next(outputPts + frame.offsetUs) else outputPts + frame.offsetUs
                            val previousPts = lastOutputPtsByKind[kind]
                            require(kind != "audio" || previousPts == null || pts > previousPts) {
                                "HLS 音频轨道跨分片时间重叠，无法生成连续 MP4"
                            }
                            val sampleSize = frame.data.remaining()
                            muxer.writeSampleData(track, frame.data, BufferInfo(pts, sampleSize, flags))
                            lastOutputPtsByKind[kind] = maxOf(previousPts ?: pts, pts)
                            outputCounts[kind] = (outputCounts[kind] ?: 0) + 1
                            val frameEndUs = if (mime == "audio/mp4a-latm") {
                                pts + 1024L * 1_000_000L / format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            } else {
                                pts
                            }
                            segmentEndUs = maxOf(segmentEndUs, frameEndUs)
                            if (mime == "audio/mp4a-latm") {
                                val end = if (frame.adts) aacClock!!.endUs() else pts + 1024L * 1_000_000L / format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                                audioEndUs = maxOf(audioEndUs, end)
                            }
                        }
                        extractor.advance()
                    }
                    require(segment.durationUs > 0L) { "HLS 分片时长无效" }
                    require(segmentEndUs - segmentStartUs <= segment.durationUs + 1_000_000L) {
                        "HLS 样本超出清单分片时长"
                    }
                    segmentStartUs += segment.durationUs
                } finally {
                    extractor.release()
                }
            }
            trackIds.forEach { (kind, trackId) ->
                val last = lastOutputPtsByKind[kind] ?: error("输出缺少 $kind 样本")
                val end = if (kind == "audio") maxOf(segmentStartUs, audioEndUs, last + 1) else maxOf(segmentStartUs, last + 1)
                muxer.writeSampleData(trackId, ByteBuffer.allocate(0), BufferInfo(end, 0, C.BUFFER_FLAG_END_OF_STREAM))
            }
            muxer.close()
            muxer = null
            require(temp.isFile && temp.length() > 0) { "导出文件为空" }
            require(outputCounts["video"] == inputCounts["video"] &&
                (outputCounts["audio"] ?: 0) >= (inputCounts["audio"] ?: 0) && validateOutput(temp.path, outputCounts)) {
                "导出文件音视频样本不完整"
            }
            if (output.exists()) output.delete()
            check(temp.renameTo(output)) { "无法提交导出文件" }
        } catch (error: Exception) {
            runCatching { muxer?.close() }
            if (temp.exists()) temp.delete()
            throw error
        } finally {
            if (workDir.exists()) workDir.deleteRecursively()
        }
    }

    private fun mediaTrackKind(mime: String): String? = when {
        mime.startsWith("video/") -> "video"
        mime.startsWith("audio/") -> "audio"
        else -> null
    }

    private fun mediaFormatSignature(format: MediaFormat): String {
        val integerKeys = listOf(
            MediaFormat.KEY_WIDTH,
            MediaFormat.KEY_HEIGHT,
            MediaFormat.KEY_PROFILE,
            MediaFormat.KEY_LEVEL,
            MediaFormat.KEY_SAMPLE_RATE,
            MediaFormat.KEY_CHANNEL_COUNT,
            MediaFormat.KEY_ROTATION,
        )
        val values = integerKeys.joinToString("|") { key ->
            val value = runCatching {
                if (format.containsKey(key)) format.getInteger(key).toString() else ""
            }.getOrDefault("")
            "$key=$value"
        }
        val csd = listOf("csd-0", "csd-1").joinToString("|") { key ->
            val buffer = format.getByteBuffer(key)?.duplicate() ?: return@joinToString "$key="
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            "$key=${bytes.joinToString("") { byte -> "%02x".format(byte) }}"
        }
        return "${format.getString(MediaFormat.KEY_MIME)}|$values|$csd"
    }

    private fun toMuxerFormat(format: MediaFormat): Format {
        val converted = MediaFormatUtil.createFormatFromMediaFormat(format)
        if (converted.sampleMimeType == "video/avc") {
            require(converted.initializationData.size >= 2 &&
                converted.initializationData.take(2).all { it.isNotEmpty() }) {
                "HLS 视频解码初始化信息缺失"
            }
        }
        if (converted.sampleMimeType in setOf("video/hevc", "audio/mp4a-latm")) {
            require(converted.initializationData.isNotEmpty() && converted.initializationData.all { it.isNotEmpty() }) {
                "HLS 音视频解码初始化信息缺失"
            }
        }
        return converted
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
            if (line.startsWith("#EXT-X-DISCONTINUITY")) {
                error("暂不支持含 discontinuity 的 HLS 清单导出")
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
            require(durationUs > 0L) { "HLS 分片时长无效" }
            result += HlsSegment(
                file = localResource(base, line, "HLS 输入分片"),
                key = keyFile,
                explicitIv = explicitIv,
                sequence = sequence++,
                init = initFile,
                durationUs = durationUs,
            )
            durationUs = 0L
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

    private fun validateOutput(path: String, expectedCounts: Map<String, Int>? = null): Boolean {
        val file = File(path).canonicalFile
        if (!file.isFile || file.length() <= 0L) return false
        require(nativeValidatePath(file.path, filesRoot.path)) { "输出路径越界" }
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            val tracks = (0 until extractor.trackCount).mapNotNull { index ->
                val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true || mime?.startsWith("video/") == true) index else null
            }
            if (tracks.isEmpty()) return false
            tracks.forEach(extractor::selectTrack)
            var samples = 0
            val sampleCounts = mutableMapOf<Int, Int>()
            while (extractor.sampleTrackIndex >= 0) {
                val track = extractor.sampleTrackIndex
                if (extractor.sampleSize <= 0L) return false
                sampleCounts[track] = (sampleCounts[track] ?: 0) + 1
                samples++
                extractor.advance()
                if (samples > 10_000_000) return false
            }
            samples > 0 && sampleCounts.keys.containsAll(tracks) && (expectedCounts == null || tracks.all { index ->
                val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME) ?: return@all false
                sampleCounts[index] == expectedCounts[mediaTrackKind(mime)]
            })
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
        if (!context.contentResolver.persistedUriPermissions.any { it.uri == directory && it.isWritePermission && it.isReadPermission }) {
            throw SecurityException("保存目录权限已失效，请在媒体管理中重新选择 MP4 保存目录")
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

    private fun delete(source: String, allowMissing: Boolean = false) {
        val uri = Uri.parse(source)
        if (uri.scheme == "content") {
            try {
                if (!DocumentsContract.deleteDocument(context.contentResolver, uri)) {
                    val missing = allowMissing && context.contentResolver.query(
                        uri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null,
                    )?.use { !it.moveToFirst() } == true
                    check(missing) { "无法删除媒体文件" }
                }
            } catch (error: Exception) {
                if (!allowMissing || MediaFileErrors.code(error) != "media_file_missing") throw error
            }
        } else {
            require(uri.scheme == null || uri.scheme == "file") { "仅允许本地媒体文件" }
            val path = if (uri.scheme == "file") uri.path!! else source
            val file = validateLocalPath(path)
            if (allowMissing && !file.exists()) return
            require(file.isFile) { "本地媒体文件不存在" }
            check(file.delete()) { "无法删除媒体文件" }
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

    /** Readability is required for delivery; thumbnails and codecs are not. */
    private fun stat(source: String): Map<String, Any?> {
        val uri = Uri.parse(source)
        if (uri.scheme == "content") {
            var size = -1L
            var modified = 0L
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { asset ->
                size = asset.length
                require(asset.createInputStream().use { it.read() } >= 0) { "媒体文件为空" }
            } ?: throw FileNotFoundException("媒体文件不存在")
            runCatching {
                context.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use {
                    if (it.moveToFirst()) {
                        if (!it.isNull(0)) size = it.getLong(0)
                        if (!it.isNull(1)) modified = it.getLong(1)
                    }
                }
            }
            return mapOf("size" to size, "modifiedMs" to modified)
        }
        require(uri.scheme == null || uri.scheme == "file") { "仅允许本地媒体文件" }
        val path = if (uri.scheme == "file") uri.path ?: error("媒体路径无效") else source
        val file = validateLocalPath(path)
        if (!file.isFile) throw FileNotFoundException("媒体文件不存在")
        require(file.length() > 0L) { "媒体文件为空" }
        file.inputStream().use { require(it.read() >= 0) { "媒体文件为空" } }
        return mapOf("size" to file.length(), "modifiedMs" to file.lastModified())
    }

    private fun scanMedia(directory: String?, cancelled: AtomicBoolean): Map<String, Any> {
        val grants = context.contentResolver.persistedUriPermissions.filter {
            it.isReadPermission && DocumentsContract.isTreeUri(it.uri)
        }
        val roots = if (directory.isNullOrBlank()) grants.map { it.uri }
        else {
            val tree = Uri.parse(directory)
            require(grants.any { it.uri == tree }) { "MP4 目录权限已失效，请重新选择保存目录" }
            listOf(tree)
        }
        val files = mutableListOf<Map<String, Any?>>()
        val warnings = mutableListOf<String>()
        val visited = mutableSetOf<String>()
        if (roots.isEmpty()) warnings += "未找到可读取的保存目录；请选择 MP4 保存目录后重新扫描"
        for (tree in roots) {
            val pending = java.util.ArrayDeque<Pair<String, String>>()
            pending.add(DocumentsContract.getTreeDocumentId(tree) to "")
            while (pending.isNotEmpty()) {
                check(!cancelled.get() && !disposed) { "扫描已取消" }
                val (parentId, folder) = pending.removeFirst()
                if (!visited.add("${tree.authority}/$parentId")) continue
                if (visited.size > 10_000 || files.size >= 10_000) {
                    warnings += "目录项目较多，请选择较小的媒体目录继续扫描"
                    pending.clear()
                    break
                }
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
                try {
                    context.contentResolver.query(children, arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                        DocumentsContract.Document.COLUMN_SIZE,
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    ), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            check(!cancelled.get() && !disposed) { "扫描已取消" }
                            val id = cursor.getString(0) ?: continue
                            val name = cursor.getString(1) ?: continue
                            val mime = cursor.getString(2)
                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                if (folder.count { it == '/' } < 16 && name != "materialized") {
                                    pending.add(id to if (folder.isEmpty()) name else "$folder/$name")
                                }
                                continue
                            }
                            if (!name.endsWith(".mp4", true)) continue
                            val document = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                            // Reading track headers rejects a still-empty or incomplete
                            // document. No MP4 copy, thumbnail, or network request is made.
                            val extractor = MediaExtractor()
                            try {
                                context.contentResolver.openAssetFileDescriptor(document, "r")?.use { asset ->
                                    if (asset.length >= 0) extractor.setDataSource(asset.fileDescriptor, asset.startOffset, asset.length)
                                    else extractor.setDataSource(asset.fileDescriptor)
                                    if ((0 until extractor.trackCount).none {
                                            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                                        }) continue
                                    files += mapOf(
                                        "uri" to document.toString(), "name" to name,
                                        "size" to if (cursor.isNull(3)) asset.length else cursor.getLong(3),
                                        "modifiedMs" to if (cursor.isNull(4)) 0L else cursor.getLong(4),
                                        "folder" to folder.ifEmpty { null },
                                    )
                                }
                            } catch (_: Exception) {
                                warnings += "部分 MP4 暂不可读，已保留现有索引"
                            } finally { extractor.release() }
                        }
                    }
                } catch (error: SecurityException) {
                    warnings += "部分目录读取权限已失效，请重新选择保存目录"
                } catch (error: Exception) {
                    check(!cancelled.get() && !disposed) { "扫描已取消" }
                    warnings += "部分目录暂不可读，已保留现有索引"
                }
            }
        }
        return mapOf("files" to files, "warnings" to warnings.distinct())
    }

    private fun inspect(source: String): Map<String, Any?> {
        val metadata = stat(source).toMutableMap()
        val uri = Uri.parse(source)
        val path = if (uri.scheme == "file") uri.path!! else source
        var asset: android.content.res.AssetFileDescriptor? = null
        val reader = MediaMetadataRetriever()
        try {
            if (uri.scheme == "content") {
                asset = context.contentResolver.openAssetFileDescriptor(uri, "r")
                    ?: throw FileNotFoundException("媒体文件不存在")
                if (asset!!.length >= 0) reader.setDataSource(asset!!.fileDescriptor, asset!!.startOffset, asset!!.length)
                else reader.setDataSource(asset!!.fileDescriptor)
            } else reader.setDataSource(path)
            fun metadataValue(key: Int) = runCatching { reader.extractMetadata(key) }.getOrNull()
            metadata["durationMs"] = metadataValue(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            metadata["width"] = metadataValue(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            metadata["height"] = metadataValue(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            metadata["mime"] = metadataValue(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            val key = MessageDigest.getInstance("SHA-256").digest("$source:${metadata["size"]}:${metadata["modifiedMs"]}".toByteArray()).joinToString("") { "%02x".format(it) }
            val thumbnail = File(File(filesRoot, "media_thumbnails").apply { mkdirs() }, "$key.jpg")
            if (!thumbnail.isFile) runCatching {
                val frame = if (Build.VERSION.SDK_INT >= 27) reader.getScaledFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 320, 180) else reader.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                frame?.let { bitmap ->
                    val scaled = Bitmap.createScaledBitmap(bitmap, 320, 180, true)
                    try { thumbnail.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 80, it) } }
                    finally { if (scaled !== bitmap) scaled.recycle(); bitmap.recycle() }
                }
            }
            metadata["thumbnailPath"] = thumbnail.takeIf { it.isFile && it.length() > 0L }?.path
        } catch (_: Exception) {
            // A provider/codec failure does not make readable bytes invalid.
        } finally {
            runCatching { reader.release() }
            runCatching { asset?.close() }
        }
        if (metadata["durationMs"] == null || metadata["width"] == null || metadata["mime"] == null) {
            var extractor: MediaExtractor? = null
            var extractorAsset: android.content.res.AssetFileDescriptor? = null
            try {
                val reader = MediaExtractor()
                extractor = reader
                if (uri.scheme == "content") {
                    extractorAsset = context.contentResolver.openAssetFileDescriptor(uri, "r")
                        ?: throw FileNotFoundException("媒体文件不存在")
                    if (extractorAsset!!.length >= 0) reader.setDataSource(extractorAsset!!.fileDescriptor, extractorAsset!!.startOffset, extractorAsset!!.length)
                    else reader.setDataSource(extractorAsset!!.fileDescriptor)
                } else reader.setDataSource(path)
                var duration = 0L
                for (index in 0 until reader.trackCount) {
                    val format = reader.getTrackFormat(index)
                    if (format.containsKey(MediaFormat.KEY_DURATION)) duration = maxOf(duration, format.getLong(MediaFormat.KEY_DURATION))
                    if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        if (metadata["width"] == null && format.containsKey(MediaFormat.KEY_WIDTH)) metadata["width"] = format.getInteger(MediaFormat.KEY_WIDTH)
                        if (metadata["height"] == null && format.containsKey(MediaFormat.KEY_HEIGHT)) metadata["height"] = format.getInteger(MediaFormat.KEY_HEIGHT)
                    }
                }
                if (metadata["durationMs"] == null && duration > 0) metadata["durationMs"] = duration / 1000
            } catch (_: Exception) {
                // Preserve basic file facts and the caller's known metadata.
            } finally {
                runCatching { extractor?.release() }
                runCatching { extractorAsset?.close() }
            }
        }
        return metadata
    }
}
