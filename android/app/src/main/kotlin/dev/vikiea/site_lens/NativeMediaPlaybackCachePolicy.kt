package dev.vikiea.site_lens

import java.io.File
import java.net.URI
import java.security.MessageDigest
import java.util.Locale

/**
 * 远程播放缓存层的位置、键与回收策略（T7）。
 *
 * 三条不变量由这个对象单独表达，服务只照着执行：
 *
 * 1. **缓存与下载分目录**。缓存在应用私有 `cacheDir/media_playback_cache`，
 *    下载在外部 `Download/site-lens`。目录不相交，清缓存走不到下载目录。
 * 2. **同一份字节只归一边**。下载任务登记的远端路径与这次请求的路径互相
 *    包含时，这次播放不进缓存、只读远端（[admitPlayback]）；缓存目录里因此
 *    不会出现与下载同源的一份。
 * 3. **缓存键带站点身份**。键里含档案与站点，两个档案的同名路径不会互相命中。
 *
 * 这一层不处理失败，也不建任务（工单 #19）。
 */
object NativeMediaPlaybackCachePolicy {
    /** 缓存目录名；位于 `cacheDir` 下，系统可回收，与下载目录无交集。 */
    const val DIRECTORY = "media_playback_cache"

    /** 容量上限：超过后按最近使用时间回收。 */
    const val MAX_BYTES = 512L * 1024L * 1024L

    /** 回收目标：低于它就不再删，留一段余量，不至于每次播放结束都扫到极限。 */
    const val TARGET_BYTES = 384L * 1024L * 1024L

    /** 缓存目录里只认 media3 `SimpleCache` 自己的文件，其余一概不动。 */
    private val MANAGED_FILES = listOf(
        "index",
        "index.lock",
        "content_index",
        "content_index.lock",
    )

    /**
     * 站点身份：一次播放请求里能确定「属于哪个站点」的全部输入。
     *
     * 档案来自请求，站点来自远程地址的 host。公开内容没有档案，用 -1 表示，
     * 与「另一个档案」仍然分开。
     */
    data class Station(val profileId: Int, val host: String) {
        /** 缓存键的前缀；不以分隔符结尾，由 [ContentKey] 负责拼接。 */
        val prefix: String get() = "profile=$profileId|host=$host"

        companion object {
            fun of(profileId: Int, raw: String): Station {
                val host = runCatching { URI(raw).host }
                    .getOrNull()
                    ?.lowercase(Locale.ROOT)
                    ?.takeIf { it.isNotBlank() }
                    ?: "invalid"
                return Station(profileId.coerceAtLeast(-1), host)
            }
        }
    }

    /** 缓存键：站点身份 + 远端路径（不含 query）。 */
    object ContentKey {
        /**
         * query 不参与：站点常给同一份分片挂不同的短期令牌，按 query 分键会把
         * 缓存拆碎；真正区分资源的档案与 host 已经在前缀里。
         */
        fun of(station: Station, raw: String): String =
            "${station.prefix}|${remotePath(raw)}"

        fun hash(key: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02x".format(it) }
        }

        private fun remotePath(raw: String): String = runCatching {
            val uri = URI(raw)
            buildString {
                append(uri.rawPath?.takeIf { it.isNotEmpty() } ?: "/")
                uri.rawFragment?.takeIf { it.isNotEmpty() }?.let { append('#').append(it) }
            }
        }.getOrElse { raw }
    }

    /**
     * 这次远程播放能不能进缓存。
     *
     * 整集已被某个下载任务拥有时，播放直接读远端：不缓存、不争同一份字节，
     * 下载与播放因此互不干扰（工单验收 2、3）。
     */
    fun admitPlayback(raw: String, downloadPaths: List<String>): Boolean =
        !ownedByDownload(raw, downloadPaths)

    /**
     * 下载任务已经拥有的字节。
     *
     * 下载队列以 Dart 的 `cacheKey` 作主键，播放这边的键是按站点身份算的
     * 摘要，两者本来对不上；能对上的是**远端路径**。所以判定用「下载任务
     * 的地址路径 ⊆ 这次播放的路径」：整集或它的某个变体已经在下载，播放就
     * 不缓存这段字节，只读远端。宁可少缓存，也不让同一份字节落在两份存储里。
     */
    fun downloadPaths(urls: Iterable<String>): List<String> = urls.mapNotNull { raw ->
        runCatching { URI(raw).rawPath }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    /**
     * 这次请求的字节是否已归某个下载任务。
     *
     * 两个方向都算：分片落在下载的目录下（整集下载），或者下载的地址落在
     * 这次请求的目录下（播放的是清单、下载的是它的某个分片）。任一方向命中
     * 都不缓存——少缓存一次可以接受，同一份字节写两处不可以。
     */
    fun ownedByDownload(raw: String, downloadPaths: List<String>): Boolean {
        val path = runCatching { URI(raw).rawPath }.getOrNull()?.takeIf { it.isNotBlank() }
            ?: return false
        val directory = path.substringBeforeLast('/', "")
        return downloadPaths.any { owned ->
            path == owned ||
                path.startsWith(owned.trimEnd('/') + '/') ||
                directory.startsWith(owned.trimEnd('/') + '/') ||
                owned.startsWith(directory.trimEnd('/') + '/')
        }
    }

    /** 缓存根目录；不创建，创建交给 media3 自己的 `SimpleCache`。 */
    fun root(cacheDir: File): File = File(cacheDir, DIRECTORY)

    /**
     * 回收计划：按「最近使用」从旧到新挑出要删的足迹，直到剩下的总量落进
     * [targetBytes]。最近使用的那一份不论多大都保留，否则正在播的那份会被
     * 自己回收。只按最近使用时间排序（media3 每次读都会 touch 文件），不看
     * 文件名。这里只决定删谁，真正删文件由调用方在缓存实例关闭后执行。
     */
    fun evict(
        spans: List<Span>,
        maxBytes: Long = MAX_BYTES,
        targetBytes: Long = TARGET_BYTES,
    ): List<Span> {
        val managed = spans.filter { it.managed }
        if (managed.sumOf { it.bytes } <= maxBytes) return emptyList()
        val keep = managed.maxWithOrNull(
            compareBy<Span> { it.lastUsedMs }.thenBy { it.bytes }.thenByDescending { it.identity },
        )
        var live = managed.sumOf { it.bytes }
        val victims = mutableListOf<Span>()
        for (span in managed.sortedWith(compareBy<Span> { it.lastUsedMs }.thenBy { it.identity })) {
            if (live <= targetBytes) break
            if (keep != null && span.identity == keep.identity) continue
            victims += span
            live -= span.bytes
        }
        return victims
    }

    data class Span(val identity: String, val bytes: Long, val lastUsedMs: Long, val managed: Boolean)

    /**
     * 把目录里的条目映射成回收足迹。
     *
     * 只映射 media3 `SimpleCache` 自己的东西：两份索引与每个键一个的 span 文件
     * （可能带 `.vN` 后缀）。本地播放列表副本这类副本目录、临时文件（`.` 开头）
     * 都不管理，既不计数也不删除——清缓存走不到它们。
     */
    fun spansOf(root: File): List<Span> {
        val entries = root.listFiles() ?: return emptyList()
        return entries.mapNotNull { entry ->
            val name = entry.name
            val managed = isManagedEntry(name)
            Span(
                identity = entry.absolutePath,
                bytes = if (entry.isDirectory) directoryBytes(entry) else entry.length(),
                lastUsedMs = entry.lastModified(),
                managed = managed,
            )
        }
    }

    private fun isManagedEntry(name: String): Boolean =
        name in MANAGED_FILES || (name.isNotEmpty() && !name.startsWith("."))

    private fun directoryBytes(directory: File): Long =
        directory.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    /** 清缓存要删的条目：只由 media3 写入的那些。不管理的一律留下。 */
    fun purgePlan(root: File): List<File> =
        (root.listFiles() ?: emptyArray()).filter { isManagedEntry(it.name) }

    /** 缓存目录与下载目录互不相交；相交说明配置错了，调用方据此拒绝写入缓存。 */
    fun overlapsDownloadRoot(cacheRoot: File, downloadRoot: File): Boolean {
        val cache = runCatching { cacheRoot.canonicalPath }.getOrDefault(cacheRoot.absolutePath)
        val download = runCatching { downloadRoot.canonicalPath }.getOrDefault(downloadRoot.absolutePath)
        return cache == download ||
            cache.startsWith(download + File.separator) ||
            download.startsWith(cache + File.separator)
    }
}
