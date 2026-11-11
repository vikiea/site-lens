package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MediaConcurrencyGateTest {
    @Test
    fun configuredLimitBoundsActiveOperations() {
        val gate = MediaConcurrencyGate(4)
        gate.configure(2)
        val active = AtomicInteger(0)
        val peak = AtomicInteger(0)
        val cancelled = AtomicBoolean(false)
        val started = CountDownLatch(4)
        val activeStarted = CountDownLatch(2)
        val finish = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(4)
        try {
            repeat(4) {
                executor.submit {
                    started.countDown()
                    gate.withPermit(cancelled) {
                        val now = active.incrementAndGet()
                        peak.updateAndGet { old -> maxOf(old, now) }
                        activeStarted.countDown()
                        finish.await()
                        active.decrementAndGet()
                    }
                }
            }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            assertTrue(activeStarted.await(5, TimeUnit.SECONDS))
            assertEquals(2, peak.get())
            finish.countDown()
        } finally {
            finish.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun lowMemorySerializesAndRecoveryWakesWaitingOperations() {
        val gate = MediaConcurrencyGate(4)
        gate.configure(4, lowMemory = true)
        val firstStarted = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondWaiting = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val first = executor.submit {
                gate.withPermit(AtomicBoolean(false)) {
                    firstStarted.countDown()
                    assertTrue(finish.await(5, TimeUnit.SECONDS))
                }
            }
            assertTrue(firstStarted.await(5, TimeUnit.SECONDS))
            val second = executor.submit {
                secondWaiting.countDown()
                gate.withPermit(AtomicBoolean(false)) {
                    secondStarted.countDown()
                }
            }
            assertTrue(secondWaiting.await(5, TimeUnit.SECONDS))
            assertFalse(secondStarted.await(100, TimeUnit.MILLISECONDS))
            gate.configure(4, lowMemory = false)
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
            finish.countDown()
            first.get(5, TimeUnit.SECONDS)
            second.get(5, TimeUnit.SECONDS)
        } finally {
            finish.countDown()
            executor.shutdownNow()
        }
    }
}
