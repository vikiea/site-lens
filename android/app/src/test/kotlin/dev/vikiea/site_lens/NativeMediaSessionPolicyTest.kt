package dev.vikiea.site_lens

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMediaSessionPolicyTest {
    @Test fun taskRemovalPreservesExplicitlyPausedPlayback() {
        assertEquals(
            NativeMediaSessionPolicy.TaskRemovalAction.PRESERVE_RESTORABLE,
            NativeMediaSessionPolicy.taskRemovalAction(userPaused = true, state = "paused"),
        )
        assertEquals(
            NativeMediaSessionPolicy.TaskRemovalAction.KEEP_RUNNING,
            NativeMediaSessionPolicy.taskRemovalAction(userPaused = false, state = "buffering"),
        )
        assertEquals(
            NativeMediaSessionPolicy.TaskRemovalAction.RELEASE,
            NativeMediaSessionPolicy.taskRemovalAction(userPaused = true, state = "completed"),
        )
    }

    @Test fun controllerPolicyRejectsUntrustedPackages() {
        assertTrue(
            NativeMediaSessionPolicy.isAllowedController(
                controllerPackage = "dev.vikiea.site_lens",
                appPackage = "dev.vikiea.site_lens",
                trusted = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.isAllowedController(
                controllerPackage = "com.android.systemui",
                appPackage = "dev.vikiea.site_lens",
                trusted = true,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.isAllowedController(
                controllerPackage = "com.example.other",
                appPackage = "dev.vikiea.site_lens",
                trusted = false,
            ),
        )
    }

    @Test fun externalControllersCannotReplaceOrReleaseTheMediaItem() {
        assertTrue(
            NativeMediaSessionPolicy.isExternalPlayerCommandAllowed(
                Player.COMMAND_PLAY_PAUSE,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.isExternalPlayerCommandAllowed(
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.isExternalPlayerCommandAllowed(
                Player.COMMAND_SET_MEDIA_ITEM,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.isExternalPlayerCommandAllowed(
                Player.COMMAND_RELEASE,
            ),
        )
    }

    @Test fun remotePlaybackCommandsCountAsExplicitUserIntent() {
        assertTrue(
            NativeMediaSessionPolicy.isExplicitPlayWhenReadyChange(
                Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.isExplicitPlayWhenReadyChange(
                Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.isExplicitPlayWhenReadyChange(
                Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.isExplicitPlayWhenReadyChange(
                Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY,
            ),
        )
    }

    @Test fun stopIsAcceptedThenReleasedAfterInteraction() {
        assertEquals(
            NativeMediaSessionPolicy.PlayerCommandDecision.ALLOW_AND_RELEASE,
            NativeMediaSessionPolicy.playerCommandDecision(
                controllerAllowed = true,
                appController = false,
                command = Player.COMMAND_STOP,
            ),
        )
        assertTrue(NativeMediaSessionPolicy.shouldReleaseAfterPlayerCommand(Player.COMMAND_STOP))
    }

    @Test fun rejectedControllersCannotTriggerReleaseOrReplaceMedia() {
        assertEquals(
            NativeMediaSessionPolicy.PlayerCommandDecision.REJECT,
            NativeMediaSessionPolicy.playerCommandDecision(
                controllerAllowed = false,
                appController = false,
                command = Player.COMMAND_STOP,
            ),
        )
        assertEquals(
            NativeMediaSessionPolicy.PlayerCommandDecision.REJECT,
            NativeMediaSessionPolicy.playerCommandDecision(
                controllerAllowed = true,
                appController = false,
                command = Player.COMMAND_SET_MEDIA_ITEM,
            ),
        )
    }
}
