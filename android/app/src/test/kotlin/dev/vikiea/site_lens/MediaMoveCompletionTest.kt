package dev.vikiea.site_lens

import org.junit.Assert.*
import org.junit.Test

class MediaMoveCompletionTest {
    @Test fun successfulSourceDeleteKeepsThePublishedTarget() {
        var rolledBack = false
        completeMediaMove("target", {}, { rolledBack = true })
        assertFalse(rolledBack)
    }

    @Test fun sourceFailureRollsBackBeforeReturningTheOriginalError() {
        val failure = IllegalStateException("source delete failed")
        var rolledBack = false
        val result = assertThrows(IllegalStateException::class.java) {
            completeMediaMove("target", { throw failure }, { rolledBack = true })
        }
        assertSame(failure, result)
        assertTrue(rolledBack)
    }

    @Test fun doubleFailureReturnsThePublishedTargetForDurableRecovery() {
        val failure = IllegalStateException("source delete failed")
        val result = assertThrows(MediaMoveRollbackFailure::class.java) {
            completeMediaMove("content://provider/document/new", { throw failure }, { error("rollback failed") })
        }
        assertEquals("content://provider/document/new", result.target)
        assertSame(failure, result.cause)
    }
}
