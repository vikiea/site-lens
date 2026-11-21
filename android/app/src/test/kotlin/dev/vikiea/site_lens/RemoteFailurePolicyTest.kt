package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 远程播放失败的四类归因（T8，ADR-0005）：凭证失效、清单失效、分片失败、网络
 * 失败各有各的结局；前两类各自只重开一次，后两类不重开整集。
 */
class RemoteFailurePolicyTest {
    @Test fun theFourOutcomesDoNotShareAClassification() {
        assertEquals(
            RemoteFailurePolicy.Kind.CREDENTIAL_REJECTED,
            RemoteFailurePolicy.classify(recoverable = false, httpStatus = 401),
        )
        assertEquals(
            RemoteFailurePolicy.Kind.CREDENTIAL_REJECTED,
            RemoteFailurePolicy.classify(recoverable = false, httpStatus = 403),
        )
        assertEquals(
            RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE,
            RemoteFailurePolicy.classify(recoverable = false, manifestFailed = true),
        )
        assertEquals(
            RemoteFailurePolicy.Kind.SEGMENT_FAILED,
            RemoteFailurePolicy.classify(recoverable = false, segmentFailed = true),
        )
        assertEquals(
            RemoteFailurePolicy.Kind.NETWORK,
            RemoteFailurePolicy.classify(recoverable = true),
        )
    }

    @Test fun aManifestFailureIsNeverMistakenForANetworkFailure() {
        // 清单本身就是坏的：即使 ExoPlayer 也把它标成 recoverable，结论仍是清单
        // 失效，处置是重取清单，而不是「网络已切换」。
        assertEquals(
            RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE,
            RemoteFailurePolicy.classify(recoverable = true, manifestFailed = true),
        )
        // 401/403 优先于一切：站点拒绝的是会话，不是清单。
        assertEquals(
            RemoteFailurePolicy.Kind.CREDENTIAL_REJECTED,
            RemoteFailurePolicy.classify(
                recoverable = true,
                manifestFailed = true,
                httpStatus = 403,
            ),
        )
    }

    @Test fun onlyCredentialAndManifestFailuresReopenTheEpisode() {
        for (kind in listOf(
            RemoteFailurePolicy.Kind.CREDENTIAL_REJECTED,
            RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE,
        )) {
            assertEquals(1, RemoteFailurePolicy.budgetFor(kind))
            assertTrue(RemoteFailurePolicy.reopensEpisode(kind))
        }
        for (kind in listOf(
            RemoteFailurePolicy.Kind.SEGMENT_FAILED,
            RemoteFailurePolicy.Kind.NETWORK,
        )) {
            assertEquals(0, RemoteFailurePolicy.budgetFor(kind))
            assertFalse(RemoteFailurePolicy.reopensEpisode(kind))
        }
        assertEquals(1, RemoteFailurePolicy.MAX_AUTO_RETRIES)
    }

    @Test fun eachKindHasItsOwnBudgetWithinOneSession() {
        val state = RemoteFailurePolicy.State()
        assertTrue(state.mayReopen("native_7", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE))
        assertFalse(
            "清单失效只重开一次",
            state.mayReopen("native_7", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE),
        )
        assertEquals(1, state.attemptsFor("native_7", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE))
        // 凭证失效不占用清单失效的预算，反之亦然。
        assertTrue(state.mayReopen("native_7", RemoteFailurePolicy.Kind.CREDENTIAL_REJECTED))
        assertEquals(1, state.attemptsFor("native_7", RemoteFailurePolicy.Kind.CREDENTIAL_REJECTED))
    }

    @Test fun segmentAndNetworkFailuresNeverSpendABudget() {
        val state = RemoteFailurePolicy.State()
        for (kind in listOf(
            RemoteFailurePolicy.Kind.SEGMENT_FAILED,
            RemoteFailurePolicy.Kind.NETWORK,
        )) {
            assertFalse(state.mayReopen("native_7", kind))
            assertEquals(0, state.attemptsFor("native_7", kind))
        }
    }

    @Test fun aNewSessionStartsWithFreshBudgetsAndForgetReclaims() {
        val state = RemoteFailurePolicy.State()
        assertTrue(state.mayReopen("native_7", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE))
        assertTrue(state.mayReopen("native_8", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE))
        state.forget("native_7")
        assertEquals(0, state.attemptsFor("native_7", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE))
        assertTrue(state.mayReopen("native_7", RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE))
    }

    @Test fun theEventCarriesOnlyKindAndCounts() {
        val event = RemoteFailurePolicy.eventFor(
            kind = RemoteFailurePolicy.Kind.SEGMENT_FAILED,
            sessionId = "native_7",
            profileId = 7,
            attempt = 1,
        )
        assertTrue(event.startsWith(RemoteFailurePolicy.EVENT_REMOTE_FAILURE))
        assertTrue(event.contains("kind=segmentFailed"))
        assertTrue(event.contains("profile=7"))
        assertTrue(event.contains("attempt=1"))
        // 分片失败不重开整集：它没有「终局」可言，重试预算恒为 0。
        assertTrue(event.contains("terminal=false"))
        // 事件里没有地址、凭证值或分片内容。
        for (forbidden in listOf("http://", "https://", "token", "cookie", "Cookie", "Authorization")) {
            assertFalse(forbidden, event.contains(forbidden))
        }
    }

    @Test fun aManifestEventMarksItselfTerminalAfterTheSingleRetry() {
        val first = RemoteFailurePolicy.eventFor(
            kind = RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE,
            sessionId = "native_7",
            profileId = 7,
            attempt = 1,
        )
        // 第一次清单失效：还有一次自动重开，所以不是终局。
        assertTrue(first.contains("terminal=false"))
        val second = RemoteFailurePolicy.eventFor(
            kind = RemoteFailurePolicy.Kind.MANIFEST_UNAVAILABLE,
            sessionId = "native_7",
            profileId = 7,
            attempt = 2,
        )
        assertTrue(second.contains("terminal=true"))
    }
}
