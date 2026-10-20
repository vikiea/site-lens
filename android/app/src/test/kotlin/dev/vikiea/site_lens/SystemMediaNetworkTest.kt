package dev.vikiea.site_lens

import java.io.IOException
import java.net.InetSocketAddress
import java.net.InetAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SystemMediaNetworkTest {
    @Test
    fun privateAndReservedTargetsAreRejectedBeforeProxySelection() {
        for (host in listOf("localhost", "127.0.0.1", "2130706433", "10.1.2.3", "192.168.1.1",
            "169.254.169.254", "198.18.0.1", "[::1]", "[::ffff:127.0.0.1]")) {
            assertThrows(IllegalArgumentException::class.java) {
                SystemMediaNetwork.proxies(URI("http://$host/video"), selector { error("must not select proxy") })
            }
        }
        assertEquals(true, SystemMediaNetwork.publicAddress(InetAddress.getByName("8.8.8.8")))
        assertEquals(true, SystemMediaNetwork.fakeIp(InetAddress.getByName("198.19.0.1")))
    }

    private fun selector(select: (URI) -> List<Proxy>) = object : ProxySelector() {
        override fun select(uri: URI) = select.invoke(uri)
        override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) = Unit
    }

    @Test
    fun httpProxyAndExclusionsAreResolvedForEachOrigin() {
        val visited = mutableListOf<URI>()
        val policy = selector { uri ->
            visited.add(uri)
            if (uri.host == "direct.example") listOf(Proxy.NO_PROXY)
            else listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890)))
        }
        assertEquals("PROXY 127.0.0.1:7890", SystemMediaNetwork.configuration(URI("https://cdn.example/a"), policy))
        assertEquals("DIRECT", SystemMediaNetwork.configuration(URI("https://direct.example/b"), policy))
        assertEquals(2, visited.size)
    }

    @Test
    fun ipv6ProxyUsesBracketedHost() {
        val policy = selector { listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("::1", 7890))) }
        assertEquals("PROXY [::1]:7890", SystemMediaNetwork.configuration(URI("https://cdn.example/a"), policy))
    }

    @Test
    fun unsupportedProxyNeverBecomesDirect() {
        val policy = selector { listOf(Proxy(Proxy.Type.SOCKS, InetSocketAddress.createUnresolved("127.0.0.1", 7890))) }
        assertThrows(IllegalStateException::class.java) {
            SystemMediaNetwork.configuration(URI("https://cdn.example/a"), policy)
        }
    }

    @Test
    fun rejectsCredentialBearingAndNonWebUrls() {
        for (raw in listOf("https://user:password@cdn.example/a", "file:///tmp/video", "ftp://cdn.example/a")) {
            assertThrows(IllegalArgumentException::class.java) { SystemMediaNetwork.configuration(URI(raw), null) }
        }
    }
}
