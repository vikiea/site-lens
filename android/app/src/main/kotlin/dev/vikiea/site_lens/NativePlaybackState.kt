package dev.vikiea.site_lens

import androidx.media3.common.Player

internal object NativePlaybackState {
    fun resolve(previous: String, playbackState: Int, isPlaying: Boolean, playWhenReady: Boolean): String {
        if (previous == "failed" || previous == "stopped") return previous
        return when (playbackState) {
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_READY -> when {
                isPlaying -> "playing"
                !playWhenReady -> "paused"
                else -> previous
            }
            Player.STATE_ENDED -> "completed"
            Player.STATE_IDLE -> "preparing"
            else -> previous
        }
    }
}
