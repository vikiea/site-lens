package dev.vikiea.site_lens

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Metadata
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Muxer
import com.google.common.collect.ImmutableList
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class Media3TimestampMuxerTest {
    @Test
    fun fragmentedEmptyEditsPreserveDistinctAudioVideoOrigins() {
        // Values independently read from the synthetic fMP4 init's elst boxes.
        assertEquals(9L, fragmentedEditOffset(2048L, 166L, 12288L, 1000L))
        assertEquals(-6960L, fragmentedEditOffset(0L, 145L, 48000L, 1000L))
    }

    @Test
    fun finiteOrEmptyOnlyEditCannotSilentlyExpandIntoWholeTrack() {
        requireWholeTimelineEdit(0L, 100L, 1000L, 1000L, 4_000_000L)
        requireWholeTimelineEdit(4000L, 0L, 1000L, 1000L, 4_000_000L)
        assertThrows(IllegalArgumentException::class.java) {
            requireWholeTimelineEdit(1000L, 0L, 1000L, 1000L, 4_000_000L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            requireWholeTimelineEdit(0L, -1L, 1000L, 1000L, 4_000_000L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            requireWholeTimelineEdit(1000L, 0L, 1000L, 1000L, -1L)
        }
    }

    @Test
    fun restoresClampedFirstPtsWithoutSortingBFramesOrChangingBytes() {
        val output = RecordingMuxer()
        val muxer = create(output)
        val video = muxer.addTrack(Format.Builder().setSampleMimeType("video/avc").build())
        val audio = muxer.addTrack(Format.Builder().setSampleMimeType("audio/mp4a-latm").build())
        write(muxer, video, 0L, 1)
        assertTrue(output.samples.isEmpty())
        write(muxer, video, 271_334L, 2)
        write(muxer, video, 104_667L, 3)
        write(muxer, video, 188_000L, 4)
        write(muxer, audio, 0L, 5)
        muxer.close()
        assertEquals(listOf(21_334L, 271_334L, 104_667L, 188_000L),
            output.samples.filter { it.track == video }.map { it.pts })
        output.samples.forEachIndexed { index, sample ->
            assertArrayEquals(byteArrayOf((index + 1).toByte()), sample.bytes)
        }
        assertTrue(output.closed)
    }

    @Test
    fun audioAnchorCanArriveBeforeOrAfterSingleVideoSample() {
        for (audioFirst in listOf(false, true)) {
            val output = RecordingMuxer()
            val muxer = create(output)
            val video = muxer.addTrack(Format.Builder().setSampleMimeType("video/avc").build())
            val audio = muxer.addTrack(Format.Builder().setSampleMimeType("audio/mp4a-latm").build())
            if (audioFirst) write(muxer, audio, 0L, 5)
            write(muxer, video, 0L, 1)
            if (!audioFirst) write(muxer, audio, 0L, 5)
            muxer.close()
            assertEquals(21_334L, output.samples.single { it.track == video }.pts)
        }
    }

    @Test
    fun failedOrCancelledPendingSampleStillClosesOfficialMuxer() {
        val output = RecordingMuxer()
        val muxer = create(output)
        val video = muxer.addTrack(Format.Builder().setSampleMimeType("video/avc").build())
        write(muxer, video, 0L, 1)
        muxer.close()
        assertTrue(output.closed)
        assertTrue(output.samples.isEmpty())
    }

    private fun create(output: RecordingMuxer): Muxer {
        val factory = object : Muxer.Factory {
            override fun create(path: String): Muxer = output
            override fun getSupportedSampleMimeTypes(trackType: Int): ImmutableList<String> = ImmutableList.of()
        }
        fun trace(kind: String, pts: List<Long>) = Media3SampleTrace(kind, kind, pts,
            pts.map { 1 }, listOf(0))
        return PreserveFirstVideoPtsMuxerFactory(factory, mapOf(
            "video" to trace("video", listOf(1_566_667L, 1_816_667L, 1_650_000L, 1_733_333L)),
            "audio" to trace("audio", listOf(1_545_333L)),
        )).create("ignored")
    }

    private fun write(muxer: Muxer, track: Int, pts: Long, value: Int) {
        muxer.writeSampleData(track, ByteBuffer.wrap(byteArrayOf(value.toByte())),
            BufferInfo(pts, 1, C.BUFFER_FLAG_KEY_FRAME))
    }

    private data class Sample(val track: Int, val pts: Long, val bytes: ByteArray)
    private class RecordingMuxer : Muxer {
        val samples = mutableListOf<Sample>()
        var closed = false
        private var nextTrack = 0
        override fun addTrack(format: Format) = nextTrack++
        override fun writeSampleData(trackId: Int, byteBuffer: ByteBuffer, bufferInfo: BufferInfo) {
            val bytes = ByteArray(byteBuffer.remaining()).also { byteBuffer.get(it) }
            samples += Sample(trackId, bufferInfo.presentationTimeUs, bytes)
        }
        override fun addMetadataEntry(metadataEntry: Metadata.Entry) {}
        override fun close() { closed = true }
    }
}
