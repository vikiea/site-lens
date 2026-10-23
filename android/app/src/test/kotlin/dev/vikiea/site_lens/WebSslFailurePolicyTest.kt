package dev.vikiea.site_lens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebSslFailurePolicyTest {
    private val page = "https://site.example/watch?episode=2"

    private fun affects(errorUrl: String?, documents: List<String?>): Boolean {
        val policy = WebSslFailurePolicy()
        policy.navigate(documents.firstOrNull())
        documents.drop(1).forEach(policy::redirected)
        return policy.affectsDocument(errorUrl)
    }

    @Test fun delayedFailureOfRetiredDocumentDoesNotRevokeNewNavigation() {
        val policy = WebSslFailurePolicy()
        policy.navigate("https://first.example/watch")
        policy.redirected("https://first-cdn.example/watch")
        policy.navigate("https://second.example/watch")
        assertFalse(policy.affectsDocument("https://first.example/watch"))
        assertFalse(policy.affectsDocument("https://first-cdn.example/watch"))
        assertTrue(policy.affectsDocument("https://second.example/watch"))
    }

    @Test fun currentNavigationTargetCoversRedirectBeforeRedirectCallback() {
        val policy = WebSslFailurePolicy()
        policy.navigate(page)
        assertTrue(policy.affectsDocument("https://redirect.example/watch", "https://redirect.example/watch"))
        assertFalse(policy.affectsDocument("https://tracker.example/event", "https://redirect.example/watch"))
        policy.redirected("https://redirect.example/watch")
        assertTrue(policy.affectsDocument("https://redirect.example/watch"))
    }

    @Test fun lateMainFrameErrorsDoNotCancelPreparingOrStartedDocument() {
        val policy = WebSslFailurePolicy()
        val old = "https://site.example/watch?episode=1"
        val next = "https://site.example/watch?episode=2"
        policy.navigate(old)
        policy.navigate(next)

        // WebResourceRequest has a main-frame bit, but no navigation ID.
        // Both onReceivedError and onReceivedHttpError must use the full
        // document identity even while the new policy reply is pending.
        assertFalse(policy.affectsDocument(old))
        assertTrue(policy.affectsDocument(next))
        assertFalse(policy.affectsDocument(old, next))
        assertTrue(policy.affectsDocument(next, next))
    }

    @Test fun currentRedirectTargetStillReportsMainFrameFailures() {
        val policy = WebSslFailurePolicy()
        val entry = "https://site.example/entry"
        val landed = "https://landing.example/watch?episode=2"
        policy.navigate(entry)
        policy.redirected(landed)

        assertTrue(policy.affectsDocument(entry, landed))
        assertTrue(policy.affectsDocument(landed, landed))
        assertFalse(policy.affectsDocument("https://retired.example/watch", landed))
    }

    @Test fun trackerFailureDoesNotInvalidateMainDocument() {
        assertFalse(affects(
            "https://tracker.example/eventTracking/batchReport.json", listOf(page),
        ))
    }

    @Test fun sameOriginSubresourceStillDoesNotInvalidateDocument() {
        assertFalse(affects(
            "https://site.example/image.jpg", listOf(page),
        ))
        assertFalse(affects(
            "https://site.example/watch?episode=1", listOf(page),
        ))
    }

    @Test fun mainDocumentAndRedirectCertificateFailuresRemainFatal() {
        assertTrue(affects(page, listOf(page)))
        assertTrue(affects(
            "https://redirect.example/watch", listOf(page, "https://redirect.example/watch"),
        ))
    }

    @Test fun normalizeOnlyHostDefaultPortEmptyPathAndFragment() {
        assertTrue(affects(
            "https://SITE.example:443/#part", listOf("https://site.example"),
        ))
        assertFalse(affects(
            "https://site.example/a%2Fb", listOf("https://site.example/a/b"),
        ))
    }

    @Test fun unknownDocumentOrFailedIdentityIsConservative() {
        assertTrue(affects(page, listOf(null, "about:blank")))
        assertTrue(affects(null, listOf(page)))
        assertTrue(affects("invalid url", listOf(page)))
        assertTrue(affects("https://user:secret@site.example/", listOf(page)))
    }
}
