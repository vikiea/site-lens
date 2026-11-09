package dev.vikiea.site_lens

import java.net.HttpURLConnection
import java.net.URI
import java.net.SocketTimeoutException
import javax.net.ssl.SSLPeerUnverifiedException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class HealthHttpProbeTest {
    private fun response(
        uri: URI,
        status: Int,
        location: String? = null,
        proxy: Boolean = false,
    ) = object : HttpURLConnection(uri.toURL()) {
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = proxy
        override fun getResponseCode() = status
        override fun getHeaderField(name: String?) = if (name == "Location") location else null
    }

    @Test
    fun redirectsKeepSystemOrderAndAllowLoopbackTargets() {
        val hosts = mutableListOf<String>()
        HealthHttpProbe { uri ->
            hosts += uri.host
            if (uri.host == "start.example") {
                response(uri, 302, "https://127.0.0.1/private")
            } else {
                response(uri, 200, proxy = true)
            }
        }.use { probe ->
            val result = probe.probe("https://start.example/")
            assertEquals(listOf("start.example", "127.0.0.1"), hosts)
            assertEquals("reachable", result["status"])
            assertEquals(true, result["proxyConfigured"])
            assertFalse(result.toString().contains("token="))
        }
    }

    @Test
    fun oneConnectionFailureStaysOneFailure() {
        var requests = 0
        HealthHttpProbe { _ ->
            requests++
            throw SocketTimeoutException()
        }.use { probe ->
            val result = probe.probe("https://cdn.example/media?token=secret")
            assertEquals(1, requests)
            assertEquals("timeout", result["failureCategory"])
            assertFalse(result.toString().contains("secret"))
        }
    }

    @Test
    fun authorizationTransportAndTlsRemainDistinct() {
        for ((code, category) in listOf(
            401 to "http_401",
            403 to "http_403",
            503 to "http_5xx",
        )) {
            HealthHttpProbe { uri -> response(uri, code) }.use {
                assertEquals(category, it.probe("https://cdn.example/")["failureCategory"])
            }
        }
        HealthHttpProbe { _ ->
            throw SSLPeerUnverifiedException("hostname mismatch")
        }.use {
            assertEquals(
                "hostname",
                it.probe("https://cdn.example/")["failureCategory"],
            )
        }
    }
}
