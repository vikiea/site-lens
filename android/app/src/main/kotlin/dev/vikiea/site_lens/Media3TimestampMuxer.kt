package dev.vikiea.site_lens

import androidx.media3.common.Format
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Muxer
import java.nio.ByteBuffer

/** Media3 1.11.1 MuxerWrapper replaces only the first positive video PTS
 * with zero when keeping leading audio. Restore that timestamp using an
 * untouched sample as a common clock anchor. All encoded data and container
 * writing remain owned by Transformer and its official application muxer.
 */
internal class PreserveFirstVideoPtsMuxerFactory(
    private val delegate: Muxer.Factory,
    private val input: Map<String, Media3SampleTrace>,
) : Muxer.Factory by delegate {
    override fun create(path: String): Muxer = PreserveFirstVideoPtsMuxer(delegate.create(path), input)
}

private class PreserveFirstVideoPtsMuxer(
    private val delegate: Muxer,
    private val input: Map<String, Media3SampleTrace>,
) : Muxer by delegate {
    private val kinds = mutableMapOf<Int, String>()
    private val counts = mutableMapOf<Int, Int>()
    private var shiftUs: Long? = null
    private data class Pending(val track: Int, val bytes: ByteBuffer, val info: BufferInfo)
    private var pending: Pending? = null

    override fun addTrack(format: Format): Int {
        val id = delegate.addTrack(format)
        kinds[id] = when {
            format.sampleMimeType?.startsWith("video/") == true -> "video"
            format.sampleMimeType?.startsWith("audio/") == true -> "audio"
            else -> error("HLS 导出轨道类型无效")
        }
        return id
    }

    override fun writeSampleData(trackId: Int, byteBuffer: ByteBuffer, bufferInfo: BufferInfo) {
        val kind = kinds.getValue(trackId)
        val index = counts.getOrDefault(trackId, 0)
        counts[trackId] = index + 1
        val expected = input.getValue(kind).presentationTimesUs
        require(index < expected.size) { "输出样本数量超出输入" }
        if (kind == "video" && index == 0 && input.containsKey("audio")) {
            require(byteBuffer.remaining() == bufferInfo.size && bufferInfo.size in 1..32 * 1024 * 1024) {
                "首视频样本大小无效"
            }
            val copy = ByteBuffer.allocateDirect(bufferInfo.size)
            copy.put(byteBuffer).flip()
            pending = Pending(trackId, copy, bufferInfo)
            flushPending()
            return
        }
        // Audio's first PTS, or the second video PTS, is untouched by the
        // upstream first-sample special case. Only one video buffer is held.
        if (shiftUs == null) shiftUs = bufferInfo.presentationTimeUs - expected[index]
        flushPending()
        delegate.writeSampleData(trackId, byteBuffer, bufferInfo)
    }

    private fun flushPending() {
        val sample = pending ?: return
        val shift = shiftUs ?: return
        val timestamp = input.getValue("video").presentationTimesUs.first() + shift
        require(sample.info.presentationTimeUs == 0L || sample.info.presentationTimeUs == timestamp) {
            "首视频时间戳不是预期的 Media3 调整"
        }
        delegate.writeSampleData(sample.track, sample.bytes,
            BufferInfo(timestamp, sample.info.size, sample.info.flags))
        pending = null
    }

    override fun close() {
        // cancel() may close after the first buffer, before an anchor arrives.
        // Completion still requires the independent output sample/PTS checks.
        pending = null
        delegate.close()
    }
}
