package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File

class Media3ExportValidationTest {
    @Test
    fun videoCsdNormalizesThreeAndFourByteNalPrefixes() {
        val ts = byteArrayOf(0, 0, 1, 0x67, 0x42, 0x80.toByte(), 0, 0, 1, 0x68, 0x60)
        val mp4 = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x80.toByte(), 0, 0, 0, 1, 0x68, 0x60)
        assertEquals(Media3ExportValidation.canonicalVideoCsd(ts), Media3ExportValidation.canonicalVideoCsd(mp4))
        val changed = mp4.copyOf().apply { this[lastIndex] = 0x61 }
        assertNotEquals(Media3ExportValidation.canonicalVideoCsd(ts), Media3ExportValidation.canonicalVideoCsd(changed))
    }

    @Test
    fun mergesBFramePtsAndKeepsOneTrackOffset() {
        val input = Media3ExportValidation.mergeInputSegments(
            listOf(
                mapOf(
                    "video" to trace("video", listOf(0L, 80L, 40L), listOf(10, 11, 12), listOf(0)),
                    "audio" to trace("audio", listOf(0L, 20L, 40L), listOf(4, 4, 4), emptyList()),
                ),
                mapOf(
                    "video" to trace("video", listOf(120L, 200L, 160L), listOf(13, 14, 15), listOf(0)),
                    "audio" to trace("audio", listOf(60L, 80L, 100L), listOf(4, 4, 4), emptyList()),
                ),
            ),
        )
        val output = input.mapValues { (_, value) ->
            value.copy(presentationTimesUs = value.presentationTimesUs.map { it + 1_000L })
        }
        Media3ExportValidation.validateParity(input, output)
        assertEquals(listOf(0L, 80L, 40L, 120L, 200L, 160L), input.getValue("video").presentationTimesUs)
    }

    @Test
    fun rejectsTimestampResetBetweenSegments() {
        assertThrows(IllegalArgumentException::class.java) {
            Media3ExportValidation.mergeInputSegments(
                listOf(
                    mapOf("video" to trace("video", listOf(100L), listOf(10), listOf(0))),
                    mapOf("video" to trace("video", listOf(90L), listOf(10), listOf(0))),
                ),
            )
        }
    }

    @Test
    fun videoRepresentationMayChangeSampleByteSizeButAacMayNot() {
        val input = mapOf(
            "video" to trace("video", listOf(0L), listOf(10), listOf(0)),
            "audio" to trace("audio", listOf(0L), listOf(4), emptyList()),
        )
        val output = mapOf(
            "video" to trace("video", listOf(1_000L), listOf(12), listOf(0)),
            "audio" to trace("audio", listOf(1_000L), listOf(4), emptyList()),
        )
        Media3ExportValidation.validateParity(input, output)
        assertThrows(IllegalArgumentException::class.java) {
            Media3ExportValidation.validateParity(input, output.mapValues { (kind, trace) ->
                if (kind == "audio") trace.copy(sampleSizes = listOf(5)) else trace
            })
        }
    }

    @Test
    fun api26DoesNotTreatLaterPermissionsAsDenied() {
        assertTrue(isPermissionApplicable("android.permission.FOREGROUND_SERVICE", 28))
        assertTrue(!isPermissionApplicable("android.permission.FOREGROUND_SERVICE", 26))
        assertTrue(!isPermissionApplicable("android.permission.POST_NOTIFICATIONS", 26))
        assertTrue(!isPermissionApplicable("android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK", 33))
        assertTrue(isPermissionApplicable("android.permission.INTERNET", 26))
    }

    @Test
    fun validatesMp4TablesAndRejectsSampleOutsideMdat() {
        val file = File.createTempFile("media3-table-", ".mp4")
        try {
            file.writeBytes(mp4(chunkOffset = 24))
            val table = Media3ExportValidation.inspect(file).getValue("video")
            assertEquals(listOf(4, 4), table.sampleSizes)
            assertEquals(2_000_000L, table.durationUs)
            file.writeBytes(mp4(chunkOffset = 25))
            assertThrows(IllegalArgumentException::class.java) {
                Media3ExportValidation.inspect(file)
            }
        } finally { file.delete() }
    }

    @Test
    fun rejectsTruncatedSampleTableEvenWhenFollowingBoxHasBytes() {
        val file = File.createTempFile("media3-truncated-", ".mp4")
        try {
            file.writeBytes(mp4(chunkOffset = 24, declaredSamples = 3))
            assertThrows(IllegalArgumentException::class.java) {
                Media3ExportValidation.inspect(file)
            }
        } finally { file.delete() }
    }

    private fun mp4(chunkOffset: Int, declaredSamples: Int = 2): ByteArray {
        val ftyp = box("ftyp", "isom0000".toByteArray())
        val mdat = box("mdat", ByteArray(8))
        val mvhd = box("mvhd", ints(0, 0, 0, 1000, 2000))
        val mdhd = box("mdhd", ints(0, 0, 0, 1000, 2000))
        val hdlr = box("hdlr", ints(0, 0) + "vide".toByteArray())
        val stbl = box("stbl",
            box("stsd", ints(0, 1)) +
                box("stsz", ints(0, 0, declaredSamples, 4, 4)) +
                box("stsc", ints(0, 1, 1, 2, 1)) +
                box("stco", ints(0, 1, chunkOffset)) +
                box("stts", ints(0, 1, 2, 1000)) +
                box("stss", ints(0, 1, 1)),
        )
        val trak = box("trak", box("mdia", mdhd + hdlr + box("minf", stbl)))
        return ftyp + mdat + box("moov", mvhd + trak)
    }

    private fun box(type: String, payload: ByteArray): ByteArray =
        ints(payload.size + 8) + type.toByteArray() + payload

    private fun ints(vararg values: Int): ByteArray {
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).use { output -> values.forEach(output::writeInt) }
        return buffer.toByteArray()
    }

    private fun trace(kind: String, pts: List<Long>, sizes: List<Int>, keyFrames: List<Int>) =
        Media3SampleTrace(kind, "${kind}:fixture", pts, sizes, keyFrames)
}
