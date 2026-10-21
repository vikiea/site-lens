package dev.vikiea.site_lens

import java.nio.ByteBuffer

/** Converts TS extractor packets containing ADTS frames to MP4 AAC access units. */
internal object AacAccessUnits {
    data class Frame(val data: ByteBuffer, val offsetUs: Long, val adts: Boolean = false)

    private data class Config(val objectType: Int, val sampleRate: Int, val channels: Int)

    /** Transport packet PTS is rounded and can overlap by one AAC frame. */
    class Clock(private val sampleRate: Int) {
        private var anchorUs: Long? = null
        private var frameCount = 0L

        fun next(inputPtsUs: Long): Long {
            val anchor = anchorUs ?: inputPtsUs.also { anchorUs = it }
            val expected = anchor + frameCount * 1024L * 1_000_000L / sampleRate
            require(kotlin.math.abs(inputPtsUs - expected) <= 50_000L) { "AAC 音频时间轴不连续，无法生成连续 MP4" }
            frameCount++
            return expected
        }

        fun endUs(): Long = (anchorUs ?: 0L) + frameCount * 1024L * 1_000_000L / sampleRate
    }

    private val sampleRates = intArrayOf(
        96000, 88200, 64000, 48000, 44100, 32000, 24000,
        22050, 16000, 12000, 11025, 8000, 7350,
    )

    fun split(
        sample: ByteBuffer,
        sampleRate: Int,
        channelCount: Int,
        audioSpecificConfig: ByteArray,
        adtsRequired: Boolean = false,
    ): List<Frame> {
        val input = sample.duplicate()
        val start = input.position()
        fun byteAt(offset: Int) = input.get(offset).toInt() and 0xff
        fun syncAt(offset: Int) = input.limit() - offset >= 2 &&
            byteAt(offset) == 0xff && byteAt(offset + 1) and 0xf6 == 0xf0
        require(audioSpecificConfig.size >= 2) { "AAC 解码初始化信息缺失" }
        // ADTS transports 1024-sample AAC frames. Extended HE/LD profiles need
        // their own clock/config handling instead of silently using LC timing.
        val config = parseConfig(audioSpecificConfig)
        require(config.objectType in 1..4 && sampleRate > 0 &&
            config.sampleRate == sampleRate && config.channels == channelCount) {
            "AAC 解码初始化信息与轨道不一致"
        }
        if (!syncAt(start)) {
            require(!adtsRequired) { "AAC ADTS 音频帧头无效" }
            require(input.hasRemaining()) { "AAC 音频样本为空" }
            return listOf(Frame(input.slice(), 0L))
        }
        val frames = mutableListOf<Frame>()
        var cursor = start
        while (cursor < input.limit()) {
            require(input.limit() - cursor >= 7 && syncAt(cursor)) { "AAC ADTS 音频帧不完整" }
            val headerSize = if (byteAt(cursor + 1) and 1 == 1) 7 else 9
            val rateIndex = (byteAt(cursor + 2) ushr 2) and 0xf
            val channels = ((byteAt(cursor + 2) and 1) shl 2) or (byteAt(cursor + 3) ushr 6)
            val decodedChannels = if (channels == 7) 8 else channels
            val profile = (byteAt(cursor + 2) ushr 6) + 1
            require(rateIndex < sampleRates.size && sampleRates[rateIndex] == sampleRate &&
                decodedChannels > 0 && decodedChannels == channelCount && profile == config.objectType) {
                "AAC ADTS 音频配置与轨道不一致"
            }
            require(byteAt(cursor + 6) and 3 == 0) { "暂不支持多数据块 AAC ADTS 音频帧" }
            val frameSize = ((byteAt(cursor + 3) and 3) shl 11) or
                (byteAt(cursor + 4) shl 3) or (byteAt(cursor + 5) ushr 5)
            require(frameSize > headerSize && frameSize <= input.limit() - cursor) { "AAC ADTS 音频帧长度无效" }
            val payload = input.duplicate().apply {
                position(cursor + headerSize)
                limit(cursor + frameSize)
            }.slice()
            val offsetUs = frames.size.toLong() * 1024L * 1_000_000L / sampleRate
            frames += Frame(payload, offsetUs, adts = true)
            cursor += frameSize
        }
        return frames
    }

    private fun parseConfig(value: ByteArray): Config {
        val reader = BitReader(value)
        var objectType = reader.read(5)
        if (objectType == 31) objectType = 32 + reader.read(6)
        require(objectType in 1..4) { "暂不支持该 AAC ADTS 音频配置" }
        val rateIndex = reader.read(4)
        val rate = if (rateIndex == 15) reader.read(24) else sampleRates.getOrNull(rateIndex)
        require(rate != null && rate > 0) { "AAC 解码初始化采样率无效" }
        val channels = reader.read(4)
        val channelCount = when (channels) {
            1 -> 1
            2 -> 2
            3 -> 3
            4 -> 4
            5 -> 5
            6 -> 6
            7 -> 8
            else -> 0
        }
        require(channelCount > 0) { "AAC 解码初始化声道配置无效" }
        return Config(objectType, rate, channelCount)
    }

    private class BitReader(private val bytes: ByteArray) {
        private var position = 0

        fun read(count: Int): Int {
            require(count in 1..24 && position + count <= bytes.size * 8) { "AAC 解码初始化信息不完整" }
            var result = 0
            repeat(count) {
                result = (result shl 1) or ((bytes[position / 8].toInt() ushr (7 - position % 8)) and 1)
                position++
            }
            return result
        }
    }
}
