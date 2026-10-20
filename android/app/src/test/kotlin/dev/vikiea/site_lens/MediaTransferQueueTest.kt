package dev.vikiea.site_lens

import java.io.InterruptedIOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class MediaTransferQueueTest {
    @Test fun queuedCancellationCompletesBeforeOccupiedWorkersFinish() {
        val executor = Executors.newFixedThreadPool(2)
        val occupied = CountDownLatch(2)
        val release = CountDownLatch(1)
        try {
            val queue = MediaTransferQueue(executor)
            repeat(2) { index ->
                queue.submit("active-$index", {}, { occupied.countDown(); release.await() }, {})
            }
            assertTrue(occupied.await(2, TimeUnit.SECONDS))
            val complete = CountDownLatch(1)
            val calls = AtomicInteger()
            val writes = AtomicInteger()
            queue.submit("waiting", {}, { writes.incrementAndGet() }) {
                assertTrue(it.exceptionOrNull() is InterruptedIOException)
                calls.incrementAndGet()
                complete.countDown()
            }
            queue.cancel("waiting")
            assertTrue(complete.await(1, TimeUnit.SECONDS))
            assertEquals(1L, release.count)
            assertEquals(0, writes.get())
            release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS))
            assertEquals(1, calls.get())
            assertEquals(0, writes.get())
        } finally { release.countDown(); executor.shutdownNow() }
    }

    @Test fun runningCancellationDrainsBeforeCompletingAndDoesNotCancelNextJob() {
        val executor = Executors.newSingleThreadExecutor()
        val started = CountDownLatch(1)
        val abort = CountDownLatch(1)
        val release = CountDownLatch(1)
        val complete = CountDownLatch(1)
        try {
            val queue = MediaTransferQueue(executor)
            queue.submit("same", { abort.countDown() }, {
                started.countDown()
                release.await()
                throw InterruptedIOException("cancelled")
            }) { complete.countDown() }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            queue.cancel("same")
            assertEquals(0L, abort.count)
            assertEquals(1L, complete.count)
            release.countDown()
            assertTrue(complete.await(2, TimeUnit.SECONDS))
            val next = CountDownLatch(1)
            queue.submit("same", { fail("stale cancellation") }, {}) {
                assertTrue(it.isSuccess)
                next.countDown()
            }
            assertTrue(next.await(2, TimeUnit.SECONDS))
        } finally { release.countDown(); executor.shutdownNow() }
    }
}
