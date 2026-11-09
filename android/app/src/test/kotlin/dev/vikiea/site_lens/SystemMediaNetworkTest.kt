package dev.vikiea.site_lens

import java.io.IOException
import java.io.InterruptedIOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLPeerUnverifiedException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SystemMediaNetworkTest {
    private fun selector(vararg candidates: Proxy) = object : ProxySelector() {
        override fun select(uri: URI): List<Proxy> = candidates.toList()
        override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) = Unit
    }

    @Test
    fun proxyListPreservesSystemOrderAndProtocolTypes() {
        val http = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        val socks = Proxy(
            Proxy.Type.SOCKS,
            InetSocketAddress.createUnresolved("127.0.0.1", 7891),
        )
        val target = URI("https://example.com/")
        assertEquals(
            listOf(http, socks, Proxy.NO_PROXY, http),
            SystemMediaNetwork.proxyCandidates(
                target,
                selector(http, socks, Proxy.NO_PROXY, http),
            ),
        )
    }

    @Test
    fun emptyOrMalformedSystemPolicyNeverBecomesDirect() {
        val target = URI("https://example.com/")
        assertThrows(IOException::class.java) {
            SystemMediaNetwork.proxyCandidates(target, selector())
        }
    }

    @Test
    fun onlyAnExplicitDirectCandidateUsesDirect() {
        val target = URI("https://example.com/")
        assertEquals(
            listOf(Proxy.NO_PROXY),
            SystemMediaNetwork.proxyCandidates(target, selector(Proxy.NO_PROXY)),
        )
    }

    @Test
    fun loopbackPrivateLanAndLocalNamesReachTheConnectionStage() {
        listOf(
            "http://127.0.0.1:7890/",
            "http://10.0.0.8/",
            "http://172.31.255.8/",
            "http://192.168.1.8/",
            "https://printer.local/",
            "http://media.internal/",
            "http://[::1]/",
        ).forEach { raw ->
            SystemMediaNetwork.validateTarget(URI(raw))
        }
    }

    @Test
    fun nonHttpAndCredentialBearingTargetsRemainRejected() {
        listOf(
            "ftp://example.com/file",
            "file:///tmp/test",
            "https://user:pass@example.com/",
            "https:///missing-host",
        ).forEach { raw ->
            assertThrows(IllegalArgumentException::class.java) {
                SystemMediaNetwork.validateTarget(URI(raw))
            }
        }
    }

    @Test
    fun proxyFailureClassificationStaysAtTheTransportBoundary() {
        assertEquals(
            "proxy_connect",
            (SystemMediaNetwork.classifyTransportFailure(
                java.net.ProtocolException("proxy connect failed"),
                proxyRoute = true,
            ) as MediaRouteIOException).category,
        )
        assertEquals(
            "timeout",
            (SystemMediaNetwork.classifyTransportFailure(
                SocketTimeoutException("slow"),
                proxyRoute = false,
            ) as MediaRouteIOException).category,
        )
        assertEquals(
            "hostname",
            (SystemMediaNetwork.classifyTransportFailure(
                SSLPeerUnverifiedException("hostname mismatch"),
                proxyRoute = false,
            ) as MediaRouteIOException).category,
        )
    }

    @Test
    fun tlsFailuresNameTheReasonAUserCanActOn() {
        fun category(error: IOException): String =
            (SystemMediaNetwork.classifyTransportFailure(error, proxyRoute = false)
                as MediaRouteIOException).category

        assertEquals(
            "tls_protocol",
            category(javax.net.ssl.SSLProtocolException("Received fatal alert: protocol_version")),
        )
        assertEquals(
            "tls_reset",
            category(
                javax.net.ssl.SSLHandshakeException(
                    "Connection reset by peer",
                    java.net.SocketException("Connection reset"),
                ),
            ),
        )
        assertEquals(
            "tls_handshake",
            category(javax.net.ssl.SSLHandshakeException("no appropriate handshake")),
        )
        assertEquals(
            "certificate",
            category(
                javax.net.ssl.SSLHandshakeException(
                    "handshake failed",
                    java.security.cert.CertificateException("expired"),
                ),
            ),
        )
        // A bare socket error never becomes a TLS category.
        assertEquals("io", category(java.io.IOException("broken")))
    }

    @Test
    fun media3ClientDelegatesPacCandidateRecoveryToOneOkHttpCall() {
        val http = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("proxy-one.local", 8080),
        )
        val socks = Proxy(
            Proxy.Type.SOCKS,
            InetSocketAddress.createUnresolved("proxy-two.local", 1080),
        )
        val source = URI("https://example.com/")
        val client = SystemMediaNetwork.buildOkHttpClient(
            source,
            selector = selector(http, socks, Proxy.NO_PROXY),
        )
        assertEquals(listOf(http, socks, Proxy.NO_PROXY), client.proxySelector.select(source))
        assertTrue(client.retryOnConnectionFailure)
        assertFalse(client.followRedirects)
        assertFalse(client.followSslRedirects)
        assertEquals(0, client.callTimeoutMillis)
    }

    @Test
    fun pacProxyHostsAreResolvedThroughSystemDnsPerRedirect() {
        val first = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("proxy-first.local", 8080),
        )
        val second = Proxy(
            Proxy.Type.SOCKS,
            InetSocketAddress.createUnresolved("proxy-second.local", 1080),
        )
        val dns = SystemMediaNetwork.SystemDns("cloudflare")
        val selector = SystemMediaNetwork.SystemProxySelector(
            object : ProxySelector() {
                override fun select(uri: URI): List<Proxy> =
                    if (uri.host == "first.example") listOf(first) else listOf(second)

                override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) = Unit
            },
            dns,
        )

        selector.select(URI("https://first.example/"))
        assertTrue(dns.usesSystemResolver("proxy-first.local"))
        assertFalse(dns.usesSystemResolver("proxy-second.local"))

        selector.select(URI("https://second.example/"))
        assertTrue(dns.usesSystemResolver("proxy-first.local"))
        assertTrue(dns.usesSystemResolver("proxy-second.local"))
    }

    @Test
    fun repeatedAndroidCallbacksDoNotAdvanceTheNetworkEpoch() {
        val gate = NetworkChangeGate()
        assertTrue(gate.available("wifi-1"))
        assertTrue(gate.capabilities("wifi-1", "wifi|validated"))
        assertFalse(gate.capabilities("wifi-1", "wifi|validated"))
        assertTrue(gate.linkProperties("wifi-1", "dns=192.0.2.1;proxy=none"))
        assertFalse(gate.linkProperties("wifi-1", "dns=192.0.2.1;proxy=none"))

        assertTrue(gate.available("vpn-2"))
        assertFalse(gate.lost("wifi-1"))
        assertTrue(gate.linkProperties("vpn-2", "dns=198.18.0.2;proxy=127.0.0.1:7890"))
    }

    @Test
    fun oneCallbackBurstPublishesOneNetworkEpoch() {
        var published = 0
        val first = CountDownLatch(1)
        val batcher = NetworkChangeBatcher(delayMs = 50) {
            published++
            first.countDown()
        }
        try {
            batcher.changed()
            batcher.changed()
            batcher.changed()
            assertTrue(first.await(2, TimeUnit.SECONDS))
            Thread.sleep(100)
            assertEquals(1, published)
        } finally {
            batcher.close()
        }
    }

    @Test
    fun aFailedProxiedHopReportsTheProxyItAttempted() {
        // selectedProxy is only assigned after execute() succeeds, so a
        // connect failure used to report DIRECT for a proxied attempt.
        val proxy = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        val connection = SystemMediaNetwork.openMediaConnection(
            URI("https://tp6.drleao.cn/key.bin"),
            listOf(proxy),
            opener = { throw java.io.IOException("connect refused") },
        )
        assertThrows(java.io.IOException::class.java) { connection.connect() }
        assertTrue(connection.usingProxy())
        connection.disconnect()
    }

    @Test
    fun anInjectedDirectHopReportsDirect() {
        val stub = object : java.net.HttpURLConnection(java.net.URL("https://tp6.drleao.cn/key.bin")) {
            override fun connect() = Unit
            override fun disconnect() = Unit
            override fun usingProxy() = false
            override fun getResponseCode() = 200
        }
        val connection = SystemMediaNetwork.openMediaConnection(
            URI("https://tp6.drleao.cn/key.bin"),
            listOf(Proxy.NO_PROXY),
            opener = { stub },
        )
        assertEquals(200, connection.responseCode)
        assertFalse(connection.usingProxy())
        connection.disconnect()
    }

    @Test
    fun nativeCancellationSurvivesTheTransferFailureWrapper() {
        assertTrue(mediaTransferCancelled(InterruptedIOException("paused")))
        assertTrue(
            mediaTransferCancelled(
                IOException("wrapped", InterruptedIOException("paused")),
            ),
        )
        assertFalse(mediaTransferCancelled(IOException("network")))
    }
}
