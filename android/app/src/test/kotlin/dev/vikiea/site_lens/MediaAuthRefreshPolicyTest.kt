package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaAuthRefreshPolicyTest {
    // ---- main-playlist detection ------------------------------------------

    @Test fun hlsManifestByPathIsAMainPlaylist() {
        assertTrue(MediaAuthRefreshPolicy.isMainPlaylist("https://cdn.example/show/master.m3u8", null))
        assertTrue(MediaAuthRefreshPolicy.isMainPlaylist("https://cdn.example/show/variant.M3U8", null))
        assertTrue(MediaAuthRefreshPolicy.isMainPlaylist("https://cdn.example/show/list.m3u", null))
        assertTrue(
            MediaAuthRefreshPolicy.isMainPlaylist(
                "https://cdn.example/play?token=abc&format=123",
                "application/vnd.apple.mpegurl",
            ),
        )
    }

    @Test fun dashManifestByPathIsAMainPlaylist() {
        assertTrue(MediaAuthRefreshPolicy.isMainPlaylist("https://cdn.example/show/manifest.mpd", null))
        assertTrue(
            MediaAuthRefreshPolicy.isMainPlaylist(
                "https://cdn.example/play?id=7",
                "application/dash+xml",
            ),
        )
    }

    @Test fun acceptHeaderParametersDoNotHideTheManifestType() {
        assertTrue(
            MediaAuthRefreshPolicy.isMainPlaylist(
                "https://cdn.example/stream",
                "application/vnd.apple.mpegurl; charset=utf-8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isMainPlaylist(
                "https://cdn.example/stream",
                "text/plain, application/dash+xml;q=0.9",
            ),
        )
    }

    @Test fun transportArtefactsAreNeverMainPlaylists() {
        val rejected = listOf(
            "https://cdn.example/show/seg-000123.ts",
            "https://cdn.example/show/video/0/segment.m4s",
            "https://cdn.example/show/video/0/init.mp4",
            "https://cdn.example/show/init",
            "https://cdn.example/show/movie.mp4",
            "https://cdn.example/show/audio.m4a",
            "https://cdn.example/show/audio.aac",
            "https://cdn.example/show/audio.mp3",
            "https://cdn.example/show/audio.ogg",
            "https://cdn.example/show/audio.wav",
            "https://cdn.example/show/clip.webm",
            "https://cdn.example/show/clip.mov",
            "https://cdn.example/show/clip.mkv",
            "https://cdn.example/show/index.m4s",
        )
        rejected.forEach { url ->
            assertFalse(
                "must reject $url",
                MediaAuthRefreshPolicy.isMainPlaylist(url, null),
            )
        }
        // A media Accept header must not rescue a segment either.
        assertFalse(
            MediaAuthRefreshPolicy.isMainPlaylist(
                "https://cdn.example/show/seg-000123.ts",
                "video/mp2t",
            ),
        )
    }

    @Test fun nonManifestAcceptHeadersAreNotPlaylists() {
        assertFalse(
            MediaAuthRefreshPolicy.isMainPlaylist(
                "https://cdn.example/watch",
                "video/mp4; codecs=\"avc1.42E01E\"",
            ),
        )
        assertFalse(MediaAuthRefreshPolicy.isMainPlaylist("https://cdn.example/watch", ""))
        assertFalse(MediaAuthRefreshPolicy.isMainPlaylist("", null))
    }

    // ---- same-origin filtering ------------------------------------------

    @Test fun sameOriginAcceptsTheSessionDomain() {
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example",
                "https://site.example/api/playlist.m3u8",
            ),
        )
    }

    @Test fun thirdPartyDomainIsRejected() {
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example",
                "https://third-party-cdn.example/playlist.m3u8",
            ),
        )
    }

    @Test fun originComparisonIgnoresSchemeCaseHostCaseDefaultPortAndPath() {
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://Site.Example",
                "HTTPS://SITE.example/watch?id=1#t=0",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example:443",
                "https://site.example/playlist.m3u8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "http://site.example:80",
                "http://site.example/playlist.m3u8",
            ),
        )
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example",
                "http://site.example/playlist.m3u8",
            ),
        )
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example:8443",
                "https://site.example/playlist.m3u8",
            ),
        )
    }

    @Test fun embeddedCredentialsAndPortlessOriginsCanNeverMatch() {
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example",
                "https://user:secret@site.example/playlist.m3u8",
            ),
        )
        assertFalse(MediaAuthRefreshPolicy.isSameSessionOrigin("", "https://site.example/a.m3u8"))
        assertFalse(MediaAuthRefreshPolicy.isSameSessionOrigin("https://site.example", ""))
    }

    // ---- three-way outcome ----------------------------------------------

    @Test fun capturedSameOriginMainPlaylistWinsImmediately() {
        val outcome = MediaAuthRefreshPolicy.classify(
            capturedUrl = "https://site.example/master.m3u8",
            acceptHeader = null,
            pageOrigin = "https://site.example",
            cookieChanged = false,
            pageSettled = false,
        )
        assertEquals(
            MediaAuthRefreshPolicy.RefreshOutcome.Refreshed("https://site.example/master.m3u8"),
            outcome,
        )
    }

    @Test fun capturedThirdPartyOrTransportRequestDoesNotCountAsACapture() {
        val settledNoCookie = MediaAuthRefreshPolicy.classify(
            capturedUrl = "https://third-party-cdn.example/master.m3u8",
            acceptHeader = null,
            pageOrigin = "https://site.example",
            cookieChanged = false,
            pageSettled = true,
        )
        assertTrue(settledNoCookie is MediaAuthRefreshPolicy.RefreshOutcome.PageRequired)

        val settledCookie = MediaAuthRefreshPolicy.classify(
            capturedUrl = "https://site.example/seg-1.ts",
            acceptHeader = null,
            pageOrigin = "https://site.example",
            cookieChanged = true,
            pageSettled = true,
        )
        assertEquals(MediaAuthRefreshPolicy.RefreshOutcome.Unchanged, settledCookie)
    }

    @Test fun settledPageWithoutCaptureNorCookieChangeRequiresThePage() {
        val outcome = MediaAuthRefreshPolicy.classify(
            capturedUrl = null,
            acceptHeader = null,
            pageOrigin = "https://site.example",
            cookieChanged = false,
            pageSettled = true,
        )
        assertTrue(outcome is MediaAuthRefreshPolicy.RefreshOutcome.PageRequired)
        assertTrue((outcome as MediaAuthRefreshPolicy.RefreshOutcome.PageRequired).reason.isNotEmpty())
    }

    @Test fun cookieChangeWithoutCaptureIsUnchanged() {
        val outcome = MediaAuthRefreshPolicy.classify(
            capturedUrl = null,
            acceptHeader = null,
            pageOrigin = "https://site.example",
            cookieChanged = true,
            pageSettled = true,
        )
        assertEquals(MediaAuthRefreshPolicy.RefreshOutcome.Unchanged, outcome)
    }

    @Test fun unsettledPageWithoutCaptureKeepsWaiting() {
        assertNull(
            MediaAuthRefreshPolicy.classify(
                capturedUrl = null,
                acceptHeader = null,
                pageOrigin = "https://site.example",
                cookieChanged = false,
                pageSettled = false,
            ),
        )
        assertNull(
            MediaAuthRefreshPolicy.classify(
                capturedUrl = null,
                acceptHeader = null,
                pageOrigin = "https://site.example",
                cookieChanged = true,
                pageSettled = false,
            ),
        )
    }

    // ---- capture distribution -------------------------------------------

    private fun request(
        id: String,
        logicalIdentity: String,
        pageUrl: String = "https://site.example/watch?episode=$id",
        mediaUrl: String = "https://site.example/ep$id.m3u8",
    ) = MediaAuthRefreshPolicy.RefreshRequestIdentity(
        taskId = id,
        logicalIdentity = logicalIdentity,
        pageUrl = pageUrl,
        mediaUrl = mediaUrl,
    )

    @Test fun captureGoesOnlyToTheRequestWhoseLogicalIdentityMatches() {
        val requests = listOf(
            request("ep1", "show/episode-1"),
            request("ep2", "show/episode-2"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/episode-2/master.m3u8",
                logicalIdentity = "show/episode-2",
            ),
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/episode-1/master.m3u8",
                logicalIdentity = "show/episode-1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals("https://site.example/episode-1/master.m3u8", assigned["ep1"])
        assertEquals("https://site.example/episode-2/master.m3u8", assigned["ep2"])
        assertEquals(2, assigned.size)
    }

    @Test fun requestWithNoMatchingCaptureIsAbsentFromTheAssignment() {
        val requests = listOf(
            request("ep1", "show/episode-1"),
            request("ep9", "show/episode-9"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/episode-1/master.m3u8",
                logicalIdentity = "show/episode-1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals(mapOf("ep1" to "https://site.example/episode-1/master.m3u8"), assigned)
        assertFalse(assigned.containsKey("ep9"))
    }

    @Test fun oneCaptureIsNeverHandedToTwoTasksAndCapturesAreCaseInsensitive() {
        val requests = listOf(
            request("a", "show/episode-1"),
            request("b", "show/episode-1"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/episode-1/master.m3u8",
                logicalIdentity = "Show/Episode-1",
            ),
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/episode-1/backup.m3u8",
                logicalIdentity = "show/episode-1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals("https://site.example/episode-1/master.m3u8", assigned["a"])
        assertEquals("https://site.example/episode-1/backup.m3u8", assigned["b"])
    }

    @Test fun captureFromAnotherOriginNeverSatisfiesARequest() {
        val requests = listOf(
            request("ep1", "show/episode-1", pageUrl = "https://site.example/watch?episode=1"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://third-party-cdn.example/episode-1/master.m3u8",
                logicalIdentity = "show/episode-1",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    @Test fun blankLogicalIdentityNeverMatches() {
        val requests = listOf(request("legacy", ""))
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/any.m3u8",
                logicalIdentity = "",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    // ---- same-origin batching -------------------------------------------

    @Test fun sameOriginRequestsShareOnePageLoadAndNavigateOncePerPageUrl() {
        val requests = listOf(
            request("ep1", "show/episode-1", pageUrl = "https://site.example/series"),
            request("ep2", "show/episode-2", pageUrl = "https://site.example/series"),
            request("ep3", "show/episode-3", pageUrl = "https://site.example/series?page=2"),
            request("other", "show/episode-4", pageUrl = "https://other.example/series"),
        )

        val groups = MediaAuthRefreshPolicy.groupByOrigin(requests)

        assertEquals(2, groups.size)
        assertEquals(listOf("ep1", "ep2", "ep3"), groups.first().map { it.taskId })
        assertEquals(listOf("other"), groups.last().map { it.taskId })
        assertEquals(
            listOf("https://site.example/series", "https://site.example/series?page=2"),
            MediaAuthRefreshPolicy.distinctPageUrls(groups.first()),
        )
    }

    @Test fun defaultPortsAndHostCaseDoNotSplitOneOrigin() {
        val requests = listOf(
            request("a", "show/a", pageUrl = "https://Site.Example/watch"),
            request("b", "show/b", pageUrl = "https://site.example:443/watch"),
        )

        val groups = MediaAuthRefreshPolicy.groupByOrigin(requests)

        assertEquals(1, groups.size)
        assertEquals(listOf("https://Site.Example/watch"), MediaAuthRefreshPolicy.distinctPageUrls(groups.single()))
    }

    @Test fun invalidPageUrlsAreExcludedFromBatching() {
        val requests = listOf(
            request("ok", "show/a", pageUrl = "https://site.example/watch"),
            request("bad", "show/b", pageUrl = "not a url"),
        )

        val groups = MediaAuthRefreshPolicy.groupByOrigin(requests)

        assertEquals(1, groups.size)
        assertEquals(listOf("ok"), groups.single().map { it.taskId })
        assertTrue(MediaAuthRefreshPolicy.groupByOrigin(listOf(requests.last())).isEmpty())
    }
}
