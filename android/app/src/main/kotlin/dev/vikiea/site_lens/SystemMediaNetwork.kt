package dev.vikiea.site_lens

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI

/** Resolve only the OS policy: an unusable proxy must not silently become DIRECT. */
object SystemMediaNetwork {
    enum class RouteKind(val wireName: String) {
        PUBLIC_DIRECT("public_direct"),
        HTTP_PROXY("http_proxy"),
        VPN_TUN_FAKE_IP("vpn_tun_fake_ip"),
        ROUTER_FAKE_IP("router_fake_ip"),
        UNKNOWN("unknown"),
    }

    enum class DnsOwner(val wireName: String) {
        SECURE_DNS("secure_dns"),
        SYSTEM_DNS("system_dns"),
        PROXY("proxy"),
        UNKNOWN("unknown"),
    }

    data class RouteInfo(
        val kind: RouteKind,
        val dnsOwner: DnsOwner,
        val fakeIpAllowed: Boolean,
    )

    fun fakeIpRouteKind(vpnTransport: Boolean): RouteKind =
        if (vpnTransport) RouteKind.VPN_TUN_FAKE_IP else RouteKind.ROUTER_FAKE_IP

    fun routerFakeIpEligible(
        networkValidated: Boolean,
        wifiCellularOrEthernet: Boolean,
        privateDns: Boolean,
        directRoute: Boolean,
    ): Boolean =
        networkValidated && wifiCellularOrEthernet && privateDns && directRoute

    private fun validateWebUri(uri: URI) {
        require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) {
            "媒体地址无效"
        }
    }

    fun validateTarget(uri: URI) {
        validateWebUri(uri)
        val host = uri.host.lowercase().removePrefix("[").removeSuffix("]")
        require(host != "localhost" && !host.endsWith(".localhost") &&
            !host.endsWith(".local") && !host.endsWith(".internal")) { "禁止本机/私网媒体目标" }
        if (host.contains(':') || host.all { it.isDigit() || it == '.' }) {
            require(publicAddress(InetAddress.getByName(host))) { "禁止本机/私网媒体 IP" }
        }
    }

    fun fakeIp(address: InetAddress): Boolean {
        val bytes = address.address.map { it.toInt() and 255 }
        return bytes.size == 4 && bytes[0] == 198 && bytes[1] in 18..19
    }

    fun publicAddress(address: InetAddress): Boolean {
        val b = address.address.map { it.toInt() and 255 }
        if (b.size == 4) {
            return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
                b[0] == 100 && b[1] in 64..127 || b[0] == 169 && b[1] == 254 ||
                b[0] == 172 && b[1] in 16..31 || b[0] == 192 && (b[1] == 168 || b[1] == 0 && b[2] in listOf(0, 2)) ||
                b[0] == 198 && (b[1] in 18..19 || b[1] == 51 && b[2] == 100) ||
                b[0] == 203 && b[1] == 0 && b[2] == 113)
        }
        return address is Inet6Address && b[0] and 0xe0 == 0x20 &&
            !(b[0] == 0x20 && b[1] == 0x01 && (b[2] < 2 || b[2] == 0x0d && b[3] == 0xb8)) &&
            !(b[0] == 0x20 && b[1] == 0x02)
    }

    fun proxies(uri: URI, selector: ProxySelector? = ProxySelector.getDefault()): List<Proxy> {
        validateTarget(uri)
        return selectedProxies(uri, selector)
    }

    private fun selectedProxies(uri: URI, selector: ProxySelector?): List<Proxy> {
        validateWebUri(uri)
        val selected = selector?.select(uri) ?: listOf(Proxy.NO_PROXY)
        check(selected.isNotEmpty()) { "系统代理配置为空" }
        check(selected.all { it.type() == Proxy.Type.HTTP || it.type() == Proxy.Type.DIRECT }) {
            "请在代理应用中启用 VPN/TUN 或系统 HTTP 代理后重试"
        }
        return selected
    }

    fun hasDirectRoute(uri: URI, selector: ProxySelector? = ProxySelector.getDefault()): Boolean =
        proxies(uri, selector).any { it.type() == Proxy.Type.DIRECT }

    /**
     * Detects whether the active system DNS intentionally returns a Mihomo /
     * OpenClash Fake-IP for a DIRECT route. This is a capability probe, not a
     * replacement for the connection-time address validation.
     */
    fun directDnsContainsFakeIp(
        uri: URI,
        selector: ProxySelector? = ProxySelector.getDefault(),
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    ): Boolean {
        if (!hasDirectRoute(uri, selector)) return false
        return resolve(uri.host).any(::fakeIp)
    }

    /**
     * Checks DNS ownership only after the PAC order for this attempt selects a
     * DIRECT route. Proxy-first attempts never resolve the origin here.
     */
    fun directDnsContainsFakeIpForAttempt(
        uri: URI,
        attempt: Int = 0,
        selector: ProxySelector? = ProxySelector.getDefault(),
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    ): Boolean {
        val selected = proxies(uri, selector)
        val first = selected[Math.floorMod(attempt, selected.size)]
        if (first.type() != Proxy.Type.DIRECT) return false
        return resolve(uri.host).any(::fakeIp)
    }

    fun routeInfo(
        context: Context,
        uri: URI,
        attempt: Int = 0,
        selector: ProxySelector? = ProxySelector.getDefault(),
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    ): RouteInfo {
        val selected = proxies(uri, selector)
        val first = selected[Math.floorMod(attempt, selected.size)]
        if (first.type() == Proxy.Type.HTTP) {
            return RouteInfo(RouteKind.HTTP_PROXY, DnsOwner.PROXY, false)
        }
        val addresses = resolve(uri.host)
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager?.activeNetwork
        val capabilities = network?.let(manager::getNetworkCapabilities)
        val linkProperties = network?.let(manager::getLinkProperties)
        val fake = addresses.any(::fakeIp)
        val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        if (fake) {
            val routerTrusted = routerFakeIpEligible(
                networkValidated = capabilities?.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_VALIDATED,
                ) == true,
                wifiCellularOrEthernet = capabilities?.let {
                    it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                        it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                } == true,
                privateDns = linkProperties?.dnsServers?.isNotEmpty() == true &&
                    linkProperties.dnsServers.all(::privateDnsAddress),
                directRoute = first.type() == Proxy.Type.DIRECT,
            )
            if (vpn || routerTrusted) {
                return RouteInfo(fakeIpRouteKind(vpn), DnsOwner.SYSTEM_DNS, true)
            }
            return RouteInfo(RouteKind.UNKNOWN, DnsOwner.SYSTEM_DNS, false)
        }
        require(addresses.isNotEmpty() && addresses.all(::publicAddress)) {
            "DNS 包含本机/私网媒体地址；请检查系统代理或 VPN 设置"
        }
        return RouteInfo(RouteKind.PUBLIC_DIRECT, DnsOwner.SYSTEM_DNS, false)
    }

    private fun privateDnsAddress(address: InetAddress): Boolean {
        val bytes = address.address.map { it.toInt() and 255 }
        if (bytes.size == 4) {
            return (bytes[0] == 10) ||
                (bytes[0] == 172 && bytes[1] in 16..31) ||
                (bytes[0] == 192 && bytes[1] == 168)
        }
        return bytes.isNotEmpty() && (bytes[0] and 0xfe) == 0xfc
    }

    fun fakeIpRouteEligible(
        vpnTransport: Boolean,
        explicitlyNotVpn: Boolean?,
        directRoute: Boolean,
    ): Boolean = (vpnTransport || explicitlyNotVpn == false) && directRoute

    fun fakeIpRouteAllowed(
        vpnTransport: Boolean,
        explicitlyNotVpn: Boolean?,
        directRoute: Boolean,
        dnsContainsFakeIp: Boolean,
    ): Boolean =
        fakeIpRouteEligible(vpnTransport, explicitlyNotVpn, directRoute) && dnsContainsFakeIp

    /**
     * OpenClash/Mihomo may run on the LAN gateway instead of on Android.
     * In that topology Android reports Wi-Fi with NOT_VPN=true, while the
     * gateway's DNS intentionally returns a fake-IP and intercepts the
     * subsequent DIRECT socket. Preserve the PAC order and allow that address
     * only after DIRECT was selected and the DNS answer is in the known
     * fake-IP range.
     */
    fun routerFakeIpRouteAllowed(
        directRoute: Boolean,
        dnsContainsFakeIp: Boolean,
    ): Boolean = directRoute && dnsContainsFakeIp

    fun configuration(
        uri: URI,
        selector: ProxySelector? = ProxySelector.getDefault(),
        attempt: Int = 0,
    ): String {
        return renderConfiguration(proxies(uri, selector), attempt)
    }

    /** Route lookup grants no connection authority; HttpProbe validates every hop. */
    fun probeConfiguration(
        uri: URI,
        selector: ProxySelector? = ProxySelector.getDefault(),
        attempt: Int = 0,
    ): String = renderConfiguration(selectedProxies(uri, selector), attempt)

    private fun renderConfiguration(selected: List<Proxy>, attempt: Int): String {
        val start = Math.floorMod(attempt, selected.size)
        val ordered = selected.drop(start) + selected.take(start)
        return ordered.joinToString("; ") { proxy ->
            if (proxy.type() == Proxy.Type.DIRECT) "DIRECT" else {
                val address = proxy.address() as InetSocketAddress
                val host = address.hostString.let { if (it.contains(':')) "[$it]" else it }
                "PROXY $host:${address.port}"
            }
        }
    }

    fun openConnection(
        uri: URI,
        allowProxyFakeIp: Boolean = false,
        attempt: Int = 0,
        selector: ProxySelector? = ProxySelector.getDefault(),
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
        open: (URI, Proxy) -> HttpURLConnection = { target, proxy -> target.toURL().openConnection(proxy) as HttpURLConnection },
        onSelectedRoute: (String) -> Unit = {},
    ): HttpURLConnection {
        val selected = proxies(uri, selector)
        var lastIo: IOException? = null
        var lastPolicy: IllegalArgumentException? = null
        var proxyAttempted = false
        // The transfer retry budget advances PAC candidates after a network
        // failure. Never resolve the origin merely because DIRECT is a later
        // fallback; check its DNS only when that route is actually selected.
        for (offset in selected.indices) {
            val proxy = selected[(attempt + offset) % selected.size]
            try {
                if (proxy.type() == Proxy.Type.DIRECT) {
                    if (proxyAttempted) break
                    // DIRECT owns origin DNS, so validate every answer locally.
                    // An HTTP proxy owns origin resolution; forcing local DNS
                    // here breaks split-DNS and proxy-only hostnames.
                    val addresses = resolve(uri.host)
                    require(addresses.isNotEmpty() && addresses.all {
                        publicAddress(it) || allowProxyFakeIp && fakeIp(it)
                    }) { "DNS 包含本机/私网媒体地址；请检查系统代理或 VPN 设置" }
                }
                proxyAttempted = true
                return open(uri, proxy).also {
                    onSelectedRoute(if (proxy.type() == Proxy.Type.HTTP) "http_proxy" else "direct")
                    it.connectTimeout = 15000
                    it.readTimeout = 20000
                }
            } catch (error: IllegalArgumentException) {
                lastPolicy = error
            } catch (error: IOException) {
                lastIo = error
            }
        }
        throw lastPolicy ?: lastIo ?: IOException("系统代理没有可用路由")
    }
}
