package dev.vikiea.site_lens

/** Keeps UI callbacks synchronous and rejects stale work queued by WebView workers. */
internal class HostEventDispatcher(
    private val isMainThread: () -> Boolean,
    private val post: (() -> Unit) -> Unit,
    private val isCurrent: (Long, Long) -> Boolean,
) {
    fun dispatch(generation: Long, epoch: Long, send: () -> Unit) {
        val delivery = {
            if (isCurrent(generation, epoch)) send()
        }
        if (isMainThread()) delivery() else post(delivery)
    }
}
