package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T6：**分片与 CDN 请求也带凭证**，不只是主清单。
 *
 * 站点常把清单放在一个域、把分片放在另一个域（CDN），而只认 cookie 的往往是
 * 分片那一侧。凭证注入必须在**每一次请求前**重新取：会话中途续期、清单中途换
 * 域名、重定向到 CDN，都不能沿用主清单那一次的头。
 *
 * 这里用假的凭证副本（[FakeShelf]）代替 `org.json` 解析：本机 `android.jar`
 * 里的 `org.json` 是 Android 桩，JVM 上跑不了；`SiteCredentialRecord` 的解析
 * 另有自己的测试。
 */
class SiteCredentialFragmentAdmissionTest {
    private val profileId = 7
    private val station = "https://cdn.example.test"

    private fun credential(token: String, expiry: Long? = null) = SiteCredentialRecord(
        profileId = profileId,
        accountId = SiteCredentialRecord.DEFAULT_ACCOUNT_ID,
        station = station,
        accessToken = token,
        refreshToken = "refresh",
        cookies = linkedMapOf("sid" to "c", "uid" to "u"),
        installationStamp = null,
        expiresAtEpochMs = expiry,
    )

    private fun shelf(token: String = "access", expiry: Long? = null) =
        FakeShelf().also { it.store(credential(token, expiry)) }

    private fun channel(shelf: FakeShelf, now: Long = 1L) =
        SiteCredentialChannel(shelf = shelf, clock = { now })

    private fun headers(channel: SiteCredentialChannel, url: String) =
        SiteCredentialSources.headers(channel, profileId, url)

    @Test fun aFragmentOnTheCdnStationCarriesTheSameCredentialAsTheManifest() {
        val channel = channel(shelf())
        val manifest = headers(channel, "$station/hls/master.m3u8")
        val fragment = headers(channel, "$station/hls/seg-00001.ts")
        // 同一站点上，清单与分片拿到的头必须一模一样。
        assertEquals(manifest, fragment)
        assertEquals("Bearer access", fragment["Authorization"])
        assertEquals("sid=c; uid=u", fragment["Cookie"])
    }

    @Test fun everyRequestIsResolvedAgainSoARefreshReachesLaterFragments() {
        // 会话中途续期：分片请求不能沿用主清单那一次取到的头。
        val held = shelf()
        val channel = channel(held)
        assertEquals("Bearer access", headers(channel, "$station/a.ts")["Authorization"])
        held.store(credential("access-2"))
        assertEquals("Bearer access-2", headers(channel, "$station/b.ts")["Authorization"])
    }

    @Test fun anExpiredCopyIsEmptyForFragmentsTooInsteadOfLeakingTheOldToken() {
        val expired = channel(shelf(expiry = 10L), now = 10L)
        assertEquals(emptyMap<String, String>(), headers(expired, "$station/a.ts"))
        // 过期之前仍然带得上。
        val fresh = channel(shelf(expiry = 10L), now = 9L)
        assertEquals("Bearer access", headers(fresh, "$station/a.ts")["Authorization"])
    }

    @Test fun aFragmentOnAnotherStationGetsNothingFromThisProfile() {
        val channel = channel(shelf())
        assertEquals(emptyMap<String, String>(), headers(channel, "https://elsewhere-ads.example.test/a.ts"))
        // 同主机不同端口是另一个站点，凭证同样不外溢。
        assertEquals(emptyMap<String, String>(), headers(channel, "https://cdn.example.test:8443/a.ts"))
    }

    @Test fun eachFetchDecisionIsMadeForThatUrlAlone() {
        // 数据来源按每一次请求（主清单、每一个分片）重新问一次；不属于本站点的
        // 请求拿到空集合，而不是上一份凭证。`DataSpec` 本身依赖 Android 桩，
        // 这一层不可在本机运行，所以判定按请求地址逐次验证。
        val channel = channel(shelf())
        val manifest = "$station/hls/master.m3u8"
        val fragment = "$station/hls/seg-1.ts"
        val foreign = "https://elsewhere-ads.example.test/seg-2.ts"
        assertEquals(headers(channel, manifest), headers(channel, fragment))
        assertEquals(emptyMap<String, String>(), headers(channel, foreign))
    }

    @Test fun aStaleAuthorizationIsReplacedNotAppendedTo() {
        val headers = headers(channel(shelf()), "$station/seg-1.ts")
        val merged = AuthoredHttpRequest.merge(
            existing = mapOf("authorization" to "Bearer stale", "X-Trace" to "1"),
            headers = headers,
        )
        // 同名（忽略大小写）被替换，别的头保持不动。
        assertEquals("Bearer access", merged["Authorization"])
        assertEquals(null, merged["authorization"])
        assertEquals("1", merged["X-Trace"])
        assertEquals("sid=c; uid=u", merged["Cookie"])
    }

    @Test fun aPublicRequestKeepsItsOwnHeadersUntouched() {
        val merged = AuthoredHttpRequest.merge(
            existing = mapOf("Authorization" to "Bearer page", "X-Trace" to "1"),
            headers = emptyMap(),
        )
        // 没有凭证时不改写任何既有头：公开内容照旧。
        assertEquals(mapOf("Authorization" to "Bearer page", "X-Trace" to "1"), merged)
    }

    /** 假的消费端副本：直接放记录，不过 `org.json`。 */
    private class FakeShelf : SiteCredentialRecord.ShelfContainer {
        private val held = LinkedHashMap<Int, SiteCredentialRecord>()

        override fun store(credential: SiteCredentialRecord) {
            held[credential.profileId] = credential
        }

        override fun clear(profileId: Int) {
            held.remove(profileId)
        }

        // 与生产副本同一条规则：只有服务这条地址的凭证才算「有」。
        override fun get(profileId: Int, raw: String): SiteCredentialRecord? =
            held[profileId]?.takeIf { it.appliesAt(raw) }

        override fun held(profileId: Int): SiteCredentialRecord? = held[profileId]

        override val isEmpty: Boolean get() = held.isEmpty()

        override val size: Int get() = held.size
    }
}
