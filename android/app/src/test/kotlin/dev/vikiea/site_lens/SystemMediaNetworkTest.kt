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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

class SystemMediaNetworkTest {
    @Test
    fun publicDirectOnVpnUsesTheActiveVpnNetworkSocket() {
        assertEquals(true, SystemMediaNetwork.usesVpnNetwork(true, Proxy.NO_PROXY))
        assertEquals(false, SystemMediaNetwork.usesVpnNetwork(false, Proxy.NO_PROXY))
        assertEquals(
            false,
            SystemMediaNetwork.usesVpnNetwork(
                true,
                Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", 7890)),
            ),
        )
    }

    @Test
    fun linkPropertiesHttpProxyIsAddedWhenProxySelectorOnlyReportsDirect() {
        val link = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        val selected = SystemMediaNetwork.effectiveProxies(
            listOf(Proxy.NO_PROXY),
            link,
        )
        assertEquals(listOf(link, Proxy.NO_PROXY), selected)
    }

    @Test
    fun networkProxyIsAppendedAsASecondCandidateWithoutReordering() {
        val selectorProxy = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7891),
        )
        val linkProxy = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        // The selector entry keeps its position; the network-scoped proxy is a
        // second candidate for the retry, and no DIRECT route is invented.
        assertEquals(
            listOf(selectorProxy, linkProxy),
            SystemMediaNetwork.visibleProxyEndpoints(listOf(selectorProxy), listOf(linkProxy)),
        )
    }

    @Test
    fun duplicateNetworkProxyIsNotRetriedTwice() {
        val proxy = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        assertEquals(
            listOf(proxy),
            SystemMediaNetwork.visibleProxyEndpoints(listOf(proxy, Proxy.NO_PROXY), listOf(proxy)),
        )
    }

    @Test
    fun proxyOnlyCandidatesNeverGainADirectFallback() {
        // The invariant this change must preserve: a dead proxy is never
        // silently replaced by a direct connection.
        val first = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        val second = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7891),
        )
        val merged = SystemMediaNetwork.visibleProxyEndpoints(listOf(first), listOf(second))
        assertEquals(listOf(first, second), merged)
        assertEquals(false, merged.any { it.type() == Proxy.Type.DIRECT })
    }

    @Test
    fun aTunnelWithoutInternetIsStillUsableButANonTunnelNeverIs() {
        val wifi = Net("wifi", vpn = false, internet = true, validated = true)
        // clash.meta in rule mode: the tunnel reports no INTERNET capability
        // while the underlay carries connectivity. It must still be selected.
        assertEquals(
            "tun0",
            pick(wifi, listOf(wifi, Net("tun0", vpn = true, internet = false, validated = true))),
        )
        // With no tunnel present nothing is promoted and the underlay stays.
        assertEquals(null, pick(wifi, listOf(wifi)))
        // A non-VPN network that is "validated" does not become the tunnel.
        assertEquals(
            null,
            pick(wifi, listOf(wifi, Net("vpn-labelled-wifi", vpn = false, internet = true, validated = true))),
        )
    }

    @Test
    fun linkPropertiesProxyAloneStillYieldsAUsableCandidate() {
        val link = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        assertEquals(
            listOf(link, Proxy.NO_PROXY),
            SystemMediaNetwork.visibleProxyEndpoints(listOf(Proxy.NO_PROXY), listOf(link)),
        )
        assertEquals(
            listOf(Proxy.NO_PROXY),
            SystemMediaNetwork.visibleProxyEndpoints(listOf(Proxy.NO_PROXY), emptyList()),
        )
    }

    private data class Net(val name: String, val vpn: Boolean, val internet: Boolean,
                          val validated: Boolean)

    private fun pick(active: Net, all: List<Net>): String? = SystemMediaNetwork.pickVpnNetwork(
        active = active,
        candidates = all,
        activeIsVpn = active.vpn,
        isVpn = { it.vpn },
        isUsable = { it.internet },
        isValidated = { it.validated },
    )?.name

    @Test
    fun ruleModeTunnelWinsEvenWhenUnderlayStaysTheActiveNetwork() {
        // Observed on-device: clash.meta installs tun0 covering 0.0.0.0/5..7,
        // yet ConnectivityService still reports the Wi-Fi underlay as the
        // active default network. Reading only activeNetwork reports "no VPN"
        // and bypasses the tunnel.
        val wifi = Net("wifi", vpn = false, internet = true, validated = true)
        val tun = Net("tun0", vpn = true, internet = true, validated = true)
        assertEquals("tun0", pick(wifi, listOf(wifi, tun)))
    }

    @Test
    fun vpnSelectionKeepsAnActiveTunnelAndPromotesAValidatedOne() {
        val wifi = Net("wifi", vpn = false, internet = true, validated = true)
        val tun = Net("tun0", vpn = true, internet = true, validated = true)
        // Active network already is the tunnel: keep it.
        assertEquals("tun0", pick(tun, listOf(wifi, tun)))
        // No tunnel at all: nothing is promoted, the underlay stays.
        assertEquals(null, pick(wifi, listOf(wifi)))
        // A validated tunnel outranks an unvalidated one in the same list.
        assertEquals(
            "tun0",
            pick(
                wifi,
                listOf(
                    wifi,
                    Net("tun-old", vpn = true, internet = true, validated = false),
                    tun,
                ),
            ),
        )
        // A rule-mode tunnel may not advertise INTERNET itself; the observed
        // clash.meta tunnel is exactly that case and must still be selected.
        assertEquals(
            "tun0",
            pick(wifi, listOf(wifi, Net("tun0", vpn = true, internet = false, validated = true))),
        )
        assertEquals(
            null,
            pick(wifi, listOf(wifi, Net("dead-tun", vpn = true, internet = false, validated = false))),
        )
    }

    @Test
    fun ruleModeTunnelSelectionRequiresUsableOrValidatedNetwork() {
        // A validated tunnel may be selected even when it does not advertise
        // INTERNET, because rule-mode TUN can delegate validation to Wi-Fi.
        val wifi = Net("wifi", vpn = false, internet = true, validated = true)
        val tun = Net("tun0", vpn = true, internet = true, validated = true)
        assertEquals("tun0", pick(wifi, listOf(wifi, tun)))
        // An unvalidated tunnel without INTERNET is unusable and must not be
        // selected merely because it is present in allNetworks.
        val leanTun = Net("tun0", vpn = true, internet = false, validated = false)
        assertEquals(null, pick(wifi, listOf(wifi, leanTun)))
    }

    @Test
    fun vpnSocketBindingRequiresAConfirmedFakeIpDirectHop() {
        val fakeIp = SystemMediaNetwork.RouteInfo(
            kind = SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP,
            dnsOwner = SystemMediaNetwork.DnsOwner.SYSTEM_DNS,
            fakeIpAllowed = true,
            proxyConfigured = true,
            preferVpnTun = true,
            directAllowed = true,
            dnsClass = "fake_ip",
            targetDnsMode = "system_route",
            vpnTransport = true,
        )
        val proxy = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        val proxyHop = fakeIp.copy(
            kind = SystemMediaNetwork.RouteKind.HTTP_PROXY,
            dnsOwner = SystemMediaNetwork.DnsOwner.PROXY,
            fakeIpAllowed = false,
            dnsClass = "proxy",
        )
        val realAddress = fakeIp.copy(dnsClass = "real_address")
        val routerFakeIp = fakeIp.copy(
            kind = SystemMediaNetwork.RouteKind.ROUTER_FAKE_IP,
            proxyConfigured = false,
            preferVpnTun = false,
            vpnTransport = false,
        )

        assertTrue(SystemMediaNetwork.shouldBindVpnSocket(fakeIp, Proxy.NO_PROXY))
        assertFalse(SystemMediaNetwork.shouldBindVpnSocket(fakeIp, proxy))
        assertFalse(SystemMediaNetwork.shouldBindVpnSocket(proxyHop, proxy))
        assertFalse(SystemMediaNetwork.shouldBindVpnSocket(realAddress, Proxy.NO_PROXY))
        assertFalse(SystemMediaNetwork.shouldBindVpnSocket(routerFakeIp, Proxy.NO_PROXY))
    }

    @Test
    fun aSynthesizedAddressFallsBackToTheRealOne() {
        val target = URI("https://cdn.example/a")
        val fake = arrayOf(InetAddress.getByName("198.18.0.147"))
        val real = arrayOf(InetAddress.getByName("222.184.83.211"))

        // Default: the tunnel's synthesized answer is used as-is.
        val synthesized = SystemMediaNetwork.planFor(
            target,
            listOf(Proxy.NO_PROXY),
            vpnTransport = true,
            routerTrusted = false,
            resolve = { fake },
            resolveReal = { real },
        )
        assertEquals("fake_ip", synthesized.info.dnsClass)
        assertEquals(listOf(fake[0]), synthesized.addresses)

        // Once the host is known to fail, the real address wins while the
        // route stays a tunnel route.
        val downgraded = SystemMediaNetwork.planFor(
            target,
            listOf(Proxy.NO_PROXY),
            vpnTransport = true,
            routerTrusted = false,
            preferRealAddress = true,
            resolve = { fake },
            resolveReal = { real },
        )
        assertEquals("real_address", downgraded.info.dnsClass)
        assertEquals(listOf(real[0]), downgraded.addresses)
        assertEquals(SystemMediaNetwork.RouteKind.VPN_TUN_FAKE_IP, downgraded.info.kind)

        // A private or loopback answer never replaces the synthesized one:
        // downgrading must not weaken the address policy.
        val poisoned = SystemMediaNetwork.planFor(
            target,
            listOf(Proxy.NO_PROXY),
            vpnTransport = true,
            routerTrusted = false,
            preferRealAddress = true,
            resolve = { fake },
            resolveReal = { arrayOf(InetAddress.getByName("127.0.0.1")) },
        )
        assertEquals("fake_ip", poisoned.info.dnsClass)
        assertEquals(listOf(fake[0]), poisoned.addresses)
    }

    @Test
    fun onlyAFakeIpTunnelFailureMarksTheHost() {
        val fallback = SystemMediaNetwork.FakeIpFallback()
        fallback.observe("cdn.example", "vpn_tun_fake_ip", "tls_handshake")
        assertEquals(true, fallback.preferRealAddress("cdn.example"))

        // A different route or a different failure keeps the synthesized path.
        fallback.observe("other.example", "http_proxy", "tls_handshake")
        assertEquals(false, fallback.preferRealAddress("other.example"))
        fallback.observe("third.example", "vpn_tun_fake_ip", "timeout")
        assertEquals(false, fallback.preferRealAddress("third.example"))
        // Host matching is case-insensitive.
        assertEquals(true, fallback.preferRealAddress("CDN.example"))
    }

    @Test
    fun tunnelSocketsAreRequiredOnlyForASynthesizedAnswer() {
        // The binding decision is what a real address must NOT trigger: a real
        // address stays on the underlay, so the tunnel never sees a socket it
        // would refuse to forward.
        assertTrue(fakeIpBatch(listOf("198.18.0.9")))
        assertFalse(fakeIpBatch(listOf("222.184.83.211")))
        // A mixed answer contains a routable address, so the tunnel is optional.
        assertFalse(fakeIpBatch(listOf("198.18.0.9", "222.184.83.211")))
        assertFalse(fakeIpBatch(emptyList()))
    }

    /** Mirrors [SystemMediaNetwork.tunnelResolvesToSynthesized]'s decision. */
    private fun fakeIpBatch(addresses: List<String>): Boolean {
        val parsed = addresses.map { InetAddress.getByName(it) }
        return parsed.isNotEmpty() && parsed.all { SystemMediaNetwork.fakeIp(it) }
    }

    @Test
    fun explicitProxySelectorRemainsAuthoritativeOverLinkProperties() {
        val selectedProxy = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7891),
        )
        val link = Proxy(
            Proxy.Type.HTTP,
            InetSocketAddress.createUnresolved("127.0.0.1", 7890),
        )
        assertEquals(
            listOf(selectedProxy),
            SystemMediaNetwork.effectiveProxies(listOf(selectedProxy), link),
        )
    }

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
