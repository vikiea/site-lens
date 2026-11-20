package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example",
                "https://notsite.example/playlist.m3u8",
            ),
        )
    }

    @Test fun aCdnHostOfTheSameSiteIsTheSessionsDomain() {
        // Real pages serve their manifest from another host of their own site;
        // requiring an identical origin would make those playlists
        // uncapturable.
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://www.site.example/watch/1",
                "https://cdn.site.example/show/master.m3u8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example/watch/1",
                "https://cdn.site.example/show/master.m3u8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://my.example.co.uk/watch/1",
                "https://cdn.example.co.uk/show/master.m3u8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://cdn.site.example:8443/a",
                "https://site.example/b.m3u8",
            ),
        )
    }

    @Test fun aSiblingHostOfABareTwoLabelDomainIsNotTheSameSite() {
        // `site.example` has two labels, so `cdn.example` is a *different*
        // registrable site; only the host itself may match.
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example/watch/1",
                "https://cdn.example/show/master.m3u8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example/watch/1",
                "https://site.example/show/master.m3u8",
            ),
        )
    }

    @Test fun bareIntranetHostsOnlyMatchThemselves() {
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "http://media-box:8080/watch",
                "http://other-box:8080/show.m3u8",
            ),
        )
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "http://media-box:8080/watch",
                "http://media-box:9000/show.m3u8",
            ),
        )
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "http://localhost:8080/watch",
                "http://localhost.example/show.m3u8",
            ),
        )
    }

    @Test fun aPublicSuffixIsNeverItsOwnSite() {
        // `one.co.uk` and `two.co.uk` are unrelated sites whose last two labels
        // coincide: the suffix is not the site.
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://one.co.uk/a",
                "https://two.co.uk/b.m3u8",
            ),
        )
        // `shop.example.co.uk` and `other.example.co.uk` *are* one site —
        // `example.co.uk` — which is the point of not stopping at two labels.
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://shop.example.co.uk/a",
                "https://other.example.co.uk/b.m3u8",
            ),
        )
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://example.co.uk/a",
                "https://other.co.uk/b.m3u8",
            ),
        )
    }

    @Test fun siteComparisonIgnoresHostCaseSchemePortPathAndQuery() {
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
        // The site is the host; a different scheme or port on that host is the
        // same site, and a different host is not.
        assertTrue(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example",
                "http://site.example:8443/playlist.m3u8",
            ),
        )
        assertFalse(
            MediaAuthRefreshPolicy.isSameSessionOrigin(
                "https://site.example:8443",
                "https://site.example.evil/playlist.m3u8",
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

    @Test fun aManifestOnAnotherHostIsStillThePagesOwnAddress() {
        // The HLS host is reached after the page's own multi-hop resolution and
        // usually shares no registrable domain with it.
        val outcome = MediaAuthRefreshPolicy.classify(
            capturedUrl = "https://yd-lphu-hls.tjyyjk.cn/hls/19140/playlist.m3u8",
            acceptHeader = null,
            pageOrigin = "https://site.example",
            cookieChanged = false,
            pageSettled = true,
        )
        assertEquals(
            MediaAuthRefreshPolicy.RefreshOutcome.Refreshed(
                "https://yd-lphu-hls.tjyyjk.cn/hls/19140/playlist.m3u8",
            ),
            outcome,
        )
    }

    @Test fun transportRequestsAreNotCaptures() {

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
        pageUrl: String = "https://site.example/watch?episode=" + id,
        mediaUrl: String = "https://site.example/" + id + ".m3u8",
    ) = MediaAuthRefreshPolicy.RefreshRequestIdentity(
        taskId = id,
        logicalIdentity = logicalIdentity,
        pageUrl = pageUrl,
        mediaUrl = mediaUrl,
    )

    @Test fun captureGoesToTheRequestWhoseMediaAddressItReplaces() {
        val requests = listOf(
            request("ep1", "show/episode-1"),
            request("ep2", "show/episode-2"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep2.m3u8",
                pageUrl = "https://site.example/watch?episode=ep2",
            ),
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep1.m3u8",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals("https://site.example/ep1.m3u8", assigned["ep1"])
        assertEquals("https://site.example/ep2.m3u8", assigned["ep2"])
        assertEquals(2, assigned.size)
    }

    @Test fun requestWithNoMatchingCaptureIsAbsentFromTheAssignment() {
        val requests = listOf(
            request("ep1", "show/episode-1"),
            request("ep9", "show/episode-9"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep1.m3u8",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals(mapOf("ep1" to "https://site.example/ep1.m3u8"), assigned)
        assertFalse(assigned.containsKey("ep9"))
    }

    @Test fun oneCaptureIsNeverHandedToTwoTasks() {
        val requests = listOf(
            request("a", "show/episode-1"),
            request("b", "show/episode-1"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep1.m3u8",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        // Two tasks claim the same address and no identity distinguishes them,
        // so neither gets it: a guess here would bind one task to the other's
        // media.
        assertTrue(assigned.isEmpty())
    }

    @Test fun captureOnAnUnrelatedHostStillReachesItsOwner() {
        // A play address is resolved by the page through several hops and
        // routinely lives on another registrable domain, so the capture's host
        // says nothing about ownership; the address is what both sides know.
        val requests = listOf(
            request(
                "ep1",
                "show/episode-1",
                pageUrl = "https://site.example/watch?episode=1",
                mediaUrl = "https://yd-lphu-hls.tjyyjk.cn/hls/19140/playlist.m3u8?sign=STALE",
            ),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://yd-lphu-hls.tjyyjk.cn/hls/19140/playlist.m3u8?sign=FRESH",
                pageUrl = "https://site.example/watch?episode=1",
            ),
        )

        assertEquals(
            mapOf(
                "ep1" to
                    "https://yd-lphu-hls.tjyyjk.cn/hls/19140/playlist.m3u8?sign=FRESH",
            ),
            MediaAuthRefreshPolicy.assignCapture(captured, requests),
        )
    }

    @Test fun aCaptureOnAnotherPathIsNotTheRequestsOwnAddress() {
        val requests = listOf(request("ep1", "show/episode-1"))
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/other-show/episode.m3u8",
                pageUrl = "https://site.example/watch?episode=1",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    @Test fun thePagesOwnSpellingOfItsAddressStillOwnsTheCapture() {
        // The page decides where its manifest lives: the recorded address sat
        // in one subdirectory of the episode, the refreshed load serves it from
        // another. Both are the same episode, so the task keeps ownership.
        val requests = listOf(
            request(
                "ep2",
                "show/episode-2",
                mediaUrl = "https://site.example/11987/ep-2/index.m3u8",
            ),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/11987/ep-2/index.m3u8?v=2",
                pageUrl = "https://site.example/video/11987/ep-2/",
            ),
        )

        assertEquals(
            mapOf("ep2" to "https://site.example/11987/ep-2/index.m3u8?v=2"),
            MediaAuthRefreshPolicy.assignCapture(captured, requests),
        )
    }

    @Test fun theSameManifestOnAnotherHostIsNotTheRequestsOwnAddress() {
        // Different host means different resource: a same-path deck on another
        // origin is never adopted, even when the path looks familiar.
        val requests = listOf(
            request(
                "ep2",
                "show/episode-2",
                mediaUrl = "http://page.example/media/553877/1/index.m3u8",
            ),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://other.example/media/553877/1/index.m3u8?token=FRESH",
                pageUrl = "http://page.example/video/553877/1",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    @Test fun aSiblingEpisodeIsNeverClaimedByAPathExtension() {
        val requests = listOf(
            request(
                "ep2",
                "show/episode-2",
                mediaUrl = "https://site.example/11987/ep-2/index.m3u8",
            ),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/11987/ep-20/master.m3u8",
                pageUrl = "https://site.example/video/11987/ep-20/",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    @Test fun blankLogicalIdentityDoesNotStopTheAddressFromOwningTheCapture() {
        val requests = listOf(
            request("ep1", "show/episode-1"),
            request("legacy", ""),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep1.m3u8",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals(mapOf("ep1" to "https://site.example/ep1.m3u8"), assigned)
    }

    @Test fun aTransportArtefactIsNeverAssignedEvenWhenItIsThePagesOwnRequest() {
        val requests = listOf(request("ep1", "show/episode-1"))
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/seg-0001.ts",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    @Test fun aSignatureRefreshKeepsTheOwnersTaskAndDropsTheStaleQuery() {
        val requests = listOf(
            request(
                id = "ep1",
                logicalIdentity = "show/episode-1",
                mediaUrl = "https://site.example/ep1.m3u8?token=STALE",
            ),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep1.m3u8?token=FRESH",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        val assigned = MediaAuthRefreshPolicy.assignCapture(captured, requests)

        assertEquals(
            "https://site.example/ep1.m3u8?token=FRESH",
            assigned["ep1"],
        )
    }

    @Test fun aPlaylistOnAnotherPathIsNeverTheRequestsOwnAddress() {
        val requests = listOf(
            request("ep1", "show/episode-1", mediaUrl = "https://site.example/ep1.m3u8"),
        )
        val captured = listOf(
            MediaAuthRefreshPolicy.CapturedPlaylist(
                url = "https://site.example/ep2.m3u8",
                pageUrl = "https://site.example/watch?episode=ep1",
            ),
        )

        assertTrue(MediaAuthRefreshPolicy.assignCapture(captured, requests).isEmpty())
    }

    /**
     * The batch path, exactly as the service runs it.
     *
     * `refreshBatch` asks each page origin once under its own probe identity
     * (`refresh:<pageUrl>`), records the capture against that page, and hands
     * everything to [MediaAuthRefreshPolicy.finishBatch]. The capture must
     * still reach the task whose resource it is — the defect this test exists
     * for was a capture that matched no task at all, because the only identity
     * it carried was the probe.
     */
    @Test fun aBatchCaptureReachesItsOwnerThroughTheServicesOwnProbeIdentity() {
        val page = "https://site.example/watch"
        val requests = listOf(
            request("ep1", "show/episode-1", pageUrl = page, mediaUrl = "https://site.example/ep1.m3u8"),
            request("ep2", "show/episode-2", pageUrl = page, mediaUrl = "https://site.example/ep2.m3u8"),
        )
        val probe = NativeMediaAuthRefreshService.probeIdentity(page)

        // The probe names no task, which is the whole point of it.
        assertFalse(probe == "show/episode-1")
        assertFalse(probe == "show/episode-2")

        val finished = MediaAuthRefreshPolicy.finishBatch(
            requests = requests,
            captured = listOf(
                MediaAuthRefreshPolicy.CapturedPlaylist(
                    url = "https://site.example/ep2.m3u8?token=FRESH",
                    pageUrl = page,
                ),
            ),
            cookieChanged = false,
        )

        assertEquals("refreshed", finished.getValue("ep2").state)
        assertEquals(
            "https://site.example/ep2.m3u8?token=FRESH",
            finished.getValue("ep2").mediaUrl,
        )
        // The other member of the same page load is answered, not guessed at.
        assertEquals("reauthorize", finished.getValue("ep1").state)
        assertNull(finished.getValue("ep1").mediaUrl)
    }

    @Test fun aBatchCaptureOnACdnHostStillReachesItsOwner() {
        val page = "https://site.example/series"
        val requests = listOf(
            request(
                "ep1",
                "show/episode-1",
                pageUrl = page,
                mediaUrl = "https://cdn.site.example/ep1/master.m3u8?token=STALE",
            ),
        )

        val finished = MediaAuthRefreshPolicy.finishBatch(
            requests = requests,
            captured = listOf(
                MediaAuthRefreshPolicy.CapturedPlaylist(
                    url = "https://cdn.site.example/ep1/master.m3u8?token=FRESH",
                    pageUrl = page,
                ),
            ),
            cookieChanged = false,
        )

        assertEquals("refreshed", finished.getValue("ep1").state)
        assertEquals(
            "https://cdn.site.example/ep1/master.m3u8?token=FRESH",
            finished.getValue("ep1").mediaUrl,
        )
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

    // ---- signed-query diagnostic -----------------------------------------

    @Test fun presentationOnlyQueryKeysAreNotUnknown() {
        // The 28-key allowlist moved out of the service unchanged: none of
        // these spellings may be read as a signed authorization parameter.
        val allowed = listOf(
            "quality=1080", "audio=aac", "format=hls", "type=m3u8", "profile=main",
            "resolution=1920x1080", "codec=avc1", "lang=zh", "language=zh-CN",
            "track=1", "channel=2", "bitrate=3000", "width=1920", "height=1080",
            "fps=25", "variant=hd", "version=3", "v=7", "source=web",
            "episode=12", "season=2", "start=0", "offset=10", "range=0-99",
            "download=1", "filename=ep12", "container=mp4", "Quality=1080",
        ).joinToString("&")
        assertFalse(MediaAuthRefreshPolicy.hasUnknownQuery("https://cdn.example/a.m3u8?$allowed"))
    }

    @Test fun signatureBearingQueryKeysAreUnknownAndNeverBlockAnything() {
        // A signed address is *classified*, not rejected: the caller keeps
        // loading the page and only attaches this as a diagnostic.
        assertTrue(
            MediaAuthRefreshPolicy.hasUnknownQuery(
                "https://cdn.example/a.m3u8?token=abc&expires=1700000000",
            ),
        )
        assertTrue(MediaAuthRefreshPolicy.hasUnknownQuery("https://cdn.example/a.m3u8?sign=x"))
        assertTrue(
            MediaAuthRefreshPolicy.hasUnknownQuery("https://cdn.example/a.m3u8?quality=hd&sig=x"),
        )
        assertFalse(MediaAuthRefreshPolicy.hasUnknownQuery("https://cdn.example/a.m3u8"))
        assertFalse(MediaAuthRefreshPolicy.hasUnknownQuery("https://cdn.example/a.m3u8?q=%"))
    }

    // ---- capture url hygiene ---------------------------------------------

    @Test fun capturedAddressIsSanitizedIntoASchemeHostPathDigest() {
        // A URL carries a signed query; the digest must keep the scheme, host
        // and a *hashed* path, and must not reproduce any of those secrets.
        val digest = MediaAuthRefreshPolicy.captureDigest(
            "https://cdn.example/secret/show/master.m3u8?token=abcd1234&expires=99",
        )!!
        assertTrue(digest.startsWith("https://cdn.example/"))
        assertFalse(digest.contains("token"))
        assertFalse(digest.contains("abcd1234"))
        assertFalse(digest.contains("master.m3u8"))
        assertFalse(digest.contains("secret/show"))
        assertEquals(
            digest,
            MediaAuthRefreshPolicy.captureDigest(
                "https://cdn.example/secret/show/master.m3u8?token=OTHER&expires=100",
            ),
        )
        assertEquals(
            MediaAuthRefreshPolicy.captureDigest(
                "https://cdn.example/secret/show/master.m3u8?token=aaaa",
            ),
            MediaAuthRefreshPolicy.captureDigest(
                "https://cdn.example/secret/show/master.m3u8?token=bbbb",
            ),
        )
    }

    // ---- batch close-out --------------------------------------------------

    @Test fun anUnansweredOriginSettlesAsPageRequiredInsteadOfBorrowingAnotherUrl() {
        val requests = listOf(
            request("ep1", "show/episode-1"),
            request("ep9", "show/episode-9"),
        )
        val finished = MediaAuthRefreshPolicy.finishBatch(
            requests = requests,
            captured = listOf(
                MediaAuthRefreshPolicy.CapturedPlaylist(
                    url = "https://site.example/ep1.m3u8",
                    pageUrl = "https://site.example/watch?episode=ep1",
                ),
            ),
            cookieChanged = true,
        )

        assertEquals("refreshed", finished.getValue("ep1").state)
        assertEquals("https://site.example/ep1.m3u8", finished.getValue("ep1").mediaUrl)
        assertEquals("unchanged", finished.getValue("ep9").state)
        assertEquals(null, finished.getValue("ep9").mediaUrl)
        assertEquals("unchanged", finished.getValue("ep9").reason)
    }

    @Test fun aSettledBatchWithoutCookieChangeRequiresThePageForUnansweredTasks() {
        val requests = listOf(request("ep9", "show/episode-9"))

        val finished = MediaAuthRefreshPolicy.finishBatch(
            requests = requests,
            captured = emptyList(),
            cookieChanged = false,
        )

        assertEquals("reauthorize", finished.getValue("ep9").state)
        assertEquals(MediaAuthRefreshPolicy.PAGE_REQUIRED_REASON, finished.getValue("ep9").reason)
        assertEquals(null, finished.getValue("ep9").mediaUrl)
    }

    @Test fun unparseableAddressNeverBecomesADigest() {
        assertEquals(null, MediaAuthRefreshPolicy.captureDigest(""))
        assertEquals(null, MediaAuthRefreshPolicy.captureDigest("not a url"))
        assertEquals(
            null,
            MediaAuthRefreshPolicy.captureDigest("https://user:pw@cdn.example/a.m3u8"),
        )
        val distinct = MediaAuthRefreshPolicy.captureDigest("https://cdn.example/a/show.m3u8")
        assertFalse(
            distinct == MediaAuthRefreshPolicy.captureDigest("https://cdn.example/b/show.m3u8"),
        )
    }

    // ---- narrowed refresh cache ------------------------------------------

    @Test fun theRefreshCacheIsKeyedByTheTaskAndItsPage() {
        // A second retry may only see the answer for the task that asked: the
        // key separates tasks on one page and separates pages of one task.
        val first = NativeMediaAuthRefreshService.Request(
            taskId = "ep1",
            pageUrl = "https://site.example/watch?episode=1",
            mediaUrl = "https://site.example/ep1.m3u8",
            resourceKey = "",
            logicalIdentity = "show/episode-1",
            callback = { _ -> },
        )
        val second = first.copy(taskId = "ep2", logicalIdentity = "show/episode-2")
        val otherPage = first.copy(
            pageUrl = "https://site.example/watch?episode=2",
        )

        assertNotEquals(
            NativeMediaAuthRefreshService.recentRefreshKey(first),
            NativeMediaAuthRefreshService.recentRefreshKey(second),
        )
        assertNotEquals(
            NativeMediaAuthRefreshService.recentRefreshKey(first),
            NativeMediaAuthRefreshService.recentRefreshKey(otherPage),
        )
        val reloaded = first.copy(
            taskId = "ep1-reload",
            mediaUrl = "https://site.example/other.m3u8",
        )
        assertEquals(
            "the key is the logical identity and the page, not the task row or the address",
            NativeMediaAuthRefreshService.recentRefreshKey(first),
            NativeMediaAuthRefreshService.recentRefreshKey(reloaded),
        )
    }

    @Test fun aBatchProbeIdentityIsNeverAReplayableCapture() {
        // The batch asks the page under a probe identity; a probe has no task to
        // hand anything to, so its cached answer can never become a task's
        // `unchanged` or `refreshed` without looking again.
        assertEquals(
            "refresh:https://site.example/watch",
            NativeMediaAuthRefreshService.probeIdentity(" https://site.example/watch "),
        )
        assertTrue(
            NativeMediaAuthRefreshService.probeIdentity("https://site.example/watch")
                .startsWith(NativeMediaAuthRefreshService.PROBE_IDENTITY_PREFIX),
        )
        assertFalse(
            "show/episode-1".startsWith(NativeMediaAuthRefreshService.PROBE_IDENTITY_PREFIX),
        )
    }
}
