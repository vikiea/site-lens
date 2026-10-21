package dev.vikiea.site_lens

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AacAccessUnitsTest {
    private val config = byteArrayOf(0x12, 0x10) // AAC-LC, 44.1 kHz, stereo.

    private fun adts(payload: ByteArray, crc: Boolean = false): ByteArray {
        val size = payload.size + if (crc) 9 else 7
        return byteArrayOf(
            0xff.toByte(), if (crc) 0xf0.toByte() else 0xf1.toByte(), 0x50,
            (0x80 or (size ushr 11)).toByte(), (size ushr 3).toByte(),
            (((size and 7) shl 5) or 0x1f).toByte(), 0xfc.toByte(),
        ) + (if (crc) byteArrayOf(0, 0) else byteArrayOf()) + payload
    }

    private fun bytes(buffer: ByteBuffer) = ByteArray(buffer.remaining()).also { buffer.duplicate().get(it) }

    @Test fun splitsAggregatedTransportFramesAndRemovesAdtsHeaders() {
        val sample = ByteBuffer.wrap(adts(byteArrayOf(1, 2, 3)) + adts(byteArrayOf(4, 5)))
        val frames = AacAccessUnits.split(sample, 44100, 2, config, true)
        assertEquals(2, frames.size)
        assertArrayEquals(byteArrayOf(1, 2, 3), bytes(frames[0].data))
        assertArrayEquals(byteArrayOf(4, 5), bytes(frames[1].data))
        assertEquals(0L, frames[0].offsetUs)
        assertEquals(23219L, frames[1].offsetUs)
        assertEquals(0, sample.position())
    }

    @Test fun crcHeaderAndSlicedInputDoNotLeakIntoAccessUnit() {
        val frame = adts(byteArrayOf(9, 8, 7), crc = true)
        val sample = ByteBuffer.wrap(byteArrayOf(0, 0) + frame + byteArrayOf(0)).apply {
            position(2); limit(2 + frame.size)
        }
        assertArrayEquals(byteArrayOf(9, 8, 7), bytes(AacAccessUnits.split(sample, 44100, 2, config).single().data))
        assertEquals(2, sample.position())
    }

    @Test fun rawFmp4AccessUnitPassesThroughWithoutRemovingBytes() {
        val raw = byteArrayOf(0x21, 0x10, 3, 4)
        assertArrayEquals(raw, bytes(AacAccessUnits.split(ByteBuffer.wrap(raw), 44100, 2, config).single().data))
    }

    @Test fun rawFmp4AccessUnitStillValidatesAscAgainstTheTrack() {
        val raw = byteArrayOf(0x21, 0x10, 3, 4)
        assertThrows(IllegalArgumentException::class.java) {
            AacAccessUnits.split(ByteBuffer.wrap(raw), 44100, 2, byteArrayOf(0x11, 0x90.toByte()))
        }
    }

    @Test fun truncatedAdtsOrGarbageAfterAValidFrameFailsClosed() {
        val valid = adts(byteArrayOf(1, 2, 3))
        for (data in listOf(valid.copyOf(valid.size - 1), valid + byteArrayOf(1))) {
            assertThrows(IllegalArgumentException::class.java) {
                AacAccessUnits.split(ByteBuffer.wrap(data), 44100, 2, config)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            AacAccessUnits.split(ByteBuffer.wrap(byteArrayOf(1, 2)), 44100, 2, config, true)
        }
    }

    @Test fun rejectsConfigChangesAndMultipleRawDataBlocks() {
        val valid = adts(byteArrayOf(1, 2, 3))
        assertThrows(IllegalArgumentException::class.java) {
            AacAccessUnits.split(ByteBuffer.wrap(valid), 48000, 2, config)
        }
        val multi = valid.copyOf().apply { this[6] = 0xfd.toByte() }
        assertThrows(IllegalArgumentException::class.java) {
            AacAccessUnits.split(ByteBuffer.wrap(multi), 44100, 2, config)
        }
    }

    @Test fun frameClockUsesTheFullFrameIndexWithoutAccumulatedRounding() {
        val packet = (0 until 100).fold(byteArrayOf()) { bytes, _ -> bytes + adts(byteArrayOf(1)) }
        val frames = AacAccessUnits.split(ByteBuffer.wrap(packet), 44100, 2, config)
        assertEquals(99L * 1024L * 1_000_000L / 44100, frames.last().offsetUs)
    }

    @Test fun adtsAndTrackMustAgreeWithAscSampleRateAndChannels() {
        val packet = ByteBuffer.wrap(adts(byteArrayOf(1, 2, 3)))
        // ASC says 48 kHz, while both ADTS and the track say 44.1 kHz.
        assertThrows(IllegalArgumentException::class.java) {
            AacAccessUnits.split(packet, 44100, 2, byteArrayOf(0x11, 0x90.toByte()))
        }
        // ASC says mono, while ADTS and the track say stereo.
        assertThrows(IllegalArgumentException::class.java) {
            AacAccessUnits.split(packet, 44100, 2, byteArrayOf(0x12, 0x08))
        }
    }

    @Test fun realTransportPacketShapeYieldsFiveRawAccessUnits() {
        // Packet lengths observed in a 44.1 kHz AAC-LC TS extractor packet.
        // Payloads are synthetic; no user media is kept in the repository.
        val lengths = listOf(522, 751, 386, 535, 595)
        val packet = lengths.fold(byteArrayOf()) { bytes, size -> bytes + adts(ByteArray(size - 7) { 0x21 }) }
        val units = AacAccessUnits.split(ByteBuffer.wrap(packet), 44100, 2, config)
        assertEquals(2789, packet.size)
        assertEquals(lengths.map { it - 7 }, units.map { it.data.remaining() })
        assertEquals(4L * 1024L * 1_000_000L / 44100, units.last().offsetUs)
    }

    @Test fun packetClockAbsorbsOneFrameTransportOverlapWithoutDroppingAudio() {
        val clock = AacAccessUnits.Clock(44100)
        val packet = (0 until 5).fold(byteArrayOf()) { bytes, _ -> bytes + adts(byteArrayOf(1)) }
        val frames = AacAccessUnits.split(ByteBuffer.wrap(packet), 44100, 2, config)
        val times = mutableListOf<Long>()
        for (start in listOf(0L, 92_880L, 208_980L)) {
            frames.forEach { times += clock.next(start + it.offsetUs) }
        }
        assertEquals(15, times.size)
        assertEquals(14L * 1024L * 1_000_000L / 44100, times.last())
        assertEquals(15L * 1024L * 1_000_000L / 44100, clock.endUs())
        assertThrows(IllegalArgumentException::class.java) { clock.next(2_000_000L) }
    }
}
