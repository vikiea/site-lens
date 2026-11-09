package dev.vikiea.site_lens

import android.content.Context
import android.util.Log
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Network
import android.net.ProxyInfo
import javax.net.SocketFactory
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.net.ProtocolException
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLProtocolException
import okhttp3.ConnectionPool
import okhttp3.Call
import okhttp3.Dns
import okhttp3.EventListener
import okhttp3.Protocol
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.RequestBody.Companion.toRequestBody

class MediaRouteIOException(
    val category: String,
    cause: IOException,
) : IOException("媒体路由 $category", cause)

/** Resolve only the OS policy: an unusable proxy must not silently become DIRECT. */
object SystemMediaNetwork {
    private val epoch = java.util.concurrent.atomic.AtomicLong(0)
    private val observedNetwork = java.util.concurrent.atomic.AtomicReference<String?>(null)
    private fun resolverExecutor(name: String, core: Int, max: Int, queue: Int): ThreadPoolExecutor =
        ThreadPoolExecutor(
            core,
            max,
            30L,
            TimeUnit.SECONDS,
            ArrayBlockingQueue(queue),
            { runnable -> Thread(runnable, "site-lens-system-dns-$name").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy(),
        )

    // The probe coordinator runs up to 8 candidates at once, and each request
    // resolves a name (plus every redirect hop). With core=1/max=2/queue=4 a
    // slow tunnel filled this pool and later lookups were rejected outright as
    // "DNS resolver busy", which surfaced as a generic request failure rather
    // than as a DNS problem.
    private val probeResolver = resolverExecutor("probe", core = 4, max = 8, queue = 16)
    private val updateResolver = resolverExecutor("update", core = 2, max = 4, queue = 8)
    private val generalResolver = resolverExecutor("general", core = 2, max = 4, queue = 8)

    private fun resolverFor(lane: String): ThreadPoolExecutor = when (lane.lowercase()) {
        "probe" -> probeResolver
        "update" -> updateResolver
        else -> generalResolver
    }
    fun networkEpoch(): Long = epoch.get()

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
        val proxyConfigured: Boolean = false,
        val preferVpnTun: Boolean = false,
        val directAllowed: Boolean = false,
        val dnsClass: String = "unknown",
        val targetDnsMode: String = "unknown",
        val vpnTransport: Boolean = false,
        /**
         * Whether the tunnel is the OS default route. When it is not - a
         * per-app or rule-mode tunnel - an unbound socket leaves through the
         * underlay and never reaches the tunnel at all.
         */
        val vpnIsDefault: Boolean = true,
    )

    fun fakeIpRouteKind(vpnTransport: Boolean): RouteKind =
        if (vpnTransport) RouteKind.VPN_TUN_FAKE_IP else RouteKind.ROUTER_FAKE_IP

    @Suppress("UNUSED_PARAMETER")
    fun routerFakeIpEligible(
        networkValidated: Boolean,
        wifiCellularOrEthernet: Boolean,
        privateDns: Boolean,
        directRoute: Boolean,
    ): Boolean {
        // The DNS server address is not an ownership proof. Users may select
        // a public DNS resolver while OpenClash/Mihomo still owns the system
        // route, and a proxy/VPN can legitimately make the DNS server appear
        // outside RFC1918. The actual authority check happens later in
        // planFor: DIRECT must already be selected and every answer must be a
        // known 198.18.0.0/15 Fake-IP. Real private and loopback answers still
        // fail publicAddress validation.
        return wifiCellularOrEthernet && directRoute
    }

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

    /**
     * Default first-known proxy for in-process media transports (Media3).
     *
     * The global ProxySelector is authoritative when it already names a proxy.
     * When it reports DIRECT -- which is what several VPN/TUN implementations
     * expose while keeping their proxy in LinkProperties -- that proxy is used
     * instead, so in-process playback does not bypass the OS proxy. No proxy
     * anywhere means a direct connection is the only remaining route.
     */
    fun mediaProxy(
        context: Context,
        uri: URI,
        selector: ProxySelector? = ProxySelector.getDefault(),
    ): Proxy {
        val selected = selectedProxies(uri, selector)
        if (selected.any { it.type() == Proxy.Type.HTTP }) {
            return selected.first { it.type() == Proxy.Type.HTTP }
        }
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val links = routeNetwork(manager)?.let(manager::getLinkProperties)
        return linkHttpProxies(links?.httpProxy).firstOrNull() ?: Proxy.NO_PROXY
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

    data class RoutePlan(
        val info: RouteInfo,
        val proxy: Proxy,
        val addresses: List<InetAddress> = emptyList(),
        val network: Network? = null,
        /**
         * Who answers a name that [addresses] does not cover.
         *
         * A multi-CDN playlist moves segments, keys and maps to other hosts.
         * Those lookups only stay on the hop this plan describes when the plan
         * itself owns DNS; a DIRECT plan on the underlay must let the system
         * resolver answer, and a proxy plan must keep them remote.
         */
        val secondaryDns: SecondaryDns = SecondaryDns.UNKNOWN,
    )

    /** Lookup owner for names other than the planned origin host. */
    enum class SecondaryDns(val wireName: String) {
        /** The plan owns the answer; use [RoutePlan.network] when present. */
        ROUTE("route"),

        /** The OS resolver carries the name, as the WebView does. */
        SYSTEM("system"),

        /** The proxy resolves the name; no local lookup happens. */
        REMOTE("remote"),
        UNKNOWN("unknown"),
    }

    data class BufferedResponse(
        val statusCode: Int,
        val headers: Map<String, String>,
        val body: ByteArray,
        val finalUri: URI,
        val networkEpoch: Long,
    )

    fun routeInfo(
        context: Context,
        uri: URI,
        attempt: Int = 0,
    ): RouteInfo = routePlan(context, uri, attempt).info

    /**
     * Proxy/VPN snapshot for callers that must not resolve the target, such as
     * a WebView diagnostic for an arbitrary page URL. It never touches DNS, so
     * a broken resolver cannot make the diagnostic itself fail.
     */
    fun activeRouteInfo(
        context: Context,
        uri: URI? = null,
        attempt: Int = 0,
    ): RouteInfo {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = routeNetwork(manager)
        val capabilities = network?.let(manager::getNetworkCapabilities)
        val links = network?.let(manager::getLinkProperties)
        val selector = if (uri == null) {
            listOf(Proxy.NO_PROXY)
        } else {
            runCatching { selectedProxies(uri, ProxySelector.getDefault()) }
                .getOrDefault(listOf(Proxy.NO_PROXY))
        }
        val visible = visibleProxyEndpoints(selector, linkHttpProxies(links?.httpProxy))
        val http = visible.filter { it.type() == Proxy.Type.HTTP }
        val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true ||
            (network != null && looksLikeTunnelInterface(manager, network))
        // This snapshot deliberately does not resolve the target. A VPN alone
        // proves tunnel presence, not Fake-IP DNS ownership, so report an
        // unknown route until the connection-time planner confirms the answer.
        val kind = when {
            http.isNotEmpty() -> RouteKind.HTTP_PROXY
            vpn -> RouteKind.UNKNOWN
            else -> RouteKind.PUBLIC_DIRECT
        }
        return RouteInfo(
            kind,
            if (http.isEmpty()) DnsOwner.SYSTEM_DNS else DnsOwner.PROXY,
            fakeIpAllowed = false,
            proxyConfigured = http.isNotEmpty(),
            preferVpnTun = vpn && http.isNotEmpty(),
            directAllowed = http.isEmpty() && !vpn,
            dnsClass = if (http.isEmpty()) "unknown" else "proxy",
            targetDnsMode = if (http.isEmpty()) "unknown" else "proxy_remote",
            vpnTransport = vpn,
        )
    }

    /**
     * The VPN network that actually carries traffic, which is not always
     * `activeNetwork`.
     *
     * Clash/Mihomo in rule mode installs a tun interface that covers the whole
     * IPv4 space, yet Android can still report the underlay Wi-Fi as the
     * active, validated network. Reading only `activeNetwork` then concludes
     * "no VPN" and hands every socket to the Wi-Fi route, so the tunnel's
     * split-DNS and its Fake-IP answers never apply. Prefer a validated VPN
     * network over the underlay.
     *
     * A rule-mode tunnel may not advertise NET_CAPABILITY_INTERNET itself
     * (the underlay carries connectivity), so a missing capability is treated
     * as unknown rather than as "unusable"; an explicit false still skips it.
     */
    fun vpnNetwork(manager: ConnectivityManager?): Network? {
        if (manager == null) return null
        val all = runCatching { manager.allNetworks }.getOrDefault(emptyArray())
        fun caps(network: Network) = manager.getNetworkCapabilities(network)
        fun isTunnel(network: Network): Boolean =
            caps(network)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true ||
                looksLikeTunnelInterface(manager, network)
        return pickVpnNetwork(
            active = manager.activeNetwork,
            candidates = all.toList(),
            activeIsVpn = manager.activeNetwork?.let(::isTunnel) == true,
            isVpn = ::isTunnel,
            isUsable = { caps(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) != false },
            isValidated = {
                caps(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
            },
        )
    }

    /**
     * Recognises a tunnel from its link, not only from its capabilities.
     *
     * On recent Android the capability object an app receives for a VPN it did
     * not create can omit TRANSPORT_VPN while the network itself still works:
     * name resolution through it succeeds and its routes carry traffic. Trusting
     * the flag alone therefore reported "no tunnel" while DNS answers were
     * demonstrably coming from the tunnel's own resolver.
     *
     * A tunnel link is identified by its interface family (tun/ppp/wireguard and
     * the Android VPN family) together with either a point-to-point /30 link or
     * a default route it declares. Real Wi-Fi and cellular links have neither.
     */
    private fun looksLikeTunnelInterface(manager: ConnectivityManager, network: Network): Boolean {
        val links = runCatching { manager.getLinkProperties(network) }.getOrNull() ?: return false
        val name = links.interfaceName.orEmpty().lowercase()
        val named = name.startsWith("tun") || name.startsWith("ppp") ||
            name.startsWith("utun") || name.startsWith("wg") || name.startsWith("tap")
        if (!named) return false
        // A /30 point-to-point link is the shape every Android tunnel uses for
        // its own leg; a declared 0.0.0.0/0 route is the other common shape.
        val pointToPoint = links.linkAddresses.any { it.prefixLength == 30 }
        val declaresDefault = links.routes.any { it.destination.prefixLength == 0 }
        return pointToPoint || declaresDefault
    }

    /**
     * Pure selection of the tunnel that should carry traffic. [isVpn] and
     * [isValidated] are supplied by the caller so the rule is unit-testable
     * without a live ConnectivityManager.
     */
    fun <N> pickVpnNetwork(
        active: N?,
        candidates: List<N>,
        activeIsVpn: Boolean,
        isVpn: (N) -> Boolean,
        isUsable: (N) -> Boolean,
        isValidated: (N) -> Boolean,
    ): N? {
        if (active != null && activeIsVpn) return active
        // A rule-mode TUN can deliberately omit NET_CAPABILITY_INTERNET:
        // the underlay owns validation while the tunnel owns the app socket.
        // VALIDATED is the second proof that such a tunnel is still live;
        // reject a VPN that has neither capability.
        val tunnels = candidates.filter { isVpn(it) && (isUsable(it) || isValidated(it)) }
        // A validated tunnel outranks one that has not completed validation yet.
        return tunnels.firstOrNull(isValidated) ?: tunnels.firstOrNull()
    }

    /** The network that actually carries this app's traffic for the next hop. */
    fun routeNetwork(manager: ConnectivityManager?): Network? =
        vpnNetwork(manager) ?: manager?.activeNetwork

    /**
     * Bind an in-process HTTP client to the tunnel that owns routing.
     *
     * [Network] exposes a plain [SocketFactory] and no network-scoped TLS
     * factory. OkHttp creates the socket from our factory, connects it through
     * the tunnel, then asks the sslSocketFactory to wrap that same socket. The
     * TLS slot therefore only needs to delegate to the platform default:
     * handshaking in place inherits the binding, and certificate validation
     * stays exactly as the platform performs it.
     *
     * Returns true when the client was bound, false when there is no tunnel.
     */
    fun bindToVpn(context: Context, builder: OkHttpClient.Builder): Boolean {
        val network = vpnNetwork(context.getSystemService(ConnectivityManager::class.java))
            ?: return false
        return bindToNetwork(network, builder)
    }

    private fun bindToNetwork(network: Network, builder: OkHttpClient.Builder): Boolean {
        return runCatching {
            val trust = defaultTrustManager()
            // The socket factory owns transport: every socket it creates is
            // already bound to this network. TLS then wraps that socket in
            // place, so the handshake inherits the binding and the platform
            // still validates the certificate.
            builder.socketFactory(network.socketFactory)
            builder.sslSocketFactory(TunnelSslSocketFactory(), trust)
            true
        }.getOrDefault(false)
    }

    /**
     * Builds the shared native OkHttp client for one route plan. Consumers pass
     * the plan through unchanged; proxy, DNS and VPN binding are decided here.
     */
    fun buildOkHttpClient(
        context: Context,
        uri: URI,
        plan: RoutePlan,
        beforeConnect: () -> Unit = {},
        timeoutMs: Long? = null,
        listener: EventListener? = null,
    ): OkHttpClient = buildOkHttpClient(
        context = context,
        uri = uri,
        proxy = plan.proxy,
        validatedAddresses = plan.addresses.takeIf { it.isNotEmpty() },
        bindVpn = shouldBindVpnSocket(plan.info, plan.proxy),
        network = plan.network,
        beforeConnect = beforeConnect,
        timeoutMs = timeoutMs,
        listener = listener,
    )

    /**
     * Phase timing for one request, logged only when a hop fails.
     *
     * A timed-out call reported nothing beyond "network timed out", so a DNS
     * stall, a TCP refusal, a TLS mismatch and a silent first byte all looked
     * identical. Recording the phase boundaries makes the failing stage
     * explicit without touching request behaviour.
     */
    private class PhaseProbe(
        private val uri: URI,
        private val attempt: Int,
    ) : EventListener() {
        private val start = System.nanoTime()
        private val phases = LinkedHashMap<String, Long>()

        private fun mark(name: String) {
            phases[name] = (System.nanoTime() - start) / 1_000_000
        }

        fun summary(): String =
            phases.entries.joinToString(" ") { "${it.key}=${it.value}ms" }

        fun reached(): String = phases.keys.lastOrNull() ?: "none"

        override fun callStart(call: Call) = mark("start")

        override fun dnsStart(call: Call, domainName: String) = mark("dnsStart")

        override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<java.net.InetAddress>) =
            mark("dnsEnd(" + inetAddressList.joinToString(",") { it.hostAddress ?: "?" } + ")")

        override fun connectStart(call: Call, inetSocketAddress: java.net.InetSocketAddress, proxy: java.net.Proxy) =
            mark("connectStart")

        override fun connectEnd(
            call: Call,
            inetSocketAddress: java.net.InetSocketAddress,
            proxy: java.net.Proxy,
            protocol: Protocol?,
        ) = mark("connectEnd(${protocol?.name ?: "?"})")

        override fun connectFailed(
            call: Call,
            inetSocketAddress: java.net.InetSocketAddress,
            proxy: java.net.Proxy,
            protocol: Protocol?,
            ioe: java.io.IOException,
        ) = mark("connectFailed(${ioe.javaClass.simpleName})")

        override fun secureConnectStart(call: Call) = mark("tlsStart")

        override fun secureConnectEnd(call: Call, handshake: okhttp3.Handshake?) = mark("tlsEnd")

        override fun requestHeadersStart(call: Call) = mark("requestStart")

        override fun requestHeadersEnd(call: Call, request: Request) = mark("requestSent")

        override fun responseHeadersStart(call: Call) = mark("responseHeaders")

        override fun callFailed(call: Call, ioe: java.io.IOException) =
            mark("failed(${ioe.javaClass.simpleName}:${ioe.message})")

        override fun callEnd(call: Call) = mark("end")

        fun describe(): String =
            "uri=" + uri.host + " attempt=" + attempt +
                " reached=" + reached() + " " + summary()
    }

    /** Executes a bounded, non-streaming request using the shared route plan. */
    fun requestBuffered(
        context: Context,
        uri: URI,
        method: String = "GET",
        headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null,
        maxBytes: Int = 2 * 1024 * 1024,
        attempt: Int = 0,
        timeoutMs: Long = 15_000L,
        isCancelled: (() -> Boolean)? = null,
        resolverLane: String = "general",
        registerCall: ((Call) -> Unit)? = null,
        unregisterCall: ((Call) -> Unit)? = null,
    ): BufferedResponse {
        require(maxBytes in 1..(8 * 1024 * 1024)) { "网络响应大小上限无效" }
        require(timeoutMs in 1..60_000L) { "网络请求超时无效" }
        require(method in setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")) {
            "不支持 HTTP 方法"
        }
        if (isCancelled?.invoke() == true) throw java.io.InterruptedIOException("请求已取消")
        validateTarget(uri)
        val plan = routePlan(
            context,
            uri,
            attempt,
            lookupTimeoutMs = timeoutMs.coerceAtMost(1_500L),
            isCancelled = isCancelled,
            resolverLane = resolverLane,
        )
        if (isCancelled?.invoke() == true) throw java.io.InterruptedIOException("请求已取消")
        val probe = PhaseProbe(uri, attempt)
        val client = buildOkHttpClient(
            context,
            uri,
            plan,
            timeoutMs = timeoutMs,
            listener = probe,
        )
        val contentType = headers.entries.firstOrNull {
            it.key.equals("Content-Type", ignoreCase = true)
        }?.value?.toMediaTypeOrNull()
        val requestBody = when {
            method == "GET" || method == "HEAD" -> null
            body != null -> body.toRequestBody(contentType)
            method in setOf("POST", "PUT", "PATCH") -> ByteArray(0).toRequestBody(contentType)
            else -> null
        }
        val request = Request.Builder()
            .url(uri.toURL())
            .method(method, requestBody)
            .apply { headers.forEach { (name, value) -> header(name, value) } }
            .build()
        val call = client.newCall(request)
        registerCall?.invoke(call)
        try {
            call.execute().use { response ->
                val output = ByteArrayOutputStream()
                val stream = response.body?.byteStream()
                if (stream != null && method != "HEAD") {
                    stream.use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (output.size() + count > maxBytes) {
                                throw IOException("网络响应超过大小限制")
                            }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                return BufferedResponse(
                    statusCode = response.code,
                    headers = response.headers.toMultimap().mapValues { it.value.joinToString(", ") },
                    body = output.toByteArray(),
                    finalUri = uri,
                    networkEpoch = networkEpoch(),
                )
            }
        } catch (error: IOException) {
            // One line per failed hop: the route that was chosen, whether the
            // socket was bound, and the last phase OkHttp reached.
            Log.w(
                "SiteLensNetDiag",
                "failed route=" + plan.info.kind.wireName +
                    " dns=" + plan.info.dnsClass +
                    " bind=" + shouldBindVpnSocket(plan.info, plan.proxy) +
                    " vpnDefault=" + plan.info.vpnIsDefault +
                    " timeoutMs=" + timeoutMs +
                    " " + probe.describe() +
                    " error=" + error.javaClass.simpleName + ": " + error.message,
            )
            throw error
        } finally {
            unregisterCall?.invoke(call)
        }
    }

    /**
     * Empty shell that satisfies OkHttp's TLS slot without altering TLS.
     *
     * OkHttp builds the TLS socket itself:
     *
     * ```
     * raw = socketFactory.createSocket()      // our tunnel socket
     * raw.connect(...)                        // through the tunnel
     * ssl = sslSocketFactory.createSocket(raw, host, port, true)
     * ```
     *
     * That last call is the only overload OkHttp uses, and it wraps the socket
     * we just connected. Delegating every method to the platform default keeps
     * the certificate chain and hostname verification untouched.
     *
     * An earlier version replaced these methods with raw tunnel sockets and
     * called startHandshake() itself. OkHttp then started a second handshake on
     * the same stream, so TLS state desynchronised and the request hung until
     * the timeout even though the TCP connection had reached the proxy.
     */
    private class TunnelSslSocketFactory : SSLSocketFactory() {
        private val delegate: SSLSocketFactory
            get() = SSLSocketFactory.getDefault() as SSLSocketFactory

        override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

        override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

        override fun createSocket(): Socket = delegate.createSocket()

        override fun createSocket(host: String, port: Int): Socket =
            delegate.createSocket(host, port)

        override fun createSocket(
            host: String,
            port: Int,
            localHost: InetAddress,
            localPort: Int,
        ): Socket = delegate.createSocket(host, port, localHost, localPort)

        override fun createSocket(host: InetAddress, port: Int): Socket =
            delegate.createSocket(host, port)

        override fun createSocket(
            address: InetAddress,
            port: Int,
            localAddress: InetAddress,
            localPort: Int,
        ): Socket = delegate.createSocket(address, port, localAddress, localPort)

        /** OkHttp's TLS entry point. Handshake policy stays with the platform. */
        override fun createSocket(
            socket: Socket,
            host: String,
            port: Int,
            autoClose: Boolean,
        ): Socket = delegate.createSocket(socket, host, port, autoClose)
    }

    /** The platform's own trust manager; certificate checks stay enforced. */
    private fun defaultTrustManager(): X509TrustManager {
        val factory = javax.net.ssl.TrustManagerFactory.getInstance(
            javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm(),
        )
        factory.init(null as java.security.KeyStore?)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().firstOrNull()
            ?: throw IllegalStateException("系统缺少证书校验器")
    }

    private fun resolveBounded(
        timeoutMs: Long,
        isCancelled: (() -> Boolean)? = null,
        resolverLane: String = "general",
        block: () -> Array<InetAddress>,
    ): Array<InetAddress> {
        val future = try {
            resolverFor(resolverLane).submit(Callable { block() })
        } catch (_: RejectedExecutionException) {
            throw SocketTimeoutException("DNS resolver busy")
        }
        val deadline = System.nanoTime() + timeoutMs.coerceIn(100L, 10_000L) * 1_000_000L
        try {
            while (true) {
                if (isCancelled?.invoke() == true) {
                    future.cancel(true)
                    throw java.io.InterruptedIOException("请求已取消")
                }
                val remainingNanos = deadline - System.nanoTime()
                if (remainingNanos <= 0L) {
                    future.cancel(true)
                    throw SocketTimeoutException("DNS resolution timeout")
                }
                try {
                    return future.get(
                        minOf(remainingNanos, 50_000_000L),
                        TimeUnit.NANOSECONDS,
                    )
                } catch (_: java.util.concurrent.TimeoutException) {
                    // Poll briefly so Dart cancellation can stop waiting even
                    // when the platform resolver itself ignores interruption.
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            future.cancel(true)
            throw SocketTimeoutException("DNS resolution interrupted")
        } catch (error: ExecutionException) {
            val cause = error.cause
            if (cause is IOException) throw cause
            throw IOException("DNS resolution failed", cause)
        }
        throw AssertionError("unreachable DNS resolution state")
    }

    /** One snapshot for the proxy, system DNS, and socket owner of this hop. */
    fun routePlan(
        context: Context,
        uri: URI,
        attempt: Int = 0,
        lookupTimeoutMs: Long = 5_000L,
        isCancelled: (() -> Boolean)? = null,
        resolverLane: String = "general",
    ): RoutePlan {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = routeNetwork(manager)
        val capabilities = network?.let(manager::getNetworkCapabilities)
        val links = network?.let(manager::getLinkProperties)
        val selected = visibleProxyEndpoints(
            selectedProxies(uri, ProxySelector.getDefault()),
            linkHttpProxies(links?.httpProxy),
        )
        val fingerprint = "${network?.networkHandle}:${links?.httpProxy}:${links?.dnsServers}"
        if (observedNetwork.getAndSet(fingerprint) != fingerprint) epoch.incrementAndGet()
        // The capability flag can be withheld for a VPN this app did not create,
        // so the interface shape is the second proof. Without it the hop was
        // misclassified as public-direct while its DNS answers were still being
        // served by the tunnel.
        val vpn = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true ||
            (network != null && looksLikeTunnelInterface(manager, network))
        val routerTrusted = routerFakeIpEligible(
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
            capabilities?.let {
                it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    it.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            } == true,
            links?.dnsServers?.isNotEmpty() == true && links.dnsServers.all(::privateDnsAddress),
            selected.none { it.type() == Proxy.Type.HTTP },
        )
        val planned = planFor(
            uri, selected, vpn, routerTrusted, attempt,
            resolve = { host ->
                resolveBounded(
                    lookupTimeoutMs,
                    isCancelled,
                    resolverLane,
                ) {
                    if (isCancelled?.invoke() == true) {
                        throw java.io.InterruptedIOException("请求已取消")
                    }
                    network?.getAllByName(host) ?: InetAddress.getAllByName(host)
                }
            },
        )
        // A tunnel that is not the OS default route only carries traffic whose
        // sockets were bound to it. Record that so the binding decision does
        // not have to re-derive it.
        val vpnIsDefault = !vpn || manager?.activeNetwork == network
        // A proxied hop resolves the origin remotely and must keep doing so for
        // every redirect target. A local hop that is not the tunnel asks the OS,
        // exactly like the WebView. Only a socket bound to the tunnel takes
        // extra names through the tunnel resolver.
        val secondaryDns = when {
            planned.proxy.type() == Proxy.Type.HTTP -> SecondaryDns.REMOTE
            shouldBindVpnSocket(planned.info, planned.proxy) -> SecondaryDns.ROUTE
            else -> SecondaryDns.SYSTEM
        }
        return planned.copy(
            info = planned.info.copy(vpnTransport = vpn, vpnIsDefault = vpnIsDefault),
            network = network,
            secondaryDns = secondaryDns,
        )
    }

    /**
     * Some Android VPN/TUN implementations expose DIRECT through the global
     * ProxySelector while keeping their HTTP proxy only in LinkProperties.
     * Preserve that OS-level proxy candidate before deciding whether a direct
     * route is allowed; otherwise discovery can bypass the proxy and reset at
     * the origin socket.
     */
    fun effectiveProxies(selected: List<Proxy>, linkProxy: Proxy?): List<Proxy> {
        if (linkProxy == null || selected.any { it.type() == Proxy.Type.HTTP }) {
            return selected
        }
        return listOf(linkProxy) + selected
    }

    /**
     * Proxy candidates visible to other apps: the ProxySelector order first,
     * then any HTTP proxy the active network declares in LinkProperties.
     *
     * The network-scoped proxy is a distinct OS route. Some VPN/TUN apps keep
     * their proxy only in LinkProperties, and a stale selector entry can be
     * followed by a working one. Appending never reorders what the OS already
     * chose, and no DIRECT fallback is invented, so an unusable proxy never
     * becomes a silent direct connection.
     */
    fun visibleProxyEndpoints(
        selected: List<Proxy>,
        linkProxies: List<Proxy>,
    ): List<Proxy> {
        val selectedHttp = selected.filter { it.type() == Proxy.Type.HTTP }
        val selectedDirect = selected.filter { it.type() == Proxy.Type.DIRECT }
        val merged = ArrayList<Proxy>(selected.size + linkProxies.size)
        // Once ProxySelector already supplies an HTTP route, DIRECT is only a
        // fallback token from that PAC result. Keeping it would allow a failed
        // proxy attempt to leak to the public socket. A LinkProperties proxy
        // is still an additional candidate after the explicit selector list.
        merged += selectedHttp
        for (candidate in linkProxies) {
            val duplicate = merged.any { existing ->
                existing.type() == Proxy.Type.HTTP && sameEndpoint(existing, candidate)
            }
            if (!duplicate) merged += candidate
        }
        if (selectedHttp.isEmpty()) merged += selectedDirect
        // DIRECT is present only because the OS offered it, so a dead proxy
        // never silently becomes a direct connection.
        return if (merged.isEmpty()) listOf(Proxy.NO_PROXY) else merged
    }

    private fun sameEndpoint(first: Proxy, second: Proxy): Boolean {
        val a = first.address() as? InetSocketAddress ?: return false
        val b = second.address() as? InetSocketAddress ?: return false
        return a.hostString == b.hostString && a.port == b.port
    }

    /** Every HTTP proxy endpoint the active network declares, in order. */
    fun linkHttpProxies(info: ProxyInfo?): List<Proxy> {
        val proxy = linkHttpProxy(info) ?: return emptyList()
        return listOf(proxy)
    }

    private fun linkHttpProxy(info: ProxyInfo?): Proxy? {
        val host = info?.host?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val port = info.port
        if (port !in 1..65535) return null
        return Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(host, port))
    }

    fun usesVpnNetwork(vpnTransport: Boolean, proxy: Proxy): Boolean =
        vpnTransport && proxy.type() == Proxy.Type.DIRECT

    /**
     * Decides whether an OkHttp client must own the tunnel's sockets.
     *
     * Only one case genuinely needs the binding: a synthesized Fake-IP answer
     * exists solely for the tunnel to translate, so the socket must be the
     * tunnel's.
     *
     * A tunnel that is not the OS default route must *not* be bound. Such a
     * tunnel declares 0.0.0.0/0 to ConnectivityManager but keeps only its own
     * /30 in the kernel routing table; interception happens in fwmark/iptables
     * rules keyed on the app's uid. Binding a socket bypasses those rules
     * without adding a default route, so the destination becomes unroutable and
     * the connect hangs until the caller's timeout. Leaving the socket on the
     * underlay is what lets the tunnel's own rules carry it - the same path the
     * WebView already takes.
     *
     * HTTP proxy hops keep their normal socket owner: the proxy, not the
     * tunnel, carries the CONNECT.
     */
    fun shouldBindVpnSocket(info: RouteInfo, proxy: Proxy): Boolean {
        if (proxy.type() != Proxy.Type.DIRECT) return false
        return info.kind == RouteKind.VPN_TUN_FAKE_IP && info.dnsClass == "fake_ip"
    }

    /**
     * Pure policy. HTTP proxies own origin DNS unless VPN Fake-IP is proven.
     *
     */
    fun planFor(
        uri: URI,
        selected: List<Proxy>,
        vpnTransport: Boolean,
        routerTrusted: Boolean,
        attempt: Int = 0,
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    ): RoutePlan {
        validateTarget(uri)
        check(selected.isNotEmpty() && selected.all {
            it.type() == Proxy.Type.HTTP || it.type() == Proxy.Type.DIRECT
        }) { "系统代理没有可用路由" }
        val http = selected.filter { it.type() == Proxy.Type.HTTP }
        fun proxyPlan(index: Int, dnsClass: String = "proxy"): RoutePlan = RoutePlan(
            RouteInfo(RouteKind.HTTP_PROXY, DnsOwner.PROXY, false,
                proxyConfigured = true, dnsClass = dnsClass,
                targetDnsMode = "proxy_remote"),
            http[Math.floorMod(index, http.size)],
        )
        if (http.isNotEmpty() && !vpnTransport) return proxyPlan(attempt)
        // When both HTTP proxy and VPN/TUN are present, odd attempts are the
        // proxy fallback. Do not resolve the origin on that attempt: the
        // proxy owns remote DNS and proxy-only hostnames must never leak to
        // the local resolver.
        if (http.isNotEmpty() && vpnTransport && attempt % 2 != 0) {
            return proxyPlan(attempt / 2)
        }
        val addresses = try {
            resolve(uri.host).toList()
        } catch (error: IOException) {
            if (http.isNotEmpty()) return proxyPlan(attempt, "unknown")
            throw error
        }
        val onlyFakeIp = addresses.isNotEmpty() && addresses.all(::fakeIp)
        // The tunnel does not exempt a name from Fake-IP just because its rule
        // ends in DIRECT: a domestic name is answered with a synthesized
        // address too, and the rule only chooses the outbound at connect time.
        // The synthesized answer therefore stays as it is, and the system route
        // carries it exactly like the WebView does.
        if (vpnTransport) {
            requireUsableAnswer(addresses)
            return RoutePlan(
                RouteInfo(RouteKind.VPN_TUN_FAKE_IP, DnsOwner.SYSTEM_DNS, true,
                    proxyConfigured = http.isNotEmpty(), preferVpnTun = true,
                    directAllowed = true,
                    dnsClass = if (onlyFakeIp) "fake_ip" else "public",
                    targetDnsMode = "system_route"),
                Proxy.NO_PROXY, addresses,
            )
        }
        val realAddresses = addresses.filter { publicAddress(it) }
        if (http.isNotEmpty()) return proxyPlan(attempt,
            if (realAddresses.isNotEmpty() || onlyFakeIp) "public" else "blocked")
        // A soft router intercepts at the gateway, so no local tunnel exists and
        // a synthesized answer is the router's own contract.
        if (onlyFakeIp && routerTrusted) return RoutePlan(
            RouteInfo(RouteKind.ROUTER_FAKE_IP, DnsOwner.SYSTEM_DNS, true,
                directAllowed = true, dnsClass = "fake_ip",
                targetDnsMode = "system_route"),
            Proxy.NO_PROXY, addresses,
        )
        requireUsableAnswer(addresses)
        return RoutePlan(
            RouteInfo(RouteKind.PUBLIC_DIRECT, DnsOwner.SYSTEM_DNS, false,
                directAllowed = true, dnsClass = "public",
                targetDnsMode = "direct_validated"),
            Proxy.NO_PROXY, realAddresses,
        )
    }

    /**
     * Rejects an answer that can never name a remote service.
     *
     * A loopback, link-local or private answer is a poisoned resolver, not a
     * routing decision, so it stays fail-closed. A synthesized address is not
     * rejected here: it belongs to the intercepting route that produced it.
     */
    private fun requireUsableAnswer(addresses: List<InetAddress>) {
        val usable = addresses.isNotEmpty() &&
            addresses.all { publicAddress(it) || fakeIp(it) }
        if (!usable) {
            throw MediaRouteIOException(
                "private_address",
                IOException("DNS 返回本机/私网地址，已拒绝连接；请检查系统代理、VPN 或 DNS 设置"),
            )
        }
    }

    fun configuration(plan: RoutePlan): String = renderConfiguration(listOf(plan.proxy), 0)

    /**
     * Whether the tunnel answers [uri]'s host with only synthesized addresses.
     *
     * Only then is the socket expected inside the tunnel: a synthesized address
     * exists solely for the tunnel to translate, while a real address must
     * leave through the underlay. Deciding this before binding avoids pushing a
     * real address into a tunnel that will not carry it.
     */
    fun tunnelResolvesToSynthesized(tunnel: Network, uri: URI): Boolean {
        val host = uri.host ?: return false
        val answer = runCatching { tunnel.getAllByName(host).toList() }.getOrDefault(emptyList())
        return answer.isNotEmpty() && answer.all(::fakeIp)
    }

    fun openMediaConnection(
        context: Context,
        uri: URI,
        attempt: Int,
        onRoute: (RouteInfo) -> Unit = {},
    ): HttpURLConnection {
        val plan = routePlan(context, uri, attempt)
        onRoute(plan.info)
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val bindVpn = shouldBindVpnSocket(plan.info, plan.proxy)
        return openOkHttpConnection(
            context, uri, plan.proxy, plan.addresses.takeIf { it.isNotEmpty() },
            bindVpn = bindVpn,
            network = plan.network,
            secondaryDns = plan.secondaryDns,
            beforeConnect = {
                // Recheck the tunnel that owns this socket. Comparing with
                // activeNetwork is wrong for rule-mode tunnels, where the
                // underlay Wi-Fi legitimately stays the active network.
                val stillVpn = plan.network != null && manager != null &&
                    (manager.getNetworkCapabilities(plan.network)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true ||
                        looksLikeTunnelInterface(manager, plan.network))
                if (bindVpn && !stillVpn) {
                    throw MediaRouteIOException("route_changed", IOException("媒体网络已变化"))
                }
            },
        )
    }

    fun strategyForAttempt(info: RouteInfo, attempt: Int): RouteKind {
        if (info.preferVpnTun && info.proxyConfigured) {
            return if (Math.floorMod(attempt, 2) == 0) {
                RouteKind.VPN_TUN_FAKE_IP
            } else {
                RouteKind.HTTP_PROXY
            }
        }
        return info.kind
    }

    fun configurationForStrategy(
        uri: URI,
        strategy: RouteKind,
        attempt: Int = 0,
        selector: ProxySelector? = ProxySelector.getDefault(),
    ): String {
        val selected = proxies(uri, selector)
        if (strategy != RouteKind.HTTP_PROXY) {
            check(strategy != RouteKind.UNKNOWN) { "无法确认媒体路由" }
            return "DIRECT"
        }
        val http = selected.filter { it.type() == Proxy.Type.HTTP }
        check(http.isNotEmpty()) { "系统代理没有可用 HTTP 代理" }
        return renderConfiguration(http, attempt)
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
        preferredRoute: RouteKind? = null,
        selector: ProxySelector? = ProxySelector.getDefault(),
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
        open: ((URI, Proxy) -> HttpURLConnection)? = null,
        onSelectedRoute: (String) -> Unit = {},
        context: Context? = null,
    ): HttpURLConnection {
        val selected = proxies(uri, selector)
        val http = selected.filter { it.type() == Proxy.Type.HTTP }
        val candidates = when (preferredRoute) {
            RouteKind.HTTP_PROXY -> http
            RouteKind.PUBLIC_DIRECT,
            RouteKind.VPN_TUN_FAKE_IP,
            RouteKind.ROUTER_FAKE_IP -> listOf(Proxy.NO_PROXY)
            else -> selected
        }
        if (candidates.isEmpty()) throw IOException("系统代理没有可用路由")
        var lastIo: IOException? = null
        var lastPolicy: IllegalArgumentException? = null
        var proxyAttempted = false
        val confirmedFakeIpDirect = allowProxyFakeIp &&
            preferredRoute in setOf(RouteKind.VPN_TUN_FAKE_IP, RouteKind.ROUTER_FAKE_IP)
        // The transfer retry budget advances PAC candidates after a network
        // failure. Never resolve the origin merely because DIRECT is a later
        // fallback; check its DNS only when that route is actually selected.
        for (offset in candidates.indices) {
            val proxy = candidates[(attempt + offset) % candidates.size]
            try {
                if (proxy.type() == Proxy.Type.DIRECT) {
                    val explicitDirect = preferredRoute == RouteKind.PUBLIC_DIRECT ||
                        preferredRoute == RouteKind.VPN_TUN_FAKE_IP ||
                        preferredRoute == RouteKind.ROUTER_FAKE_IP
                    if (proxyAttempted) break
                    if (http.isNotEmpty() && !explicitDirect) continue
                    // DIRECT owns origin DNS, so validate every answer locally.
                    // An HTTP proxy owns origin resolution; forcing local DNS
                    // here breaks split-DNS and proxy-only hostnames.
                    val addresses = resolve(uri.host)
                    require(addresses.isNotEmpty() && addresses.all {
                        if (preferredRoute == RouteKind.VPN_TUN_FAKE_IP ||
                            preferredRoute == RouteKind.ROUTER_FAKE_IP) {
                            confirmedFakeIpDirect && fakeIp(it)
                        } else {
                            publicAddress(it) || confirmedFakeIpDirect && fakeIp(it)
                        }
                    }) { "DNS 返回本机/私网地址，已拒绝连接；请检查系统代理、VPN 或 DNS 设置" }
                    proxyAttempted = true
                    return (open?.invoke(uri, proxy) ?: openOkHttpConnection(
                        context, uri, proxy, addresses.toList(),
                        bindVpn = preferredRoute == RouteKind.VPN_TUN_FAKE_IP &&
                            confirmedFakeIpDirect && addresses.all(::fakeIp),
                    )).also {
                        onSelectedRoute(preferredRoute?.wireName ?: "direct")
                        it.connectTimeout = 15000
                        it.readTimeout = 20000
                    }
                }
                proxyAttempted = true
                return (open?.invoke(uri, proxy) ?: openOkHttpConnection(
                    context, uri, proxy,
                    // The proxy owns this hop's socket, even when a VPN is
                    // present for another route in the retry sequence.
                    bindVpn = false,
                )).also {
                    onSelectedRoute(
                        preferredRoute?.wireName
                            ?: if (proxy.type() == Proxy.Type.HTTP) "http_proxy" else "direct",
                    )
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

    private fun openOkHttpConnection(
        context: Context?,
        uri: URI,
        proxy: Proxy,
        validatedAddresses: List<InetAddress>? = null,
        /**
         * Bind the tunnel's socket factories. Off by default: a caller on a
         * direct route must not push a real address into a tunnel that will
         * not carry it.
         */
        bindVpn: Boolean = false,
        network: Network? = null,
        secondaryDns: SecondaryDns = SecondaryDns.UNKNOWN,
        beforeConnect: () -> Unit = {},
    ): HttpURLConnection {
        val client = buildOkHttpClient(
            context = context,
            uri = uri,
            proxy = proxy,
            validatedAddresses = validatedAddresses,
            bindVpn = bindVpn,
            network = network,
            secondaryDns = secondaryDns,
            beforeConnect = beforeConnect,
        )
        return OkHttpMediaConnection(uri, client, proxy.type() == Proxy.Type.HTTP, beforeConnect)
    }

    private fun buildOkHttpClient(
        context: Context?,
        uri: URI,
        proxy: Proxy,
        validatedAddresses: List<InetAddress>? = null,
        bindVpn: Boolean = false,
        network: Network? = null,
        secondaryDns: SecondaryDns = SecondaryDns.UNKNOWN,
        beforeConnect: () -> Unit = {},
        timeoutMs: Long? = null,
        listener: EventListener? = null,
    ): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .proxy(proxy)
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .connectionPool(ConnectionPool(0, 1, TimeUnit.MILLISECONDS))
        listener?.let { builder.eventListener(it) }
        timeoutMs?.let { timeout ->
            val duration = timeout.coerceIn(1L, 60_000L)
            builder
                .connectTimeout(duration, TimeUnit.MILLISECONDS)
                .readTimeout(duration, TimeUnit.MILLISECONDS)
                .callTimeout(duration, TimeUnit.MILLISECONDS)
        }
        // One resolver for every name a single request can reach. A pinned
        // address only covers the planned origin; redirects and the resources
        // a playlist names move to other hosts, and those must follow the same
        // DNS owner the plan recorded, not whichever one this hop happened to
        // have bound.
        if (validatedAddresses != null || secondaryDns != SecondaryDns.UNKNOWN) {
            builder.dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> {
                    if (hostname.equals(uri.host, ignoreCase = true) &&
                        validatedAddresses != null) {
                        return validatedAddresses
                    }
                    // The plan's DNS owner answers every other name. A bound
                    // tunnel resolves inside itself; a direct hop on the
                    // underlay asks the OS like the WebView; a proxy hop never
                    // resolves locally at all. A routed lookup without a bound
                    // network falls back to the OS resolver because there is
                    // nothing else to hand the name to.
                    return when (secondaryDns) {
                        SecondaryDns.ROUTE -> network?.getAllByName(hostname)?.toList()
                            ?: Dns.SYSTEM.lookup(hostname)
                        else -> Dns.SYSTEM.lookup(hostname)
                    }
                }
            })
        }
        // An HTTPS hop needs the tunnel's TLS factory as well as its plain
        // socket factory; binding only the latter leaves the handshake on the
        // underlay network.
        if (bindVpn && context != null) {
            val selectedNetwork = network ?: vpnNetwork(
                context.getSystemService(ConnectivityManager::class.java),
            )
            check(selectedNetwork != null && bindToNetwork(selectedNetwork, builder)) {
                "VPN/TUN socket binding unavailable"
            }
            // Name resolution must also happen inside the tunnel, otherwise a
            // split-DNS name is answered by the underlay and the tunnelled
            // socket then connects to the wrong address. The plan's DNS owner
            // already recorded that decision, so this is only the fallback for
            // a caller that built the client without one.
            val tunnel = selectedNetwork
            // `validatedAddresses` already carries the address this hop must
            // use (including a Fake-IP), so it wins over a second lookup.
            if (validatedAddresses == null && secondaryDns == SecondaryDns.UNKNOWN) {
                builder.dns(object : Dns {
                    override fun lookup(hostname: String): List<InetAddress> =
                        tunnel.getAllByName(hostname).toList()
                })
            }
        }
        return builder.build()
    }

    fun classifyTransportFailure(error: IOException, proxyRoute: Boolean): IOException {
        if (error is MediaRouteIOException) return error
        val category = when {
            error is UnknownHostException -> "dns"
            error is SocketTimeoutException -> "timeout"
            error is SSLPeerUnverifiedException -> {
                if (error.message.orEmpty().lowercase().contains("hostname")) "hostname" else "certificate"
            }
            error is SSLHandshakeException -> {
                val chain = generateSequence(error as Throwable?) { it.cause }.toList()
                when {
                    chain.any { it is CertificateException } -> "certificate"
                    error.message.orEmpty().lowercase().contains("hostname") -> "hostname"
                    else -> "tls_handshake"
                }
            }
            error is SSLProtocolException -> "tls_handshake"
            proxyRoute && error.message.orEmpty().lowercase().let {
                it.contains("authenticate with proxy") ||
                    it.contains("unexpected response code for connect") ||
                    it.contains("proxy connect") && it.contains("response")
            } -> "proxy_connect_status"
            proxyRoute && error is ProtocolException -> "proxy_connect"
            proxyRoute && error.message.orEmpty().lowercase().contains("connect") -> "proxy_connect"
            else -> "io"
        }
        return MediaRouteIOException(category, error)
    }
}

private class OkHttpMediaConnection(
    uri: URI,
    private val client: OkHttpClient,
    private val proxyRoute: Boolean,
    private val beforeConnect: () -> Unit,
) : HttpURLConnection(uri.toURL()) {
    private val stateLock = Any()
    @Volatile private var cancelled = false
    private val requestProperties = linkedMapOf<String, String>()
    private var call: okhttp3.Call? = null
    private var response: Response? = null

    override fun connect() {
        synchronized(stateLock) {
            if (cancelled) throw IOException("媒体连接已取消")
            if (response != null) return
        }
        beforeConnect()
        val request = Request.Builder()
            .url(url)
            .get()
            .apply { requestProperties.forEach { (name, value) -> header(name, value) } }
            .build()
        val nextCall = client.newCall(request)
        synchronized(stateLock) {
            if (cancelled) {
                nextCall.cancel()
                throw IOException("媒体连接已取消")
            }
            call = nextCall
        }
        try {
            val received = nextCall.execute()
            synchronized(stateLock) {
                if (cancelled) {
                    received.close()
                    throw IOException("媒体连接已取消")
                }
                response = received
            }
        } catch (error: IOException) {
            throw SystemMediaNetwork.classifyTransportFailure(error, proxyRoute)
        }
    }

    override fun disconnect() {
        val activeCall: okhttp3.Call?
        val activeResponse: Response?
        synchronized(stateLock) {
            cancelled = true
            activeCall = call
            activeResponse = response
            call = null
            response = null
        }
        activeCall?.cancel()
        activeResponse?.close()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    override fun usingProxy(): Boolean = proxyRoute

    override fun getResponseCode(): Int {
        connect()
        return response!!.code
    }

    override fun getInputStream(): InputStream {
        connect()
        return response?.body?.byteStream() ?: ByteArrayInputStream(ByteArray(0))
    }

    override fun getErrorStream(): InputStream? = runCatching {
        connect()
        response?.body?.byteStream()
    }.getOrNull()

    override fun getHeaderField(name: String): String? {
        connect()
        return response?.header(name)
    }

    override fun getHeaderFieldKey(position: Int): String? {
        connect()
        return response?.headers?.names()?.toList()?.getOrNull(position)
    }

    override fun getContentLengthLong(): Long {
        connect()
        return response?.body?.contentLength() ?: -1L
    }

    override fun setRequestProperty(key: String, value: String?) {
        if (value == null) requestProperties.remove(key) else requestProperties[key] = value
    }

    override fun addRequestProperty(key: String, value: String?) {
        if (value != null) requestProperties[key] = value
    }

    override fun getRequestProperty(key: String): String? = requestProperties[key]
}
