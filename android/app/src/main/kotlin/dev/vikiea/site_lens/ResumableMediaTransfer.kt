package dev.vikiea.site_lens

import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.Properties
import java.util.concurrent.atomic.AtomicBoolean

/** Pure JVM transport, also exercised against an actual local HTTP server. */
class ResumableMediaTransfer(
    private val cancelled: () -> Boolean = { false },
    private val connect: (URI) -> HttpURLConnection = { SystemMediaNetwork.openConnection(it) },
    private val validate: (URI) -> Unit = SystemMediaNetwork::validateTarget,
) {
    private val aborted = AtomicBoolean(false)
    @Volatile private var connection: HttpURLConnection? = null
    @Synchronized fun abort() { aborted.set(true); connection?.disconnect() }
    fun <T> publishIfActive(obsolete: () -> Boolean, action: () -> T): T? = synchronized(this) {
        if (aborted.get() || obsolete()) null else action()
    }
    private fun checkActive() {
        if (aborted.get() || cancelled() || Thread.currentThread().isInterrupted) {
            throw InterruptedIOException("下载已暂停")
        }
    }

    fun transfer(url: URI, source: URI, partial: File, userAgent: String,
        maxBytes: Long = 2L * 1024 * 1024 * 1024,
        requestCookies: (URI) -> String? = { null },
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long {
        val metadataFile = File(partial.path + ".resume")
        val identity = MessageDigest.getInstance("SHA-256").digest(stableIdentity(url).toByteArray())
            .joinToString("") { "%02x".format(it) }
        var failure: IOException? = null
        repeat(4) { attempt ->
            checkActive()
            try {
                while (true) {
                    checkActive()
                    val metadata = Properties().apply {
                        if (metadataFile.isFile) runCatching { metadataFile.inputStream().use { load(it) } }
                    }
                    var offset = partial.length()
                    val validator = metadata.getProperty("validator")?.takeIf { it.isNotBlank() }
                    if (offset > 0 && (metadata.getProperty("identity") != identity || validator == null)) {
                        RandomAccessFile(partial, "rw").use { it.setLength(0) }
                        metadataFile.delete()
                        offset = 0
                    }
                    var uri = url
                    var response: HttpURLConnection? = null
                    try {
                        for (redirect in 0..5) {
                            checkActive(); validate(uri)
                            val current = connect(uri)
                            connection = current
                            current.instanceFollowRedirects = false
                            current.connectTimeout = 15000
                            current.readTimeout = 20000
                            current.setRequestProperty("Accept-Encoding", "identity")
                            current.setRequestProperty("User-Agent", userAgent)
                            current.setRequestProperty("Accept", "*/*")
                            current.setRequestProperty("Referer", source.toString())
                            current.setRequestProperty("Origin", "${source.scheme}://${source.rawAuthority}")
                            requestCookies(uri)?.takeIf { it.isNotBlank() }?.let {
                                current.setRequestProperty("Cookie", it)
                            }
                            if (offset > 0) {
                                current.setRequestProperty("Range", "bytes=$offset-")
                                current.setRequestProperty("If-Range", validator)
                            }
                            // Cookie selection is recalculated for every redirect target.
                            val status = current.responseCode
                            if (status in listOf(301, 302, 303, 307, 308)) {
                                check(redirect < 5) { "重定向过多" }
                                val next = uri.resolve(current.getHeaderField("Location") ?: error("重定向缺少地址"))
                                require(uri.scheme != "https" || next.scheme == "https") { "禁止 HTTPS 降级重定向" }
                                current.disconnect(); uri = next
                            } else {
                                response = current; break
                            }
                        }
                        val current = response ?: error("重定向过多")
                        val status = current.responseCode
                        val receivedValidator = current.getHeaderField("ETag")?.takeIf {
                            it.startsWith('"') && it.endsWith('"')
                        } ?: current.getHeaderField("Last-Modified")
                        val contentRange = current.getHeaderField("Content-Range").orEmpty()
                        if (status == 416) {
                            val total = Regex("bytes \\*/(\\d+)").matchEntire(contentRange)?.groupValues?.get(1)?.toLongOrNull()
                            if (offset > 0 && total == offset && receivedValidator == validator) return offset
                            RandomAccessFile(partial, "rw").use { it.setLength(0) }
                            metadataFile.delete()
                            throw IOException("媒体 Range 已失效")
                        }
                        if (status == 401 || status == 403) throw MediaAuthorizationException()
                        if (status == 408 || status == 425 || status == 429 || status >= 500) {
                            throw IOException("媒体服务器暂时不可用 HTTP $status")
                        }
                        check(status == 200 || status == 206) { "媒体下载 HTTP $status" }
                        check(current.getHeaderField("Content-Encoding").let { it == null || it == "identity" }) {
                            "媒体续传不支持压缩响应"
                        }
                        val range = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(contentRange)
                        val start = range?.groupValues?.get(1)?.toLongOrNull()
                        val end = range?.groupValues?.get(2)?.toLongOrNull()
                        val total = range?.groupValues?.get(3)?.toLongOrNull()
                        if (status == 206) {
                            check(start == offset && end != null && total != null && end >= start && end < total) {
                                "媒体响应 Range 无效"
                            }
                            if (offset > 0L &&
                                (receivedValidator == null || receivedValidator != validator)) {
                                RandomAccessFile(partial, "rw").use { it.setLength(0) }
                                metadataFile.delete()
                                throw IOException("媒体响应验证标识缺失或已变化，重新下载")
                            }
                        }
                        val append = status == 206 && offset > 0
                        val expected = current.contentLengthLong.takeIf { it >= 0 }
                        check((expected ?: 0) + (if (append) offset else 0) <= maxBytes) { "媒体响应过大" }
                        partial.parentFile?.mkdirs()
                        // Truncate before replacing the validator: a crash between
                        // these steps cannot associate old bytes with a new ETag.
                        var length = 0L
                        RandomAccessFile(partial, "rw").use { output ->
                            if (!append) output.setLength(0)
                            output.seek(if (append) offset else 0)
                            val state = Properties().apply {
                                setProperty("identity", identity)
                                setProperty("validator", receivedValidator ?: if (append) validator.orEmpty() else "")
                            }
                            val tmp = File(metadataFile.path + ".tmp")
                            try {
                                tmp.outputStream().use { state.store(it, null) }
                                check(tmp.renameTo(metadataFile)) { "无法保存续传状态" }
                            } finally {
                                if (tmp.exists()) tmp.delete()
                            }
                            var written = 0L
                            current.inputStream.use { input ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    checkActive()
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    checkActive()
                                    check(output.filePointer + read <= maxBytes) { "媒体响应过大" }
                                    output.write(buffer, 0, read)
                                    written += read
                                    onProgress(output.filePointer, total ?: expected)
                                }
                            }
                            output.fd.sync()
                            if (expected != null && written != expected ||
                                status == 206 && written != end!! - start!! + 1) {
                                throw IOException("媒体响应未完整接收")
                            }
                            length = output.length()
                        }
                        checkActive()
                        if (status == 206 && length < total!!) {
                            if (receivedValidator == null && validator == null) {
                                throw IOException("媒体分段响应缺少验证标识")
                            }
                            continue
                        }
                        return length
                    } finally {
                        response?.disconnect(); connection = null
                    }
                }
            } catch (error: InterruptedIOException) {
                checkActive(); failure = error
            } catch (error: IOException) {
                checkActive(); failure = error
            } finally {
                connection?.disconnect(); connection = null
            }
            if (attempt < 3) Thread.sleep(100L shl attempt)
        }
        throw failure ?: IOException("媒体连接失败")
    }

    private fun stableIdentity(uri: URI): String {
        val volatile = setOf("auth", "auth_key", "expires", "expire", "exp", "hmac", "sig", "sign", "signature", "t", "time", "timestamp", "token", "v", "via", "via_bm")
        val query = uri.rawQuery?.split('&')?.filter {
            it.substringBefore('=').lowercase() !in volatile
        }?.joinToString("&")
        return URI(uri.scheme, uri.rawAuthority, uri.path, query, null).toString()
    }
}

class MediaAuthorizationException : IllegalStateException("下载地址需要重新授权")
