package dev.vikiea.site_lens

import androidx.media3.common.DataReader
import androidx.media3.common.Format
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.TimestampAdjuster
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.source.BundledExtractorsAdapter
import androidx.media3.exoplayer.source.ProgressiveMediaExtractor
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.mp4.FragmentedMp4Extractor
import androidx.media3.extractor.mp4.Track
import androidx.media3.extractor.text.SubtitleParser
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.extractor.ts.PesReader
import androidx.media3.extractor.ts.TsPayloadReader
import androidx.media3.extractor.ts.TsExtractor
import androidx.media3.exoplayer.hls.DefaultHlsExtractorFactory
import androidx.media3.exoplayer.hls.HlsExtractorFactory
import androidx.media3.exoplayer.hls.HlsMediaChunkExtractor
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.inspector.MediaExtractorCompat
import android.net.Uri
import java.io.EOFException
import com.google.common.primitives.ImmutableLongArray

/** Latches failures that MediaExtractorCompat intentionally turns into EOF. */
internal class StickyMediaFailure {
    @Volatile private var failure: Throwable? = null

    fun record(error: Throwable) {
        if (failure == null) synchronized(this) {
            if (failure == null) failure = error
        }
    }

    fun throwIfFailed() {
        failure?.let { throw IllegalStateException("媒体读取失败", it) }
    }
}

internal class LatchingDataSource(
    private val delegate: DataSource,
    private val failure: StickyMediaFailure,
) : DataSource {
    override fun addTransferListener(transferListener: androidx.media3.datasource.TransferListener) =
        delegate.addTransferListener(transferListener)

    override fun open(dataSpec: DataSpec): Long = call { delegate.open(dataSpec) }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        call { delegate.read(buffer, offset, length) }

    override fun getUri(): Uri? = delegate.uri

    override fun getResponseHeaders(): Map<String, List<String>> = delegate.responseHeaders

    override fun close() {
        try {
            delegate.close()
        } catch (error: Throwable) {
            failure.record(error)
            throw error
        }
    }

    private inline fun <T> call(block: () -> T): T = try {
        block()
    } catch (error: Throwable) {
        failure.record(error)
        throw error
    }
}

internal class LatchingProgressiveMediaExtractor(
    private val delegate: ProgressiveMediaExtractor,
    private val failure: StickyMediaFailure,
) : ProgressiveMediaExtractor {
    override fun init(
        dataReader: DataReader,
        uri: Uri,
        responseHeaders: Map<String, List<String>>,
        position: Long,
        length: Long,
        output: androidx.media3.extractor.ExtractorOutput,
    ) = call {
        delegate.init(dataReader, uri, responseHeaders, position, length, output)
    }

    override fun release() = delegate.release()

    override fun disableSeekingOnMp3Streams() = delegate.disableSeekingOnMp3Streams()

    override fun getCurrentInputPosition(): Long = delegate.currentInputPosition

    override fun seek(position: Long, timeUs: Long) = call { delegate.seek(position, timeUs) }

    override fun read(positionHolder: PositionHolder): Int = call { delegate.read(positionHolder) }

    override fun getUnderlyingImplementationName(): String? = delegate.underlyingImplementationName

    private inline fun <T> call(block: () -> T): T = try {
        block()
    } catch (error: Throwable) {
        failure.record(error)
        throw error
    }
}

internal fun createLatchingMediaExtractor(
    extractorsFactory: ExtractorsFactory,
    dataSourceFactory: DataSource.Factory,
    failure: StickyMediaFailure,
): MediaExtractorCompat {
    val progressive = LatchingProgressiveMediaExtractor(
        BundledExtractorsAdapter(extractorsFactory),
        failure,
    )
    val dataSource = DataSource.Factory {
        LatchingDataSource(dataSourceFactory.createDataSource(), failure)
    }
    return MediaExtractorCompat(progressive, dataSource)
}

internal fun createSharedTsExtractorsFactory(adjuster: TimestampAdjuster): ExtractorsFactory =
    object : ExtractorsFactory {
        override fun createExtractors(): Array<androidx.media3.extractor.Extractor> =
            androidx.media3.extractor.DefaultExtractorsFactory().createExtractors().map { extractor ->
                when (extractor) {
                    is TsExtractor -> CompleteSegmentTsExtractor(adjuster)
                    is FragmentedMp4Extractor -> EditListFragmentedMp4Extractor()
                    else -> extractor
                }
            }.toTypedArray()
    }

/** Equivalent whole-timeline translation for the common empty edit followed
 * by the complete fragmented media. Media3 otherwise ignores this two-entry
 * edit list, losing the distinct audio/video start offsets.
 */
private class EditListFragmentedMp4Extractor(
    timestampAdjuster: TimestampAdjuster? = null,
    captions: List<Format> = emptyList(),
) : FragmentedMp4Extractor(
    SubtitleParser.Factory.UNSUPPORTED,
    FLAG_ENABLE_EMSG_TRACK or FLAG_EMIT_RAW_SUBTITLE_DATA,
    timestampAdjuster, null, captions, null,
) {
    override fun modifyTrack(track: Track?): Track? {
        val current = super.modifyTrack(track) ?: return null
        val durations = current.editListDurations ?: return current
        val times = current.editListMediaTimes ?: error("fMP4 edit list 不完整")
        if (durations.length() == 1 && times.length() == 1) {
            requireWholeTimelineEdit(durations.get(0), times.get(0), current.timescale,
                current.movieTimescale, current.durationUs)
            return current
        }
        require(durations.length() == 2 && times.length() == 2 && times.get(0) == -1L &&
            times.get(1) >= 0L && durations.get(0) >= 0L && durations.get(1) == 0L) {
            "暂不支持非完整时间平移的 fMP4 edit list"
        }
        val offset = fragmentedEditOffset(times.get(1), durations.get(0), current.timescale, current.movieTimescale)
        return current.buildUpon().setEditListDurations(ImmutableLongArray.of(0L))
            .setEditListMediaTimes(ImmutableLongArray.of(offset)).build()
    }
}

internal fun requireWholeTimelineEdit(
    duration: Long, mediaTime: Long, timescale: Long, movieTimescale: Long, trackDurationUs: Long,
) {
    require(duration >= 0L && mediaTime >= 0L && timescale > 0L && movieTimescale > 0L) {
        "fMP4 edit list 时间无效"
    }
    if (duration == 0L) return
    val durationUs = Math.multiplyExact(duration, 1_000_000L) / movieTimescale
    val mediaTimeUs = Math.multiplyExact(mediaTime, 1_000_000L) / timescale
    require(trackDurationUs >= 0L && Math.addExact(durationUs, mediaTimeUs) >= trackDurationUs) {
        "暂不支持有限裁剪的 fMP4 edit list"
    }
}

internal fun fragmentedEditOffset(mediaTime: Long, emptyDuration: Long, timescale: Long, movieTimescale: Long): Long {
    require(mediaTime >= 0L && emptyDuration >= 0L && timescale > 0L && movieTimescale > 0L)
    // Integer track ticks match MP4's edit-list precision. Reject overflow.
    val emptyTicks = Math.multiplyExact(emptyDuration, timescale) / movieTimescale
    return Math.subtractExact(mediaTime, emptyTicks)
}

/** The validated export input has complete, independent TS segments. Media3
 * 1.11.1's HLS EOF heuristic re-parses its mutable PES header scratch; payload
 * bytes may have overwritten that header, suppressing the final video sample.
 * Keep the official readers and explicitly finish complete PES units at EOF.
 * HLS AVC carries AUDs, so use the official HLS flags (no slice-based splitting).
 */
private class CompleteSegmentTsExtractor(adjuster: TimestampAdjuster) : Extractor {
    private val readers = mutableListOf<PesReader>()
    private val defaults = DefaultTsPayloadReaderFactory()
    private val payloads = object : TsPayloadReader.Factory {
        override fun createInitialPayloadReaders() = defaults.createInitialPayloadReaders()

        override fun createPayloadReader(streamType: Int, esInfo: TsPayloadReader.EsInfo): TsPayloadReader? {
            val reader = defaults.createPayloadReader(streamType, esInfo) ?: return null
            if (reader !is PesReader) return reader
            readers += reader
            // Prevent TsExtractor's HLS-only EOF heuristic from also flushing.
            return object : TsPayloadReader by reader {}
        }
    }
    private val delegate = TsExtractor(TsExtractor.MODE_HLS, adjuster, payloads)
    private var flushed = false

    override fun sniff(input: ExtractorInput) = delegate.sniff(input)
    override fun init(output: ExtractorOutput) = delegate.init(output)
    override fun seek(position: Long, timeUs: Long) = delegate.seek(position, timeUs)
    override fun release() = delegate.release()
    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
        val result = delegate.read(input, seekPosition)
        if (result != Extractor.RESULT_END_OF_INPUT) flushed = false
        else if (!flushed) {
            flushed = true
            for (reader in readers) {
                // The non-HLS predicate checks completion state without
                // interpreting scratch bytes as a second PES header.
                if (reader.canConsumeSynthesizedEmptyPusi(false)) {
                    reader.consume(ParsableByteArray(), TsPayloadReader.FLAG_PAYLOAD_UNIT_START_INDICATOR)
                }
            }
        }
        return result
    }
}

internal fun createCompleteHlsExtractorFactory(firstPresentationTimeUs: Long): HlsExtractorFactory {
    val defaults = DefaultHlsExtractorFactory()
    return object : HlsExtractorFactory by defaults {
        override fun createExtractor(
            uri: Uri,
            format: Format,
            muxedCaptionFormats: MutableList<Format>?,
            timestampAdjuster: TimestampAdjuster,
            responseHeaders: MutableMap<String, MutableList<String>>,
            sniffingExtractorInput: ExtractorInput,
            playerId: PlayerId,
        ): HlsMediaChunkExtractor {
            // Anchor the shared HLS clock before a video-first fMP4 parser can
            // turn earlier AAC into negative/decode-only samples. Preflight
            // has already established one continuous clock for both tracks.
            if (!timestampAdjuster.isInitialized) {
                timestampAdjuster.sharedInitializeOrWait(true, 0L, 0L)
                timestampAdjuster.adjustSampleTimestamp(firstPresentationTimeUs)
            }
            val ts = CompleteSegmentTsExtractor(timestampAdjuster)
            val isTs = try { ts.sniff(sniffingExtractorInput) } catch (_: EOFException) { false }
            finally { sniffingExtractorInput.resetPeekPosition() }
            val extractor: Extractor = if (isTs) ts else {
                val mp4 = EditListFragmentedMp4Extractor(timestampAdjuster, muxedCaptionFormats ?: emptyList())
                val isMp4 = try { mp4.sniff(sniffingExtractorInput) } catch (_: EOFException) { false }
                finally { sniffingExtractorInput.resetPeekPosition() }
                if (!isMp4) return defaults.createExtractor(uri, format, muxedCaptionFormats,
                    timestampAdjuster, responseHeaders, sniffingExtractorInput, playerId)
                mp4
            }
            return object : HlsMediaChunkExtractor {
                private val position = PositionHolder()
                override fun init(output: ExtractorOutput) = extractor.init(output)
                override fun read(input: ExtractorInput) = extractor.read(input, position) == Extractor.RESULT_CONTINUE
                override fun isPackedAudioExtractor() = false
                override fun isReusable() = true
                override fun recreate(): HlsMediaChunkExtractor = error("TS extractor is reusable")
                override fun onTruncatedSegmentParsed() = error("HLS 导出不允许截断分片")
            }
        }
    }
}
