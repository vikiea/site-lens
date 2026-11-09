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

class MediaTransferFailure(
    val phase: String,
    val host: String,
    val attempt: Int,
    val offset: Long,
    val bytesWritten: Long,
    val route: String,
    val cookiePresent: Boolean,
    val reason: String,
    cause: Throwable,
    val attemptsUsed: Int = attempt + 1,
) : IOException("媒体连接失败，已保留缓存，可重试", cause) {
    fun retryable(): Boolean = reason !in setOf("certificate", "hostname")

    fun diagnostics(): Map<String, Any> = mapOf(
        "phase" to phase, "host" to host, "attempt" to attempt,
        "offset" to offset, "bytesWritten" to bytesWritten,
        "route" to route, "cookiePresent" to cookiePresent, "reason" to reason,
        "attemptsUsed" to attemptsUsed,
    )
}

/** Pure JVM transport, also exercised against an actual local HTTP server. */
class ResumableMediaTransfer(
    private val cancelled: () -> Boolean = { false },
    private val connect: ((URI) -> HttpURLConnection)? = null,
    private val connectForAttempt: ((URI, Int) -> HttpURLConnection)? = null,
    private val validate: (URI) -> Unit = SystemMediaNetwork::validateTarget,
    private val routeForConnection: (HttpURLConnection) -> String = {
        if (it.usingProxy()) "system_proxy" else "direct"
    },
    private val onAttempt: (Map<String, Any>) -> Unit = {},
    private val onAttemptStarted: (Int) -> Unit = {},
    private val networkEpochForAttempt: () -> Long = { 0L },
) {
    private val routeConnect: (URI, Int) -> HttpURLConnection =
        connectForAttempt
            ?: { _, _ -> error("生产媒体传输必须提供系统网络连接工厂") }

    var finalUrl: URI? = null
        private set
    var attemptsUsed: Int = 0
        private set
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
        requestHeaders: Map<String, String> = emptyMap(),
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
        maxAttempts: Int = 5,
        startAttempt: Int = 0,
    ): Long {
        require(maxAttempts > 0 && startAttempt >= 0) { "媒体重试预算无效" }
        val availableAttempts = maxAttempts.coerceAtMost(5)
        attemptsUsed = 0
        finalUrl = null
        val metadataFile = File(partial.path + ".resume")
        val identity = MessageDigest.getInstance("SHA-256").digest(stableIdentity(url).toByteArray())
            .joinToString("") { "%02x".format(it) }
        var failure: IOException? = null
        for (localAttempt in 0 until availableAttempts) {
            val attempt = startAttempt + localAttempt
            val startedAt = System.nanoTime()
            checkActive()
            attemptsUsed = localAttempt + 1
            onAttemptStarted(attemptsUsed)
            var failedUri = url
            var failurePhase = "connect"
            var failureOffset = 0L
            var failureBytes = 0L
            var failureRoute = "unknown"
            var cookiePresent = false
            var responseStatus = 0
            var attemptFailed = false
            var failureCategory = "none"
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
                            checkActive(); validate(uri); failurePhase = "connect"
                            failedUri = uri
                            val current = connect?.invoke(uri)
                                ?: routeConnect(uri, attempt)
                            failureRoute = routeForConnection(current)
                            connection = current
                            current.instanceFollowRedirects = false
                            current.connectTimeout = 15000
                            current.readTimeout = 20000
                            current.setRequestProperty("Accept-Encoding", "identity")
                            current.setRequestProperty("User-Agent", userAgent)
                            current.setRequestProperty("Accept", "*/*")
                            // A CDN redirect cannot inherit origin credentials.
                            if (sameOrigin(url, uri)) requestHeaders.forEach { (name, value) ->
                                current.setRequestProperty(name, value)
                            }
                            current.setRequestProperty("Referer", URI(source.scheme, null, source.host, source.port, source.path, null, null).toASCIIString())
                            current.setRequestProperty("Origin", "${source.scheme}://${source.rawAuthority}")
                            requestCookies(uri)?.takeIf { it.isNotBlank() }?.let {
                                cookiePresent = true
                                current.setRequestProperty("Cookie", it)
                            }
                            if (offset > 0) {
                                current.setRequestProperty("Range", "bytes=$offset-")
                                current.setRequestProperty("If-Range", validator)
                            }
                            // Cookie selection is recalculated for every redirect target.
                            // connect() is where OkHttp runs DNS, TCP and the
                            // tunnel recheck, so a handshake or route failure
                            // belongs to this phase until a response exists.
                            failurePhase = "connect"
                            val status = current.responseCode
                            failurePhase = "response_headers"
                            failureOffset = offset
                            responseStatus = status
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
                        finalUrl = uri
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
                        if (status == 401 || status == 403) {
                            throw MediaAuthorizationException(attemptsUsed, status)
                        }
                        if (status == 407 && failureRoute !in setOf("direct", "unknown")) {
                            throw MediaRouteIOException(
                                "proxy_connect_status",
                                IOException("代理 CONNECT 被拒绝"),
                            )
                        }
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
                        failurePhase = "file_io"
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
                            failurePhase = "body_read"
                            current.inputStream.use { input ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    checkActive()
                                    failurePhase = "body_read"
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    checkActive()
                                    check(output.filePointer + read <= maxBytes) { "媒体响应过大" }
                                    failurePhase = "file_io"
                                    output.write(buffer, 0, read)
                                    written += read
                                    failureBytes = output.filePointer
                                    onProgress(output.filePointer, total ?: expected)
                                }
                            }
                            failurePhase = "file_io"
                            output.fd.sync()
                            failurePhase = "body_read"
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
                        connection?.disconnect(); connection = null
                    }
                }
            } catch (error: IOException) {
                attemptFailed = true
                checkActive()
                // Never serialize provider messages, URLs, query parameters,
                // proxy addresses or cookies through the diagnostics channel.
                val classified = if (error is MediaRouteIOException) {
                    error
                } else {
                    SystemMediaNetwork.classifyTransportFailure(
                        error,
                        proxyRoute = failureRoute !in setOf("direct", "unknown"),
                    )
                }
                val text = error.message.orEmpty().lowercase()
                val reason = when {
                    classified is MediaRouteIOException && classified.category != "io" ->
                        classified.category
                    "reset" in text -> "connection_reset"
                    "closed" in text -> "connection_closed"
                    else -> (classified as? MediaRouteIOException)?.category ?: "io"
                }
                failureCategory = reason
                failure = MediaTransferFailure(
                    phase = failurePhase,
                    host = failedUri.host ?: "unknown",
                    attempt = attempt,
                    offset = failureOffset,
                    bytesWritten = failureBytes,
                    route = failureRoute,
                    cookiePresent = cookiePresent,
                    reason = reason,
                    cause = error,
                    attemptsUsed = attemptsUsed,
                )
            } finally {
                connection?.disconnect(); connection = null
                runCatching {
                    onAttempt(mapOf(
                        "elapsedMs" to (System.nanoTime() - startedAt) / 1_000_000L,
                        "phase" to failurePhase,
                        "attempt" to attempt,
                        "route" to failureRoute,
                        "routeKind" to failureRoute,
                        "host" to (failedUri.host ?: "unknown"),
                        "offset" to failureOffset,
                        "failureCategory" to failureCategory,
                        "networkEpoch" to networkEpochForAttempt(),
                        "httpStatus" to responseStatus,
                        "bytesWritten" to failureBytes,
                        "outcome" to if (attemptFailed) "retry" else "completed",
                    ))
                }
            }
            val currentFailure = checkNotNull(failure)
            if (!currentFailure.retryable()) break
            if (localAttempt + 1 < availableAttempts) {
                Thread.sleep(
                    retryDelayMillis(
                        reason = currentFailure.reason,
                        bytesWritten = currentFailure.bytesWritten,
                        attempt = localAttempt,
                    ),
                )
            }
        }
        throw failure ?: IOException("媒体连接失败")
    }

    companion object {
        fun retryDelayMillis(reason: String?, bytesWritten: Long, attempt: Int): Long {
            val base = when (reason) {
                "dns", "proxy_connect", "proxy_connect_status", "timeout" -> 250L
                "connection_reset", "connection_closed" -> if (bytesWritten > 0L) 100L else 300L
                "tls", "tls_handshake", "tls_protocol" -> 500L
                // A reset socket is often a per-connection decision by the
                // edge, so the retry can succeed sooner than a protocol
                // refusal would.
                "tls_reset" -> if (bytesWritten > 0L) 150L else 250L
                else -> if (bytesWritten > 0L) 150L else 400L
            }
            return (base shl attempt.coerceIn(0, 4)).coerceAtMost(5_000L)
        }
    }

    private fun sameOrigin(first: URI, second: URI): Boolean =
        first.scheme.equals(second.scheme, ignoreCase = true) &&
            first.host.equals(second.host, ignoreCase = true) &&
            effectivePort(first) == effectivePort(second)

    private fun effectivePort(uri: URI): Int =
        if (uri.port != -1) uri.port else if (uri.scheme == "https") 443 else 80

    private fun stableIdentity(uri: URI): String {
        // Keep this list aligned with MediaDownloadService._resumeContentIdentity.
        // Rotating authorization parameters must not discard flushed bytes.
        val volatile = setOf(
            "auth", "auth_key", "expires", "expire", "exp", "hmac",
            "sig", "sign", "signature", "t", "time", "timestamp",
            "via", "via_bm", "token",
        )
        val query = uri.rawQuery?.split('&')?.filter {
            it.substringBefore('=').lowercase() !in volatile
        }?.joinToString("&")
        val base = uri.toASCIIString().substringBefore('#').substringBefore('?')
        return base + if (query.isNullOrEmpty()) "" else "?$query"
    }
}

class MediaAuthorizationException(
    val attemptsUsed: Int = 1,
    val statusCode: Int = 403,
) : IllegalStateException("下载地址需要重新授权")
