package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Test

class HostEventDispatcherTest {
    private class Harness {
        var main = true
        var generation = 1L
        var epoch = 0L
        var destroyed = false
        val pending = mutableListOf<() -> Unit>()
        val delivered = mutableListOf<String>()
        val dispatcher = HostEventDispatcher(
            isMainThread = { main },
            post = { pending.add(it) },
            isCurrent = { ticket, host -> !destroyed && generation == ticket && epoch == host },
        )
        fun send(value: String) = dispatcher.dispatch(generation, epoch) { delivered.add(value) }
        fun drain() {
            main = true
            pending.toList().also { pending.clear() }.forEach { it() }
        }
    }

    @Test fun rendererInvalidationArrivesBeforeSynchronousCleanup() {
        val h = Harness()
        h.send("hostInvalidated")
        h.destroyed = true
        h.epoch++
        assertEquals(listOf("hostInvalidated"), h.delivered)
        assertEquals(0, h.pending.size)
    }

    @Test fun workerEventsAreQueuedInOrderAndDeliveredOnMain() {
        val h = Harness()
        h.main = false
        h.send("filtered")
        h.send("filterStats")
        assertEquals(emptyList<String>(), h.delivered)
        h.drain()
        assertEquals(listOf("filtered", "filterStats"), h.delivered)
    }

    @Test fun navigationDropsQueuedEventsFromPreviousDocument() {
        val h = Harness()
        h.main = false
        h.send("old")
        h.generation++
        h.send("new")
        h.drain()
        assertEquals(listOf("new"), h.delivered)
    }

    @Test fun closingHostDropsQueuedEventsEvenWhenGenerationMatches() {
        val h = Harness()
        h.main = false
        h.send("old")
        h.epoch++
        h.drain()
        assertEquals(emptyList<String>(), h.delivered)
    }

    @Test fun destroyedHostNeverDeliversQueuedOrDirectEvents() {
        val h = Harness()
        h.main = false
        h.send("queued")
        h.destroyed = true
        h.drain()
        h.send("direct")
        assertEquals(emptyList<String>(), h.delivered)
    }
}
