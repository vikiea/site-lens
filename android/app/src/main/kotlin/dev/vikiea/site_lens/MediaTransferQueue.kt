package dev.vikiea.site_lens

import java.io.InterruptedIOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor

/** Registers ownership before enqueueing so a waiting transfer can be stopped. */
class MediaTransferQueue(private val executor: Executor) {
    private val jobs = ConcurrentHashMap<String, Job>()

    fun submit(id: String, abort: () -> Unit, action: () -> Unit, complete: (Result<Unit>) -> Unit) {
        val job = Job(id, abort, complete)
        require(jobs.putIfAbsent(id, job) == null) { "下载任务已在运行" }
        try {
            executor.execute {
                if (!job.start()) return@execute
                job.finish(runCatching(action))
            }
        } catch (error: Exception) {
            job.finish(Result.failure(error))
        }
    }

    fun cancel(id: String) { jobs[id]?.cancel() }

    private inner class Job(
        val id: String,
        val abort: () -> Unit,
        val complete: (Result<Unit>) -> Unit,
    ) {
        private var started = false
        private var finished = false

        @Synchronized fun start(): Boolean {
            if (finished) return false
            started = true
            return true
        }

        @Synchronized fun cancel() {
            if (finished) return
            abort()
            // Running work must stop touching its partial file before Dart
            // resumes/deletes it. Queued work has no bytes to drain.
            if (!started) finish(Result.failure(InterruptedIOException("下载已暂停")))
        }

        @Synchronized fun finish(outcome: Result<Unit>) {
            if (finished) return
            finished = true
            jobs.remove(id, this)
            complete(outcome)
        }
    }
}
