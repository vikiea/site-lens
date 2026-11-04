package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeUpdatePolicyTest {
    @Test fun acceptsTheSiteLensReleaseAssetAndKnownRedirectHosts() {
        val initial = NativeUpdatePolicy.initialUrl(
            "https://github.com/vikiea/site-lens/releases/download/v0.6.0.alpha21/site-lens-v0.6.0.alpha21.apk",
            "v0.6.0.alpha21",
            "site-lens-v0.6.0.alpha21.apk",
        )
        assertEquals("github.com", initial.host)
        assertEquals(
            "release-assets.githubusercontent.com",
            NativeUpdatePolicy.redirectUrl(
                "https://release-assets.githubusercontent.com/site-lens.apk",
            ).host,
        )
        assertEquals(
            "objects.githubusercontent.com",
            NativeUpdatePolicy.redirectUrl(
                "https://objects.githubusercontent.com/site-lens.apk",
            ).host,
        )
    }

    @Test fun rejectsUntrustedRedirectsQueriesAndCredentials() {
        assertThrows(IllegalArgumentException::class.java) {
            NativeUpdatePolicy.redirectUrl("https://example.com/site-lens.apk")
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeUpdatePolicy.initialUrl(
                "https://github.com/vikiea/site-lens/releases/download/v0.6.0.alpha21/site-lens-v0.6.0.alpha21.apk?token=secret",
                "v0.6.0.alpha21",
                "site-lens-v0.6.0.alpha21.apk",
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeUpdatePolicy.redirectUrl("https://user:pass@github.com/site-lens.apk")
        }
    }

    @Test fun parsesOnlyCompleteContentRanges() {
        val range = NativeUpdatePolicy.parseContentRange("bytes 12-99/100")
        assertTrue(range != null)
        assertEquals(12L, range!!.start)
        assertEquals(99L, range.end)
        assertEquals(100L, range.total)
        assertEquals(null, NativeUpdatePolicy.parseContentRange("bytes 12-99/*"))
        assertEquals(null, NativeUpdatePolicy.parseContentRange("bytes 99-12/100"))
    }
}
