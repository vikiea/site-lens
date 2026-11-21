package dev.vikiea.site_lens

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 消费端解析（ADR-0007）：应用侧写入的记录在原生侧只有一种读法，读不懂就是
 * 「没有凭证」，绝不是一个半截会话。
 */
class SiteCredentialRecordTest {
    private val record = """
        {"version":1,"account":"default","station":"https://cdn.example.test",
        "accessToken":"access-2f7a","refreshToken":"refresh-91bc",
        "cookies":{"sid":"cookie-4de1","cdn":"cookie-8aa0"},
        "installationStamp":"install-77c3","expiresAt":"2030-01-02T03:04:05.000Z"}
    """.trimIndent()

    @Test fun decodesTheApplicationRecordIntoOneValue() {
        val credential = SiteCredentialRecord.decode(7, record)
        assertEquals(7, credential.profileId)
        assertEquals("default", credential.accountId)
        assertEquals("https://cdn.example.test", credential.station)
        assertEquals("access-2f7a", credential.accessToken)
        assertEquals("refresh-91bc", credential.refreshToken)
        assertEquals(mapOf("sid" to "cookie-4de1", "cdn" to "cookie-8aa0"), credential.cookies)
        assertEquals("install-77c3", credential.installationStamp)
        assertEquals(1_893_553_445_000L, credential.expiresAtEpochMs)
        assertTrue(credential.hasAccessToken)
        assertTrue(credential.hasCookies)
        assertFalse(credential.isEmpty)
    }

    @Test fun aMissingOrNullStationMeansAnyStation() {
        val withoutStation = """{"version":1,"accessToken":"a","cookies":{"sid":"c"}}"""
        assertNull(SiteCredentialRecord.decode(7, withoutStation).station)
        // 应用侧的 `jsonEncode` 会把没有站点的凭证写成显式 null。
        val explicitNull = """{"version":1,"accessToken":"a","cookies":{"sid":"c"},"station":null}"""
        assertNull(SiteCredentialRecord.decode(7, explicitNull).station)
        assertTrue(SiteCredentialRecord.decode(7, withoutStation).appliesAt("https://any.example.test/x.m3u8"))
    }

    @Test fun recordsWithoutATokenOrCookieAreNotCredentials() {
        for (raw in listOf(
            """{"version":1,"cookies":{"sid":"c"}}""",
            """{"version":1,"accessToken":"a"}""",
            """{"version":1,"accessToken":"a","cookies":{}}""",
            """{"version":1,"accessToken":"   ","cookies":{"sid":"c"}}""",
            """{"version":2,"accessToken":"a","cookies":{"sid":"c"}}""",
            """{"accessToken":"a","cookies":{"sid":"c"}}""",
            """{"version":1,"accessToken":7,"cookies":{"sid":"c"}}""",
            """{"version":1,"accessToken":"a","cookies":{"sid":7}}""",
        )) {
            try {
                SiteCredentialRecord.decode(7, raw)
                fail("应把无法识别的记录当成没有凭证：$raw")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }

    @Test fun aBrokenOrOversizedRecordIsRejectedAsAWhole() {
        for (raw in listOf(
            "",
            "not json",
            "[1,2,3]",
            """{"version":1,"accessToken":"a","cookies":{"sid":"c"},"expiresAt":"tomorrow"}""",
            """{"version":1,"accessToken":"a","cookies":{"sid":"c"},"station":5}""",
            """{"version":1,"accessToken":"${"a".repeat(SiteCredentialRecord.MAX_FIELD_LENGTH + 1)}","cookies":{"sid":"c"}}""",
            """{"version":1,"accessToken":"a","cookies":{"${"n".repeat(SiteCredentialRecord.MAX_COOKIE_NAME_LENGTH + 1)}":"c"}}""",
        )) {
            try {
                SiteCredentialRecord.decode(7, raw)
                fail("应整体拒绝：${raw.take(80)}")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }

    @Test fun anOversizedRecordIsRejectedBeforeItIsParsed() {
        try {
            SiteCredentialRecord.decode(7, "x".repeat(SiteCredentialRecord.MAX_RECORD_LENGTH + 1))
            fail("过大的记录必须在解析前拒绝")
        } catch (expected: IllegalArgumentException) {
            assertEquals(SiteCredentialRecord.UNREADABLE, expected.message)
        }
    }

    @Test fun requestHeadersCarryTheTokenAndTheCookieJar() {
        val headers = SiteCredentialRecord.decode(7, record).headers()
        assertEquals("Bearer access-2f7a", headers["Authorization"])
        assertEquals("sid=cookie-4de1; cdn=cookie-8aa0", headers["Cookie"])
        // 设备标识不参与网络请求：它是站点自己的东西，止步于适配器。
        assertFalse(headers.values.any { it.contains("install-77c3") })
        assertEquals(emptyMap<String, String>(), SiteCredentialRecord.NONE.headers())
    }

    @Test fun aStationlessCredentialAppliesAndANamedOneDoesNot() {
        val credential = SiteCredentialRecord.decode(7, record)
        assertTrue(credential.appliesAt("https://cdn.example.test/hls/master.m3u8"))
        assertTrue(credential.appliesAt("https://CDN.example.test/a.mp4"))
        assertFalse(credential.appliesAt("https://other.example.test/a.mp4"))
        assertFalse(credential.appliesAt("http://cdn.example.test/a.mp4"))
        assertFalse(credential.appliesAt("not a uri at all"))
        assertTrue(credential.appliesAt(SiteCredentialRecord.decode(7, record).station!!))
    }

    @Test fun whatTheNativeSideHoldsNeverPrintsASecret() {
        val credential = SiteCredentialRecord.decode(7, record)
        val text = credential.toString()
        for (secret in listOf("access-2f7a", "refresh-91bc", "cookie-4de1", "install-77c3")) {
            assertFalse("凭证值出现在 toString 里：$secret", text.contains(secret))
        }
        assertTrue(text.contains("profileId=7"))
        assertTrue(text.contains("accessTokenPresent=true"))
    }

    @Test fun theShelfHasNoStringConstructorForCredentials() {
        assertEquals(
            SiteCredentialRecord.NOT_A_STRING,
            runCatching { SiteCredentialRecord.of("anything") }.exceptionOrNull()?.message,
        )
    }

    @Test fun aPushReplacesEverythingTheApplicationOwed() {
        val shelf = SiteCredentialRecord.Shelf()
        assertTrue(shelf.isEmpty)
        shelf.store(SiteCredentialRecord.decode(7, record))
        assertEquals("access-2f7a", shelf.get(7, "https://cdn.example.test/a.m3u8")?.accessToken)
        val refreshed = SiteCredentialRecord.decode(
            7,
            """{"version":1,"accessToken":"access-new","cookies":{"sid":"cookie-new"}}""",
        )
        shelf.store(refreshed)
        val held = shelf.get(7, "https://cdn.example.test/a.m3u8")
        assertEquals("access-new", held?.accessToken)
        // 覆盖是整份替换：旧记录里的刷新令牌不会残留。
        assertNull(held?.refreshToken)
        assertEquals(mapOf("sid" to "cookie-new"), held?.cookies)
        assertEquals(1, shelf.size)
    }

    @Test fun aClearedProfileHasNoCredentialAndClearIsIdempotent() {
        val shelf = SiteCredentialRecord.Shelf()
        shelf.store(SiteCredentialRecord.decode(7, record))
        shelf.clear(7)
        assertNull(shelf.get(7, "https://cdn.example.test/a.m3u8"))
        shelf.clear(7)
        assertTrue(shelf.isEmpty)
    }

    @Test fun oneCredentialNeedsBothTheTokenAndTheCookieJar() {
        // 分片与 CDN 常只认 cookie，而清单要令牌：只有一半不是会话（GLOSSARY:
        // 站点凭证）。和 Dart 侧 `SiteCredential.isUsable` 是同一条门槛。
        for (raw in listOf(
            """{"version":1,"accessToken":"a"}""",
            """{"version":1,"cookies":{"sid":"c"}}""",
        )) {
            try {
                SiteCredentialRecord.decode(7, raw)
                fail("只有一半的凭证不是会话：$raw")
            } catch (expected: IllegalArgumentException) {
                assertEquals(SiteCredentialRecord.UNREADABLE, expected.message)
            }
        }
    }

    @Test fun theDecodeIsAFunctionOfTheRawRecordOnly() {
        assertEquals(
            SiteCredentialRecord.decode(7, record),
            SiteCredentialRecord.decode(7, record),
        )
        assertEquals(
            "access-2f7a",
            (Json.parseToJsonElement(record) as JsonObject)["accessToken"]!!.jsonPrimitive.content,
        )
    }
}

/**
 * 两份副本的覆盖规则（ADR-0007 Consequences）：
 *
 * - 生产端（应用侧）是唯一真相：每次推送整份覆盖原生侧那一份，原生从不回写。
 * - 原生读到过期副本（过期时间已过）时**不自行修补**：它不刷新凭证，只把一个
 *   判定交回应用，由应用续期成功后重推。
 * - 原生读不到凭证 = 没有凭证 = 公开内容，不是错误。
 */
class SiteCredentialShelfCoverageTest {
    private fun credential(
        profileId: Int,
        accessToken: String,
        station: String? = "https://cdn.example.test",
        expiresAt: String? = null,
    ) = SiteCredentialRecord.decode(
        profileId,
        buildString {
            append("""{"version":1,"accessToken":"$accessToken","cookies":{"sid":"c"}""")
            if (station != null) append(""","station":"$station"""")
            if (expiresAt != null) append(""","expiresAt":"$expiresAt"""")
            append("}")
        },
    )

    @Test fun aProfileWithoutACredentialIsAPublicContentSituationNotAFailure() {
        val shelf = SiteCredentialRecord.Shelf()
        assertNull(shelf.get(7, "https://cdn.example.test/a.m3u8"))
        // 判定交给播放入口：没有凭证时远程地址仍按公开内容放行。
        assertTrue(SiteCredentialRecord.NONE.isEmpty)
        assertFalse(SiteCredentialRecord.NONE.appliesAt("https://cdn.example.test/a.m3u8"))
    }

    @Test fun aPushFromTheApplicationAlwaysWinsWholesale() {
        val shelf = SiteCredentialRecord.Shelf()
        shelf.store(credential(7, "old", station = "https://a.example.test"))
        shelf.store(credential(7, "new", station = "https://b.example.test"))
        assertNull(shelf.get(7, "https://a.example.test/x.m3u8"))
        assertEquals("new", shelf.get(7, "https://b.example.test/x.m3u8")?.accessToken)
    }

    @Test fun anExpiredCopyIsReportedAndNeverPatchedNatively() {
        val shelf = SiteCredentialRecord.Shelf()
        val expired = credential(7, "old", expiresAt = "2020-01-01T00:00:00.000Z")
        shelf.store(expired)
        val now = 1_700_000_000_000L
        assertTrue(expired.isExpiredAt(now))
        // 原生不改写自己那一份，也不清空：判定交回应用，应用续期后再推。
        assertEquals(expired, shelf.get(7, "https://cdn.example.test/a.m3u8"))
        val disposition = SiteCredentialFailurePolicy.forExpiredCopy()
        assertEquals(SiteCredentialFailurePolicy.Kind.CREDENTIAL_REJECTED, disposition.kind)
        assertTrue(disposition.shouldAskApplication)
    }

    @Test fun aProfileIdThatCouldLeakBetweenSitesIsNotUsedAsAKey() {
        val shelf = SiteCredentialRecord.Shelf()
        shelf.store(credential(7, "seven"))
        shelf.store(credential(8, "eight", station = "https://other.example.test"))
        assertEquals("seven", shelf.get(7, "https://cdn.example.test/a.m3u8")?.accessToken)
        assertEquals("eight", shelf.get(8, "https://other.example.test/a.m3u8")?.accessToken)
        assertNull(shelf.get(8, "https://cdn.example.test/a.m3u8"))
        assertEquals(setOf(7, 8), shelf.profileIds)
        // 覆盖一个档案不影响另一个。
        shelf.clear(7)
        assertNull(shelf.get(7, "https://cdn.example.test/a.m3u8"))
        assertEquals("eight", shelf.get(8, "https://other.example.test/a.m3u8")?.accessToken)
    }
}
