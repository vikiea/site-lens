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
            NativeMediaSessionPolicy.taskRemovalAction(
                allowNativeBackgroundPlayback = true,
                userPaused = true,
                backgroundPolicyPaused = false,
                state = "paused",
            ),
        )
        assertEquals(
            NativeMediaSessionPolicy.TaskRemovalAction.KEEP_RUNNING,
            NativeMediaSessionPolicy.taskRemovalAction(
                allowNativeBackgroundPlayback = true,
                userPaused = false,
                backgroundPolicyPaused = false,
                state = "buffering",
            ),
        )
        assertEquals(
            NativeMediaSessionPolicy.TaskRemovalAction.RELEASE,
            NativeMediaSessionPolicy.taskRemovalAction(
                allowNativeBackgroundPlayback = false,
                userPaused = true,
                backgroundPolicyPaused = false,
                state = "completed",
            ),
        )
    }

    @Test fun disabledBackgroundPolicyPreservesActivePlaybackAsRestorable() {
        assertEquals(
            NativeMediaSessionPolicy.TaskRemovalAction.PRESERVE_RESTORABLE,
            NativeMediaSessionPolicy.taskRemovalAction(
                allowNativeBackgroundPlayback = false,
                userPaused = false,
                backgroundPolicyPaused = true,
                state = "paused",
            ),
        )
    }

    @Test fun backgroundPlaybackPolicyControlsWhetherPlayMayStart() {
        assertTrue(
            NativeMediaSessionPolicy.canStartPlayback(
                applicationForeground = true,
                allowNativeBackgroundPlayback = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.canStartPlayback(
                applicationForeground = false,
                allowNativeBackgroundPlayback = true,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.canStartPlayback(
                applicationForeground = false,
                allowNativeBackgroundPlayback = false,
            ),
        )
    }

    @Test fun notificationPlayCommandFollowsBackgroundPlaybackPolicy() {
        assertFalse(
            NativeMediaSessionPolicy.isPlayPauseCommandAllowed(
                command = Player.COMMAND_PLAY_PAUSE,
                applicationForeground = false,
                allowNativeBackgroundPlayback = false,
                playerIsPlaying = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.isPlayPauseCommandAllowed(
                command = Player.COMMAND_PLAY_PAUSE,
                applicationForeground = false,
                allowNativeBackgroundPlayback = true,
                playerIsPlaying = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.isPlayPauseCommandAllowed(
                command = Player.COMMAND_PLAY_PAUSE,
                applicationForeground = false,
                allowNativeBackgroundPlayback = false,
                playerIsPlaying = true,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.isPlayPauseCommandAllowed(
                command = Player.COMMAND_STOP,
                applicationForeground = false,
                allowNativeBackgroundPlayback = false,
                playerIsPlaying = false,
            ),
        )
    }

    @Test fun notificationCommandsHidePlayWhenBackgroundPlaybackIsDisabled() {
        assertFalse(
            NativeMediaSessionPolicy.shouldExposePlayPauseCommand(
                applicationForeground = false,
                allowNativeBackgroundPlayback = false,
                playerIsPlaying = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.shouldExposePlayPauseCommand(
                applicationForeground = false,
                allowNativeBackgroundPlayback = true,
                playerIsPlaying = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.shouldExposePlayPauseCommand(
                applicationForeground = true,
                allowNativeBackgroundPlayback = false,
                playerIsPlaying = false,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.shouldExposePlayPauseCommand(
                applicationForeground = false,
                allowNativeBackgroundPlayback = false,
                playerIsPlaying = true,
            ),
        )
    }

    @Test fun notificationPlayIsRejectedOnlyWhenItWouldStartBackgroundPlayback() {
        assertEquals(
            NativeMediaSessionPolicy.PlayerCommandDecision.REJECT,
            NativeMediaSessionPolicy.playerCommandDecision(
                controllerAllowed = true,
                appController = false,
                command = Player.COMMAND_PLAY_PAUSE,
                playbackCommandAllowed = false,
            ),
        )
        assertEquals(
            NativeMediaSessionPolicy.PlayerCommandDecision.ALLOW,
            NativeMediaSessionPolicy.playerCommandDecision(
                controllerAllowed = true,
                appController = false,
                command = Player.COMMAND_PLAY_PAUSE,
                playbackCommandAllowed = true,
            ),
        )
    }

    @Test fun notificationPlayPauseIsExplicitUserIntent() {
        assertTrue(
            NativeMediaSessionPolicy.isExplicitPlayPauseCommand(
                Player.COMMAND_PLAY_PAUSE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.isExplicitPlayPauseCommand(
                Player.COMMAND_STOP,
            ),
        )
    }

    @Test fun stateLookupUsesPersistedSnapshotWhenServiceIsUnavailable() {
        assertTrue(
            NativeMediaSessionPolicy.shouldReadPersistedStateWithoutService(
                serviceAvailable = false,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.shouldReadPersistedStateWithoutService(
                serviceAvailable = true,
            ),
        )
    }

    @Test fun foregroundServiceStartRequiresForegroundBridge() {
        assertTrue(NativeMediaSessionPolicy.canStartForegroundService(true))
        assertFalse(NativeMediaSessionPolicy.canStartForegroundService(false))
    }

    @Test fun lifecyclePolicyUsesNativeOwnerAndSequenceOrdering() {
        assertTrue(
            NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = "bridge",
                sequence = 2L,
                currentOwnerId = "bridge",
                currentSequence = 1L,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = "new-bridge",
                sequence = 1L,
                currentOwnerId = "old-bridge",
                currentSequence = 99L,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = "bridge",
                sequence = 1L,
                currentOwnerId = "bridge",
                currentSequence = 1L,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = "",
                sequence = 2L,
                currentOwnerId = "bridge",
                currentSequence = 1L,
            ),
        )
    }

    @Test fun oldOwnerIsRejectedAfterNewOwnerClaimsThePolicy() {
        val claimedOwner = "new-bridge"
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = "old-bridge",
                sequence = 100L,
                currentOwnerId = claimedOwner,
                currentSequence = 0L,
            ),
        )
        assertTrue(
            NativeMediaSessionPolicy.acceptsLifecyclePolicy(
                ownerId = claimedOwner,
                sequence = 1L,
                currentOwnerId = claimedOwner,
                currentSequence = 0L,
            ),
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

    @Test fun staleOrReleasedCallbacksAreIgnored() {
        assertTrue(
            NativeMediaSessionPolicy.acceptsLifecycleCallback(
                callbackGeneration = 7L,
                currentGeneration = 7L,
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecycleCallback(
                callbackGeneration = 6L,
                currentGeneration = 7L,
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecycleCallback(
                callbackGeneration = 7L,
                currentGeneration = 7L,
                phase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsLifecycleCallback(
                callbackGeneration = 7L,
                currentGeneration = 7L,
                phase = NativeMediaSessionPolicy.LifecyclePhase.RELEASED,
            ),
        )
    }

    @Test fun serviceDispatchWaitsForAReplacementAfterReleaseStarts() {
        assertTrue(
            NativeMediaSessionPolicy.acceptsServiceDispatch(
                stopping = false,
                engineReleased = false,
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsServiceDispatch(
                stopping = true,
                engineReleased = false,
                phase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsServiceDispatch(
                stopping = false,
                engineReleased = true,
                phase = NativeMediaSessionPolicy.LifecyclePhase.RELEASED,
            ),
        )
    }

    @Test fun replacementActionsSurviveReleaseButExplicitStopCancelsThem() {
        assertTrue(
            NativeMediaSessionPolicy.shouldRequeueAfterRelease(
                retryOnRelease = true,
                explicitStopInProgress = false,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.shouldRequeueAfterRelease(
                retryOnRelease = true,
                explicitStopInProgress = true,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.shouldRequeueAfterRelease(
                retryOnRelease = false,
                explicitStopInProgress = false,
            ),
        )
    }

    @Test fun surfaceBindingRequiresTheCurrentSessionAndActiveLifecycle() {
        assertTrue(
            NativeMediaSessionPolicy.acceptsSurfaceBinding(
                requestedSessionId = "session-7",
                requestedBindingId = "binding-new",
                requestedOwnerId = "bridge-new",
                activeSessionId = "session-7",
                activeOwnerId = "bridge-new",
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsSurfaceBinding(
                requestedSessionId = "old-session",
                requestedBindingId = "binding-new",
                requestedOwnerId = "bridge-new",
                activeSessionId = "session-7",
                activeOwnerId = "bridge-new",
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsSurfaceBinding(
                requestedSessionId = "session-7",
                requestedBindingId = "binding-new",
                requestedOwnerId = "bridge-new",
                activeSessionId = "session-7",
                activeOwnerId = "bridge-new",
                phase = NativeMediaSessionPolicy.LifecyclePhase.STOPPING,
            ),
        )
        assertFalse(
            NativeMediaSessionPolicy.acceptsSurfaceBinding(
                requestedSessionId = null,
                requestedBindingId = "binding-new",
                requestedOwnerId = "bridge-new",
                activeSessionId = null,
                activeOwnerId = "bridge-new",
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
    }

    @Test fun staleSurfaceBindingFromOldOwnerIsRejectedAfterRebind() {
        assertFalse(
            NativeMediaSessionPolicy.acceptsSurfaceBinding(
                requestedSessionId = "session-7",
                requestedBindingId = "binding-old",
                requestedOwnerId = "bridge-old",
                activeSessionId = "session-7",
                activeOwnerId = "bridge-new",
                phase = NativeMediaSessionPolicy.LifecyclePhase.ACTIVE,
            ),
        )
    }
}
