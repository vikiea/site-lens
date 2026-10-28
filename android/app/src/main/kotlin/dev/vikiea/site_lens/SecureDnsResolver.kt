package dev.vikiea.site_lens

import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps
import java.util.Locale
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class SecureDnsResolver {
    private data class CacheEntry(
        val epoch: Long,
        val expiresAtNanos: Long,
        val addresses: List<String>,
    )

    companion object {
        private const val CACHE_TTL_SECONDS = 60L
        private const val MAX_CACHE_ENTRIES = 256
        private const val LOOKUP_TIMEOUT_MILLIS = 5_000L
    }

    private val dnsByProvider = ConcurrentHashMap<String, Dns>()
    private val cache = ConcurrentHashMap<String, CacheEntry>()
    private val inFlight = ConcurrentHashMap<String, CompletableFuture<List<String>>>()
    private val cacheEpoch = AtomicLong(0)
    private val providers = mapOf(
        "tencent" to "https://doh.pub/dns-query",
        "alibaba" to "https://dns.alidns.com/dns-query",
        "q360" to "https://doh.360.cn/dns-query",
        "cloudflare" to "https://cloudflare-dns.com/dns-query",
        "cloudflare_security" to "https://security.cloudflare-dns.com/dns-query",
        "google" to "https://dns.google/dns-query",
        "quad9" to "https://dns.quad9.net/dns-query",
        "adguard" to "https://dns.adguard-dns.com/dns-query",
    )

    fun lookup(provider: String, hostname: String): List<String> {
        val normalizedHostname = hostname.trim().trimEnd('.').lowercase(Locale.US)
        require(normalizedHostname.isNotBlank()) { "hostname is empty" }
        require(provider in providers) { "unsupported secure DNS provider" }
        val key = "$provider\u0000$normalizedHostname"
        val nowEpoch = cacheEpoch.get()
        val now = System.nanoTime()
        cache[key]
            ?.takeIf { it.epoch == nowEpoch && it.expiresAtNanos > now }
            ?.let { return it.addresses }

        val pending = CompletableFuture<List<String>>()
        val flightKey = "$key\u0000$nowEpoch"
        val existing = inFlight.putIfAbsent(flightKey, pending)
        if (existing != null) {
            return existing.get(LOOKUP_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        }

        try {
            val addresses = dns(provider)
                .lookup(normalizedHostname)
                .mapNotNull(InetAddress::getHostAddress)
                .distinct()
            if (addresses.isEmpty()) {
                throw IllegalStateException("secure DNS returned no address")
            }
            val stable = addresses.toList()
            if (cacheEpoch.get() == nowEpoch) {
                cache[key] = CacheEntry(
                    epoch = nowEpoch,
                    expiresAtNanos = System.nanoTime() +
                        TimeUnit.SECONDS.toNanos(CACHE_TTL_SECONDS),
                    addresses = stable,
                )
            }
            if (cache.size > MAX_CACHE_ENTRIES) {
                cache.keys.firstOrNull()?.let(cache::remove)
            }
            pending.complete(stable)
            return stable
        } catch (error: Throwable) {
            pending.completeExceptionally(error)
            throw error
        } finally {
            inFlight.remove(flightKey, pending)
        }
    }

    fun clearCache() {
        cacheEpoch.incrementAndGet()
        cache.clear()
    }

    private fun dns(provider: String): Dns = dnsByProvider.getOrPut(provider) {
        val timeout = LOOKUP_TIMEOUT_MILLIS
        val bootstrap = OkHttpClient.Builder()
            .connectTimeout(timeout, TimeUnit.MILLISECONDS)
            .readTimeout(timeout, TimeUnit.MILLISECONDS)
            .writeTimeout(timeout, TimeUnit.MILLISECONDS)
            .callTimeout(timeout, TimeUnit.MILLISECONDS)
            .build()
        DnsOverHttps.Builder()
            .client(bootstrap)
            .url(providers.getValue(provider).toHttpUrl())
            .build()
    }
}
