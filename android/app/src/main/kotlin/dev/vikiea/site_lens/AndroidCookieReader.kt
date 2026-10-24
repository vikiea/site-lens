package dev.vikiea.site_lens

import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Reads WebView cookies without calling the UI-thread-only CookieManager API from workers. */
object AndroidCookieReader {
    private const val TIMEOUT_SECONDS = 5L
    private val main = Handler(Looper.getMainLooper())

    fun get(url: String): String? {
        if (Looper.myLooper() == Looper.getMainLooper()) return read(url)
        val value = AtomicReference<String?>()
        val done = CountDownLatch(1)
        main.post {
            try {
                value.set(read(url))
            } finally {
                done.countDown()
            }
        }
        if (!done.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) return null
        return value.get()
    }

    private fun read(url: String): String? = runCatching {
        CookieManager.getInstance().getCookie(url)
    }.getOrNull()
}
