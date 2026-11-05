package dev.vikiea.site_lens

import java.net.HttpURLConnection
import java.net.URI
import java.net.SocketTimeoutException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.*
import org.junit.Test

class HealthHttpProbeTest {
    private val vpn = SystemMediaNetwork.RouteInfo(SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
        SystemMediaNetwork.DnsOwner.SYSTEM_DNS, true, proxyConfigured = true, targetDnsMode = "system_route")
    private fun response(uri: URI, status: Int, location: String? = null) = object : HttpURLConnection(uri.toURL()) {
        override fun connect() {}
        override fun disconnect() {}
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getHeaderField(name: String?) = if (name == "Location") location else null
    }
    @Test fun redirectsShareTheTwoStrategyFailureBudget() {
        val attempts = mutableListOf<Pair<String, Int>>()
        HealthHttpProbe { uri, attempt, onRoute ->
            attempts += uri.host to attempt
            onRoute(vpn)
            if (uri.host == "start.example" && attempt == 1) {
                response(uri, 302, "https://final.example/target")
            } else { throw SocketTimeoutException() }
        }.use {
            val result = it.probe("https://start.example/")
            assertEquals("timeout", result["failureCategory"])
            assertEquals(listOf("start.example" to 0, "start.example" to 1, "final.example" to 1), attempts)
        }
    }

    @Test fun proxyFallbackIsBoundedAndNeverImplicitlyDirect() {
        val attempts = mutableListOf<Int>()
        HealthHttpProbe { uri, attempt, onRoute ->
            attempts += attempt
            onRoute(vpn.copy(kind = if (attempt == 0) vpn.kind else SystemMediaNetwork.RouteKind.HTTP_PROXY))
            if (attempt == 0) throw SSLHandshakeException("do not serialize token=secret")
            response(uri, 206)
        }.use { probe ->
            val result = probe.probe("https://cdn.example/media?token=secret")
            assertEquals(listOf(0, 1), attempts)
            assertEquals("reachable", result["status"])
            assertEquals("http_proxy", result["routeKind"])
            assertFalse(result.toString().contains("secret"))
            assertFalse(result.toString().contains("token="))
        }
    }
    @Test fun redirectsRejectPrivateTargetsWithoutConnecting() {
        val hosts = mutableListOf<String>()
        HealthHttpProbe { uri, _, onRoute ->
            hosts += uri.host; onRoute(vpn)
            response(uri, 302, "https://127.0.0.1/private")
        }.use { probe ->
            val result = probe.probe("https://cdn.example/start")
            assertEquals(listOf("cdn.example"), hosts)
            assertEquals("unreachable", result["status"])
            assertEquals("fake_ip_policy", result["failureCategory"])
        }
    }
    @Test fun authorizationAndTransportRemainDistinct() {
        for ((code, category) in listOf(401 to "http_401", 403 to "http_403", 503 to "http_5xx")) {
            HealthHttpProbe { uri, _, onRoute -> onRoute(vpn); response(uri, code) }.use {
                assertEquals(category, it.probe("https://cdn.example/")["failureCategory"])
            }
        }
        var requests = 0
        HealthHttpProbe { _, _, onRoute -> requests++; onRoute(vpn); throw SocketTimeoutException() }.use {
            assertEquals("timeout", it.probe("https://cdn.example/")["failureCategory"])
            assertEquals(2, requests)
        }
    }
    @Test fun certificateFailureDoesNotRetry() {
        var requests = 0
        HealthHttpProbe { _, _, onRoute ->
            requests++; onRoute(vpn)
            throw javax.net.ssl.SSLPeerUnverifiedException("hostname mismatch")
        }.use {
            assertEquals("hostname", it.probe("https://cdn.example/")["failureCategory"])
            assertEquals(1, requests)
        }
    }
}
