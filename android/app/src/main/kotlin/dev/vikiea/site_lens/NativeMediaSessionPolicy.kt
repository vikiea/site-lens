package dev.vikiea.site_lens

import androidx.media3.common.Player

internal object NativeMediaSessionPolicy {
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

    fun taskRemovalAction(userPaused: Boolean, state: String): TaskRemovalAction = when {
        state in TERMINAL_STATES -> TaskRemovalAction.RELEASE
        userPaused -> TaskRemovalAction.PRESERVE_RESTORABLE
        else -> TaskRemovalAction.KEEP_RUNNING
    }

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
    ): PlayerCommandDecision = when {
        !controllerAllowed -> PlayerCommandDecision.REJECT
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

    private val TERMINAL_STATES = setOf("failed", "completed", "stopped")
}
