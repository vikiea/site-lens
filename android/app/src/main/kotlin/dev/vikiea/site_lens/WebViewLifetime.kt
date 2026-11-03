package dev.vikiea.site_lens

/** Keeps a native WebView alive until its current Flutter platform view releases it. */
internal class WebViewLifetime(
    private val post: (() -> Unit) -> Unit,
    private val postDelayed: (Long, () -> Unit) -> Unit,
    private val destroy: () -> Unit,
) {
    var closing = false
        private set
    private var destroyed = false
    private var owner: Int? = null
    private var destroyPosted = false
    private var destroyBarrierTurns = 0
    private var destroyBarrierInitialized = false
    private var ownerTimeoutPosted = false

    fun acquire(viewId: Int) {
        check(!closing && !destroyed) { "Web host is closing" }
        owner = viewId
    }

    /** An obsolete Flutter element must not detach a view acquired by a newer one. */
    fun release(viewId: Int): Boolean {
        if (owner != viewId) return false
        owner = null
        scheduleDestroy()
        return true
    }

    fun close(force: Boolean = false) {
        closing = true
        if (force) {
            owner = null
        } else if (owner != null) {
            scheduleOwnerTimeout()
        }
        scheduleDestroy()
    }

    /** Renderer death uses its dedicated cleanup, without live-provider calls. */
    fun rendererGone() {
        closing = true
        destroyed = true
        owner = null
    }

    private fun scheduleDestroy() {
        if (!closing || destroyed || owner != null || destroyPosted) return
        destroyPosted = true
        if (!destroyBarrierInitialized) {
            destroyBarrierInitialized = true
            destroyBarrierTurns = 2
        }
        // Always leave the provider callback and allow Flutter/Android to
        // finish the platform-view SurfaceControl transaction before touching
        // WebView teardown. Android 16/WebView 156 can abort in
        // ASurfaceTransactionStats_getPreviousReleaseFenceFd when a stale
        // completion callback observes a removed SurfaceControl.
        post {
            if (destroyed || owner != null || !closing) {
                destroyPosted = false
                return@post
            }
            if (destroyBarrierTurns > 0) {
                destroyBarrierTurns--
                destroyPosted = false
                post { scheduleDestroy() }
            } else {
                destroyPosted = false
                destroyed = true
                destroy()
            }
        }
    }

    private fun scheduleOwnerTimeout() {
        if (ownerTimeoutPosted || destroyed || !closing) return
        ownerTimeoutPosted = true
        postDelayed(PLATFORM_RELEASE_TIMEOUT_MS) {
            ownerTimeoutPosted = false
            if (!destroyed && closing && owner != null) {
                owner = null
                scheduleDestroy()
            }
        }
    }

    private companion object {
        const val PLATFORM_RELEASE_TIMEOUT_MS = 1_000L
    }
}
