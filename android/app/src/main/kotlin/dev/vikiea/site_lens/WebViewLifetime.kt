package dev.vikiea.site_lens

/** Keeps a native WebView alive until its current Flutter platform view releases it. */
internal class WebViewLifetime(
    private val post: (() -> Unit) -> Unit,
    private val destroy: () -> Unit,
) {
    var closing = false
        private set
    private var destroyed = false
    private var owner: Int? = null
    private var destroyPosted = false

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
        if (force) owner = null
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
        // Always leave the provider callback before touching WebView teardown.
        post {
            destroyPosted = false
            if (!destroyed && owner == null) {
                destroyed = true
                destroy()
            }
        }
    }
}
