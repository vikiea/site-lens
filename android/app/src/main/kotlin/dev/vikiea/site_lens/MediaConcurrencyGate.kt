package dev.vikiea.site_lens

import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock

/** A dynamically bounded gate for memory-heavy media operations. */
internal class MediaConcurrencyGate(private val maximum: Int) {
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private var limit = 1
    private var active = 0

    fun configure(requested: Int, lowMemory: Boolean = false) {
        lock.lock()
        try {
            limit = if (lowMemory) 1 else requested.coerceIn(1, maximum)
            changed.signalAll()
        } finally {
            lock.unlock()
        }
    }

    fun <T> withPermit(cancelled: AtomicBoolean, block: () -> T): T {
        lock.lock()
        try {
            while (active >= limit) {
                check(!cancelled.get()) { "导出已取消" }
                changed.await(200, TimeUnit.MILLISECONDS)
            }
            check(!cancelled.get()) { "导出已取消" }
            active++
        } finally {
            lock.unlock()
        }
        try {
            return block()
        } finally {
            lock.lock()
            try {
                active--
                changed.signalAll()
            } finally {
                lock.unlock()
            }
        }
    }
}
