package dev.vikiea.site_lens

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLProtocolException
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.Dns
import okhttp3.EventListener
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

class MediaRouteIOException(
    val category: String,
    cause: IOException,
) : IOException("系统网络 $category", cause)

/**
 * Android's single execution boundary for app-owned HTTP.
 *
 * The active ProxySelector/PAC is authoritative and is consumed in the order it
 * returns. HTTP, SOCKS and DIRECT are supported without reclassification. DNS
 * is only consulted when the selected route asks OkHttp to resolve a name: a
 * proxy resolves the origin remotely, while DIRECT uses the system resolver or
 * the user's optional DoH provider with one system-DNS fallback.
 */
object SystemMediaNetwork {
    private val epoch = AtomicLong(0L)
    private val secureDnsProvider = AtomicReference("off")
    private val dnsResolver = SecureDnsResolver()
    private val listeners = ConcurrentHashMap.newKeySet<() -> Unit>()
    private val networkChangeGate = NetworkChangeGate()
    private val networkChangeBatcher = NetworkChangeBatcher(250L, ::networkChanged)
    private val supportedDnsProviders = setOf(
        "off",
        "tencent",
        "alibaba",
        "q360",
        "cloudflare",
        "cloudflare_security",
        "google",
        "quad9",
        "adguard",
    )

    @Volatile private var appContext: Context? = null
    @Volatile private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Synchronized
    fun initialize(context: Context) {
        val application = context.applicationContext
        appContext = application
        secureDnsProvider.set(
            application.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getString(DNS_PROVIDER_KEY, "off")
                ?.takeIf(supportedDnsProviders::contains)
                ?: "off",
        )
        if (networkCallback != null) return
        val manager = application.getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (networkChangeGate.available(network.toString())) {
                    networkChangeBatcher.changed()
                }
            }

            override fun onLost(network: Network) {
                if (networkChangeGate.lost(network.toString())) {
                    networkChangeBatcher.changed()
                }
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (networkChangeGate.capabilities(
                        network.toString(),
                        capabilitiesFingerprint(capabilities),
                    )
                ) {
                    networkChangeBatcher.changed()
                }
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                if (networkChangeGate.linkProperties(
                        network.toString(),
                        linkProperties.toString(),
                    )
                ) {
                    networkChangeBatcher.changed()
                }
            }
        }
        runCatching { manager.registerDefaultNetworkCallback(callback) }
            .onSuccess { networkCallback = callback }
    }

    fun setSecureDnsProvider(context: Context, provider: String) {
        val normalized = provider.trim().lowercase()
        require(normalized in supportedDnsProviders) { "unsupported secure DNS provider" }
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putString(DNS_PROVIDER_KEY, normalized)
            .apply()
        secureDnsProvider.set(normalized)
        clearSecureDnsCache()
    }

    fun clearSecureDnsCache() {
        dnsResolver.clearCache()
    }

    fun networkEpoch(): Long = epoch.get()

    fun addNetworkChangeListener(listener: () -> Unit): () -> Unit {
        listeners += listener
        return { listeners -= listener }
    }

    private fun networkChanged() {
        epoch.incrementAndGet()
        dnsResolver.clearCache()
        listeners.forEach { listener ->
            runCatching(listener).onFailure {
                Log.w("SiteLensNetwork", "network change listener failed", it)
            }
        }
    }

    private fun capabilitiesFingerprint(capabilities: NetworkCapabilities): String =
        listOf(
            listOf(
                NetworkCapabilities.TRANSPORT_WIFI,
                NetworkCapabilities.TRANSPORT_CELLULAR,
                NetworkCapabilities.TRANSPORT_ETHERNET,
                NetworkCapabilities.TRANSPORT_VPN,
            ).filter(capabilities::hasTransport).joinToString(","),
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
        ).joinToString("|")

    fun validateTarget(uri: URI) {
        require(uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) {
            "仅支持 HTTP(S) 网络地址"
        }
        require(!uri.host.isNullOrBlank()) { "网络地址缺少主机名" }
        require(uri.rawUserInfo.isNullOrEmpty()) { "网络地址不能包含账号密码" }
    }

    internal fun validateBufferedRequestLimits(maxBytes: Int, timeoutMs: Long) {
        require(maxBytes in 1..MAX_BUFFERED_RESPONSE_BYTES) {
            "网络响应大小上限无效: $maxBytes"
        }
        require(timeoutMs in 1..60_000L) { "网络请求超时无效" }
    }

    /**
     * Preserve the OS policy verbatim. A later DIRECT entry is retained only
     * when ProxySelector itself returned it; the app never manufactures one.
     */
    fun proxyCandidates(
        uri: URI,
        selector: ProxySelector? = ProxySelector.getDefault(),
    ): List<Proxy> {
        if (selector == null) return listOf(Proxy.NO_PROXY)
        val selected = runCatching { selector.select(uri) }.getOrElse { error ->
            throw IOException("系统代理配置读取失败", error)
        }
        if (selected.isEmpty()) throw IOException("系统代理配置没有返回可用路由")
        val usable = selected.filter { proxy ->
            when (proxy.type()) {
                Proxy.Type.DIRECT -> true
                Proxy.Type.HTTP, Proxy.Type.SOCKS -> proxy.address() is InetSocketAddress
            }
        }
        if (usable.isEmpty()) throw IOException("系统代理配置包含无效路由")
        return usable
    }

    fun proxyLabel(proxy: Proxy): String = when (proxy.type()) {
        Proxy.Type.DIRECT -> "DIRECT"
        Proxy.Type.HTTP -> "PROXY"
        Proxy.Type.SOCKS -> "SOCKS"
    }

    internal class SystemProxySelector(
        private val selector: ProxySelector?,
        private val dns: SystemDns,
    ) : ProxySelector() {
        override fun select(uri: URI): List<Proxy> =
            proxyCandidates(uri, selector).also(dns::rememberProxyHosts)

        override fun connectFailed(
            uri: URI?,
            socketAddress: SocketAddress?,
            error: IOException?,
        ) {
            selector?.connectFailed(uri, socketAddress, error)
        }
    }

    internal class SystemDns(
        private val provider: String,
        systemOnlyHosts: Set<String> = emptySet(),
    ) : Dns {
        private val systemOnlyHosts = ConcurrentHashMap.newKeySet<String>().apply {
            addAll(systemOnlyHosts.map(String::lowercase))
        }
        private var fallbackUsed = false

        override fun lookup(hostname: String): List<InetAddress> {
            if (hostname.lowercase() in systemOnlyHosts) return Dns.SYSTEM.lookup(hostname)
            if (provider == "off" || fallbackUsed) return Dns.SYSTEM.lookup(hostname)
            return try {
                val answers = dnsResolver.lookup(provider, hostname)
                if (answers.isEmpty()) error("secure DNS returned no address")
                answers.map(InetAddress::getByName).distinctBy { it.hostAddress }
            } catch (error: Throwable) {
                fallbackUsed = true
                Log.i(
                    "SiteLensNetwork",
                    "secure DNS failed for $hostname; falling back to system DNS: " +
                        error.javaClass.simpleName,
                )
                Dns.SYSTEM.lookup(hostname)
            }
        }

        fun rememberProxyHosts(proxies: List<Proxy>) {
            proxies.mapNotNull { (it.address() as? InetSocketAddress)?.hostString }
                .mapTo(systemOnlyHosts) { it.lowercase() }
        }

        internal fun usesSystemResolver(hostname: String): Boolean =
            hostname.lowercase() in systemOnlyHosts
    }

    private fun clientBuilder(
        timeoutMs: Long,
        listener: EventListener?,
        overallTimeout: Boolean,
        systemOnlyHosts: Set<String> = emptySet(),
        dns: Dns = SystemDns(secureDnsProvider.get(), systemOnlyHosts),
    ): OkHttpClient.Builder {
        val duration = timeoutMs.coerceIn(1L, 60_000L)
        return OkHttpClient.Builder()
            .retryOnConnectionFailure(false)
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(duration, TimeUnit.MILLISECONDS)
            .readTimeout(duration, TimeUnit.MILLISECONDS)
            .writeTimeout(duration, TimeUnit.MILLISECONDS)
            .callTimeout(if (overallTimeout) duration else 0L, TimeUnit.MILLISECONDS)
            .connectionPool(ConnectionPool(0, 1, TimeUnit.MILLISECONDS))
            .dns(dns)
            .apply { listener?.let(::eventListener) }
    }

    /**
     * Used by Media3, whose OkHttp data source owns redirects internally. The
     * selector is queried for every request URL, so PAC decisions remain live.
     */
    fun buildOkHttpClient(
        uri: URI,
        timeoutMs: Long? = null,
        listener: EventListener? = null,
        selector: ProxySelector? = ProxySelector.getDefault(),
    ): OkHttpClient {
        validateTarget(uri)
        // The system selector is queried again for every OkHttp redirect. Keep
        // its proxy hosts on system DNS so a route selected later by PAC cannot
        // accidentally send the local proxy endpoint through DoH.
        val systemDns = SystemDns(secureDnsProvider.get())
        return clientBuilder(
            timeoutMs ?: 20_000L,
            listener,
            overallTimeout = false,
            dns = systemDns,
        )
            .retryOnConnectionFailure(true)
            .proxySelector(SystemProxySelector(selector, systemDns))
            .build()
    }

    internal fun buildClientForProxy(
        uri: URI,
        proxy: Proxy,
        timeoutMs: Long,
        listener: EventListener? = null,
        overallTimeout: Boolean,
    ): OkHttpClient {
        val proxyHost = (proxy.address() as? InetSocketAddress)?.hostString?.lowercase()
        return clientBuilder(
            timeoutMs,
            listener,
            overallTimeout,
            systemOnlyHosts = setOfNotNull(proxyHost),
        )
            .proxy(proxy)
            .apply {
                if (proxy.type() != Proxy.Type.DIRECT) {
                    protocols(listOf(Protocol.HTTP_1_1))
                }
            }
            .build()
    }

    data class BufferedResponse(
        val statusCode: Int,
        val headers: Map<String, String>,
        val body: ByteArray,
        val finalUri: URI,
        val networkEpoch: Long,
    )

    /** One request, using exactly the route list supplied by the OS. */
    fun requestBuffered(
        context: Context,
        uri: URI,
        method: String = "GET",
        headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null,
        maxBytes: Int = 2 * 1024 * 1024,
        timeoutMs: Long = 15_000L,
        isCancelled: (() -> Boolean)? = null,
        registerCall: ((Call) -> Unit)? = null,
        unregisterCall: ((Call) -> Unit)? = null,
    ): BufferedResponse {
        initialize(context)
        validateBufferedRequestLimits(maxBytes, timeoutMs)
        require(method in setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")) {
            "不支持 HTTP 方法"
        }
        validateTarget(uri)
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
        val candidates = proxyCandidates(uri)
        Log.d(
            "SiteLensNetwork",
            "request routes=${candidates.joinToString(",") { proxyLabel(it) }}",
        )
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        var lastError: IOException? = null
        for ((index, proxy) in candidates.withIndex()) {
            if (isCancelled?.invoke() == true) throw java.io.InterruptedIOException("请求已取消")
            val remainingMs = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime())
                .coerceAtLeast(1L)
            if (deadlineNanos - System.nanoTime() <= 0L) {
                throw java.net.SocketTimeoutException("系统网络请求超时")
            }
            val client = buildClientForProxy(
                uri,
                proxy,
                remainingMs,
                overallTimeout = true,
            )
            val call = client.newCall(request)
            registerCall?.invoke(call)
            var responseReceived = false
            try {
                call.execute().use { response ->
                    responseReceived = true
                    val output = ByteArrayOutputStream()
                    val stream = response.body?.byteStream()
                    if (stream != null && method != "HEAD") {
                        stream.use { input ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                if (isCancelled?.invoke() == true) {
                                    throw java.io.InterruptedIOException("请求已取消")
                                }
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
                        headers = response.headers.toMultimap()
                            .mapValues { it.value.joinToString(", ") },
                        body = output.toByteArray(),
                        finalUri = uri,
                        networkEpoch = networkEpoch(),
                    )
                }
            } catch (error: IOException) {
                lastError = classifyTransportFailure(
                    error,
                    proxy.type() != Proxy.Type.DIRECT,
                )
                Log.w(
                    "SiteLensNetwork",
                    "request failed host=${uri.host} route=${proxyLabel(proxy)} " +
                        "systemIndex=$index error=${error.javaClass.simpleName}",
                )
                if (isCancelled?.invoke() == true) {
                    throw java.io.InterruptedIOException("请求已取消")
                }
                // Once a route produced response headers, a body, size-limit or
                // cancellation error belongs to this logical response. Trying a
                // later PAC candidate would replay the request and hide it.
                if (responseReceived) throw lastError
            } finally {
                unregisterCall?.invoke(call)
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
            }
        }
        throw lastError ?: IOException("系统网络没有可用路由")
    }

    /**
     * A resumable-download connection that follows the same system proxy list.
     * Redirects call this factory again, so each hop gets a fresh PAC decision.
     */
    fun openMediaConnection(
        context: Context,
        uri: URI,
        @Suppress("UNUSED_PARAMETER") attempt: Int,
        timeoutMs: Long = 20_000L,
    ): HttpURLConnection {
        val candidates = proxyCandidates(uri)
        Log.d(
            "SiteLensNetwork",
            "media routes=${candidates.joinToString(",") { proxyLabel(it) }}",
        )
        return openMediaConnection(
            uri,
            candidates,
            timeoutMs,
            initializeFirst = { initialize(context) },
        )
    }

    /**
     * Test seam: the same connection without Android services or a live socket.
     *
     * [opener] receives the proxy the hop is about to attempt, so a test can
     * fail a proxied candidate and observe how the hop reports itself.
     */
    internal fun openMediaConnection(
        uri: URI,
        candidates: List<Proxy>,
        timeoutMs: Long = 20_000L,
        initializeFirst: () -> Unit = {},
        opener: ((Proxy) -> HttpURLConnection)? = null,
    ): HttpURLConnection {
        initializeFirst()
        validateTarget(uri)
        return SystemHttpConnection(uri, candidates, timeoutMs, opener)
    }

    internal class SystemHttpConnection(
        uri: URI,
        private val candidates: List<Proxy>,
        timeoutMs: Long,
        private val opener: ((Proxy) -> HttpURLConnection)? = null,
    ) : HttpURLConnection(uri.toURL()) {
        private val targetUri = uri
        private val requestTimeoutMs = timeoutMs
        private val lock = Any()
        private var requestProperties = linkedMapOf<String, String>()
        @Volatile private var cancelled = false
        @Volatile private var activeCall: Call? = null
        @Volatile private var activeClient: OkHttpClient? = null
        @Volatile private var response: Response? = null
        @Volatile private var selectedProxy: Proxy? = null
        /**
         * The candidate this hop is working on.
         *
         * [selectedProxy] is only assigned after a successful execute(), so a
         * failure during connect() left usingProxy() false and a proxied
         * attempt was reported as DIRECT. Diagnostics then blamed the direct
         * path for a proxy failure.
         */
        @Volatile private var attemptedProxy: Proxy? = null
        @Volatile private var connection: HttpURLConnection? = null

        init {
            connectTimeout = timeoutMs.toInt()
            readTimeout = timeoutMs.toInt()
        }

        override fun connect() {
            synchronized(lock) {
                if (cancelled) throw IOException("媒体连接已取消")
                if (response != null) return
            }
            val request = Request.Builder()
                .url(url)
                .get()
                .apply { requestProperties.forEach { (name, value) -> header(name, value) } }
                .build()
            var last: IOException? = null
            for (proxy in candidates) {
                if (cancelled) throw IOException("媒体连接已取消")
                attemptedProxy = proxy
                val injected = opener
                if (injected != null) {
                    val opened = injected(proxy)
                    synchronized(lock) {
                        if (cancelled) {
                            opened.disconnect()
                            throw IOException("媒体连接已取消")
                        }
                        connection = opened
                    }
                    return
                }
                val client = buildClientForProxy(
                    targetUri,
                    proxy,
                    requestTimeoutMs,
                    overallTimeout = false,
                )
                val call = client.newCall(request)
                synchronized(lock) {
                    if (cancelled) {
                        call.cancel()
                        throw IOException("媒体连接已取消")
                    }
                    activeClient = client
                    activeCall = call
                    selectedProxy = proxy
                }
                try {
                    val received = call.execute()
                    synchronized(lock) {
                        if (cancelled) {
                            received.close()
                            throw IOException("媒体连接已取消")
                        }
                        response = received
                    }
                    return
                } catch (error: IOException) {
                    last = classifyTransportFailure(error, proxy.type() != Proxy.Type.DIRECT)
                    synchronized(lock) {
                        activeCall = null
                        activeClient = null
                    }
                    client.connectionPool.evictAll()
                    client.dispatcher.executorService.shutdown()
                }
            }
            throw last ?: IOException("系统网络没有可用路由")
        }

        override fun disconnect() {
            val call: Call?
            val client: OkHttpClient?
            val received: Response?
            synchronized(lock) {
                cancelled = true
                call = activeCall
                client = activeClient
                received = response
                activeCall = null
                activeClient = null
                response = null
                selectedProxy = null
                attemptedProxy = null
            }
            call?.cancel()
            received?.close()
            client?.connectionPool?.evictAll()
            client?.dispatcher?.executorService?.shutdown()
            connection?.disconnect()
            connection = null
        }

        override fun usingProxy(): Boolean {
            val proxy = selectedProxy ?: attemptedProxy
            return proxy != null && proxy.type() != Proxy.Type.DIRECT
        }

        override fun getResponseCode(): Int {
            connect()
            val delegated = connection
            if (delegated != null) return delegated.responseCode
            return response!!.code
        }

        override fun getInputStream(): InputStream {
            connect()
            val delegated = connection
            if (delegated != null) return delegated.inputStream
            return response?.body?.byteStream() ?: ByteArrayInputStream(ByteArray(0))
        }

        override fun getErrorStream(): InputStream? = runCatching {
            connect()
            val delegated = connection
            if (delegated != null) return delegated.errorStream
            response?.body?.byteStream()
        }.getOrNull()

        override fun getHeaderField(name: String): String? {
            connect()
            val delegated = connection
            if (delegated != null) return delegated.getHeaderField(name)
            return response?.header(name)
        }

        override fun getHeaderFieldKey(position: Int): String? {
            connect()
            val delegated = connection
            if (delegated != null) return delegated.getHeaderFieldKey(position)
            return response?.headers?.names()?.toList()?.getOrNull(position)
        }

        override fun getContentLengthLong(): Long {
            connect()
            val delegated = connection
            if (delegated != null) return delegated.contentLengthLong
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

    fun classifyTransportFailure(error: IOException, proxyRoute: Boolean): IOException {
        if (error is MediaRouteIOException) return error
        val category = when {
            error is java.net.UnknownHostException -> "dns"
            error is java.net.SocketTimeoutException -> "timeout"
            error is SSLPeerUnverifiedException -> {
                if (error.message.orEmpty().lowercase().contains("hostname")) "hostname" else "certificate"
            }
            error is SSLHandshakeException -> tlsFailure(error)
            error is SSLProtocolException -> tlsFailure(error)
            proxyRoute && error.message.orEmpty().lowercase().let {
                it.contains("authenticate with proxy") ||
                    it.contains("unexpected response code for connect") ||
                    it.contains("proxy connect") && it.contains("response")
            } -> "proxy_connect_status"
            proxyRoute && error is java.net.ProtocolException -> "proxy_connect"
            proxyRoute && error.message.orEmpty().lowercase().contains("connect") -> "proxy_connect"
            else -> "io"
        }
        return MediaRouteIOException(category, error)
    }

    /**
     * Splits a TLS failure into the reason a user can act on.
     *
     * Every one of these used to be reported as `tls_handshake`, so a peer that
     * resets the socket mid-handshake, a protocol/version refusal and a plain
     * handshake rejection were indistinguishable in the task row and in the
     * attempt log. Only failures whose cause chain already contains an SSL
     * exception are classified here; a bare socket error stays `io`.
     */
    private fun tlsFailure(error: IOException): String {
        val chain = generateSequence(error as Throwable?) { it.cause }.toList()
        if (chain.any { it is java.security.cert.CertificateException }) return "certificate"
        val text = chain.joinToString(" ") { it.message.orEmpty() }.lowercase()
        if ("hostname" in text) return "hostname"
        // A TLS alert or an explicit protocol refusal is a version or cipher
        // mismatch, not a dropped connection.
        if ("protocol" in text ||
            "version" in text ||
            "alert" in text ||
            "handshake_failure" in text ||
            "no cipher suites" in text ||
            "no appropriate protocol" in text
        ) {
            return "tls_protocol"
        }
        // The peer closed or reset the socket before the handshake completed.
        // Against a CDN edge this is what an egress that rewrites SNI produces.
        if (chain.any { it is java.net.SocketException || it is java.io.EOFException } ||
            "reset" in text ||
            "closed" in text ||
            "eof" in text ||
            "broken pipe" in text
        ) {
            return "tls_reset"
        }
        return "tls_handshake"
    }

    private const val PREFERENCES = "site_lens_network"
    private const val DNS_PROVIDER_KEY = "secure_dns_provider"
    internal const val MAX_BUFFERED_RESPONSE_BYTES = 16 * 1024 * 1024
}

/**
 * Android publishes several callbacks for one default-network state. Advance
 * the transport epoch only when the route-relevant state really changes.
 */
internal class NetworkChangeGate {
    private var network: String? = null
    private var capabilities: String? = null
    private var linkProperties: String? = null

    @Synchronized
    fun available(nextNetwork: String): Boolean {
        if (network == nextNetwork) return false
        network = nextNetwork
        capabilities = null
        linkProperties = null
        return true
    }

    @Synchronized
    fun lost(previousNetwork: String): Boolean {
        if (network != previousNetwork) return false
        network = null
        capabilities = null
        linkProperties = null
        return true
    }

    @Synchronized
    fun capabilities(nextNetwork: String, nextCapabilities: String): Boolean {
        if (network != nextNetwork) {
            network = nextNetwork
            capabilities = nextCapabilities
            linkProperties = null
            return true
        }
        if (capabilities == nextCapabilities) return false
        capabilities = nextCapabilities
        return true
    }

    @Synchronized
    fun linkProperties(nextNetwork: String, nextLinkProperties: String): Boolean {
        if (network != nextNetwork) {
            network = nextNetwork
            capabilities = null
            linkProperties = nextLinkProperties
            return true
        }
        if (linkProperties == nextLinkProperties) return false
        linkProperties = nextLinkProperties
        return true
    }
}

/**
 * Android emits an availability callback followed by capability and link
 * callbacks for one physical transition. Publish the new epoch after that
 * burst settles so one transition cancels active work once.
 */
internal class NetworkChangeBatcher(
    private val delayMs: Long,
    private val publish: () -> Unit,
) : AutoCloseable {
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "site-lens-network-change").apply { isDaemon = true }
    }
    private val lock = Any()
    private var pending: ScheduledFuture<*>? = null

    fun changed() {
        synchronized(lock) {
            pending?.cancel(false)
            pending = scheduler.schedule({
                synchronized(lock) { pending = null }
                publish()
            }, delayMs, TimeUnit.MILLISECONDS)
        }
    }

    override fun close() {
        synchronized(lock) {
            pending?.cancel(false)
            pending = null
        }
        scheduler.shutdownNow()
    }
}
