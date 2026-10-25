package dev.vikiea.site_lens

import android.os.Handler
import android.os.Looper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class NativeAppRuntime(
    private val registry: NativeWebHostRegistry,
) : AppRuntimeApi {
    private val resolver = SecureDnsResolver()
    private val executor: ExecutorService = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "site-lens-runtime").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    override fun resolveSecureDns(
        provider: String,
        hostname: String,
        callback: (Result<List<String>>) -> Unit,
    ) {
        executor.execute {
            val result = runCatching { resolver.lookup(provider, hostname) }
            main.post { callback(result) }
        }
    }

    override fun clearSecureDnsCache(callback: (Result<Unit>) -> Unit) {
        executor.execute {
            val result = runCatching { resolver.clearCache() }
            main.post { callback(result) }
        }
    }

    override fun clearWebViewHttpCache(
        callback: (Result<RuntimeCacheReport>) -> Unit,
    ) {
        main.post {
            callback(
                runCatching {
                    RuntimeCacheReport(
                        registry.clearHttpCache().toLong(),
                        true,
                    )
                },
            )
        }
    }
}
