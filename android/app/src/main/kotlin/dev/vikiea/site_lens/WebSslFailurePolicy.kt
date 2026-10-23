package dev.vikiea.site_lens

import java.net.URI

/** Classification only: the caller must cancel every SSL error, regardless of scope. */
class WebSslFailurePolicy {
    private val documents = linkedSetOf<List<Any>>()

    /** App preparation retires the previous document before WebView callbacks. */
    fun navigate(url: String?) {
        documents.clear()
        identity(url)?.let(documents::add)
    }

    fun redirected(url: String?) {
        identity(url)?.let(documents::add)
    }
    /**
     * SslError has no isForMainFrame flag. Match full document identities,
     * including an in-flight redirect, rather than treating an unrelated
     * tracker/image/iframe failure as a certificate failure of the whole tab.
     * Missing identities remain conservative. Never use this to proceed().
     */
    fun affectsDocument(errorUrl: String?, navigationUrl: String? = null): Boolean {
        val failed = identity(errorUrl) ?: return true
        val current = identity(navigationUrl)
        return documents.isEmpty() && current == null || failed in documents || failed == current
    }

    private fun identity(value: String?): List<Any>? = runCatching {
        val uri = URI(value ?: return null)
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme !in setOf("http", "https") || uri.userInfo != null) return null
        val host = uri.host?.lowercase() ?: return null
        listOf(scheme, host, uri.port.takeIf { it >= 0 } ?: if (scheme == "https") 443 else 80,
            uri.rawPath?.takeIf { it.isNotEmpty() } ?: "/", uri.rawQuery ?: "")
    }.getOrNull()
}
