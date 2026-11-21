package dev.vikiea.site_lens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NativeMediaSessionRouteTest {
    @Test fun localPlaybackRoutesKeepTheFileBranches() {
        assertEquals(
            NativeMediaSessionRoute.Family.LOCAL,
            NativeMediaSessionRoute.classify("file:///data/user/0/dev.vikiea.site_lens/files/play/exports/1.mp4").family,
        )
        assertEquals(
            NativeMediaSessionRoute.Family.LOCAL,
            NativeMediaSessionRoute.classify("content://com.android.providers.downloads.documents/document/42").family,
        )
        assertEquals(
            NativeMediaSessionRoute.Family.LOCAL,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.FILE,
                playableLocalFile = true,
                hasCredential = true,
            ).family,
        )
        assertEquals(
            NativeMediaSessionRoute.Family.LOCAL,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.CONTENT,
                playableLocalFile = true,
                hasCredential = true,
            ).family,
        )
    }

    @Test fun remotePlaybackRoutesAcceptOnlyPlayableHttpsAndHttpAddresses() {
        assertEquals(
            NativeMediaSessionRoute.Family.REMOTE,
            NativeMediaSessionRoute.classify("https://cdn.example.test/hls/master.m3u8?sig=1").family,
        )
        assertEquals(
            NativeMediaSessionRoute.Scheme.HTTPS,
            NativeMediaSessionRoute.classify("HTTPS://cdn.example.test/hls/master.m3u8").scheme,
        )
        assertEquals(
            NativeMediaSessionRoute.Family.REMOTE,
            NativeMediaSessionRoute.classify("http://192.0.2.10:8080/live/index.m3u8").family,
        )
    }

    @Test fun nonPlayableAddressesKeepTheLocalRejection() {
        for (raw in listOf(
            "ftp://cdn.example.test/a.mp4",
            "asset:///a.mp4",
            "https:///no-host.m3u8",
            "https:relative",
            "https://user:pass@cdn.example.test/a.mp4",
            "blob:https://cdn.example.test/3f2a1c",
            "//cdn.example.test/a.mp4",
        )) {
            assertFalse(raw, NativeMediaSessionRoute.isPlayable(raw))
            try {
                NativeMediaSessionRoute.classify(raw)
                fail("应拒绝不可播放的媒体地址：$raw")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }

    @Test fun remoteRoutesTakeNoFileLeaseAndAreNotRestorable() {
        val remote = NativeMediaSessionRoute.of(
            NativeMediaSessionRoute.Scheme.HTTPS,
            playableLocalFile = false,
            hasCredential = true,
        )
        assertEquals(NativeMediaSessionRoute.Family.REMOTE, remote.family)
        assertNull(remote.leaseForOpening("play_7_1", "https://cdn.example.test/a.m3u8", hls = true))
        assertNull(remote.leaseForOpening("play_7_1", "https://cdn.example.test/a.mp4", hls = false))
        assertFalse(remote.isRestorable)
    }

    @Test fun localRoutesTakeAFileLeaseAndStayRestorable() {
        val file = NativeMediaSessionRoute.classify("file:///tmp/site-lens/hls/index.m3u8")
        val lease = file.leaseForOpening("play_7_1", "file:///tmp/site-lens/hls/index.m3u8", hls = true)
        requireNotNull(lease)
        assertEquals(
            MediaFileLeaseRegistry.Scope.task("play_7_1") +
                MediaFileLeaseRegistry.Scope.file(java.io.File("/tmp/site-lens/hls")),
            lease,
        )
        assertEquals(
            MediaFileLeaseRegistry.Scope.task("play_7_1") +
                MediaFileLeaseRegistry.Scope.source("file:///tmp/site-lens/hls/index.m3u8"),
            file.leaseForOpening("play_7_1", "file:///tmp/site-lens/hls/index.m3u8", hls = false),
        )
        assertTrue(file.isRestorable)
        assertTrue(
            NativeMediaSessionRoute.classify("content://com.android.providers.media.documents/document/9")
                .isRestorable,
        )
    }

    @Test fun remoteLeasesStayEmptyForCertificateGatedRoutes() {
        assertNull(
            NativeMediaSessionRoute.classify("https://cdn.example.test/a.m3u8")
                .leaseForOpening("play_7_1", "https://cdn.example.test/a.m3u8", hls = true),
        )
    }

    @Test fun publicContentIsAdmittedWithoutACredential() {
        // ADR-0009：准入门槛是站点凭证，不是设置开关。没有凭证的公开内容照播；
        // 凭证只决定请求要不要注入请求头（见 SiteCredentialRemoteAdmissionTest）。
        val publicContent = NativeMediaSessionRoute.of(
            NativeMediaSessionRoute.Scheme.HTTPS,
            playableLocalFile = false,
            hasCredential = false,
        )
        assertEquals(NativeMediaSessionRoute.Family.REMOTE, publicContent.family)
        assertEquals(
            NativeMediaSessionRoute.Family.REMOTE,
            NativeMediaSessionRoute.classify("https://cdn.example.test/a.m3u8", hasCredential = false).family,
        )
    }

    @Test fun restorableRecordsAreReadBackOnlyForLocalRoutes() {
        assertTrue(
            NativeMediaSessionRoute.shouldPreserveRestorable("file:///tmp/a.mp4"),
        )
        assertTrue(
            NativeMediaSessionRoute.shouldRestore("content://p/d/1"),
        )
        assertFalse(
            NativeMediaSessionRoute.shouldPreserveRestorable("https://cdn.example.test/a.m3u8"),
        )
        assertFalse(
            NativeMediaSessionRoute.shouldRestore("https://cdn.example.test/a.m3u8"),
        )
        assertFalse(
            NativeMediaSessionRoute.shouldPreserveRestorable("ftp://cdn.example.test/a.mp4"),
        )
    }

    @Test fun remoteHlsUsesTheRemoteSourceFactoryAndLocalHlsKeepsTheGrowingReader() {
        assertEquals(
            NativeMediaSessionRoute.SourceKind.REMOTE_HTTP,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.HTTPS,
                playableLocalFile = false,
                hasCredential = true,
            ).sourceOf(isHls = true),
        )
        assertEquals(
            NativeMediaSessionRoute.SourceKind.REMOTE_HTTP_PROGRESSIVE,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.HTTP,
                playableLocalFile = false,
                hasCredential = true,
            ).sourceOf(isHls = false),
        )
        assertEquals(
            NativeMediaSessionRoute.SourceKind.LOCAL_GROWING_FILE,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.FILE,
                playableLocalFile = true,
                hasCredential = true,
            ).sourceOf(isHls = true),
        )
        assertEquals(
            NativeMediaSessionRoute.SourceKind.LOCAL_DEFAULT,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.CONTENT,
                playableLocalFile = true,
                hasCredential = true,
            ).sourceOf(isHls = true),
        )
    }

    @Test fun downloadedLocalFileWinsOverTheRemoteAddress() {
        assertEquals(
            NativeMediaSessionRoute.Family.LOCAL,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.HTTPS,
                playableLocalFile = true,
                hasCredential = true,
            ).family,
        )
        // 远程地址在已有可播放本地文件时按本地会话处理；数据源类别由**请求地址**
        // 决定——HLS 覆盖只对 file 请求生效，远程清单已落成本地文件时走默认本地源。
        assertEquals(
            NativeMediaSessionRoute.SourceKind.LOCAL_DEFAULT,
            NativeMediaSessionRoute.of(
                NativeMediaSessionRoute.Scheme.HTTPS,
                playableLocalFile = true,
                hasCredential = true,
            ).sourceOf(isHls = true),
        )
        assertEquals(
            NativeMediaSessionRoute.SourceKind.LOCAL_GROWING_FILE,
            NativeMediaSessionRoute.classify("file:///tmp/site-lens/hls/index.m3u8")
                .sourceOf(isHls = true),
        )
    }

    @Test fun remoteRoutesWithoutATaskHoldNoLeaseAtAll() {
        assertNull(
            NativeMediaSessionRoute.classify("https://cdn.example.test/a.m3u8")
                .leaseForOpening("", "https://cdn.example.test/a.m3u8", hls = true),
        )
    }
}
