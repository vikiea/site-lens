package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 凭证通道的读写面（ADR-0007）：`push` / `clear` 进来就整份落地，`has` / `epoch`
 * 只回答「有没有」，任何 `get` / `read` / `dump` 都不存在。
 */
class SiteCredentialChannelTest {
    private var now = 1_700_000_000_000L

    private fun channel(loader: ((SiteCredentialChannel.Loader) -> Unit)? = null): SiteCredentialChannel =
        SiteCredentialChannel(
            shelf = SiteCredentialRecord.Shelf(),
            clock = { now },
            loader = loader
                ?: { reader ->
                    reader.accept(
                        7,
                        """{"version":1,"accessToken":"stored","cookies":{"sid":"c"},""" +
                            """"station":"https://cdn.example.test","expiresAt":"2030-01-01T00:00:00.000Z"}""",
                    )
                },
        ).also { it.restore() }

    @Test fun aPushAnswersOnlyWithWhatTheEntryNowHolds() {
        val channel = channel()
        now += 1
        val reply = channel.push(7, """{"version":1,"accessToken":"a1","cookies":{"sid":"c"}}""")
        assertEquals(true, reply["accepted"])
        assertEquals(7, reply["profileId"])
        assertEquals(now, reply["epoch"])
        // 回执里没有凭证值。
        assertFalse(reply.values.any { it.toString().contains("a1") })
        assertEquals(channel.admissionHeaders("https://x.example.test/a.m3u8", 7)["Authorization"], "Bearer a1")
    }

    @Test fun aRefusedPushKeepsTheCopyTheApplicationAlreadyGave() {
        val channel = channel()
        channel.push(
            7,
            """{"version":1,"accessToken":"good","cookies":{"sid":"c"},"station":"https://cdn.example.test"}""",
        )
        for (raw in listOf(
            """{"version":1,"accessToken":"bad"}""",
            """{"version":9,"accessToken":"bad","cookies":{"sid":"c"}}""",
            "not json",
        )) {
            try {
                channel.push(7, raw)
                fail("不完整或版本不认识的记录必须拒绝：$raw")
            } catch (expected: IllegalArgumentException) {
                assertEquals(SiteCredentialRecord.UNREADABLE, expected.message)
            }
        }
        // 拒绝不覆盖：应用侧送来的坏记录不会把一份好凭证换成半截。
        assertEquals(
            channel.admissionHeaders("https://cdn.example.test/a.m3u8", 7)["Authorization"],
            "Bearer good",
        )
    }

    @Test fun aStoredCopyThatIsNoLongerReadableCountsAsNoCredential() {
        val channel = channel()
        assertEquals(
            channel.admissionHeaders("https://cdn.example.test/a.m3u8", 7)["Authorization"],
            "Bearer stored",
        )
        // 版本不认识、已过期的副本一律当「没有凭证」：公开内容照播，私有内容会以
        // 401/403 回传失效事件，由应用续期后重推。
        val rotated = channel { reader ->
            reader.accept(7, """{"version":6,"accessToken":"stored","cookies":{"sid":"c"}}""")
        }
        assertEquals(emptyMap<String, String>(), rotated.admissionHeaders("https://cdn.example.test/a.m3u8", 7))

        val expired = channel { reader ->
            reader.accept(
                7,
                """{"version":1,"accessToken":"stored","cookies":{"sid":"c"},"expiresAt":"2020-01-01T00:00:00.000Z"}""",
            )
        }
        assertEquals(emptyMap<String, String>(), expired.admissionHeaders("https://cdn.example.test/a.m3u8", 7))
        // 过期副本不被原生改写，也不被删掉：应用随时可以覆盖。
        assertEquals(1, expired.shelfSize)
    }

    @Test fun clearIsIdempotentAndDoesNotTouchOtherProfiles() {
        val channel = channel()
        channel.push(
            8,
            """{"version":1,"accessToken":"eight","cookies":{"sid":"c"},"station":"https://b.example.test"}""",
        )
        val reply = channel.clear(8)
        assertEquals(true, reply["accepted"])
        assertEquals(8, reply["profileId"])
        channel.clear(8)
        assertEquals(emptyMap<String, String>(), channel.admissionHeaders("https://b.example.test/a.m3u8", 8))
        assertEquals(
            channel.admissionHeaders("https://cdn.example.test/a.m3u8", 7)["Authorization"],
            "Bearer stored",
        )
    }

    @Test fun theReadSideAnswersPresenceAndNeverAValue() {
        val channel = channel()
        assertTrue(channel.has(7))
        assertFalse(channel.has(99))
        assertTrue(channel.remoteSourceEnabled(7, "https://cdn.example.test/a.m3u8"))
        assertFalse(channel.remoteSourceEnabled(99, "https://cdn.example.test/a.m3u8"))
        assertFalse(channel.remoteSourceEnabled(7, "https://nothing-here.example.test/a.m3u8"))
        // 通道自己的描述也不打印凭证。
        assertFalse(channel.toString().contains("stored"))
    }

    @Test fun theEpochMovesWithEveryAcceptedPush() {
        val channel = channel()
        val first = channel.push(7, """{"version":1,"accessToken":"a1","cookies":{"sid":"c"}}""")["epoch"] as Long
        now += 5
        val second = channel.push(7, """{"version":1,"accessToken":"a2","cookies":{"sid":"c"}}""")["epoch"] as Long
        assertEquals(5L, second - first)
        assertEquals(channel.admissionHeaders("https://x.example.test/a.m3u8", 7)["Authorization"], "Bearer a2")
    }
}
