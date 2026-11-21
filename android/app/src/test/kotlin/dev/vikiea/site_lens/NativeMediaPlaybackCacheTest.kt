package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * T7：远程播放缓存的键、归属与回收。
 *
 * 这三件事决定「同一份字节只归一边」：键带站点身份（不串档）、下载拥有的
 * 字节不进缓存（不抢）、回收只按最近使用且不碰最近用过的那份（不误删）。
 */
class NativeMediaPlaybackCacheTest {
    private val station = "https://cdn.example.test"

    private fun span(identity: String, bytes: Long, lastUsedMs: Long, managed: Boolean = true) =
        NativeMediaPlaybackCachePolicy.Span(identity, bytes, lastUsedMs, managed)

    @Test fun theCacheKeyCarriesTheProfileAndTheStation() {
        val first = NativeMediaPlaybackCachePolicy.Station.of(7, "$station/hls/seg-1.ts")
        val second = NativeMediaPlaybackCachePolicy.Station.of(8, "$station/hls/seg-1.ts")
        assertNotEquals(first, second)
        assertNotEquals(
            NativeMediaPlaybackCachePolicy.ContentKey.of(first, "$station/hls/seg-1.ts"),
            NativeMediaPlaybackCachePolicy.ContentKey.of(second, "$station/hls/seg-1.ts"),
        )
        assertTrue(first.prefix.contains("profile=7"))
        assertTrue(first.prefix.contains("host=cdn.example.test"))
    }

    @Test fun theSamePathOnAnotherStationNeverHitsTheSameEntry() {
        val path = "/hls/seg-1.ts"
        val one = NativeMediaPlaybackCachePolicy.ContentKey.hash(
            NativeMediaPlaybackCachePolicy.ContentKey.of(
                NativeMediaPlaybackCachePolicy.Station.of(7, "https://one.example.test$path"),
                "https://one.example.test$path",
            ),
        )
        val two = NativeMediaPlaybackCachePolicy.ContentKey.hash(
            NativeMediaPlaybackCachePolicy.ContentKey.of(
                NativeMediaPlaybackCachePolicy.Station.of(7, "https://two.example.test$path"),
                "https://two.example.test$path",
            ),
        )
        assertNotEquals(one, two)
    }

    @Test fun shortLivedQueryTokensDoNotSplitOneFragmentIntoTwoEntries() {
        val key = NativeMediaPlaybackCachePolicy.Station.of(7, "$station/hls/seg-1.ts?token=a")
        assertEquals(
            NativeMediaPlaybackCachePolicy.ContentKey.of(key, "$station/hls/seg-1.ts?token=a"),
            NativeMediaPlaybackCachePolicy.ContentKey.of(key, "$station/hls/seg-1.ts?token=b"),
        )
    }

    @Test fun aFragmentAlreadyOwnedByADownloadNeverEntersTheCache() {
        val downloads = NativeMediaPlaybackCachePolicy.downloadPaths(
            listOf("$station/hls/index.m3u8", "$station/hls/seg-1.ts"),
        )
        assertFalse(NativeMediaPlaybackCachePolicy.admitPlayback("$station/hls/seg-1.ts", downloads))
        // 播放清单、下载它下面的分片：两边仍然是同一份字节。
        assertFalse(NativeMediaPlaybackCachePolicy.admitPlayback("$station/hls/index.m3u8", downloads))
        // 另一集不进下载的目录，照常缓存。
        assertTrue(NativeMediaPlaybackCachePolicy.admitPlayback("$station/other/seg-9.ts", downloads))
        assertTrue(NativeMediaPlaybackCachePolicy.admitPlayback("$station/hls/seg-1.ts", emptyList()))
    }

    @Test fun evictionKeepsTheMostRecentlyUsedEntryAndStopsAtTheTarget() {
        val spans = listOf(
            span("/c/old", 40, 1),
            span("/c/middle", 40, 2),
            span("/c/playing", 40, 3),
        )
        val victims = NativeMediaPlaybackCachePolicy.evict(
            spans,
            maxBytes = 100,
            targetBytes = 50,
        )
        assertEquals(listOf("/c/old", "/c/middle"), victims.map { it.identity })
        // 最近使用的那一份即使一个人就超过目标，也不会被回收。
        val alone = listOf(span("/c/huge", 500, 9))
        assertTrue(
            NativeMediaPlaybackCachePolicy.evict(alone, maxBytes = 100, targetBytes = 50).isEmpty(),
        )
    }

    @Test fun nothingIsEvictedBelowTheLimitAndUnmanagedEntriesAreNeverChosen() {
        val spans = listOf(
            span("/c/a", 40, 1),
            span("/c/foreign-download", 400, 0, managed = false),
        )
        assertTrue(
            NativeMediaPlaybackCachePolicy.evict(spans, maxBytes = 1024, targetBytes = 512).isEmpty(),
        )
        val victims = NativeMediaPlaybackCachePolicy.evict(spans, maxBytes = 10, targetBytes = 1)
        assertEquals(listOf("/c/a"), victims.map { it.identity })
    }

    @Test fun theCacheDirectoryIsItsOwnAndNeverInsideTheDownloadRoot() {
        val cacheDir = File("/data/user/0/dev.vikiea.site_lens/cache")
        val cache = NativeMediaPlaybackCachePolicy.root(cacheDir)
        val downloads = File("/storage/emulated/0/Download/site-lens")
        assertFalse(NativeMediaPlaybackCachePolicy.overlapsDownloadRoot(cache, downloads))
        assertTrue(
            NativeMediaPlaybackCachePolicy.overlapsDownloadRoot(
                File(downloads, "media_playback_cache"),
                downloads,
            ),
        )
        assertTrue(NativeMediaPlaybackCachePolicy.overlapsDownloadRoot(downloads, downloads))
    }

    @Test fun clearingASpanListOnlyNamesEntriesMedia3Wrote() {
        val root = createTempDir("cache")
        try {
            File(root, "index").writeText("i")
            File(root, "abc123.0").writeText("s")
            File(root, ".tmp").writeText("t")
            File(root, "exports").mkdirs()
            val planned = NativeMediaPlaybackCachePolicy.purgePlan(root).map { it.name }.sorted()
            assertEquals(listOf("abc123.0", "index"), planned)
            assertFalse(File(root, "exports").deleted())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun File.deleted(): Boolean = !exists()

    private fun createTempDir(prefix: String): File {
        val dir = File.createTempFile(prefix, "")
        dir.delete()
        dir.mkdirs()
        return dir
    }
}
