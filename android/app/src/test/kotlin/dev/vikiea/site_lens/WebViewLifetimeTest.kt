package dev.vikiea.site_lens

import org.junit.Assert.*
import org.junit.Test

class WebViewLifetimeTest {
    private val queued = ArrayDeque<() -> Unit>()
    private var destroys = 0
    private val lifetime = WebViewLifetime({ queued.addLast(it) }, { destroys++ })

    private fun drain() {
        while (queued.isNotEmpty()) queued.removeFirst().invoke()
    }

    @Test fun closeWaitsForFlutterReleaseAndLeavesTheCallback() {
        lifetime.acquire(7)
        lifetime.close()
        drain()
        assertTrue(lifetime.closing)
        assertEquals(0, destroys)
        assertTrue(lifetime.release(7))
        assertEquals(0, destroys)
        drain()
        assertEquals(1, destroys)
    }

    @Test fun obsoletePlatformViewCannotDetachTheNewOwner() {
        lifetime.acquire(7)
        lifetime.acquire(8)
        lifetime.close()
        assertFalse(lifetime.release(7))
        drain()
        assertEquals(0, destroys)
        assertTrue(lifetime.release(8))
        drain()
        assertEquals(1, destroys)
    }

    @Test fun closeWithoutAPlatformViewIsDeferredAndIdempotent() {
        lifetime.close()
        lifetime.close()
        assertEquals(0, destroys)
        assertEquals(1, queued.size)
        drain()
        lifetime.close()
        drain()
        assertEquals(1, destroys)
    }

    @Test fun engineShutdownReleasesAnOutstandingOwner() {
        lifetime.acquire(1)
        lifetime.close()
        lifetime.close(force = true)
        assertEquals(0, destroys)
        drain()
        assertEquals(1, destroys)
    }

    @Test fun rendererDeathCancelsPendingLiveProviderCleanup() {
        lifetime.close()
        lifetime.rendererGone()
        drain()
        assertEquals(0, destroys)
    }

    @Test fun closedHostsCannotAcquireAnotherPlatformView() {
        lifetime.close()
        assertThrows(IllegalStateException::class.java) { lifetime.acquire(1) }
    }

    @Test fun switchingTabsKeepsTheUnselectedHostAlive() {
        lifetime.acquire(1)
        assertTrue(lifetime.release(1))
        drain()
        assertEquals(0, destroys)
        lifetime.acquire(2)
        assertFalse(lifetime.closing)
    }
}
