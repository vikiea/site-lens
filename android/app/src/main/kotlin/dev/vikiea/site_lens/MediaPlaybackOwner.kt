package dev.vikiea.site_lens

import android.content.Context

/** Process-wide arbitration between the WebView and the native player. */
object MediaPlaybackOwner {
    private var nativeActive = false
    private var suspendedWeb: BrowserMediaService.WebOwnerSnapshot? = null
    private var nextGeneration = 0L
    private var activeGeneration: Long? = null

    @Synchronized
    fun nativeStarted(context: Context): Long {
        val generation = ++nextGeneration
        if (!nativeActive) {
            nativeActive = true
            suspendedWeb = BrowserMediaService.suspendForNative(context)
        }
        activeGeneration = generation
        return generation
    }

    fun nativeStopped(context: Context, generation: Long) {
        synchronized(this) {
            if (!nativeActive || activeGeneration != generation) return
            nativeActive = false
            activeGeneration = null
            val previous = suspendedWeb
            suspendedWeb = null
            // Keep the ownership check and WebView restoration under the same
            // monitor as nativeStarted(). A newer native session cannot start
            // between clearing this session and restoring the Web session.
            if (previous != null && !nativeActive) {
                BrowserMediaService.restoreAfterNative(context, previous)
            }
        }
    }

    @Synchronized
    fun nativeIsActive(): Boolean = nativeActive
}
