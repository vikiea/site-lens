package dev.vikiea.site_lens

import java.io.IOException
import java.net.InetSocketAddress
import java.net.InetAddress
import java.net.HttpURLConnection
import java.net.ProtocolException
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

class SystemMediaNetworkTest {
    @Test
    fun proxyWithDirectFallbackDoesNotResolveOriginBeforeTryingProxy() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val policy = selector { listOf(proxy, Proxy.NO_PROXY) }
        val target = URI("https://cdn.example/a")
        val visited = mutableListOf<Proxy>()
        var resolutions = 0
        val connection = object : HttpURLConnection(target.toURL()) {
            override fun connect() = Unit
            override fun disconnect() = Unit
            override fun usingProxy() = true
        }
        fun open(attempt: Int) = SystemMediaNetwork.openConnection(
            target, attempt = attempt, selector = policy,
            resolve = { resolutions++; arrayOf(InetAddress.getByName("198.18.0.1")) },
            open = { _, selected -> visited.add(selected); connection },
        )
        assertEquals(connection, open(0))
        assertEquals(0, resolutions)
        assertEquals(listOf(proxy), visited)
        // An HTTP proxy configuration skips DIRECT without resolving it.
        assertEquals(connection, open(1))
        assertEquals(0, resolutions)
        assertEquals(listOf(proxy, proxy), visited)
    }

    @Test
    fun unavailableProxyNeverSilentlyFallsBackToDirect() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val policy = selector { listOf(proxy, Proxy.NO_PROXY) }
        val target = URI("https://cdn.example/a")
        val visited = mutableListOf<Proxy>()
        assertThrows(IOException::class.java) {
            SystemMediaNetwork.openConnection(
                target,
                selector = policy,
                open = { _, selected ->
                    visited.add(selected)
                    if (selected == proxy) throw IOException("proxy unavailable")
                    error("DIRECT must not be attempted")
                },
            )
        }
        assertEquals(listOf(proxy), visited)
    }

    @Test
    fun retryAdvancesHttpProxyCandidatesWithoutAddingDirect() {
        val first = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val second = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7891))
        val policy = selector { listOf(first, second, Proxy.NO_PROXY) }
        val target = URI("https://cdn.example/a")
        val visited = mutableListOf<Proxy>()
        var resolutions = 0
        for (attempt in 0..2) {
            SystemMediaNetwork.openConnection(target, attempt = attempt, selector = policy,
                resolve = { resolutions++; arrayOf(InetAddress.getByName("8.8.8.8")) },
                open = { _, selected ->
                    visited.add(selected)
                    object : HttpURLConnection(target.toURL()) {
                        override fun connect() = Unit
                        override fun disconnect() = Unit
                        override fun usingProxy() = selected != Proxy.NO_PROXY
                    }
                },
            )
        }
        assertEquals(listOf(first, second, first), visited)
        assertEquals(0, resolutions)
    }

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

    @Test
    fun directMediaRouteMayUseDnsFakeIpWhenProxyPolicyAllowsIt() {
        val target = URI("https://cdn.example/a")
        val connection = object : HttpURLConnection(target.toURL()) {
            override fun connect() = Unit
            override fun disconnect() = Unit
            override fun usingProxy() = false
        }
        val actual = SystemMediaNetwork.openConnection(
            target,
            allowProxyFakeIp = true,
            preferredRoute = SystemMediaNetwork.RouteKind.ROUTER_FAKE_IP,
            selector = selector { listOf(Proxy.NO_PROXY) },
            resolve = { arrayOf(InetAddress.getByName("198.18.0.7")) },
            open = { _, _ -> connection },
        )
        assertEquals(connection, actual)
    }

    @Test
    fun legacyDirectEntryDoesNotTreatFakeIpAsPublicWithoutConfirmedRoute() {
        val target = URI("https://cdn.example/a")
        assertThrows(IllegalArgumentException::class.java) {
            SystemMediaNetwork.openConnection(
                target,
                allowProxyFakeIp = true,
                selector = selector { listOf(Proxy.NO_PROXY) },
                resolve = { arrayOf(InetAddress.getByName("198.18.0.7")) },
                open = { _, _ -> error("fake-ip DIRECT must remain closed") },
            )
        }
    }

    @Test
    fun fakeIpCapabilityIsGrantedOnlyWhenSystemDnsActuallyReturnsFakeIp() {
        val target = URI("https://cdn.example/a")
        val direct = selector { listOf(Proxy.NO_PROXY) }
        assertEquals(
            true,
            SystemMediaNetwork.directDnsContainsFakeIp(
                target,
                selector = direct,
                resolve = { arrayOf(InetAddress.getByName("198.18.0.7")) },
            ),
        )
        assertEquals(
            false,
            SystemMediaNetwork.directDnsContainsFakeIp(
                target,
                selector = direct,
                resolve = { arrayOf(InetAddress.getByName("8.8.8.8")) },
            ),
        )
    }

    @Test
    fun fakeIpCapabilityDoesNotResolveOriginBeforeProxyAttempt() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val target = URI("https://cdn.example/a")
        var resolutions = 0
        val policy = selector { listOf(proxy, Proxy.NO_PROXY) }
        assertEquals(
            false,
            SystemMediaNetwork.directDnsContainsFakeIpForAttempt(
                target,
                attempt = 0,
                selector = policy,
                resolve = { resolutions++; arrayOf(InetAddress.getByName("198.18.0.7")) },
            ),
        )
        assertEquals(0, resolutions)
        assertEquals(
            true,
            SystemMediaNetwork.directDnsContainsFakeIpForAttempt(
                target,
                attempt = 1,
                selector = policy,
                resolve = { resolutions++; arrayOf(InetAddress.getByName("198.18.0.7")) },
            ),
        )
        assertEquals(1, resolutions)
    }

    @Test
    fun fakeIpRouteHintRequiresConfirmedVpnAndDirectEntry() {
        assertEquals(true, SystemMediaNetwork.fakeIpRouteEligible(true, true, true))
        assertEquals(true, SystemMediaNetwork.fakeIpRouteEligible(false, false, true))
        assertEquals(false, SystemMediaNetwork.fakeIpRouteEligible(false, null, true))
        assertEquals(false, SystemMediaNetwork.fakeIpRouteEligible(false, true, true))
        assertEquals(false, SystemMediaNetwork.fakeIpRouteEligible(true, false, false))
    }

    @Test
    fun fakeIpRequiresVpnOrExplicitNonVpnCapabilityAndDirectRoute() {
        assertEquals(true, SystemMediaNetwork.fakeIpRouteAllowed(true, true, true, true))
        assertEquals(true, SystemMediaNetwork.fakeIpRouteAllowed(false, false, true, true))
        assertEquals(false, SystemMediaNetwork.fakeIpRouteAllowed(false, null, true, true))
        assertEquals(false, SystemMediaNetwork.fakeIpRouteAllowed(false, false, false, true))
        assertEquals(false, SystemMediaNetwork.fakeIpRouteAllowed(false, false, true, false))
    }

    @Test
    fun routerFakeIpAllowsDirectFallbackOnlyAfterDirectRouteIsSelected() {
        assertEquals(true, SystemMediaNetwork.routerFakeIpRouteAllowed(true, true))
        assertEquals(false, SystemMediaNetwork.routerFakeIpRouteAllowed(false, true))
        assertEquals(false, SystemMediaNetwork.routerFakeIpRouteAllowed(true, false))
    }

    @Test
    fun fakeIpRouteKindDistinguishesVpnTunFromGatewayDns() {
        assertEquals(
            SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
            SystemMediaNetwork.fakeIpRouteKind(true),
        )
        assertEquals(
            SystemMediaNetwork.RouteKind.ROUTER_FAKE_IP,
            SystemMediaNetwork.fakeIpRouteKind(false),
        )
    }

    @Test
    fun vpnTunFakeIpIsPreferredWhenHttpProxyAndVpnAreBothPresent() {
        val info = SystemMediaNetwork.RouteInfo(
            SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
            SystemMediaNetwork.DnsOwner.SYSTEM_DNS,
            fakeIpAllowed = true,
            proxyConfigured = true,
            preferVpnTun = true,
            directAllowed = true,
        )
        assertEquals(SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
            SystemMediaNetwork.strategyForAttempt(info, 0))
        assertEquals(SystemMediaNetwork.RouteKind.HTTP_PROXY,
            SystemMediaNetwork.strategyForAttempt(info, 1))
        assertEquals(SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
            SystemMediaNetwork.strategyForAttempt(info, 2))
    }

    @Test
    fun routePlanAlternatesVpnTunAndHttpProxyWithoutResolvingOriginForProxy() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val target = URI("https://cdn.example/a")
        val fake = arrayOf(InetAddress.getByName("198.18.0.7"))
        var resolutions = 0
        val tun = SystemMediaNetwork.planFor(
            target,
            listOf(proxy),
            vpnTransport = true,
            routerTrusted = false,
            attempt = 0,
            resolve = { resolutions++; fake },
        )
        assertEquals(SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP, tun.info.kind)
        assertEquals("system_route", tun.info.targetDnsMode)
        assertEquals(Proxy.NO_PROXY, tun.proxy)
        assertEquals(listOf(fake[0]), tun.addresses)
        assertEquals(1, resolutions)
        val http = SystemMediaNetwork.planFor(
            target,
            listOf(proxy),
            vpnTransport = true,
            routerTrusted = false,
            attempt = 1,
            resolve = { resolutions++; fake },
        )
        assertEquals(SystemMediaNetwork.RouteKind.HTTP_PROXY, http.info.kind)
        assertEquals("proxy_remote", http.info.targetDnsMode)
        assertEquals(proxy, http.proxy)
        assertEquals(1, resolutions)
    }

    @Test
    fun routePlanAllowsPublicDirectOnlyWhenNoProxyIsConfigured() {
        val target = URI("https://cdn.example/a")
        val plan = SystemMediaNetwork.planFor(
            target,
            listOf(Proxy.NO_PROXY),
            vpnTransport = false,
            routerTrusted = false,
            resolve = { arrayOf(InetAddress.getByName("8.8.8.8")) },
        )
        assertEquals(SystemMediaNetwork.RouteKind.PUBLIC_DIRECT, plan.info.kind)
        assertEquals(true, plan.info.directAllowed)
        assertEquals(Proxy.NO_PROXY, plan.proxy)
    }

    @Test
    fun routePlanAllowsGatewayFakeIpWithPublicDnsOrUnvalidatedNetwork() {
        val target = URI("https://cdn.example/a")
        val plan = SystemMediaNetwork.planFor(
            target,
            listOf(Proxy.NO_PROXY),
            vpnTransport = false,
            routerTrusted = true,
            resolve = { arrayOf(InetAddress.getByName("198.18.0.7")) },
        )
        assertEquals(SystemMediaNetwork.RouteKind.ROUTER_FAKE_IP, plan.info.kind)
        assertEquals("system_route", plan.info.targetDnsMode)
        assertEquals(true, plan.info.fakeIpAllowed)
        assertEquals(Proxy.NO_PROXY, plan.proxy)
    }

    @Test
    fun httpProxyStrategyNeverAddsDirectCandidate() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val target = URI("https://cdn.example/a")
        val visited = mutableListOf<Proxy>()
        assertThrows(IOException::class.java) {
            SystemMediaNetwork.openConnection(
                target,
                preferredRoute = SystemMediaNetwork.RouteKind.HTTP_PROXY,
                selector = selector { listOf(proxy, Proxy.NO_PROXY) },
                open = { _, selected ->
                    visited += selected
                    throw IOException("proxy unavailable")
                },
            )
        }
        assertEquals(listOf(proxy), visited)
    }

    @Test
    fun explicitVpnTunStrategyUsesDirectFakeIpAndKeepsHostUnresolved() {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val target = URI("https://cdn.example/a")
        val visited = mutableListOf<Proxy>()
        var resolutions = 0
        val connection = object : HttpURLConnection(target.toURL()) {
            override fun connect() = Unit
            override fun disconnect() = Unit
            override fun usingProxy() = false
        }
        val actual = SystemMediaNetwork.openConnection(
            target,
            allowProxyFakeIp = true,
            preferredRoute = SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
            selector = selector { listOf(proxy) },
            resolve = { resolutions++; arrayOf(InetAddress.getByName("198.18.0.7")) },
            open = { _, selected -> visited += selected; connection },
        )
        assertEquals(connection, actual)
        assertEquals(listOf(Proxy.NO_PROXY), visited)
        assertEquals(1, resolutions)
    }

    @Test
    fun transportFailuresExposeSafeRouteCategories() {
        assertEquals(
            "proxy_connect",
            (SystemMediaNetwork.classifyTransportFailure(
                ProtocolException("proxy CONNECT failed"),
                proxyRoute = true,
            ) as MediaRouteIOException).category,
        )
        assertEquals(
            "tls_handshake",
            (SystemMediaNetwork.classifyTransportFailure(
                SSLHandshakeException("handshake failed"),
                proxyRoute = true,
            ) as MediaRouteIOException).category,
        )
        assertEquals(
            "hostname",
            (SystemMediaNetwork.classifyTransportFailure(
                SSLPeerUnverifiedException("Hostname cdn.example not verified"),
                proxyRoute = true,
            ) as MediaRouteIOException).category,
        )
        assertEquals(
            "proxy_connect_status",
            (SystemMediaNetwork.classifyTransportFailure(
                IOException("Failed to authenticate with proxy"),
                proxyRoute = true,
            ) as MediaRouteIOException).category,
        )
    }

    @Test
    fun routerFakeIpUsesDirectPhysicalRouteInsteadOfDnsOwnerHeuristic() {
        assertEquals(true, SystemMediaNetwork.routerFakeIpEligible(true, true, true, true))
        assertEquals(true, SystemMediaNetwork.routerFakeIpEligible(false, true, true, true))
        assertEquals(false, SystemMediaNetwork.routerFakeIpEligible(true, false, true, true))
        assertEquals(true, SystemMediaNetwork.routerFakeIpEligible(true, true, false, true))
        assertEquals(false, SystemMediaNetwork.routerFakeIpEligible(true, true, true, false))
    }

    private fun selector(select: (URI) -> List<Proxy>) = object : ProxySelector() {
        override fun select(uri: URI) = select.invoke(uri)
        override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) = Unit
    }

    @Test
    fun probeLookupCanReadLocalExclusionsWithoutGrantingMediaAccess() {
        val visited = mutableListOf<URI>()
        val policy = selector { uri -> visited.add(uri); listOf(Proxy.NO_PROXY) }
        val local = URI("http://127.0.0.2:8080/ready")
        assertEquals("DIRECT", SystemMediaNetwork.probeConfiguration(local, policy))
        assertEquals(listOf(local), visited)
        assertThrows(IllegalArgumentException::class.java) {
            SystemMediaNetwork.configuration(local, selector { error("must not select proxy") })
        }
        assertThrows(IllegalArgumentException::class.java) {
            SystemMediaNetwork.openConnection(local,
                selector = selector { error("must not select proxy") },
                resolve = { error("must not resolve") },
                open = { _, _ -> error("must not connect") },
            )
        }
        for (raw in listOf("https://user:password@cdn.example/a", "file:///tmp/video", "ftp://cdn.example/a")) {
            assertThrows(IllegalArgumentException::class.java) {
                SystemMediaNetwork.probeConfiguration(URI(raw), selector { error("must not select proxy") })
            }
        }
        assertThrows(IllegalStateException::class.java) {
            SystemMediaNetwork.probeConfiguration(local, selector { emptyList() })
        }
        assertThrows(IllegalStateException::class.java) {
            SystemMediaNetwork.probeConfiguration(local, selector {
                listOf(Proxy(Proxy.Type.SOCKS, InetSocketAddress.createUnresolved("127.0.0.1", 7890)))
            })
        }
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
    fun configurationRotatesProxyOrderForRetryAttempts() {
        val first = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890))
        val second = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7891))
        val policy = selector { listOf(first, second) }
        val target = URI("https://cdn.example/a")
        assertEquals(
            "PROXY 127.0.0.1:7890; PROXY 127.0.0.1:7891",
            SystemMediaNetwork.configuration(target, policy, attempt = 0),
        )
        assertEquals(
            "PROXY 127.0.0.1:7891; PROXY 127.0.0.1:7890",
            SystemMediaNetwork.configuration(target, policy, attempt = 1),
        )
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
