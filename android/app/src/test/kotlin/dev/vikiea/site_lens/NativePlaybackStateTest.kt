package dev.vikiea.site_lens

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Test

class NativePlaybackStateTest {
    @Test fun preparationAndBufferingDoNotBecomePausedWhenIsPlayingIsFalse() {
        assertEquals("preparing", NativePlaybackState.resolve("preparing", Player.STATE_IDLE, false, true))
        assertEquals("buffering", NativePlaybackState.resolve("preparing", Player.STATE_BUFFERING, false, true))
        assertEquals("buffering", NativePlaybackState.resolve("playing", Player.STATE_BUFFERING, false, true))
        assertEquals("buffering", NativePlaybackState.resolve("buffering", Player.STATE_READY, false, true))
        assertEquals("playing", NativePlaybackState.resolve("buffering", Player.STATE_READY, true, true))
    }

    @Test fun readyPlayerReportsPauseOnlyWhenPlaybackIsNoLongerRequested() {
        assertEquals("paused", NativePlaybackState.resolve("playing", Player.STATE_READY, false, false))
        assertEquals("playing", NativePlaybackState.resolve("paused", Player.STATE_READY, true, true))
    }

    @Test fun completionAndReplayFollowTheActualPlayerLifecycle() {
        assertEquals("completed", NativePlaybackState.resolve("playing", Player.STATE_ENDED, false, true))
        assertEquals("buffering", NativePlaybackState.resolve("completed", Player.STATE_BUFFERING, false, true))
        assertEquals("playing", NativePlaybackState.resolve("buffering", Player.STATE_READY, true, true))
    }

    @Test fun lateCallbacksDoNotOverwriteTerminalErrorsOrStoppedState() {
        assertEquals("failed", NativePlaybackState.resolve("failed", Player.STATE_IDLE, false, false))
        assertEquals("failed", NativePlaybackState.resolve("failed", Player.STATE_READY, true, true))
        assertEquals("stopped", NativePlaybackState.resolve("stopped", Player.STATE_BUFFERING, false, true))
    }
}
