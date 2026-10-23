package dev.vikiea.site_lens

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DlnaRelayAddressTest {
    @Test fun returnsLocalEndpointWhenReceiverHasADifferentAddress() {
        var connected = false
        var closed = false
        val fake = object : Socket() {
            override fun connect(endpoint: SocketAddress, timeout: Int) { connected = true }
            override fun getLocalAddress() = InetAddress.getByName("192.0.2.1")
            override fun getInetAddress() = InetAddress.getByName("192.0.2.2")
            override fun close() { closed = true }
        }
        val result = DlnaRelayAddress.resolve(URI("http://192.0.2.2:1400/control"), socketFactory = { fake })
        assertEquals("192.0.2.1", result)
        assertTrue(connected)
        assertTrue(closed)
    }

    @Test fun resolvesAnActualDirectConnectionAndReleasesTheSocket() {
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            val result = DlnaRelayAddress.resolve(URI("http://127.0.0.1:${server.localPort}/control"))
            assertEquals("127.0.0.1", result)
            server.accept().use { accepted ->
                accepted.soTimeout = 1000
                assertEquals(-1, accepted.getInputStream().read())
            }
        }
    }

    @Test fun exposesStructuredFailureDetailsForDartDiagnostics() {
        val error = IllegalStateException("connection refused")
        val details = DlnaRelayAddress.failureDetails(error)
        assertEquals("java.lang.IllegalStateException", details["type"])
        assertEquals("connection refused", details["message"])
        assertTrue(details["stack"].orEmpty().contains("connection refused"))
    }
}
