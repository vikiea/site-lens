package dev.vikiea.site_lens

import androidx.media3.common.Player

internal object NativeMediaSessionPolicy {
    enum class LifecyclePhase {
        READY,
        OPENING,
        ACTIVE,
        STOPPING,
        RELEASED,
    }

    enum class PlayerCommandDecision {
        ALLOW,
        ALLOW_AND_RELEASE,
        REJECT,
    }

    enum class TaskRemovalAction {
        KEEP_RUNNING,
        PRESERVE_RESTORABLE,
        RELEASE,
    }

    fun taskRemovalAction(
        allowNativeBackgroundPlayback: Boolean,
        userPaused: Boolean,
        backgroundPolicyPaused: Boolean,
        state: String,
    ): TaskRemovalAction = when {
        state in TERMINAL_STATES -> TaskRemovalAction.RELEASE
        !allowNativeBackgroundPlayback || userPaused || backgroundPolicyPaused ->
            TaskRemovalAction.PRESERVE_RESTORABLE
        else -> TaskRemovalAction.KEEP_RUNNING
    }

    fun canStartPlayback(
        applicationForeground: Boolean,
        allowNativeBackgroundPlayback: Boolean,
    ): Boolean = applicationForeground || allowNativeBackgroundPlayback

    fun isPlayPauseCommandAllowed(
        command: Int,
        applicationForeground: Boolean,
        allowNativeBackgroundPlayback: Boolean,
        playerIsPlaying: Boolean,
    ): Boolean = command != Player.COMMAND_PLAY_PAUSE ||
        applicationForeground ||
        allowNativeBackgroundPlayback ||
        playerIsPlaying

    fun shouldExposePlayPauseCommand(
        applicationForeground: Boolean,
        allowNativeBackgroundPlayback: Boolean,
        playerIsPlaying: Boolean,
    ): Boolean = applicationForeground || allowNativeBackgroundPlayback || playerIsPlaying

    fun isExplicitPlayPauseCommand(command: Int): Boolean =
        command == Player.COMMAND_PLAY_PAUSE

    fun shouldReadPersistedStateWithoutService(serviceAvailable: Boolean): Boolean =
        !serviceAvailable

    fun canStartForegroundService(applicationForeground: Boolean): Boolean =
        applicationForeground

    fun acceptsLifecyclePolicy(
        ownerId: String,
        sequence: Long,
        currentOwnerId: String,
        currentSequence: Long,
    ): Boolean = ownerId.isNotBlank() &&
        ownerId == currentOwnerId &&
        sequence > currentSequence

    fun isAppController(controllerPackage: String?, appPackage: String): Boolean =
        controllerPackage == appPackage

    fun isAllowedController(
        controllerPackage: String?,
        appPackage: String,
        trusted: Boolean,
    ): Boolean = trusted || isAppController(controllerPackage, appPackage)

    fun isExternalPlayerCommandAllowed(command: Int): Boolean = command !in setOf(
        Player.COMMAND_SET_MEDIA_ITEM,
        Player.COMMAND_CHANGE_MEDIA_ITEMS,
        Player.COMMAND_SET_MEDIA_ITEMS_METADATA,
        Player.COMMAND_SET_PLAYLIST_METADATA,
        Player.COMMAND_SET_VIDEO_SURFACE,
        Player.COMMAND_RELEASE,
    )

    fun playerCommandDecision(
        controllerAllowed: Boolean,
        appController: Boolean,
        command: Int,
        playbackCommandAllowed: Boolean = true,
    ): PlayerCommandDecision = when {
        !controllerAllowed -> PlayerCommandDecision.REJECT
        command == Player.COMMAND_PLAY_PAUSE && !playbackCommandAllowed ->
            PlayerCommandDecision.REJECT
        !appController && !isExternalPlayerCommandAllowed(command) ->
            PlayerCommandDecision.REJECT
        command == Player.COMMAND_STOP -> PlayerCommandDecision.ALLOW_AND_RELEASE
        else -> PlayerCommandDecision.ALLOW
    }

    fun shouldReleaseAfterPlayerCommand(command: Int): Boolean =
        command == Player.COMMAND_STOP

    fun isExplicitPlayWhenReadyChange(reason: Int): Boolean =
        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST ||
            reason == Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE

    fun acceptsLifecycleCallback(
        callbackGeneration: Long,
        currentGeneration: Long,
        phase: LifecyclePhase,
    ): Boolean =
        callbackGeneration == currentGeneration &&
            phase != LifecyclePhase.STOPPING &&
            phase != LifecyclePhase.RELEASED

    fun acceptsServiceDispatch(
        stopping: Boolean,
        engineReleased: Boolean,
        phase: LifecyclePhase,
    ): Boolean =
        !stopping &&
            !engineReleased &&
            phase != LifecyclePhase.STOPPING &&
            phase != LifecyclePhase.RELEASED

    fun shouldRequeueAfterRelease(
        retryOnRelease: Boolean,
        explicitStopInProgress: Boolean,
    ): Boolean = retryOnRelease && !explicitStopInProgress

    fun acceptsSurfaceBinding(
        requestedSessionId: String?,
        requestedBindingId: String?,
        requestedOwnerId: String?,
        activeSessionId: String?,
        activeOwnerId: String?,
        phase: LifecyclePhase,
    ): Boolean =
        phase != LifecyclePhase.STOPPING &&
            phase != LifecyclePhase.RELEASED &&
            activeSessionId != null &&
            (requestedSessionId.isNullOrBlank() || requestedSessionId == activeSessionId) &&
            !requestedBindingId.isNullOrBlank() &&
            !requestedOwnerId.isNullOrBlank() &&
            requestedOwnerId == activeOwnerId

    private val TERMINAL_STATES = setOf("failed", "completed", "stopped")
}
