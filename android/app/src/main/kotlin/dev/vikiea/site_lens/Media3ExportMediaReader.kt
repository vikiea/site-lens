package dev.vikiea.site_lens

import androidx.media3.common.DataReader
import androidx.media3.common.util.TimestampAdjuster
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.source.BundledExtractorsAdapter
import androidx.media3.exoplayer.source.ProgressiveMediaExtractor
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.extractor.ts.TsExtractor
import androidx.media3.inspector.MediaExtractorCompat
import android.net.Uri

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
                if (extractor is TsExtractor) TsExtractor(
                    TsExtractor.MODE_HLS,
                    adjuster,
                    DefaultTsPayloadReaderFactory(DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS),
                ) else extractor
            }.toTypedArray()
    }
