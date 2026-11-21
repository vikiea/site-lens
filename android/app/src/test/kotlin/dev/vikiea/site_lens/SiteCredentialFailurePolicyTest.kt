package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 失效判定（GLOSSARY: 凭证失效）：401/403 是站点明确拒绝，网络失败与内容不可用
 * 都不是。这个对象只回答「该怎么处置」，不读凭证、不碰网络。
 */
class SiteCredentialFailurePolicyTest {
    @Test fun onlyExplicitRejectionsCountAsCredentialRejection() {
        for (code in listOf(401, 403)) {
            val disposition = SiteCredentialFailurePolicy.forHttpStatus(code)
            assertEquals(SiteCredentialFailurePolicy.Kind.CREDENTIAL_REJECTED, disposition.kind)
            assertTrue(disposition.isCredentialRejection)
            assertTrue(disposition.shouldAskApplication)
        }
        for (code in listOf(400, 404, 408, 410, 429, 500, 502, 503, 0, -1)) {
            val disposition = SiteCredentialFailurePolicy.forHttpStatus(code)
            assertEquals(SiteCredentialFailurePolicy.Kind.CONTENT_UNAVAILABLE, disposition.kind)
            assertFalse(disposition.shouldAskApplication)
            assertFalse(disposition.isCredentialRejection)
        }
    }

    @Test fun aNetworkFailureIsNeverARetiredCredential() {
        val network = SiteCredentialFailurePolicy.networkFailure()
        assertEquals(SiteCredentialFailurePolicy.Kind.NETWORK, network.kind)
        assertFalse(network.shouldAskApplication)
        // 超时与 IO 错误按网络失败处置，绝不顺手判成凭证失效。
        for (code in listOf(408, 504)) {
            assertEquals(
                SiteCredentialFailurePolicy.Kind.CONTENT_UNAVAILABLE,
                SiteCredentialFailurePolicy.forHttpStatus(code).kind,
            )
        }
    }

    @Test fun theEventNamesTheRejectionAndTheSessionItBelongsTo() {
        val event = SiteCredentialFailurePolicy.eventFor(
            status = 401,
            sessionId = "native_7",
            profileId = 7,
            attempt = 1,
        )
        assertEquals(SiteCredentialFailurePolicy.EVENT_CREDENTIAL_REJECTED, event["kind"])
        assertEquals(401, event["status"])
        assertEquals("native_7", event["sessionId"])
        assertEquals(7, event["profileId"])
        assertEquals(1, event["attempt"])
        assertEquals(1, event["retries"])
        assertEquals(false, event["terminal"])
        // 事件只带身份，不带任何凭证值。
        assertEquals(
            setOf("kind", "status", "sessionId", "profileId", "attempt", "retries", "terminal"),
            event.keys,
        )
    }

    @Test fun aSecondEventInTheSameSessionIsTerminal() {
        val second = SiteCredentialFailurePolicy.eventFor(403, "native_7", 7, attempt = 2)
        // retries 记录这段会话已经回传过几次失效：第几次就在说第几次。
        assertEquals(2, second["retries"])
        // 有界：第二次拒绝仍回传，但标成终局，原生不再重试。
        assertEquals(true, second["terminal"])
        assertEquals(true, SiteCredentialFailurePolicy.eventFor(401, "native_7", 7, 3)["terminal"])
        assertFalse(SiteCredentialFailurePolicy.mayRetry(attempt = 0))
        assertTrue(SiteCredentialFailurePolicy.mayRetry(attempt = 1))
        assertFalse(SiteCredentialFailurePolicy.mayRetry(attempt = 2))
        assertEquals(1, SiteCredentialFailurePolicy.MAX_RETRIES)
    }

    @Test fun aCredentialThatJustArrivedDoesNotBuyARetryForTheCurrentFailure() {
        // 推送只重新开始下一段的配额；当前这次失败仍然算作已用掉它。
        val state = SiteCredentialFailurePolicy.State(sessionId = "native_7", attempt = 2)
        assertFalse(state.mayAskApplication("native_7"))
        state.onCredentialPushed("native_7")
        assertEquals(0, state.attempt)
        assertTrue(state.mayAskApplication("native_7"))
        assertEquals(1, state.nextAttempt("native_7"))
        // 同一段会话里，只有第一次拒绝是「可以重试」的。
        assertFalse(state.mayAskApplication("native_7"))
    }

    @Test fun aRejectedPushLeavesThePolicyWithoutACredentialToTrust() {
        // 应用侧把一份坏记录推过来时，原生手里还是上一份；下一次 401/403 仍然
        // 按凭证失效处理，不会被当成「刚推送过」而多试一次。
        val state = SiteCredentialFailurePolicy.State(sessionId = "native_7", attempt = 1)
        state.onCredentialPushed("native_7")
        assertEquals(1, state.nextAttempt("native_7"))
        assertFalse(state.mayAskApplication("native_7"))
    }

    @Test fun anotherSessionStartsItsOwnBudget() {
        val state = SiteCredentialFailurePolicy.State(sessionId = "native_7", attempt = 2)
        assertEquals(1, state.nextAttempt("native_8"))
        assertEquals("native_8", state.sessionId)
        assertNull(SiteCredentialFailurePolicy.State().sessionId)
    }
}
