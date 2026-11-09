package dev.vikiea.site_lens

import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** HTTP-only health check; the system owns routing, DNS, proxy and VPN. */
class HealthHttpProbe(
    private val connect: (URI) -> HttpURLConnection,
) : AutoCloseable {
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val closed = AtomicBoolean(false)
    private val connection = AtomicReference<HttpURLConnection?>()

    override fun close() {
        closed.set(true)
        connection.getAndSet(null)?.disconnect()
        timer.shutdownNow()
    }

    fun probe(url: String?, epoch: Long = 0L): Map<String, Any?> {
        val started = System.nanoTime()
        val timedOut = AtomicBoolean(false)
        val deadline = timer.schedule({
            timedOut.set(true)
            connection.getAndSet(null)?.disconnect()
        }, 5, TimeUnit.SECONDS)
        var current: URI? = null
        var category: String? = null
        var status = "unreachable"
        var usedProxy = false
        try {
            current = URI(url ?: error("缺少地址"))
            hop@ for (redirect in 0..5) {
                if (closed.get() || timedOut.get()) throw SocketTimeoutException()
                val target = current ?: throw IOException("缺少重定向目标")
                SystemMediaNetwork.validateTarget(target)
                val active = connect(target)
                connection.set(active)
                try {
                    if (closed.get() || timedOut.get()) throw SocketTimeoutException()
                    val remaining = (
                        5_000 - TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
                    ).coerceAtLeast(1).toInt()
                    active.connectTimeout = remaining
                    active.readTimeout = remaining
                    active.instanceFollowRedirects = false
                    active.setRequestProperty("Range", "bytes=0-1023")
                    val code = active.responseCode
                    usedProxy = active.usingProxy()
                    if (code in setOf(301, 302, 303, 307, 308)) {
                        require(redirect < 5)
                        val next = target.resolve(
                            active.getHeaderField("Location") ?: error("重定向缺少地址"),
                        )
                        require(target.scheme != "https" || next.scheme == "https")
                        SystemMediaNetwork.validateTarget(next)
                        current = next
                    } else {
                        status = if (code in 200..299) "reachable" else "unreachable"
                        category = when {
                            code in 200..299 -> null
                            code == 401 -> "http_401"
                            code == 403 -> "http_403"
                            code == 407 -> "proxy_connect_status"
                            code >= 500 -> "http_5xx"
                            else -> "unknown"
                        }
                        break@hop
                    }
                } finally {
                    connection.getAndSet(null)?.disconnect()
                }
            }
        } catch (error: Exception) {
            category = when {
                timedOut.get() || error is SocketTimeoutException -> "timeout"
                error is IllegalArgumentException -> "request_policy"
                error is IOException -> (
                    SystemMediaNetwork.classifyTransportFailure(error, usedProxy) as? MediaRouteIOException
                )?.category ?: "socket"
                else -> "unknown"
            }
        } finally {
            deadline.cancel(false)
            connection.getAndSet(null)?.disconnect()
        }
        val finalUrl = current
            ?.takeIf { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() }
            ?.let {
                runCatching {
                    URI(it.scheme, null, it.host, it.port, it.path, null, null).toASCIIString()
                }.getOrNull()
            }
        return mapOf(
            "status" to status,
            "finalUrl" to finalUrl,
            "proxyConfigured" to usedProxy,
            "networkEpoch" to epoch,
            "failureCategory" to if (category == "io") "socket" else category,
            "elapsedMs" to TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started),
        )
    }
}
