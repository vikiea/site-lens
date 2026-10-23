package dev.vikiea.site_lens

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.media.MediaFormat
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.TimestampAdjuster
import androidx.media3.common.util.MediaFormatUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.ContentDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.inspector.MediaExtractorCompat
import androidx.media3.inspector.MetadataRetriever
import androidx.media3.inspector.frame.FrameExtractor
import androidx.media3.transformer.Codec
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.DefaultMuxer
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ExoPlayerAssetLoader
import androidx.media3.transformer.Transformer
import androidx.media3.common.util.Clock
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import java.io.File
import java.io.Closeable
import java.io.FileNotFoundException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Local Media3 inspection/remux and verified SAF delivery. JNI only validates
 * canonical paths; no command line, network data source or encoder is exposed. */
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
        private const val MAX_MEDIA_SAMPLES = 2_000_000
        private const val MAX_SAMPLE_BYTES = 32 * 1024 * 1024
        private const val REPORTED_SAMPLES = 512
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
        val supported = setOf("validateLocalInput", "muxHls", "validateOutput", "deliver", "deliverToDirectory", "stat", "inspect", "inspectSamples", "scanMedia", "materialize", "rename", "move", "delete", "deleteOwnedSources", "copyVerified")
        if (call.method !in supported) { result.notImplemented(); return }
        val jobId = call.argument<String>("jobId") ?: "job-${System.nanoTime()}"
        val cancellation = AtomicBoolean(false)
        cancellations[jobId] = cancellation
        if (cancelledJobs.remove(jobId)) cancellation.set(true)
        worker.execute {
            if (disposed) {
                cancellations.remove(jobId)
                main.post { result.error("media_export", "媒体服务已关闭", null) }
                return@execute
            }
            activeCancellation = cancellation
            try {
                check(!cancellation.get()) { "导出已取消" }
                val value = NativeMediaFileLeases.registry.acquireRead(readScope(call)).use {
                    NativeMediaFileLeases.registry.mutate(mutationScope(call)) {
                        execute(call, cancellation)
                    }
                }
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { fail(call, result, error) }
            } finally {
                activeCancellation = null
                cancellations.remove(jobId)
            }
        }
    }

    private fun readScope(call: MethodCall): MediaFileLeaseRegistry.Scope {
        val raw = when (call.method) {
            "deliver", "deliverToDirectory", "inspect", "inspectSamples", "stat", "materialize" -> call.argument<String>("source")
            "validateOutput" -> call.argument<String>("path")
            "validateLocalInput", "muxHls" -> {
                val path = call.argument<String>(if (call.method == "muxHls") "playlist" else "path")
                    ?: return MediaFileLeaseRegistry.Scope()
                return MediaFileLeaseRegistry.Scope.file(File(path).canonicalFile.parentFile!!)
            }
            else -> null
        }
        return raw?.let(MediaFileLeaseRegistry.Scope::source) ?: MediaFileLeaseRegistry.Scope()
    }

    private fun mutationScope(call: MethodCall): MediaFileLeaseRegistry.Scope {
        fun source(name: String) = call.argument<String>(name)?.let(MediaFileLeaseRegistry.Scope::source)
            ?: MediaFileLeaseRegistry.Scope()
        return when (call.method) {
            "delete" -> source("source")
            "move" -> {
                val rawDirectory = call.argument<String>("directory").orEmpty()
                val uri = Uri.parse(rawDirectory)
                if (uri.scheme == "content") source("source") else {
                    val directory = File(if (uri.scheme == "file") uri.path!! else rawDirectory)
                    val target = File(directory, call.argument<String>("fileName").orEmpty())
                    source("source") + MediaFileLeaseRegistry.Scope.file(target) +
                        MediaFileLeaseRegistry.Scope.file(File(target.path + ".part"))
                }
            }
            "deleteOwnedSources" -> {
                val taskId = call.argument<String>("taskId")?.takeIf { it.isNotBlank() } ?: error("缺少媒体身份")
                ownedSources(call).fold(MediaFileLeaseRegistry.Scope.task(taskId)) { scope, raw ->
                    scope + MediaFileLeaseRegistry.Scope.source(raw)
                }
            }
            "copyVerified" -> source("destination") +
                MediaFileLeaseRegistry.Scope.source(call.argument<String>("destination").orEmpty() + ".part")
            "rename" -> {
                val original = source("source")
                val raw = call.argument<String>("source").orEmpty()
                val uri = Uri.parse(raw)
                if (uri.scheme == "content") original else {
                    val file = File(if (uri.scheme == "file") uri.path!! else raw)
                    original + MediaFileLeaseRegistry.Scope.file(File(file.parentFile, call.argument<String>("fileName").orEmpty()))
                }
            }
            "deliver" -> source("destination")
            "muxHls" -> source("output") +
                MediaFileLeaseRegistry.Scope.source(call.argument<String>("output").orEmpty() + ".part") +
                MediaFileLeaseRegistry.Scope.source(call.argument<String>("output").orEmpty() + ".segments")
            "materialize" -> {
                val raw = call.argument<String>("source").orEmpty()
                if (Uri.parse(raw).scheme != "content") MediaFileLeaseRegistry.Scope() else {
                    val key = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
                    val base = File(filesRoot, "media_exports/materialized")
                    MediaFileLeaseRegistry.Scope.file(File(base, "$key.mp4")) +
                        MediaFileLeaseRegistry.Scope.file(File(base, "$key.part"))
                }
            }
            else -> MediaFileLeaseRegistry.Scope()
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
            "inspectSamples" -> inspectSamples(argument("source"))
            "scanMedia" -> scanMedia(call.argument<String>("directory"), cancellation)
            "materialize" -> materialize(argument("source"))
            "copyVerified" -> copyVerified(argument("source"), argument("destination"),
                reuseExistingVerified = call.argument<Boolean>("reuseExistingVerified") == true)
            "deleteOwnedSources" -> deleteOwnedSources(ownedSources(call))
            "rename" -> rename(argument("source"), argument("fileName"))
            "move" -> {
                val source = argument("source")
                val directory = Uri.parse(argument("directory"))
                val target = if (directory.scheme == "content") {
                    deliverToDirectory(source, directory, argument("fileName"))
                } else {
                    require(directory.scheme == null || directory.scheme == "file") { "移动目录无效" }
                    validateName(argument("fileName"))
                    val base = File(if (directory.scheme == "file") directory.path!! else argument("directory"))
                    copyVerified(source, File(base, argument("fileName")).path, sourceMutationHeld = true)
                }
                completeMediaMove(target, { delete(source) }, { delete(target, allowMissing = true) })
                target
            }
            "delete" -> { delete(argument("source"), call.argument<Boolean>("allowMissing") == true); null }
            else -> error("未知媒体操作")
        }
    }

    private fun ownedSources(call: MethodCall): List<String> =
        (call.argument<List<String>>("sources") ?: error("缺少媒体文件清单")).also {
            require(it.size <= 128 && it.distinct().size == it.size) { "媒体文件清单无效" }
        }

    private class PartialMediaDeletion(val deletedSources: List<String>, cause: Exception) : Exception(cause)

    private fun deleteOwnedSources(sources: List<String>): List<String> {
        // Validate every path before deleting the first. The outer reservation
        // already covers the complete set, including any later active reader.
        sources.forEach { source ->
            val uri = Uri.parse(source)
            if (uri.scheme != "content") {
                require(uri.scheme == null || uri.scheme == "file") { "仅允许本地媒体文件" }
                validateLocalPath(if (uri.scheme == "file") uri.path!! else source)
            }
        }
        val deleted = mutableListOf<String>()
        try {
            sources.forEach { source ->
                delete(source, allowMissing = true)
                deleted.add(source)
            }
        } catch (error: Exception) { throw PartialMediaDeletion(deleted.toList(), error) }
        return deleted
    }

    private fun fail(call: MethodCall, result: MethodChannel.Result, error: Exception) {
        val failure = if (error is PartialMediaDeletion) error.cause as Exception else error
        val code = if (error is MediaMoveRollbackFailure) "media_move_incomplete" else MediaFileErrors.code(failure) ?: "media_export"
        // Provider/Media3 exception text and cause stacks can embed private paths
        // or URIs. Persist only the exception type and a safe application message.
        val message = if ((failure is IllegalArgumentException || failure is IllegalStateException) &&
            failure.message?.any { it in '\u4e00'..'\u9fff' } == true &&
            failure.message?.none { it == '/' || it == '\\' || it == '\n' } == true) failure.message!! else "媒体操作失败"
        NativeCrashStore.append(context, module = "media.export", message = message,
            details = error.javaClass.simpleName, contextValue = "method=${call.method}")
        val details = when (error) {
            is PartialMediaDeletion -> mapOf("deletedSources" to error.deletedSources)
            is MediaMoveRollbackFailure -> mapOf("recoveryTarget" to error.target, "sourceRetained" to true, "rollbackFailed" to true)
            else -> null
        }
        result.error(code, message, details)
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
        require(isAppLocal(file)) { "输入路径越界" }
        return file
    }

    private fun isAppLocal(file: File): Boolean = listOfNotNull(
        filesRoot,
        context.getExternalFilesDir(null)?.canonicalFile,
    ).any { nativeValidatePath(file.path, it.path) }

    private fun checkActive(cancelled: AtomicBoolean) {
        check(!cancelled.get() && !disposed) { "导出已取消" }
    }

    private data class TrackSamples(
        val format: MediaFormat,
        val pts: MutableList<Long> = mutableListOf(),
        val sizes: MutableList<Int> = mutableListOf(),
        val allSizes: MutableList<Int> = mutableListOf(),
        val keyFrames: MutableList<Int> = mutableListOf(),
        var hasAdtsHeader: Boolean = false,
    )

    private fun TrackSamples.trace(kind: String): Media3SampleTrace = Media3SampleTrace(
        kind = kind,
        formatSignature = mediaFormatSignature(format),
        presentationTimesUs = pts.toList(),
        sampleSizes = allSizes.toList(),
        keyFrameSampleIndices = keyFrames.toList(),
    )

    private fun muxHls(playlistPath: String, outputPath: String, cancelled: AtomicBoolean) {
        validateLocal(playlistPath)
        val output = File(outputPath).canonicalFile
        require(nativeValidatePath(output.path, filesRoot.path)) { "输出路径越界" }
        val segments = parseHlsSegments(playlistPath)
        require(segments.isNotEmpty()) { "HLS 清单没有媒体分片" }
        require(output != File(playlistPath).canonicalFile && segments.none {
            output == it.file || output == it.key || output == it.init || output == it.initKey
        }) { "输出路径与输入冲突" }
        output.parentFile?.mkdirs()
        val temp = File("${output.path}.part")
        val workDir = File("${output.path}.segments")
        require(temp.canonicalFile == temp && workDir.canonicalFile == workDir) { "临时路径不能使用符号链接" }
        val resources = segments.flatMap { listOfNotNull(it.file, it.key, it.init, it.initKey) } + File(playlistPath).canonicalFile
        require(resources.none { it == temp || it == workDir || it.path.startsWith(workDir.path + File.separator) }) {
            "输入路径与临时目录冲突"
        }
        if (temp.exists()) check(temp.delete()) { "无法清理临时导出文件" }
        if (workDir.exists()) check(workDir.deleteRecursively()) { "无法清理临时分片" }
        check(workDir.mkdirs()) { "无法创建临时分片目录" }
        try {
            // Decrypted/concatenated copies are only for strict preflight. Transformer
            // reads the original local HLS, including AES keys and EXT-X-MAP, itself.
            val prepared = segments.mapIndexed { index, segment ->
                checkActive(cancelled)
                prepareSegment(segment, workDir, index)
            }
            // One no-offset adjuster for the whole input, never one zero-based
            // adjuster per segment. It also unwraps the 33-bit MPEG clock.
            val sharedTsAdjuster = TimestampAdjuster(TimestampAdjuster.MODE_NO_OFFSET)
            val inputExtractors = createSharedTsExtractorsFactory(sharedTsAdjuster)
            var totalInputSamples = 0L
            val inputSamples = prepared.map { input ->
                readSamples(Uri.fromFile(input), cancelled, extractorsFactory = inputExtractors).also { tracks ->
                    require(tracks.containsKey("video")) { "HLS 分片缺少视频轨道" }
                    tracks.forEach { (kind, samples) ->
                        require(samples.pts.isNotEmpty()) { "HLS 分片存在空音视频轨道" }
                        validateTrackFormat(samples.format)
                        require(kind != "video" || samples.keyFrames.firstOrNull() == 0) {
                            "HLS 分片不是从视频关键帧开始"
                        }
                        require(kind != "audio" || samples.pts.asSequence().zipWithNext().all { (a, b) -> b > a }) {
                            "HLS 音频轨道时间顺序无效"
                        }
                        totalInputSamples += samples.pts.size
                    }
                    require(totalInputSamples <= MAX_MEDIA_SAMPLES) { "HLS 样本数量过大" }
                }
            }
            val inputTimeline = Media3ExportValidation.mergeInputSegments(inputSamples.map { tracks ->
                tracks.mapValues { (kind, samples) -> samples.trace(kind) }
            })
            val inputCounts = inputTimeline.mapValues { it.value.presentationTimesUs.size }
            val audioSegments = inputSamples.count { it.containsKey("audio") }
            require(audioSegments == 0 || audioSegments == prepared.size) {
                "HLS 音频轨道只覆盖部分分片，无法生成连续有声 MP4"
            }
            val normalized = writeTransformerPlaylist(segments, workDir)
            val allowed = (segments.flatMap { listOfNotNull(it.file, it.key, it.init, it.initKey) } + normalized)
                .map { it.canonicalPath }.toSet()
            val export = transformHls(normalized, temp, allowed, cancelled, inputTimeline)
            require(export.videoConversionProcess == ExportResult.CONVERSION_PROCESS_TRANSMUXED &&
                export.audioConversionProcess == if (audioSegments == 0) ExportResult.CONVERSION_PROCESS_NA
                    else ExportResult.CONVERSION_PROCESS_TRANSMUXED) { "HLS 导出不允许转码" }
            require(export.audioEncoderName == null && export.videoEncoderName == null) { "HLS 导出不允许编码器" }
            checkActive(cancelled)
            require(temp.isFile && temp.length() > 0) { "导出文件为空" }
            val outputSamples = readSamples(Uri.fromFile(temp), cancelled)
            require(outputSamples.keys == inputCounts.keys && outputSamples.all { (kind, track) ->
                track.pts.size == inputCounts[kind]
            }) {
                "导出文件音视频样本不完整 " +
                    "expected=${inputCounts.toSortedMap()} actual=${outputSamples.mapValues { it.value.pts.size }.toSortedMap()}"
            }
            validateSampleParity(inputSamples, outputSamples)
            require(validateOutput(temp.path, inputCounts)) { "导出文件音视频样本不完整" }
            checkActive(cancelled)
            // renameTo replaces the previous app-local file atomically on Android.
            check(temp.renameTo(output)) { "无法提交导出文件" }
        } finally {
            // transformHls returns only after completion/error or synchronous cancel
            // has released its writer. No reader/writer can outlive these files/lease.
            if (temp.exists()) temp.delete()
            workDir.deleteRecursively()
        }
    }

    private fun validateSampleParity(
        inputs: List<Map<String, TrackSamples>>,
        output: Map<String, TrackSamples>,
    ) {
        val expected = Media3ExportValidation.mergeInputSegments(inputs.map { tracks ->
            tracks.mapValues { (kind, samples) -> samples.trace(kind) }
        })
        val actual = output.mapValues { (kind, samples) -> samples.trace(kind) }
        Media3ExportValidation.validateParity(expected, actual)
    }

    /** No default/HTTP data source is reachable from this factory, even on a
     * secondary playlist/key/init request. Canonical allow-list checks are repeated
     * at open, so an input symlink cannot redirect the loader out of its lease. */
    private fun localDataSources(allowed: Set<String>): DataSource.Factory = DataSource.Factory {
        val fileSource = FileDataSource()
        object : DataSource by fileSource {
            override fun open(dataSpec: DataSpec): Long {
                val uri = dataSpec.uri
                require((uri.scheme == "file" || uri.scheme == null) && uri.authority.isNullOrEmpty() &&
                    uri.query == null && uri.fragment == null) { "HLS 仅允许本地文件" }
                val file = File(uri.path ?: error("HLS 本地地址无效")).canonicalFile
                require(file.path in allowed && isAppLocal(file) && file.isFile) {
                    "HLS 输入缺失或越界"
                }
                return fileSource.open(dataSpec.withUri(Uri.fromFile(file)))
            }
        }
    }

    private fun transformHls(
        playlist: File, output: File, allowed: Set<String>, cancelled: AtomicBoolean,
        inputTimeline: Map<String, Media3SampleTrace>,
    ): ExportResult {
        val thread = HandlerThread("site-lens-transformer").apply { start() }
        val handler = Handler(thread.looper)
        val settled = CountDownLatch(1)
        val terminal = AtomicBoolean(false)
        val export = AtomicReference<ExportResult?>(null)
        val failure = AtomicReference<Exception?>(null)
        var transformer: Transformer? = null // Accessed only on application Looper.
        fun finish(value: ExportResult? = null, error: Exception? = null) {
            if (terminal.compareAndSet(false, true)) {
                export.set(value)
                failure.set(error)
                settled.countDown()
            }
        }
        handler.post {
            try {
                checkActive(cancelled)
                val sources = HlsMediaSource.Factory(localDataSources(allowed))
                    .setExtractorFactory(createCompleteHlsExtractorFactory(
                        inputTimeline.values.minOf { it.presentationTimesUs.min() }))
                val encoders = object : Codec.EncoderFactory {
                    override fun createForAudioEncoding(format: Format, logSessionId: android.media.metrics.LogSessionId?): Codec =
                        throw ExportException.createForUnexpected(IllegalStateException("HLS 导出禁止音频转码"))
                    override fun createForVideoEncoding(format: Format, logSessionId: android.media.metrics.LogSessionId?): Codec =
                        throw ExportException.createForUnexpected(IllegalStateException("HLS 导出禁止视频转码"))
                }
                val created = Transformer.Builder(context)
                    .setLooper(thread.looper)
                    .setUsePlatformDiagnostics(false)
                    .setAssetLoaderFactory(ExoPlayerAssetLoader.Factory(
                        context, DefaultDecoderFactory.Builder(context).build(), Clock.DEFAULT, sources))
                    .setEncoderFactory(encoders)
                    .setMuxerFactory(PreserveFirstVideoPtsMuxerFactory(DefaultMuxer.Factory(), inputTimeline))
                    .setEnsureFileStartsOnVideoFrameEnabled(false)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) { finish(value = result) }
                        override fun onError(composition: Composition, result: ExportResult, exception: ExportException) {
                            finish(error = IllegalStateException("Media3 HLS 导出失败 (${exception.errorCode})"))
                        }
                    }).build()
                transformer = created
                val item = EditedMediaItem.Builder(androidx.media3.common.MediaItem.Builder()
                    .setUri(Uri.fromFile(playlist)).setMimeType("application/x-mpegURL").build()).build()
                val composition = Composition.Builder(EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item)))
                    .setTransmuxAudio(true).setTransmuxVideo(true).build()
                created.start(composition, output.path)
            } catch (error: Exception) {
                // start() can fail after acquiring resources; cancel on the same
                // application Looper before notifying the worker to release files.
                runCatching { transformer?.cancel() }
                finish(error = error)
            }
        }
        var cancelPosted = false
        var interrupted = false
        try {
            while (true) {
                try { if (settled.await(50, TimeUnit.MILLISECONDS)) break }
                catch (_: InterruptedException) { interrupted = true; cancelled.set(true) }
                if ((cancelled.get() || disposed) && !cancelPosted) {
                    cancelPosted = true
                    handler.post {
                        if (!terminal.get()) {
                            // cancel() suppresses completion callbacks. Its return is
                            // the release barrier; explicitly terminalize afterwards.
                            val cancelError = runCatching { transformer?.cancel() }.exceptionOrNull()
                            finish(error = IllegalStateException(if (cancelError == null) "导出已取消" else "导出取消清理失败"))
                        }
                    }
                }
            }
        } finally {
            thread.quitSafely()
            if (interrupted) Thread.currentThread().interrupt()
        }
        failure.get()?.let { throw it }
        checkActive(cancelled)
        return export.get() ?: error("Media3 导出没有结果")
    }

    private fun writeTransformerPlaylist(segments: List<HlsSegment>, workDir: File): File {
        fun key(file: File?, iv: ByteArray?): String = if (file == null) "#EXT-X-KEY:METHOD=NONE"
            else "#EXT-X-KEY:METHOD=AES-128,URI=\"${Uri.fromFile(file)}\",IV=0x${iv!!.toHex()}"
        val normalized = File(workDir, "input.m3u8")
        normalized.writeText(buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-VERSION:7")
            appendLine("#EXT-X-PLAYLIST-TYPE:VOD")
            appendLine("#EXT-X-TARGETDURATION:${(segments.maxOf { it.durationUs } + 999_999L) / 1_000_000L}")
            segments.forEach { segment ->
                if (segment.init != null) {
                    appendLine(key(segment.initKey, segment.initIv))
                    appendLine("#EXT-X-MAP:URI=\"${Uri.fromFile(segment.init)}\"")
                }
                // Normalize tolerated legacy METHOD-less/single-quote/semicolon
                // syntax before the strict official HLS parser sees it.
                appendLine(key(segment.key, segment.explicitIv ?: sequenceIv(segment.sequence)))
                appendLine("#EXTINF:${java.lang.String.format(java.util.Locale.ROOT, "%.6f", segment.durationUs / 1_000_000.0)},")
                appendLine(Uri.fromFile(segment.file).toString())
            }
            appendLine("#EXT-X-ENDLIST")
        })
        return normalized
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
            MediaFormat.KEY_SAMPLE_RATE,
            MediaFormat.KEY_CHANNEL_COUNT,
            MediaFormat.KEY_ROTATION,
        )
        val values = integerKeys.joinToString("|") { key ->
            val value = runCatching {
                if (format.containsKey(key)) format.getInteger(key).toString()
                else if (key == MediaFormat.KEY_ROTATION) "0" else ""
            }.getOrDefault("")
            "$key=$value"
        }
        val csd = listOf("csd-0", "csd-1").joinToString("|") { key ->
            val buffer = format.getByteBuffer(key)?.duplicate() ?: return@joinToString "$key="
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            val identity = if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true)
                Media3ExportValidation.canonicalVideoCsd(bytes)
            else bytes.joinToString("") { byte -> "%02x".format(byte) }
            "$key=$identity"
        }
        return "${format.getString(MediaFormat.KEY_MIME)}|$values|$csd"
    }

    private fun validateTrackFormat(format: MediaFormat) {
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
    }

    private data class HlsSegment(
        val file: File,
        val key: File?,
        val explicitIv: ByteArray?,
        val sequence: Long,
        val init: File?,
        val initKey: File?,
        val initIv: ByteArray?,
        val durationUs: Long,
    )

    private fun parseHlsSegments(playlistPath: String): List<HlsSegment> {
        val playlist = File(playlistPath).canonicalFile
        val base = playlist.parentFile ?: error("HLS 清单目录无效")
        var sequence = 0L
        var keyFile: File? = null
        var explicitIv: ByteArray? = null
        var initFile: File? = null
        var initKey: File? = null
        var initIv: ByteArray? = null
        var durationUs = 0L
        val result = mutableListOf<HlsSegment>()
        for (raw in playlist.readLines(Charsets.UTF_8)) {
            val line = raw.trim()
            require(!line.startsWith("#EXT-X-BYTERANGE") && !line.startsWith("#EXT-X-STREAM-INF") &&
                !line.startsWith("#EXT-X-I-FRAMES-ONLY") && !line.startsWith("#EXT-X-GAP")) {
                "暂不支持该 HLS 清单布局"
            }
            if (line.startsWith("#EXTINF:")) {
                durationUs = ((line.substringAfter(':').substringBefore(',').toDoubleOrNull() ?: 0.0) * 1_000_000).toLong().coerceAtLeast(0L)
                continue
            }
            if (line.startsWith("#EXT-X-MEDIA-SEQUENCE:")) {
                sequence = line.substringAfter(':').trim().toLongOrNull()
                    ?: error("HLS 序列号无效")
                require(sequence >= 0) { "HLS 序列号无效" }
                continue
            }
            if (line.startsWith("#EXT-X-DISCONTINUITY")) {
                error("暂不支持含 discontinuity 的 HLS 清单导出")
            }
            if (line.startsWith("#EXT-X-KEY:")) {
                require(attribute(line, "KEYFORMAT").let { it == null || it == "identity" }) { "暂不支持该 HLS 密钥格式" }
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
                require(attribute(line, "BYTERANGE") == null) { "暂不支持 HLS 初始化分片字节范围" }
                val rawInit = attribute(line, "URI") ?: error("HLS 初始化分片地址缺失")
                initFile = localResource(base, rawInit, "HLS 初始化分片")
                initKey = keyFile
                initIv = explicitIv
                require(initKey == null || initIv != null) { "HLS 加密初始化分片必须指定 IV" }
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
                initKey = initKey,
                initIv = initIv,
                durationUs = durationUs,
            )
            durationUs = 0L
        }
        return result
    }

    private fun localResource(base: File, raw: String, label: String): File {
        val value = raw.trim().removeSurrounding("\"")
        val uri = Uri.parse(value)
        require(uri.scheme == null && uri.authority == null && uri.query == null && uri.fragment == null &&
            !File(value).isAbsolute) { "${label}必须是本地相对路径" }
        val file = File(base, value).canonicalFile
        require(nativeValidatePath(file.path, base.canonicalPath) && isAppLocal(file) && file.isFile) {
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
            if (segment.initKey == null) segment.init.inputStream().use { it.copyTo(stream) }
            else {
                val key = segment.initKey.readBytes()
                require(key.size == 16) { "HLS AES-128 密钥长度无效" }
                val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(segment.initIv!!))
                stream.write(cipher.doFinal(segment.init.readBytes()))
            }
            stream.write(segmentBytes)
        }
        return output
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private fun localMediaUri(source: String): Uri {
        val uri = Uri.parse(source)
        require(uri.scheme == null || uri.scheme == "file" || uri.scheme == "content") { "仅允许本地媒体文件" }
        if (uri.scheme == "content") return uri
        require(uri.authority.isNullOrEmpty() && uri.query == null && uri.fragment == null) { "媒体路径无效" }
        return Uri.fromFile(validateLocalPath(if (uri.scheme == "file") uri.path ?: error("媒体路径无效") else source))
    }

    /** Inspector can read the selected SAF document, but neither nested playlists
     * nor unexpected network resources get a default data source. */
    private fun inspectorDataSources(uri: Uri): DataSource.Factory = DataSource.Factory {
        val source: DataSource = if (uri.scheme == "content") ContentDataSource(context) else FileDataSource()
        object : DataSource by source {
            override fun open(dataSpec: DataSpec): Long {
                require(dataSpec.uri == uri) { "媒体检查不允许读取其他资源" }
                if (uri.scheme == "file") validateLocalPath(uri.path ?: error("媒体路径无效"))
                return source.open(dataSpec)
            }
        }
    }

    private fun readSamples(
        uri: Uri,
        cancelled: AtomicBoolean,
        strict: Boolean = true,
        extractorsFactory: androidx.media3.extractor.ExtractorsFactory = androidx.media3.extractor.DefaultExtractorsFactory(),
    ): Map<String, TrackSamples> {
        val failure = StickyMediaFailure()
        val reader = createLatchingMediaExtractor(extractorsFactory, inspectorDataSources(uri), failure)
        try {
            reader.setDataSource(uri, 0L)
            failure.throwIfFailed()
            val tracks = linkedMapOf<String, TrackSamples>()
            val byIndex = mutableMapOf<Int, TrackSamples>()
            val signatures = mutableMapOf<Int, String>()
            for (index in 0 until reader.trackCount) {
                val format = reader.getTrackFormat(index)
                val kind = mediaTrackKind(format.getString(MediaFormat.KEY_MIME) ?: continue) ?: continue
                require(!strict || kind !in tracks) { "媒体包含多个同类音视频轨道" }
                val track = TrackSamples(format)
                tracks[if (strict) kind else "$kind-$index"] = track
                byIndex[index] = track
                signatures[index] = mediaFormatSignature(format)
                reader.selectTrack(index)
            }
            var buffer = ByteBuffer.allocateDirect(1024 * 1024)
            var samples = 0
            while (true) {
                checkActive(cancelled)
                failure.throwIfFailed()
                val sampleTrackIndex = reader.sampleTrackIndex
                failure.throwIfFailed()
                if (sampleTrackIndex < 0) break
                require(++samples <= MAX_MEDIA_SAMPLES) { "媒体样本数量过大" }
                val index = sampleTrackIndex
                val track = byIndex[index] ?: error("媒体样本轨道无效")
                val required = reader.sampleSize
                require(required in 1..MAX_SAMPLE_BYTES.toLong()) { "媒体样本大小无效" }
                if (required > buffer.capacity()) buffer = ByteBuffer.allocateDirect(required.toInt())
                buffer.clear()
                val size = reader.readSampleData(buffer, 0)
                failure.throwIfFailed()
                require(size > 0 && size.toLong() == required) { "媒体样本读取不完整" }
                val format = reader.getTrackFormat(index)
                require(mediaFormatSignature(format) == signatures[index]) { "媒体轨道格式发生变化" }
                if (reader.sampleFlags and C.BUFFER_FLAG_KEY_FRAME != 0) {
                    track.keyFrames += track.pts.size
                }
                track.pts += reader.sampleTime
                track.allSizes += size
                if (track.sizes.size < REPORTED_SAMPLES) track.sizes += size
                if (format.getString(MediaFormat.KEY_MIME) == "audio/mp4a-latm") {
                    buffer.position(0)
                    buffer.limit(size)
                    val adts = size >= 2 && (buffer.get(0).toInt() and 0xff) == 0xff &&
                        (buffer.get(1).toInt() and 0xf6) == 0xf0
                    track.hasAdtsHeader = track.hasAdtsHeader || adts
                    if (strict) {
                        val config = format.getByteBuffer("csd-0")?.duplicate() ?: error("AAC 解码初始化信息缺失")
                        val bytes = ByteArray(config.remaining()).also { config.get(it) }
                        // Compat's AdtsReader already strips ADTS and emits one AU.
                        // Validate ASC/rate/channels; never split/retime its raw samples.
                        require(!adts && AacAccessUnits.split(buffer, format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                            format.getInteger(MediaFormat.KEY_CHANNEL_COUNT), bytes).size == 1) { "AAC 样本不是单个原始访问单元" }
                    }
                }
                reader.advance()
                failure.throwIfFailed()
            }
            failure.throwIfFailed() // Includes errors that advance() reports as EOF.
            checkActive(cancelled)
            return tracks
        } finally {
            reader.release()
            failure.throwIfFailed()
        }
    }

    /** Bounded, read-only acceptance helper; no source path is returned. */
    private fun inspectSamples(source: String): Map<String, Any?> {
        stat(source)
        val tracks = readSamples(localMediaUri(source), activeCancellation ?: AtomicBoolean(false), strict = false)
        return mapOf("tracks" to tracks.values.map { track ->
            val format = track.format
            fun integer(key: String): Int? = if (format.containsKey(key)) format.getInteger(key) else null
            val csd = (0..2).mapNotNull { index ->
                val key = "csd-$index"
                val bytes = format.getByteBuffer(key)?.duplicate() ?: return@mapNotNull null
                key to ByteArray(bytes.remaining()).also { bytes.get(it) }.toHex()
            }.toMap()
            mapOf(
                "mime" to format.getString(MediaFormat.KEY_MIME),
                "sampleCount" to track.pts.size,
                "sampleRate" to integer(MediaFormat.KEY_SAMPLE_RATE),
                "channelCount" to integer(MediaFormat.KEY_CHANNEL_COUNT),
                "width" to integer(MediaFormat.KEY_WIDTH), "height" to integer(MediaFormat.KEY_HEIGHT),
                "csd" to csd,
                "presentationTimesUs" to track.pts.take(REPORTED_SAMPLES),
                "sampleSizes" to track.sizes,
                "durationUs" to if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else null,
                "keyFrameSampleIndices" to track.keyFrames.filter { it < REPORTED_SAMPLES },
                "hasAdtsHeader" to track.hasAdtsHeader,
                "reportedSamplesTruncated" to (track.pts.size > REPORTED_SAMPLES),
            )
        }, "maxScannedSamples" to MAX_MEDIA_SAMPLES)
    }

    private fun validateOutput(path: String, expectedCounts: Map<String, Int>? = null): Boolean {
        val file = File(path).canonicalFile
        if (!file.isFile || file.length() <= 0L) return false
        require(nativeValidatePath(file.path, filesRoot.path)) { "输出路径越界" }
        val cancelled = activeCancellation ?: error("输出检查缺少任务所有权")
        checkActive(cancelled)
        val container = Media3ExportValidation.inspect(file) { checkActive(cancelled) }
        val tracks = readSamples(Uri.fromFile(file), cancelled)
        require(tracks.isNotEmpty() && tracks.keys == container.keys) { "MP4 轨道计数不完整" }
        tracks.forEach { (kind, samples) ->
            val table = container.getValue(kind)
            require(samples.pts.isNotEmpty() && samples.pts.size == table.sampleSizes.size &&
                samples.allSizes == table.sampleSizes) { "MP4 样本表与 Inspector 计数不一致" }
            if (expectedCounts != null) require(samples.pts.size == expectedCounts[kind]) { "MP4 输入输出样本计数不一致" }
            val durationUs = samples.format.takeIf { it.containsKey(MediaFormat.KEY_DURATION) }
                ?.getLong(MediaFormat.KEY_DURATION)
            require(durationUs == null || durationUs <= 0L ||
                kotlin.math.abs(durationUs - table.durationUs) <= 2_000_000L) {
                "MP4 轨道 duration 与容器表不一致"
            }
        }
        checkActive(cancelled)
        return expectedCounts == null || tracks.keys == expectedCounts.keys
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

    private fun copyVerified(source: String, destination: String, sourceMutationHeld: Boolean = false,
                             reuseExistingVerified: Boolean = false): String {
        val uri = Uri.parse(destination)
        require(uri.scheme == null || uri.scheme == "file") { "本地复制目标无效" }
        val target = validateLocalPath(if (uri.scheme == "file") uri.path!! else destination)
        val temporary = File(target.path + ".part")
        require(temporary.canonicalFile == temporary) { "临时文件不能使用符号链接" }
        val reader = if (sourceMutationHeld) Closeable {} else
            NativeMediaFileLeases.registry.acquireRead(MediaFileLeaseRegistry.Scope.source(source))
        return reader.use {
            if (reuseExistingVerified && verifyExistingMediaCopy(target, { sourceStream(source) }, {
                    check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                })) return@use target.path
            require(!target.exists()) { "目标目录存在同名文件" }
            require(!temporary.exists()) { "临时文件已存在，请先清理" }
            target.parentFile?.mkdirs()
            try {
                val expected = MessageDigest.getInstance("SHA-256")
                var bytes = 0L
                sourceStream(source).use { input -> temporary.outputStream().use { output ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        expected.update(buffer, 0, read)
                        bytes += read
                    }
                } }
                require(bytes > 0 && temporary.length() == bytes) { "复制文件校验失败" }
                val actual = MessageDigest.getInstance("SHA-256")
                temporary.inputStream().use { input ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                        val read = input.read(buffer)
                        if (read < 0) break
                        actual.update(buffer, 0, read)
                    }
                }
                require(actual.digest().contentEquals(expected.digest())) { "复制文件校验失败" }
                check(!disposed && activeCancellation?.get() != true) { "导出已取消" }
                check(!target.exists() && temporary.renameTo(target)) { "无法发布复制文件" }
                target.path
            } finally { if (temporary.exists()) temporary.delete() }
        }
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
                            val extractor = MediaExtractorCompat(context)
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

    private fun <T> awaitInspection(future: com.google.common.util.concurrent.ListenableFuture<T>): T {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        try {
            while (true) {
                checkActive(activeCancellation ?: AtomicBoolean(false))
                if (System.nanoTime() >= deadline) error("媒体检查超时")
                try { return future.get(50, TimeUnit.MILLISECONDS) }
                catch (_: java.util.concurrent.TimeoutException) { /* Check cancellation/deadline. */ }
            }
        } finally { if (!future.isDone) future.cancel(true) }
    }

    private fun inspect(source: String): Map<String, Any?> {
        val metadata = stat(source).toMutableMap()
        val uri = localMediaUri(source)
        val item = androidx.media3.common.MediaItem.fromUri(uri)
        val sources = DefaultMediaSourceFactory(inspectorDataSources(uri))
        try {
            MetadataRetriever.Builder(context, item).setMediaSourceFactory(sources).build().use { reader ->
                val groups = awaitInspection(reader.retrieveTrackGroups())
                val duration = awaitInspection(reader.retrieveDurationUs())
                if (duration != C.TIME_UNSET && duration >= 0) metadata["durationMs"] = duration / 1000L
                for (groupIndex in 0 until groups.length) {
                    val group = groups[groupIndex]
                    for (index in 0 until group.length) {
                        val format = group.getFormat(index)
                        if (format.sampleMimeType?.startsWith("video/") == true) {
                            if (format.width > 0) metadata["width"] = format.width
                            if (format.height > 0) metadata["height"] = format.height
                            metadata["mime"] = format.containerMimeType ?: format.sampleMimeType
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // Optional provider/codec metadata must not invalidate readable bytes.
        }
        if (metadata["durationMs"] == null || metadata["width"] == null || metadata["mime"] == null) {
            val reader = MediaExtractorCompat(androidx.media3.extractor.DefaultExtractorsFactory(), inspectorDataSources(uri))
            try {
                reader.setDataSource(uri, 0L)
                var durationUs = 0L
                for (index in 0 until reader.trackCount) {
                    val format = reader.getTrackFormat(index)
                    if (format.containsKey(MediaFormat.KEY_DURATION)) durationUs = maxOf(durationUs, format.getLong(MediaFormat.KEY_DURATION))
                    val mime = format.getString(MediaFormat.KEY_MIME)
                    if (mime?.startsWith("video/") == true) {
                        if (metadata["width"] == null && format.containsKey(MediaFormat.KEY_WIDTH)) metadata["width"] = format.getInteger(MediaFormat.KEY_WIDTH)
                        if (metadata["height"] == null && format.containsKey(MediaFormat.KEY_HEIGHT)) metadata["height"] = format.getInteger(MediaFormat.KEY_HEIGHT)
                        if (metadata["mime"] == null) metadata["mime"] = mime
                    }
                }
                if (metadata["durationMs"] == null && durationUs > 0) metadata["durationMs"] = durationUs / 1000L
            } catch (_: Exception) {
                // Keep basic file facts even when optional extraction fails.
            } finally { reader.release() }
        }
        val key = MessageDigest.getInstance("SHA-256").digest("$source:${metadata["size"]}:${metadata["modifiedMs"]}".toByteArray()).toHex()
        // The old cache forced every frame to 16:9. A new namespace makes
        // existing catalog entries regenerate their thumbnail on inspection.
        val thumbnail = File(File(filesRoot, "media_thumbnails").apply { mkdirs() }, "v2-$key.jpg")
        if (!thumbnail.isFile || thumbnail.length() == 0L) runCatching {
            FrameExtractor.Builder(context, item).setMediaSourceFactory(sources).build().use { reader ->
                val bitmap = awaitInspection(reader.getThumbnail()).bitmap
                val temporary = File(thumbnail.path + ".part")
                try {
                    val size = MediaThumbnailGeometry.fit(bitmap.width, bitmap.height)
                    val scaled = Bitmap.createScaledBitmap(bitmap, size.width, size.height, true)
                    try {
                        temporary.outputStream().use { check(scaled.compress(Bitmap.CompressFormat.JPEG, 80, it)) }
                        check(temporary.renameTo(thumbnail))
                    } finally { if (scaled !== bitmap) scaled.recycle() }
                } finally { bitmap.recycle(); temporary.delete() }
            }
        }
        metadata["thumbnailPath"] = thumbnail.takeIf { it.isFile && it.length() > 0 }?.path
        checkActive(activeCancellation ?: AtomicBoolean(false))
        return metadata
    }
}
