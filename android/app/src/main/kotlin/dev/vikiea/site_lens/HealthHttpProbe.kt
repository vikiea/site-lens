package dev.vikiea.site_lens

import java.net.HttpURLConnection
import java.net.URI
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** HTTP-only state machine. No Activity, cookies, WebView or media state. */
class HealthHttpProbe(
    private val connect: (URI, Int, (SystemMediaNetwork.RouteInfo) -> Unit) -> HttpURLConnection,
) : AutoCloseable {
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val closed = AtomicBoolean(false)
    private val connection = AtomicReference<HttpURLConnection?>()
    override fun close() {
        closed.set(true)
        connection.getAndSet(null)?.disconnect()
        timer.shutdownNow()
    }
    fun probe(url: String?, startAttempt: Int = 0, epoch: Long = 0L): Map<String, Any?> {
        val started = System.nanoTime()
        val timedOut = AtomicBoolean(false)
        val deadline = timer.schedule({
            timedOut.set(true)
            connection.getAndSet(null)?.disconnect()
        }, 5, TimeUnit.SECONDS)
        var info: SystemMediaNetwork.RouteInfo? = null
        var current: URI? = null
        var routeFailures = 0
        var attempt = startAttempt
        var category: String? = null
        var status = "unreachable"
        try {
            require(startAttempt >= 0)
            current = URI(url ?: error("缺少地址"))
            hop@ for (redirect in 0..5) {
                var response: HttpURLConnection? = null
                while (routeFailures < 2) {
                    if (closed.get() || timedOut.get()) throw SocketTimeoutException()
                    attempt = startAttempt + routeFailures
                    try {
                        SystemMediaNetwork.validateTarget(current!!)
                        val active = connect(current!!, attempt) { info = it }
                        connection.set(active)
                        if (closed.get() || timedOut.get()) { active.disconnect(); throw SocketTimeoutException() }
                        val remaining = (5000 - TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)).coerceAtLeast(1).toInt()
                        active.connectTimeout = remaining
                        active.readTimeout = remaining
                        active.instanceFollowRedirects = false
                        active.setRequestProperty("Range", "bytes=0-1023")
                        active.responseCode
                        response = active
                        break
                    } catch (error: IOException) {
                        connection.getAndSet(null)?.disconnect()
                        category = (SystemMediaNetwork.classifyTransportFailure(error, info?.proxyConfigured == true) as? MediaRouteIOException)?.category ?: "socket"
                        routeFailures++
                        if (category in setOf("certificate", "hostname") || routeFailures >= 2) throw error
                    }
                }
                val active = response ?: throw IOException()
                try {
                    val code = active.responseCode
                    if (code in setOf(301, 302, 303, 307, 308)) {
                        require(redirect < 5)
                        val next = current!!.resolve(active.getHeaderField("Location") ?: error("重定向缺少地址"))
                        require(current!!.scheme != "https" || next.scheme == "https")
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
                } finally { connection.getAndSet(null)?.disconnect() }
            }
        } catch (error: Exception) {
            category = when {
                timedOut.get() || error is SocketTimeoutException -> "timeout"
                error is IllegalArgumentException -> "fake_ip_policy"
                error is IOException -> (SystemMediaNetwork.classifyTransportFailure(error, info?.kind == SystemMediaNetwork.RouteKind.HTTP_PROXY) as? MediaRouteIOException)?.category ?: "socket"
                else -> "unknown"
            }
        } finally {
            deadline.cancel(false)
            connection.getAndSet(null)?.disconnect()
        }
        // The final locator is deliberately stripped of query, fragment and
        // user info. The actual request retained the original URI in memory.
        val finalUrl = current?.takeIf { it.scheme in setOf("http", "https") && !it.host.isNullOrBlank() }
            ?.let { runCatching { URI(it.scheme, null, it.host, it.port, it.path, null, null).toASCIIString() }.getOrNull() }
        val payload = mapOf(
            "status" to status, "finalUrl" to finalUrl,
            "routeKind" to (info?.kind?.wireName ?: "unknown"),
            "dnsOwner" to (info?.dnsOwner?.wireName ?: "unknown"),
            "targetDnsMode" to (info?.targetDnsMode ?: "unknown"),
            "fakeIpAllowed" to (info?.fakeIpAllowed ?: false),
            "proxyConfigured" to (info?.proxyConfigured ?: false),
            "attempt" to attempt, "networkEpoch" to epoch,
            "failureCategory" to if (category == "io") "socket" else category,
            "elapsedMs" to TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started),
        )
        return payload
    }
}
