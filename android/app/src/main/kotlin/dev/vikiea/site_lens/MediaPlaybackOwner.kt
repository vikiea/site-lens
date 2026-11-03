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

    @Synchronized
    fun nativeStopped(context: Context, generation: Long) {
        if (!nativeActive || activeGeneration != generation) return
        nativeActive = false
        activeGeneration = null
        val snapshot = suspendedWeb
        suspendedWeb = null
        if (snapshot != null) BrowserMediaService.restoreAfterNative(context, snapshot)
    }

    @Synchronized
    fun nativeIsActive(): Boolean = nativeActive
}
