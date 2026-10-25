package dev.vikiea.site_lens

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.TransferListener
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException

/**
 * Reads committed local HLS files while a download is still publishing the
 * next resource. The writer remains responsible for atomic publication; this
 * source only waits for a readable file and never reads a .part path.
 */
internal class GrowingFileDataSource(
    private val waitTimeoutMs: Long = DEFAULT_WAIT_TIMEOUT_MS,
) : DataSource {
    private val delegate = FileDataSource()

    override fun addTransferListener(transferListener: TransferListener) {
        delegate.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val uri = dataSpec.uri
        require(uri.scheme == "file" && uri.authority.isNullOrEmpty()) {
            "边下边播仅允许应用本地文件"
        }
        val file = File(uri.path ?: error("本地媒体地址无效")).canonicalFile
        awaitCommitted(file, dataSpec.position)
        return delegate.open(dataSpec.withUri(Uri.fromFile(file)))
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        delegate.read(buffer, offset, length)

    override fun getUri(): Uri? = delegate.uri

    override fun getResponseHeaders(): Map<String, List<String>> =
        delegate.responseHeaders

    override fun close() = delegate.close()

    private fun awaitCommitted(file: File, position: Long) {
        val deadline = System.nanoTime() + waitTimeoutMs * 1_000_000L
        while (true) {
            if (file.isFile && file.length() > position) return
            if (System.nanoTime() >= deadline) {
                throw IOException("等待媒体分片提交超时")
            }
            try {
                Thread.sleep(POLL_INTERVAL_MS)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                throw InterruptedIOException("媒体读取已取消")
            }
        }
    }

    internal class Factory(
        private val waitTimeoutMs: Long = DEFAULT_WAIT_TIMEOUT_MS,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource =
            GrowingFileDataSource(waitTimeoutMs)
    }

    private companion object {
        const val DEFAULT_WAIT_TIMEOUT_MS = 15_000L
        const val POLL_INTERVAL_MS = 100L
    }
}
