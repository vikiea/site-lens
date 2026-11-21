package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T6：远程播放**真的带上凭证**，并且过期能自愈。
 *
 * - 主清单与分片各自在请求时取头（[SiteCredentialDataSource] 每次 `open` 问一次）。
 * - 401/403 是凭证失效，处置是有界的一次：续期、重推、原生重试一次。
 * - 一次续期失败落到「需要重新登录」，不进入无限重试。
 * - 没有凭证的公开内容照常播放，本地文件路径完全不走这里。
 */
class CredentialedPlaybackAdmissionTest {
    private val profileId = 7
    private val station = "https://cdn.example.test"

    private fun held(token: String = "access", expiry: Long? = null) =
        SiteCredentialRecord(
            profileId = profileId,
            accountId = SiteCredentialRecord.DEFAULT_ACCOUNT_ID,
            station = station,
            accessToken = token,
            refreshToken = "refresh",
            cookies = linkedMapOf("sid" to "c"),
            installationStamp = null,
            expiresAtEpochMs = expiry,
        )

    private fun channel(token: String = "access", expiry: Long? = null, now: Long = 1L): SiteCredentialChannel {
        val shelf = SiteCredentialRecord.Shelf()
        shelf.store(held(token, expiry))
        return SiteCredentialChannel(shelf = shelf, clock = { now })
    }

    @Test fun theManifestAndItsFragmentsBothCarryTheTokenAndTheCookie() {
        val source = channel()
        for (url in listOf(
            "$station/hls/master.m3u8",
            "$station/hls/variant/index.m3u8",
            "$station/hls/seg-00001.ts",
            "$station/hls/seg-00002.m4s",
        )) {
            val headers = SiteCredentialSources.headers(source, profileId, url)
            assertEquals("Bearer access", headers[SiteCredentialRecord.HEADER_AUTHORIZATION])
            assertEquals("sid=c", headers[SiteCredentialRecord.HEADER_COOKIE])
        }
    }

    @Test fun anExpiredCopyIsTreatedAsNoCredentialSoPublicContentStillPlays() {
        val expired = channel(expiry = 5L, now = 5L)
        assertEquals(emptyMap<String, String>(), SiteCredentialSources.headers(expired, profileId, "$station/a.ts"))
        // 准入仍放行：没有凭证不是「不能播」，只是不带头。
        assertEquals(
            NativeMediaSessionRoute.Family.REMOTE,
            NativeMediaSessionRoute.classify("$station/a.m3u8", hasCredential = false).family,
        )
    }

    @Test fun publicContentWithoutAnyCredentialKeepsItsRemoteRoute() {
        val empty = SiteCredentialRecord.Shelf()
        val admission = NativeMediaSessionRoute.admit("$station/public.m3u8", empty, profileId)
        assertEquals(NativeMediaSessionRoute.Family.REMOTE, admission.route.family)
        assertEquals(emptyMap<String, String>(), admission.headers)
        assertFalse(admission.route.holdsFileLease)
    }

    @Test fun localFilesNeverTouchCredentialsEvenWhenTheProfileHasThem() {
        val route = NativeMediaSessionRoute.of(
            NativeMediaSessionRoute.Scheme.FILE,
            playableLocalFile = true,
            hasCredential = true,
        )
        assertEquals(NativeMediaSessionRoute.Family.LOCAL, route.family)
        assertEquals(
            NativeMediaSessionRoute.SourceKind.LOCAL_GROWING_FILE,
            route.sourceOf(isHls = true),
        )
        assertEquals(
            NativeMediaSessionRoute.SourceKind.LOCAL_DEFAULT,
            route.sourceOf(isHls = false),
        )
        // 本地路径不经过凭证数据来源：远程的两个来源才有凭证注入。
        assertTrue(route.holdsFileLease)
    }

    @Test fun aRejectionAsksTheApplicationOnceAndTheNextOneIsTerminal() {
        val state = SiteCredentialFailurePolicy.State()
        state.bindProfile(profileId)
        val first = state.nextAttempt("native_7")
        // 这一段会话的第一次失效：原生回传「可以重试」，应用续期一次。
        assertEquals(1, first)
        assertTrue(SiteCredentialFailurePolicy.mayRetry(first))
        assertEquals(
            false,
            SiteCredentialFailurePolicy.eventFor(401, "native_7", profileId, first)["terminal"],
        )
        // 续期成功、凭证重推之后，原生只重试一次：这一次失败就是终局结论。
        state.onCredentialPushed("native_7")
        val second = state.nextAttempt("native_7")
        assertEquals(1, second)
        assertFalse(state.mayAskApplication("native_7"))
        val terminal = SiteCredentialFailurePolicy.eventFor(403, "native_7", profileId, attempt = 2)
        assertEquals(true, terminal["terminal"])
        // 终局事件不再让原生重试：一次刷新、一次重推、最多两次拒绝，到此为止。
        assertFalse(SiteCredentialFailurePolicy.mayRetry(2))
    }

    @Test fun aNewSessionStartsAFreshBudget() {
        val state = SiteCredentialFailurePolicy.State()
        state.nextAttempt("native_7")
        state.nextAttempt("native_7")
        // 换一集（新会话）重新开始，而不是继续耗尽上一集的名额。
        assertEquals(1, state.nextAttempt("native_8"))
        assertTrue(SiteCredentialFailurePolicy.mayRetry(1))
    }

    @Test fun onlyHttpRejectionsCountNotNetworkOrContentFailures() {
        assertTrue(SiteCredentialFailurePolicy.forHttpStatus(401).isCredentialRejection)
        assertTrue(SiteCredentialFailurePolicy.forHttpStatus(403).isCredentialRejection)
        for (code in listOf(404, 408, 429, 500, 503)) {
            assertFalse(SiteCredentialFailurePolicy.forHttpStatus(code).isCredentialRejection)
        }
        assertFalse(SiteCredentialFailurePolicy.networkFailure().shouldAskApplication)
    }
}
