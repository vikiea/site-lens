package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaRequestContextRegistryTest {
    @Test
    fun onlyShortLivedCdnAndAuthorizationHeadersAreRetained() {
        val value = MediaRequestContextRegistry.record(
            hostId = 7,
            generation = 3,
            sourceUrl = "https://site.example/watch",
            mediaUrl = "https://cdn.example/index.m3u8",
            rawHeaders = mapOf(
                "Authorization" to "Bearer secret",
                "X-CDN-App" to "150",
                "Cookie" to "sid=private",
                "Host" to "cdn.example",
            ),
        )

        requireNotNull(value)
        assertEquals(
            mapOf("authorization" to "Bearer secret", "x-cdn-app" to "150"),
            value.headers,
        )
        assertEquals(value, MediaRequestContextRegistry.get(value.id))
        MediaRequestContextRegistry.clearHost(7)
        assertNull(MediaRequestContextRegistry.get(value.id))
    }
}
