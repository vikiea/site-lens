package dev.vikiea.site_lens

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
    fun validateTarget(uri: URI) {
        require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null) {
            "媒体地址无效"
        }
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
        val selected = selector?.select(uri) ?: listOf(Proxy.NO_PROXY)
        check(selected.isNotEmpty()) { "系统代理配置为空" }
        check(selected.all { it.type() == Proxy.Type.HTTP || it.type() == Proxy.Type.DIRECT }) {
            "请在代理应用中启用 VPN/TUN 或系统 HTTP 代理后重试"
        }
        return selected
    }

    fun configuration(
        uri: URI,
        selector: ProxySelector? = ProxySelector.getDefault(),
        attempt: Int = 0,
    ): String {
        val selected = proxies(uri, selector)
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
    ): HttpURLConnection {
        val selected = proxies(uri, selector)
        var lastIo: IOException? = null
        var lastPolicy: IllegalArgumentException? = null
        // The transfer retry budget advances PAC candidates after a network
        // failure. Never resolve the origin merely because DIRECT is a later
        // fallback; check its DNS only when that route is actually selected.
        for (offset in selected.indices) {
            val proxy = selected[(attempt + offset) % selected.size]
            try {
                if (proxy.type() == Proxy.Type.DIRECT) {
                    val addresses = resolve(uri.host)
                    require(addresses.isNotEmpty() && addresses.all {
                        publicAddress(it) || allowProxyFakeIp && fakeIp(it)
                    }) { "DNS 包含本机/私网媒体地址；请检查系统代理或 VPN 设置" }
                }
                return open(uri, proxy).also {
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
