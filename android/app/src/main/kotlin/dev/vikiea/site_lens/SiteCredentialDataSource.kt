package dev.vikiea.site_lens

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * 远程媒体请求的凭证注入（ADR-0007）：主清单与分片、渐进式的每个字节区间都走
 * 同一个数据来源，请求头在**每次请求时**从当前凭证里取。
 *
 * 取不到凭证时请求头就是空的：公开内容照常播放。凭证只进请求，不回显、不打日志、
 * 不进异常消息。
 */
internal class SiteCredentialDataSource(
    private val upstream: DataSource,
    private val headersFor: (String) -> Map<String, String>,
) : DataSource {
    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long = upstream.open(withCredentialHeaders(dataSpec))

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        upstream.read(buffer, offset, length)

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() = upstream.close()

    /** 把这条地址的凭证合并进请求头；同名（忽略大小写）的旧值被替换。 */
    fun withCredentialHeaders(dataSpec: DataSpec): DataSpec {
        val headers = headersFor(dataSpec.uri.toString())
        if (headers.isEmpty()) return dataSpec
        val merged = LinkedHashMap<String, String>(dataSpec.httpRequestHeaders)
        for (name in listOf(SiteCredentialRecord.HEADER_AUTHORIZATION, SiteCredentialRecord.HEADER_COOKIE)) {
            val value = headers[name] ?: continue
            merged.keys.firstOrNull { it.equals(name, ignoreCase = true) }?.let(merged::remove)
            merged[name] = value
        }
        return dataSpec.withAdditionalHeaders(merged)
    }

    companion object {
        /** 远程 HLS（主清单与分片）与远程渐进式共用这一套注入口。 */
        fun factory(headersFor: (String) -> Map<String, String>): DataSource.Factory =
            DataSource.Factory { SiteCredentialDataSource(HttpDataSourceFactory.create(), headersFor) }
    }
}
