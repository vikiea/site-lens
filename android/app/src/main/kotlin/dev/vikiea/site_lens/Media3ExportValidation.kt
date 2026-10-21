package dev.vikiea.site_lens

import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs

internal data class Media3SampleTrace(
    val kind: String,
    val formatSignature: String,
    val presentationTimesUs: List<Long>,
    val sampleSizes: List<Int>,
    val keyFrameSampleIndices: List<Int>,
)

/** Pure local checks for the behavior contract around Media3 exports. */
internal object Media3ExportValidation {
    private const val MAX_BOXES = 2_000_000

    /** Parameter-set payload identity, independent of Annex-B start-code width. */
    fun canonicalVideoCsd(bytes: ByteArray): String {
        fun codeSize(index: Int): Int {
            if (index + 2 >= bytes.size || bytes[index] != 0.toByte() || bytes[index + 1] != 0.toByte()) return 0
            if (bytes[index + 2] == 1.toByte()) return 3
            return if (index + 3 < bytes.size && bytes[index + 2] == 0.toByte() && bytes[index + 3] == 1.toByte()) 4 else 0
        }
        val starts = mutableListOf<Pair<Int, Int>>()
        var index = 0
        while (index < bytes.size) {
            val width = codeSize(index)
            if (width == 0) index++ else { starts += index to width; index += width }
        }
        if (starts.isEmpty()) return bytes.joinToString("") { "%02x".format(it) }
        require(bytes.take(starts.first().first).all { it == 0.toByte() }) { "视频参数集前缀无效" }
        return starts.mapIndexed { nalIndex, (position, width) ->
            val start = position + width
            var end = starts.getOrNull(nalIndex + 1)?.first ?: bytes.size
            // Annex-B permits trailing_zero_8bits outside the RBSP payload.
            while (end > start && bytes[end - 1] == 0.toByte()) end--
            require(end > start) { "视频参数集为空" }
            bytes.copyOfRange(start, end).joinToString("") { "%02x".format(it) }
        }.joinToString(":")
    }

    internal data class Mp4TrackTable(
        val sampleSizes: List<Int>,
        val durationUs: Long,
    )

    fun mergeInputSegments(segments: List<Map<String, Media3SampleTrace>>): Map<String, Media3SampleTrace> {
        require(segments.isNotEmpty()) { "媒体没有输入分片" }
        val merged = linkedMapOf<String, MutableTrace>()
        segments.forEachIndexed { segmentIndex, segment ->
            require(segment.isNotEmpty()) { "媒体分片没有音视频轨道" }
            if (segmentIndex > 0) require(segment.keys == merged.keys) { "媒体分片轨道集合发生变化" }
            segment.forEach { (kind, trace) ->
                require(trace.presentationTimesUs.isNotEmpty() && trace.presentationTimesUs.size == trace.sampleSizes.size) {
                    "媒体分片样本为空或大小不一致"
                }
                val current = merged.getOrPut(kind) { MutableTrace(trace) }
                if (segmentIndex > 0) {
                    require(current.formatSignature == trace.formatSignature) { "媒体分片轨道配置发生变化" }
                    val previousLast = current.presentationTimesUs.maxOrNull() ?: error("媒体轨道为空")
                    require(trace.presentationTimesUs.min() > previousLast) {
                        "媒体分片时间戳 reset 或 discontinuity"
                    }
                    current.append(trace)
                }
            }
        }
        return merged.mapValues { (_, trace) -> trace.freeze() }
    }

    fun validateParity(
        input: Map<String, Media3SampleTrace>,
        output: Map<String, Media3SampleTrace>,
        maxSampleOffsetUs: Long = 150L,
        maxTrackOffsetDeltaUs: Long = 1_000L,
    ) {
        require(input.keys == output.keys) { "输出轨道集合不完整" }
        val shifts = mutableMapOf<String, Long>()
        input.forEach { (kind, expected) ->
            val actual = output.getValue(kind)
            require(expected.formatSignature == actual.formatSignature) { "输出轨道配置发生变化" }
            require(expected.presentationTimesUs.size == actual.presentationTimesUs.size) {
                "输出样本数量不完整"
            }
            if (kind == "audio") {
                require(expected.sampleSizes == actual.sampleSizes) { "输出 AAC 样本大小发生变化" }
            }
            require(expected.keyFrameSampleIndices == actual.keyFrameSampleIndices) {
                "输出关键帧索引发生变化"
            }
            val shift = actual.presentationTimesUs.first() - expected.presentationTimesUs.first()
            shifts[kind] = shift
            expected.presentationTimesUs.forEachIndexed { index, pts ->
                require(abs((actual.presentationTimesUs[index] - pts) - shift) <= maxSampleOffsetUs) {
                    "输出样本解码顺序或 PTS 发生变化"
                }
            }
        }
        val shiftsToCompare = shifts.values.toList()
        if (shiftsToCompare.size > 1) {
            require(shiftsToCompare.maxOrNull()!! - shiftsToCompare.minOrNull()!! <= maxTrackOffsetDeltaUs) {
                "输出音视频公共 PTS offset 不一致"
            }
        }
    }

    /** Parses bounded MP4 sample tables and verifies every sample is inside mdat. */
    fun inspect(file: File, onProgress: () -> Unit = {}): Map<String, Mp4TrackTable> {
        require(file.isFile && file.length() >= 16L) { "MP4 文件为空或过短" }
        RandomAccessFile(file, "r").use { input ->
            val top = readChildren(input, 0L, input.length())
            require(top.any { it.type == "ftyp" }) { "MP4 缺少 ftyp" }
            val moov = top.single { it.type == "moov" }
            val mdats = top.filter { it.type == "mdat" }
            require(mdats.isNotEmpty()) { "MP4 缺少 mdat" }
            val movieTimescale = parseMovieTimescale(input, child(input, moov, "mvhd"))
            val tracks = children(input, moov, "trak").map { parseTrack(input, it, movieTimescale) }
            require(tracks.isNotEmpty() && tracks.map { it.kind }.toSet().size == tracks.size) {
                "MP4 音视频轨道不完整"
            }
            return tracks.associate { track ->
                validateSampleExtents(input, track, mdats, onProgress)
                track.kind to Mp4TrackTable(track.sampleSizes.map { it.toInt() }, track.effectiveDurationUs)
            }
        }
    }

    private data class Box(val type: String, val payloadStart: Long, val end: Long)
    private data class ChunkMap(val firstChunk: Long, val samplesPerChunk: Long, val descriptionIndex: Long)
    private data class ParsedTrack(
        val kind: String,
        val sampleSizes: List<Long>,
        val chunkMaps: List<ChunkMap>,
        val chunkOffsets: List<Long>,
        val effectiveDurationUs: Long,
    )

    private class MutableTrace(trace: Media3SampleTrace) {
        val kind = trace.kind
        val formatSignature = trace.formatSignature
        val presentationTimesUs = trace.presentationTimesUs.toMutableList()
        val sampleSizes = trace.sampleSizes.toMutableList()
        val keyFrameSampleIndices = trace.keyFrameSampleIndices.toMutableList()

        fun append(trace: Media3SampleTrace) {
            val base = presentationTimesUs.size
            presentationTimesUs += trace.presentationTimesUs
            sampleSizes += trace.sampleSizes
            keyFrameSampleIndices += trace.keyFrameSampleIndices.map { it + base }
        }

        fun freeze() = Media3SampleTrace(
            kind, formatSignature, presentationTimesUs, sampleSizes, keyFrameSampleIndices,
        )
    }

    private fun parseTrack(input: RandomAccessFile, trak: Box, movieTimescale: Long): ParsedTrack {
        val mdia = child(input, trak, "mdia")
        val handler = child(input, mdia, "hdlr")
        val kind = when (ascii(input, handler.payloadStart + 8L, 4)) {
            "vide" -> "video"
            "soun" -> "audio"
            else -> error("不支持的 MP4 轨道")
        }
        val (timescale, mediaDuration) = parseMediaDuration(input, child(input, mdia, "mdhd"))
        val stbl = child(input, child(input, mdia, "minf"), "stbl")
        val stsd = child(input, stbl, "stsd")
        requirePayload(stsd, 8L)
        require(u32(input, stsd.payloadStart + 4L) == 1L) { "MP4 sample description 不唯一" }
        val sampleSizes = parseSampleSizes(input, stbl)
        val chunkMaps = parseChunkMaps(input, child(input, stbl, "stsc"))
        val chunkOffsets = parseChunkOffsets(input, stbl)
        val (sttsCount, sttsDuration) = parseTimeToSample(input, child(input, stbl, "stts"))
        require(sttsCount == sampleSizes.size.toLong()) { "stts 样本数量不一致" }
        val mediaDurationUs = mediaDuration * 1_000_000L / timescale
        require(abs(sttsDuration * 1_000_000L / timescale - mediaDurationUs) <= 2_000_000L) {
            "stts duration 与媒体 duration 不一致"
        }
        optionalChild(input, stbl, "ctts")?.let { ctts ->
            require(parseCompositionCount(input, ctts) == sampleSizes.size.toLong()) { "ctts 样本数量不一致" }
        }
        optionalChild(input, stbl, "stss")?.let { stss ->
            parseSyncSamples(input, stss).forEach { require(it in 1L..sampleSizes.size.toLong()) }
        }
        val editDurationUs = parseEditDurationUs(input, trak, movieTimescale)
        return ParsedTrack(kind, sampleSizes, chunkMaps, chunkOffsets, editDurationUs ?: mediaDurationUs)
    }

    private fun validateSampleExtents(input: RandomAccessFile, track: ParsedTrack, mdats: List<Box>, onProgress: () -> Unit) {
        require(track.chunkMaps.isNotEmpty() && track.chunkOffsets.isNotEmpty()) { "MP4 chunk table 缺失" }
        require(track.chunkMaps.last().firstChunk <= track.chunkOffsets.size) { "stsc 引用不存在的 chunk" }
        var sampleIndex = 0
        track.chunkOffsets.forEachIndexed { index, chunkOffset ->
            val chunkNumber = index + 1L
            val map = track.chunkMaps.lastOrNull { it.firstChunk <= chunkNumber } ?: error("stsc 缺失")
            require(map.descriptionIndex == 1L && map.samplesPerChunk in 1L..MAX_BOXES.toLong())
            var sampleOffset = chunkOffset
            repeat(map.samplesPerChunk.toInt()) {
                require(sampleIndex < track.sampleSizes.size)
                val size = track.sampleSizes[sampleIndex++]
                require(size > 0L)
                val end = Math.addExact(sampleOffset, size)
                require(mdats.any { sampleOffset >= it.payloadStart && end <= it.end }) { "MP4 sample extent 超出 mdat" }
                sampleOffset = end
                if (sampleIndex % 1024 == 0) onProgress()
            }
            onProgress()
        }
        require(sampleIndex == track.sampleSizes.size) { "stsc 未覆盖全部样本" }
    }

    private fun parseSampleSizes(input: RandomAccessFile, stbl: Box): List<Long> {
        optionalChild(input, stbl, "stsz")?.let { box ->
            requirePayload(box, 12L)
            val fixed = u32(input, box.payloadStart + 4L)
            val count = u32(input, box.payloadStart + 8L).toInt()
            require(count in 1..MAX_BOXES)
            requirePayload(box, 12L + if (fixed == 0L) count * 4L else 0L)
            return if (fixed > 0L) List(count) { fixed }
            else List(count) { u32(input, box.payloadStart + 12L + it * 4L) }.also { sizes -> require(sizes.all { it > 0L }) }
        }
        val box = child(input, stbl, "stz2")
        requirePayload(box, 12L)
        val fieldSize = input.readUnsignedByteAt(box.payloadStart + 7L)
        val count = u32(input, box.payloadStart + 8L).toInt()
        require(count in 1..MAX_BOXES && fieldSize in setOf(4, 8, 16))
        requirePayload(box, 12L + (count.toLong() * fieldSize + 7L) / 8L)
        return List(count) { index ->
            when (fieldSize) {
                4 -> if (index and 1 == 0) (input.readUnsignedByteAt(box.payloadStart + 12L + index / 2) ushr 4).toLong() else (input.readUnsignedByteAt(box.payloadStart + 12L + index / 2) and 0x0f).toLong()
                8 -> input.readUnsignedByteAt(box.payloadStart + 12L + index).toLong()
                else -> u16(input, box.payloadStart + 12L + index * 2L).toLong()
            }.also { require(it > 0L) }
        }
    }

    private fun parseChunkMaps(input: RandomAccessFile, box: Box): List<ChunkMap> {
        requirePayload(box, 8L)
        val count = u32(input, box.payloadStart + 4L).toInt()
        require(count in 1..MAX_BOXES)
        requirePayload(box, 8L + count * 12L)
        return List(count) { index ->
            val offset = box.payloadStart + 8L + index * 12L
            ChunkMap(u32(input, offset), u32(input, offset + 4L), u32(input, offset + 8L))
        }.also { maps -> require(maps.first().firstChunk == 1L && maps.zipWithNext().all { (a, b) -> a.firstChunk < b.firstChunk }) }
    }

    private fun parseChunkOffsets(input: RandomAccessFile, stbl: Box): List<Long> {
        optionalChild(input, stbl, "stco")?.let { box ->
            requirePayload(box, 8L)
            val count = u32(input, box.payloadStart + 4L).toInt()
            require(count in 1..MAX_BOXES)
            requirePayload(box, 8L + count * 4L)
            return List(count) { u32(input, box.payloadStart + 8L + it * 4L) }
        }
        val box = child(input, stbl, "co64")
        requirePayload(box, 8L)
        val count = u32(input, box.payloadStart + 4L).toInt()
        require(count in 1..MAX_BOXES)
        requirePayload(box, 8L + count * 8L)
        return List(count) { u64(input, box.payloadStart + 8L + it * 8L) }
    }

    private fun parseTimeToSample(input: RandomAccessFile, box: Box): Pair<Long, Long> {
        requirePayload(box, 8L)
        val count = u32(input, box.payloadStart + 4L).toInt()
        require(count in 1..MAX_BOXES)
        requirePayload(box, 8L + count * 8L)
        var sampleCount = 0L
        var duration = 0L
        repeat(count) { index ->
            val offset = box.payloadStart + 8L + index * 8L
            val samples = u32(input, offset)
            val delta = u32(input, offset + 4L)
            sampleCount = Math.addExact(sampleCount, samples)
            duration = Math.addExact(duration, Math.multiplyExact(samples, delta))
        }
        return sampleCount to duration
    }

    private fun parseCompositionCount(input: RandomAccessFile, box: Box): Long {
        requirePayload(box, 8L)
        val count = u32(input, box.payloadStart + 4L).toInt()
        require(count in 1..MAX_BOXES)
        requirePayload(box, 8L + count * 8L)
        var result = 0L
        repeat(count) { index -> result = Math.addExact(result, u32(input, box.payloadStart + 8L + index * 8L)) }
        return result
    }

    private fun parseSyncSamples(input: RandomAccessFile, box: Box): List<Long> {
        requirePayload(box, 8L)
        val count = u32(input, box.payloadStart + 4L).toInt()
        require(count in 1..MAX_BOXES)
        requirePayload(box, 8L + count * 4L)
        return List(count) { u32(input, box.payloadStart + 8L + it * 4L) }.also { require(it.zipWithNext().all { (a, b) -> a < b }) }
    }

    private fun parseMovieTimescale(input: RandomAccessFile, mvhd: Box): Long {
        requirePayload(mvhd, 4L)
        val version = input.readUnsignedByteAt(mvhd.payloadStart)
        require(version in 0..1)
        requirePayload(mvhd, if (version == 0) 16L else 24L)
        return u32(input, mvhd.payloadStart + if (version == 0) 12L else 20L).also { require(it > 0L) }
    }

    private fun parseMediaDuration(input: RandomAccessFile, mdhd: Box): Pair<Long, Long> {
        requirePayload(mdhd, 4L)
        val version = input.readUnsignedByteAt(mdhd.payloadStart)
        require(version in 0..1)
        requirePayload(mdhd, if (version == 0) 20L else 32L)
        val timescaleOffset = if (version == 0) 12L else 20L
        val durationOffset = if (version == 0) 16L else 24L
        val timescale = u32(input, mdhd.payloadStart + timescaleOffset)
        val duration = if (version == 0) u32(input, mdhd.payloadStart + durationOffset) else u64(input, mdhd.payloadStart + durationOffset)
        require(timescale > 0L && duration > 0L)
        return timescale to duration
    }

    private fun parseEditDurationUs(input: RandomAccessFile, trak: Box, movieTimescale: Long): Long? {
        val edts = optionalChild(input, trak, "edts") ?: return null
        val elst = child(input, edts, "elst")
        requirePayload(elst, 8L)
        val version = input.readUnsignedByteAt(elst.payloadStart)
        require(version in 0..1)
        val count = u32(input, elst.payloadStart + 4L).toInt()
        require(count in 1..MAX_BOXES)
        requirePayload(elst, 8L + count * if (version == 0) 12L else 20L)
        var duration = 0L
        repeat(count) { index ->
            val offset = elst.payloadStart + 8L + if (version == 0) index * 12L else index * 20L
            val segmentDuration = if (version == 0) u32(input, offset) else u64(input, offset)
            val mediaTime = if (version == 0) input.readIntAt(offset + 4L).toLong() else input.readLongAt(offset + 8L)
            val rate = input.readIntAt(offset + if (version == 0) 8L else 16L)
            require(rate == 0x00010000 && (mediaTime == -1L || mediaTime >= 0L))
            duration = Math.addExact(duration, segmentDuration * 1_000_000L / movieTimescale)
        }
        return duration
    }

    private fun child(input: RandomAccessFile, parent: Box, type: String): Box = children(input, parent, type).single()
    private fun optionalChild(input: RandomAccessFile, parent: Box, type: String): Box? = children(input, parent, type).singleOrNull()
    private fun children(input: RandomAccessFile, parent: Box, type: String): List<Box> = readChildren(input, parent.payloadStart, parent.end).filter { it.type == type }

    private fun readChildren(input: RandomAccessFile, start: Long, end: Long): List<Box> {
        val result = mutableListOf<Box>()
        var offset = start
        while (offset < end) {
            require(result.size < MAX_BOXES && end - offset >= 8L)
            input.seek(offset)
            val size32 = input.readInt().toLong() and 0xffffffffL
            val type = readAscii(input, 4)
            val header = if (size32 == 1L) 16L else 8L
            val size = when (size32) { 0L -> end - offset; 1L -> input.readLong(); else -> size32 }
            require(size >= header && size <= end - offset)
            result += Box(type, offset + header, offset + size)
            offset += size
        }
        require(offset == end)
        return result
    }

    private fun readAscii(input: RandomAccessFile, length: Int): String = ByteArray(length).also(input::readFully).toString(Charsets.US_ASCII)
    private fun requirePayload(box: Box, bytes: Long) { require(bytes >= 0L && bytes <= box.end - box.payloadStart) { "MP4 样本表被截断" } }
    private fun ascii(input: RandomAccessFile, offset: Long, length: Int): String { input.seek(offset); return readAscii(input, length) }
    private fun u16(input: RandomAccessFile, offset: Long): Int = input.readUnsignedShortAt(offset)
    private fun u32(input: RandomAccessFile, offset: Long): Long = input.readIntAt(offset).toLong() and 0xffffffffL
    private fun u64(input: RandomAccessFile, offset: Long): Long = input.readLongAt(offset)
    private fun RandomAccessFile.readUnsignedByteAt(offset: Long): Int { seek(offset); return readUnsignedByte() }
    private fun RandomAccessFile.readUnsignedShortAt(offset: Long): Int { seek(offset); return readUnsignedShort() }
    private fun RandomAccessFile.readIntAt(offset: Long): Int { seek(offset); return readInt() }
    private fun RandomAccessFile.readLongAt(offset: Long): Long { seek(offset); return readLong() }
}
