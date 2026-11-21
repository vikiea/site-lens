package dev.vikiea.site_lens

import android.content.Context
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * 远程播放缓存（T7）：一份进程内唯一的 media3 `SimpleCache`。
 *
 * - 目录由 [NativeMediaPlaybackCachePolicy.root] 给出，在应用私有 `cacheDir`
 *   下，和下载目录不相交；缓存回收只在这个目录里发生。
 * - 回收策略是显式的：[release] 在每次播放结束后按最近访问时间把总量压回上限；
 *   `SimpleCache` 本身用 `NoOpCacheEvictor`，不在读路径上偷偷删文件。
 * - `SimpleCache` 同一时刻只能被一个实例持有，所以这里只开一个实例，播放结束
 *   之后才 [release]，下次播放再打开。
 */
internal object NativeMediaPlaybackCache {
    private val lock = Any()
    private var cacheInstance: SimpleCache? = null
    private var databaseProvider: StandaloneDatabaseProvider? = null

    /** 拿（或打开）进程内唯一的缓存实例。 */
    fun open(context: Context): SimpleCache = synchronized(lock) {
        cacheInstance ?: run {
            val app = context.applicationContext
            val root = NativeMediaPlaybackCachePolicy.root(app.cacheDir)
            root.mkdirs()
            val provider = databaseProvider ?: StandaloneDatabaseProvider(app).also {
                databaseProvider = it
            }
            SimpleCache(root, NoOpCacheEvictor(), provider).also { cacheInstance = it }
        }
    }

    /**
     * 播放结束：先释放缓存实例，再按最近访问时间回收。顺序不能反——`SimpleCache`
     * 关闭之后它才不再记索引，删文件不会和索引打架。
     */
    fun release(context: Context) {
        synchronized(lock) {
            val root = NativeMediaPlaybackCachePolicy.root(context.applicationContext.cacheDir)
            val current = cacheInstance
            if (current != null) {
                runCatching { evictOverflow(root) }
            }
            cacheInstance = null
            runCatching { current?.release() }
        }
    }

    /**
     * 用户清除缓存：只删 media3 写下的条目，不改下载目录。
     *
     * 正在播的那一份由播放自己持有，清除只针对已经落在磁盘上的条目。返回清除
     * 前后的字节数，供调用方如实回报。
     */
    fun clear(context: Context): Pair<Long, Long> = synchronized(lock) {
        val root = NativeMediaPlaybackCachePolicy.root(context.applicationContext.cacheDir)
        val before = sizeOf(root)
        runCatching { cacheInstance?.release() }
        cacheInstance = null
        NativeMediaPlaybackCachePolicy.purgePlan(root).forEach { runCatching { it.delete() } }
        before to sizeOf(root)
    }

    /** 当前缓存总量，单位字节。 */
    fun sizeBytes(context: Context): Long {
        synchronized(lock) {
            return sizeOf(NativeMediaPlaybackCachePolicy.root(context.applicationContext.cacheDir))
        }
    }

    /**
     * 远程数据来源：先查缓存，命中就不再发网络请求；未命中的分片边读边写进
     * 缓存。`FLAG_IGNORE_CACHE_ON_ERROR` 让坏缓存退回网络而不是播不出来。
     */
    fun dataSourceFactory(context: Context, upstream: DataSource.Factory): DataSource.Factory {
        val cache = open(context)
        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstream)
            .setFlags(
                CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR or
                    CacheDataSource.FLAG_BLOCK_ON_CACHE,
            )
    }

    private fun sizeOf(root: File): Long =
        root.takeIf { it.isDirectory }
            ?.walkTopDown()
            ?.filter { it.isFile }
            ?.sumOf { it.length() } ?: 0L

    /**
     * 按最近访问时间回收：`evict` 给出要删的足迹，这里只负责删。调用方已经
     * 释放 `SimpleCache`，它不再持有这些文件的索引。
     */
    private fun evictOverflow(root: File) {
        val victims = NativeMediaPlaybackCachePolicy.evict(
            NativeMediaPlaybackCachePolicy.spansOf(root),
        )
        victims.forEach { runCatching { File(it.identity).delete() } }
    }
}
