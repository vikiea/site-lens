package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * ADR-0009：远程来源的准入门槛是**站点凭证存在**，不是设置里的开关。
 *
 * 没有凭证时公开内容照常能播：入口传 `hasCredential = false`，判定对象放行，
 * 只是这一次请求不会带上任何凭证。
 */
class SiteCredentialRemoteAdmissionTest {
    @Test fun aRemoteAddressIsAdmittedWithOrWithoutACredential() {
        val withCredential = NativeMediaSessionRoute.classify(
            "https://cdn.example.test/hls/master.m3u8",
            hasCredential = true,
        )
        assertEquals(NativeMediaSessionRoute.Family.REMOTE, withCredential.family)
        val publicContent = NativeMediaSessionRoute.classify(
            "https://cdn.example.test/hls/master.m3u8",
            hasCredential = false,
        )
        assertEquals(NativeMediaSessionRoute.Family.REMOTE, publicContent.family)
        // 公开内容与私有内容的会话语义相同：都不持文件租约、都不可冷恢复。
        assertFalse(publicContent.isRestorable)
        assertNull(publicContent.leaseForOpening("play_7_1", "https://cdn.example.test/a.m3u8", hls = true))
    }

    @Test fun theRetiredPreferenceNoLongerDecidesAnything() {
        // media_access/remoteSourceAllowed 已退休（ADR-0009）。判定对象只认凭证。
        val pref = runCatching {
            NativeMediaSessionRoute::class.java.getDeclaredField("PREF_REMOTE_SOURCE_ALLOWED")
        }.getOrNull()
        assertNull("退休的开关不得留在判定对象上", pref)
        val gate = runCatching {
            NativeMediaSessionRoute::class.java.getDeclaredMethod(
                "preferenceAllowsRemoteSource",
                String::class.java,
            )
        }.getOrNull()
        assertNull("退休的开关判定不得留在判定对象上", gate)
    }

    @Test fun malformedRemoteAddressesKeepTheirRejection() {
        for (raw in listOf(
            "https://",
            "https://user:pass@cdn.example.test/a.m3u8",
            "ftp://cdn.example.test/a.mp4",
            "asset:///a.mp4",
        )) {
            try {
                NativeMediaSessionRoute.classify(raw, hasCredential = true)
                fail("应拒绝不可播放的媒体地址：$raw")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }

    @Test fun aProfileWithoutACredentialStillNamesTheStationItFailedAt() {
        // 取不到凭证时行为明确：会话照开，`credential` 为 null，而不是抛错或悄悄
        // 退回一个空头集合。
        val admission = NativeMediaSessionRoute.admit(
            raw = "https://cdn.example.test/a.m3u8",
            shelf = SiteCredentialRecord.Shelf(),
            profileId = 7,
        )
        assertEquals(NativeMediaSessionRoute.Family.REMOTE, admission.route.family)
        assertNull(admission.credential)
        assertEquals(emptyMap<String, String>(), admission.headers)

        val shelf = SiteCredentialRecord.Shelf()
        shelf.store(
            SiteCredentialRecord.decode(
                7,
                """{"version":1,"accessToken":"access","cookies":{"sid":"c"},"station":"https://cdn.example.test"}""",
            ),
        )
        val held = NativeMediaSessionRoute.admit("https://cdn.example.test/a.m3u8", shelf, 7)
        assertEquals("Bearer access", held.headers["Authorization"])
        assertEquals("sid=c", held.headers["Cookie"])
        // 凭证只服务于它自己那个站点；别的站点照旧没有凭证。
        val other = NativeMediaSessionRoute.admit("https://other.example.test/a.m3u8", shelf, 7)
        assertNull(other.credential)
        assertEquals(emptyMap<String, String>(), other.headers)
    }
}
