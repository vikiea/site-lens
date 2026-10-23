package dev.vikiea.site_lens

import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URI

/** Resolve the local end of a direct receiver connection, independent of HTTP proxies. */
internal object DlnaRelayAddress {
    fun failureDetails(error: Throwable): Map<String, String> = mapOf(
        "type" to error.javaClass.name,
        "message" to (error.message ?: ""),
        "stack" to error.stackTraceToString(),
    )

    fun resolve(
        receiver: URI,
        timeoutMs: Int = 3000,
        socketFactory: () -> Socket = { Socket(Proxy.NO_PROXY) },
    ): String {
        require(receiver.scheme in setOf("http", "https") && !receiver.host.isNullOrBlank()) {
            "接收设备地址无效"
        }
        val port = receiver.port.takeIf { it > 0 } ?: if (receiver.scheme == "https") 443 else 80
        require(port in 1..65535) { "接收设备端口无效" }
        var lastError: Exception? = null
        for (address in InetAddress.getAllByName(receiver.host).filterIsInstance<Inet4Address>()) {
            try {
                return socketFactory().use { socket ->
                    socket.connect(InetSocketAddress(address, port), timeoutMs)
                    val local = socket.localAddress
                    check(local is Inet4Address && !local.isAnyLocalAddress) { "无法读取本机投屏地址" }
                    local.hostAddress ?: error("无法读取本机投屏地址")
                }
            } catch (error: Exception) {
                lastError = error
            }
        }
        throw IllegalStateException("无法确定通往接收设备的本机地址", lastError)
    }
}
